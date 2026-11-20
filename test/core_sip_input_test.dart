// Every value the SDK writes into a SIP message is checked first: the dialled
// destination, the sign-in user name, the access token, a push's hold
// reference. And whatever arrives on the socket (binary frames, malformed
// messages, odd caller IDs) is read without throwing out of the listener.
// ignore_for_file: implementation_imports
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';
import 'sip_test_support.dart';

/// A Vobiz-shaped access token; the device does not check its signature.
String _token({required String sub, String iss = 'MA_TESTACCT'}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part(<String, String>{'alg': 'HS256', 'typ': 'JWT'})}'
      '.${part(<String, Object?>{'iss': iss, 'sub': sub, 'nbf': now - 60, 'exp': now + 3600})}.c2ln';
}

/// An INVITE whose caller is described by [from] (and [pai], when given).
String _inviteFrom(String from, {String? pai}) => 'INVITE sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKcid\r\n'
    'From: $from\r\n'
    '${pai == null ? '' : 'P-Asserted-Identity: $pai\r\n'}'
    'To: <sip:play1@registrar.vobiz.ai>\r\n'
    'Call-ID: cid-1\r\nCSeq: 1 INVITE\r\n'
    'Content-Type: application/sdp\r\nContent-Length: 3\r\n\r\nv=0';

