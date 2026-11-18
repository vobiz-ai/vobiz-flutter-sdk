// REGISTER: the granted lifetime, 423, failures and timeouts, closing the
// socket on failure, and unregistering on disconnect.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'sip_test_support.dart';

const String _challenge = 'WWW-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n1", qop="auth"';

void main() {
  late List<String> sent;
  late SIPService s;
  late List<String> failures;
  late int registered;

  setUp(() {
    sent = <String>[];
    failures = <String>[];
    registered = 0;
    s = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
      ..debugOnSend = sent.add
      ..onRegistrationFailed = failures.add
      ..onRegistered = () => registered++;
  });

  group('lifetime (#22)', () {
    test('asks for registerExpires, not a hard-coded hour', () {
      s.register('play1', 'secret');
      expect(headerOf(sent.single, 'Expires'), '3600', reason: 'an hour: how long a closed app stays reachable by push');
      final custom = SIPService(wsUrl: 'wss://t', sipServer: 'r', registerExpires: 120)
        ..debugOnSend = sent.add;
      custom.register('play1', 'secret');
      expect(headerOf(sent.last, 'Expires'), '120');
    });

    test('refreshes at 80% of the lifetime the registrar granted on our Contact', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.single, 200, 'OK', headers: <String>[
        'Contact: <sip:someone-else@x.invalid;transport=ws>;expires=3600',
        'Contact: <${s.contactUri}>;expires=300',
        'Expires: 3600',
      ]));
      expect(s.registrationState.value, SipRegistrationState.registered);
      expect(s.registrationRefreshDelay, const Duration(seconds: 240));
    });

    test('falls back to the Expires header, then to what was asked', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK', headers: <String>['Expires: 90']));
      expect(s.registrationRefreshDelay, const Duration(seconds: 72));
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK'));
      expect(s.registrationRefreshDelay, const Duration(seconds: 2880));
    });

    test('the refresh REGISTER goes out when it is due and keeps the state registered', () async {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK', headers: <String>['Expires: 1']));
      sent.clear();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(methods(sent), <String>['REGISTER']);
      expect(s.registrationState.value, SipRegistrationState.registered);
    });

    test('423 Interval Too Brief: asks again with Min-Expires', () {
      s.register('play1', 'secret');
      // A minimum above what was asked (an hour), as a 423 carries.
      s.debugReceive(respond(sent.last, 423, 'Interval Too Brief', headers: <String>['Min-Expires: 7200']));
      expect(headerOf(sent.last, 'Expires'), '7200');
      expect(failures, isEmpty);
      s.debugReceive(respond(sent.last, 200, 'OK'));
      expect(registered, 1);
      expect(s.registrationRefreshDelay, const Duration(seconds: 5760));
    });
  });

  group('failures (#22, #16)', () {
    test('a 5xx fails the registration with its code', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 503, 'Service Unavailable'));
      expect(s.registrationState.value, SipRegistrationState.failed);
      expect(failures.single, 'Registration failed (503 Service Unavailable)');
    });

    test('a 404 fails it too', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 404, 'Not Found'));
      expect(failures.single, contains('404'));
    });

    test('no answer within Timer F fails it', () async {
      s.transactionTimeout = const Duration(milliseconds: 20);
      s.register('play1', 'secret');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(s.registrationState.value, SipRegistrationState.failed);
      expect(failures.single, contains('timed out'));
    });

    test('a provisional response is not a final one', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 100, 'Trying', toTag: ''));
      expect(s.registrationState.value, SipRegistrationState.registering);
      expect(failures, isEmpty);
    });

    test('401 after the auth answer is a wrong password', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 401, 'Unauthorized', headers: <String>[_challenge]));
      expect(headerOf(sent.last, 'Authorization'), startsWith('Digest '));
      s.debugReceive(respond(sent.last, 401, 'Unauthorized', headers: <String>[_challenge]));
      expect(failures.single, contains('wrong password'));
      expect(sent.where((m) => m.startsWith('REGISTER')), hasLength(2));
    });

    test('401 with stale=true after the auth answer is answered again, not called a wrong password', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 401, 'Unauthorized', headers: <String>[_challenge]));
      s.debugReceive(respond(sent.last, 401, 'Unauthorized', headers: <String>['$_challenge, stale=true']));
      expect(failures, isEmpty);
      expect(sent.where((m) => m.startsWith('REGISTER')), hasLength(3));
      s.debugReceive(respond(sent.last, 200, 'OK'));
      expect(registered, 1);
    });

    test('a 200 for some other REGISTER (wrong branch and CSeq) is ignored', () {
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK')
          .replaceFirst(branchOf(sent.last), 'z9hG4bKold')
          .replaceFirst(RegExp(r'CSeq: \d+'), 'CSeq: 999'));
      expect(registered, 0);
      expect(s.registrationState.value, SipRegistrationState.registering);
    });
  });

  group('the socket after a failed registration (#53)', () {
    test('403 closes the socket without reporting a socket error', () async {
      final socket = FakeSocket();
      final socketErrors = <String>[];
      s
        ..onSocketError = socketErrors.add
        ..debugAttachSocket(socket);
      s.register('play1', 'secret');
      expect(socket.fakeSink.sent, hasLength(1));
      s.debugReceive(respond(sent.last, 403, 'Forbidden'));
      expect(socket.fakeSink.closed, isTrue);
      expect(s.connectionState.value, SipConnectionState.disconnected);
      await socket.incoming.close();
      await Future<void>.delayed(Duration.zero);
      expect(socketErrors, isEmpty);
    });

    test('during a call the socket stays up until the call ends', () {
      final socket = FakeSocket();
      s.debugAttachSocket(socket);
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK'));
      s.debugReceive(inboundInvite());
      s.answer('v=0');
      // A refresh that is refused.
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 403, 'Forbidden'));
      expect(socket.fakeSink.closed, isFalse);
      s.hangup();
      expect(methods(socket.fakeSink.sent).last, 'BYE');
      expect(socket.fakeSink.closed, isTrue);
    });
  });

  group('disconnect() unregisters (#27)', () {
    test('sends REGISTER Expires: 0 on the socket, waits for the answer, then closes', () async {
      final socket = FakeSocket();
      s.debugAttachSocket(socket);
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK'));
      sent.clear();
      var done = false;
      final closing = s.disconnect().then((_) => done = true);
      expect(s.connectionState.value, SipConnectionState.disconnected);
      expect(s.registrationState.value, SipRegistrationState.unregistered);
      final unregister = socket.fakeSink.sent.last;
      expect(firstLine(unregister), 'REGISTER sip:registrar.vobiz.ai SIP/2.0');
      expect(headerOf(unregister, 'Expires'), '0');
      expect(headerOf(unregister, 'Contact'), '<${s.contactUri}>');
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      expect(socket.fakeSink.closed, isFalse);

      // The registrar challenges the unregistration too; it is answered on
      // the same socket.
      socket.incoming.add(respond(unregister, 401, 'Unauthorized', headers: <String>[_challenge]));
      await Future<void>.delayed(Duration.zero);
      final answered = socket.fakeSink.sent.last;
      expect(headerOf(answered, 'Authorization'), startsWith('Digest '));
      expect(headerOf(answered, 'Expires'), '0');

      socket.incoming.add(respond(answered, 200, 'OK'));
      await closing;
      expect(socket.fakeSink.closed, isTrue);
      expect(registered, 1, reason: 'the 200 to the unregistration is not a registration');
      expect(s.registrationState.value, SipRegistrationState.unregistered);
    });

    test('closes anyway when the registrar does not answer in time', () async {
      final socket = FakeSocket();
      s
        ..unregisterTimeout = const Duration(milliseconds: 20)
        ..debugAttachSocket(socket);
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK'));
      await s.disconnect();
      expect(headerOf(socket.fakeSink.sent.last, 'Expires'), '0');
      expect(socket.fakeSink.closed, isTrue);
    });

    test('ends an answered call with BYE before unregistering', () async {
      final socket = FakeSocket();
      s
        ..unregisterTimeout = const Duration(milliseconds: 10)
        ..debugAttachSocket(socket);
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK'));
      s.debugReceive(inboundInvite());
      s.answer('v=0');
      sent.clear();
      await s.disconnect();
      expect(methods(sent), <String>['BYE', 'REGISTER']);
    });

    test('without a registration it just closes', () async {
      final socket = FakeSocket();
      s.debugAttachSocket(socket);
      await s.disconnect();
      expect(socket.fakeSink.sent, isEmpty);
      expect(socket.fakeSink.closed, isTrue);
    });
  });
}