void main() {
  group('the dialled destination', () {
    test('a space, a line break or a URI delimiter is refused before anything is sent', () async {
      final h = Harness();
      for (final bad in <String>[
        '123\r\nX-VH-Record: true',
        '12 34',
        'a@evil.example',
        'a>;x=1',
        '"quoted"',
        'sip:alice',
        '919\u000080',
      ]) {
        await expectLater(h.client.makeCall(bad), throwsArgumentError, reason: bad);
      }
      expect(h.sent, isEmpty);
      expect(h.client.callState, CallStateStatus.idle);
      await h.dispose();
    });

    test('numbers and endpoint usernames still dial', () async {
      final h = Harness();
      await h.dial('alice_MA1.x-y+z');
      expect(firstLine(h.sent.lastWhere((m) => m.startsWith('INVITE '))),
          'INVITE sip:alice_MA1.x-y+z@registrar.vobiz.ai SIP/2.0');
      await h.client.hangup();
      await h.dispose();
    });
  });

  group('the sign-in user name', () {
    test('SIP Direct refuses one with a space, a line break, < > " or @, and keeps the connection', () {
      final h = Harness();
      for (final bad in <String>['', 'a b', 'a\r\nContact: <sip:x@evil>', 'a@b', '<a>', 'a"b']) {
        expect(() => h.client.connectWithCredentials(CredentialConfig(username: bad, password: 'x')),
            throwsArgumentError,
            reason: bad);
      }
      expect(h.client.isConnected, isTrue, reason: 'refused before the old connection was closed');
      expect(h.sent, isEmpty);
      h.dispose();
    });

    test('an access token whose sub or text cannot go into SIP is refused before connecting', () async {
      final h = Harness();
      await expectLater(h.client.connectWithAccessToken(_token(sub: 'agent 42')),
          throwsA(isA<VobizAccessTokenException>()));
      await expectLater(h.client.connectWithAccessToken(_token(sub: 'agent\r\nX-Evil: 1')),
          throwsA(isA<VobizAccessTokenException>()));
      await expectLater(h.client.connectWithAccessToken('${_token(sub: 'agent42')}\r\nX-Evil: 1x'),
          throwsA(isA<VobizAccessTokenException>()));
      expect(h.client.isConnected, isTrue);
      expect(h.sent, isEmpty);
      await h.dispose();
    });
  });

  group('a push\'s hold reference', () {
    test('a line break or other control character in index, label or registrar: not a push to act on', () {
      for (final field in <String>['index', 'label', 'registrar']) {
        for (final bad in <String>['1\r\nContact: <sip:x@evil>', '1\n2', '1\t2']) {
          final data = <String, Object?>{
            'type': 'incoming_call',
            'call_id': 'c-1',
            'index': '4211',
            'label': '1938273',
            'registrar': '203.0.113.10',
            field: bad,
          };
          expect(VobizIncomingPush.tryParse(data), isNull, reason: '$field: $bad');
          expect(VobizPushHold.tryParse(data), isNull, reason: '$field: $bad');
        }
      }
    });

    test('handleIncomingPush refuses a hand-built hold that would add header lines', () async {
      final h = Harness();
      final updates = <VobizPushCallUpdate>[];
      h.client.pushCallUpdates.listen(updates.add);
      const push = VobizIncomingPush(
        callId: 'c-1',
        hold: VobizPushHold(index: '1\r\nContact: <sip:x@evil>', label: 'l', registrar: 'r'),
      );
      expect(h.client.handleIncomingPush(push), isFalse);
      await h.settle();
      expect(h.sent, isEmpty);
      expect(updates, isEmpty);
      expect(h.sip.hasPendingClaim, isFalse);
      await h.dispose();
    });

    test('SIPService.claimHeldCall refuses such headers: nothing sent, nothing kept', () {
      final sent = <String>[];
      final s = sipService(sent);
      expect(s.claimHeldCall(const <String, String>{'X-Index': '1\r\nContact: <sip:x@evil>'}), isFalse);
      expect(s.claimHeldCall(const <String, String>{'X Index': '1'}), isFalse);
      expect(s.hasPendingClaim, isFalse);
      expect(sent, isEmpty);
    });
  });

  test('SIPService.call refuses a destination or header with a line break', () {
    final sent = <String>[];
    final s = sipService(sent);
    expect(() => s.call('1\r\nX: y', 'v=0'), throwsArgumentError);
    expect(() => s.call('1', 'v=0', extraHeaders: const <String, String>{'X-VH-A': 'b\r\nX: y'}),
        throwsArgumentError);
    expect(sent, isEmpty);
  });

  test('transferCall refuses a caller ID that is not a phone number', () {
    final h = Harness();
    expect(() => h.client.transferCall(number: '+919876543210', callerId: '"><Hangup/>'), throwsArgumentError);
    h.dispose();
  });

  group('what arrives on the socket', () {
    test('a binary frame is read as the SIP message it carries', () async {
      final socket = FakeSocket();
      final callers = <String>[];
      SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
        ..onIncomingCall = ((caller, _, __) => callers.add(caller))
        ..debugAttachSocket(socket);
      socket.incoming.add(utf8.encode(inboundInvite()));
      await Future<void>.delayed(Duration.zero);
      expect(callers, <String>['+918000000000']);
      expect(firstLine(socket.fakeSink.sent.single), 'SIP/2.0 180 Ringing');
    });

    test('a response with no status code or an empty Via is dropped, not thrown', () {
      final sent = <String>[];
      final s = sipService(sent);
      expect(() => s.debugReceive('SIP/2.0\r\n\r\n'), returnsNormally);
      expect(() => s.debugReceive('SIP/2.0 200 OK\r\nVia: \r\nCSeq: 1 REGISTER\r\nCall-ID: x\r\n\r\n'),
          returnsNormally);
      expect(() => s.debugReceive('SIP/2.0 abc\r\nVia: SIP/2.0/WSS x;branch=z9hG4bKy\r\n\r\n'), returnsNormally);
      expect(sent, isEmpty);
      expect(s.registrationState.value, SipRegistrationState.registering);
    });

    test('the caller is a number only when it is the whole user part or display name', () {
      String callerOf(String from, {String? pai}) {
        final callers = <String>[];
        final s = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
          ..debugOnSend = (_) {}
          ..onIncomingCall = ((caller, _, __) => callers.add(caller));
        s.register('play1', 'secret');
        s.debugReceive(_inviteFrom(from, pai: pai));
        return callers.single;
      }

      expect(callerOf('<sip:sales_20250001@registrar.vobiz.ai>;tag=1234567890'), 'sales_20250001');
      expect(callerOf('<sip:alice@10.0.2.9>;tag=99999999'), 'alice');
      expect(callerOf('"+918000000000" <sip:Vobiz@10.0.2.9>;tag=ab'), '+918000000000');
      expect(callerOf('<sip:Vobiz@10.0.2.9>;tag=ab', pai: '<tel:+918000000001>'), '+918000000001');
      expect(callerOf('<sip:919876543210;npdi@10.0.2.9>;tag=ab'), '919876543210');
      expect(callerOf('<sip:+918000000000@10.0.2.9>;tag=ms'), '+918000000000');
    });
  });
}
