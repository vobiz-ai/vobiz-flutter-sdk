// The outbound INVITE transaction, CANCEL, ACK, BYE and INFO: responses
// matched by branch and CSeq, digest retries bounded.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'sip_test_support.dart';

const String _challenge407 =
    'Proxy-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n1", qop="auth", opaque="op-1"';

void main() {
  late List<String> sent;
  late SIPService s;
  late List<String> failed;
  late List<String?> ended;
  late List<String> answered;

  setUp(() {
    sent = <String>[];
    failed = <String>[];
    ended = <String?>[];
    answered = <String>[];
    s = sipService(sent)
      ..onCallFailed = ((reason, code) => failed.add('$code $reason'))
      ..onCallEnded = ended.add
      ..onCallAnswered = answered.add;
  });

  String placeCall() {
    s.call('919000000000', 'v=0');
    final invite = sent.single;
    sent.clear();
    return invite;
  }

  group('cancelling an outbound call (#4)', () {
    test('CANCEL repeats the INVITE\'s Request-URI, branch, Call-ID, From, To and CSeq number', () {
      final invite = placeCall();
      s.debugReceive(respond(invite, 180, 'Ringing'));
      sent.clear();
      s.hangup();
      final cancel = sent.single;
      expect(firstLine(cancel), firstLine(invite).replaceFirst('INVITE', 'CANCEL'));
      expect(branchOf(cancel), branchOf(invite));
      expect(headerOf(cancel, 'Call-ID'), headerOf(invite, 'Call-ID'));
      expect(headerOf(cancel, 'From'), headerOf(invite, 'From'));
      expect(headerOf(cancel, 'To'), headerOf(invite, 'To'));
      expect(headerOf(cancel, 'CSeq'), headerOf(invite, 'CSeq').replaceFirst('INVITE', 'CANCEL'));
      expect(ended, <String?>['Hung up']);
    });

    test('with no provisional response yet, the CANCEL waits for one (RFC 3261 9.1)', () {
      final invite = placeCall();
      s.hangup();
      expect(sent, isEmpty);
      s.debugReceive(respond(invite, 100, 'Trying', toTag: ''));
      expect(methods(sent), <String>['CANCEL']);
    });

    test('the 487 that follows is ACKed on the INVITE branch and reported to no one', () {
      final invite = placeCall();
      s.debugReceive(respond(invite, 180, 'Ringing'));
      s.hangup();
      sent.clear();
      s.debugReceive(respond(invite, 487, 'Request Terminated'));
      expect(methods(sent), <String>['ACK']);
      expect(branchOf(sent.single), branchOf(invite));
      expect(failed, isEmpty);
      expect(ended, <String?>['Hung up']);
    });

    test('a 200 that crosses the CANCEL is ACKed, then ended with BYE to its Contact', () {
      final invite = placeCall();
      s.debugReceive(respond(invite, 180, 'Ringing'));
      s.hangup();
      sent.clear();
      s.debugReceive(respond(invite, 200, 'OK', headers: <String>[
        'Contact: <sip:Vobiz@10.0.2.9:5060>',
        'Record-Route: <sip:10.0.1.5:5060;lr>',
        'Record-Route: <sip:10.0.1.5:443;transport=ws;lr>',
      ], body: 'v=0'));
      expect(methods(sent), <String>['ACK', 'BYE']);
      final bye = sent.last;
      expect(firstLine(bye), 'BYE sip:Vobiz@10.0.2.9:5060 SIP/2.0');
      expect(headerOf(bye, 'To'), contains('tag=far'));
      expect(headerOf(bye, 'Route'), '<sip:10.0.1.5:443;transport=ws;lr>');
      expect(answered, isEmpty, reason: 'the app already saw the call end');
    });

    test('a new call can be placed while the old INVITE is still being cancelled', () {
      final first = placeCall();
      s.debugReceive(respond(first, 180, 'Ringing'));
      s.hangup();
      sent.clear();
      s.call('918888888888', 'v=0');
      final second = sent.single;
      sent.clear();
      s.debugReceive(respond(first, 487, 'Request Terminated'));
      s.debugReceive(respond(second, 180, 'Ringing'));
      expect(failed, isEmpty);
      expect(methods(sent), <String>['ACK']);
      expect(branchOf(sent.single), branchOf(first));
    });

    test('a 200 that comes after a hang-up with no provisional response is ACKed, then ended with BYE', () {
      final invite = placeCall();
      s.hangup();
      expect(sent, isEmpty, reason: 'no CANCEL before a provisional response');
      s.debugReceive(respond(invite, 200, 'OK', headers: <String>['Contact: <sip:ms@10.0.2.9>'], body: 'v=0'));
      expect(methods(sent), <String>['ACK', 'BYE']);
      expect(answered, isEmpty);
    });
  });

  group('final responses to INVITE (#21, #24)', () {
    test('every 3xx-6xx is ACKed with the INVITE\'s branch, Request-URI and CSeq, and the response\'s To', () {
      for (final code in <int>[302, 404, 480, 486, 503, 603]) {
        sent.clear();
        final invite = placeCall();
        s.debugReceive(respond(invite, code, 'X'));
        final ack = sent.single;
        expect(firstLine(ack), firstLine(invite).replaceFirst('INVITE', 'ACK'), reason: '$code');
        expect(branchOf(ack), branchOf(invite));
        expect(headerOf(ack, 'CSeq'), headerOf(invite, 'CSeq').replaceFirst('INVITE', 'ACK'));
        expect(headerOf(ack, 'To'), contains('tag=far'));
        expect(headerOf(ack, 'Route'), isEmpty);
      }
      expect(failed, hasLength(6));
    });

    test('a 200 OK repeated after the ACK is ACKed again, but answers the call only once', () {
      final invite = placeCall();
      final ok = respond(invite, 200, 'OK',
          headers: <String>['Contact: <sip:Vobiz@10.0.2.9:5060>'], body: 'v=0');
      s.debugReceive(ok);
      s.debugReceive(ok);
      expect(methods(sent), <String>['ACK', 'ACK']);
      expect(sent[0], sent[1]);
      expect(answered, hasLength(1));
    });

    test('a response is matched by branch and CSeq, not by method name', () {
      final invite = placeCall();
      // Same method, wrong branch and CSeq: not ours.
      s.debugReceive('SIP/2.0 486 Busy Here\r\n'
          'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKother\r\n'
          'From: ${headerOf(invite, 'From')}\r\nTo: ${headerOf(invite, 'To')};tag=x\r\n'
          'Call-ID: ${headerOf(invite, 'Call-ID')}\r\nCSeq: 999 INVITE\r\nContent-Length: 0\r\n\r\n');
      expect(failed, isEmpty);
      expect(sent, isEmpty);
      // The real one still sets the call up.
      s.debugReceive(respond(invite, 200, 'OK',
          headers: <String>['Contact: <sip:Vobiz@10.0.2.9:5060>'], body: 'v=0'));
      expect(answered, hasLength(1));
      expect(s.hasActiveDialog, isTrue);
    });

    test('a response whose Via was rewritten still matches on Call-ID and CSeq', () {
      final invite = placeCall();
      s.debugReceive(respond(invite, 486, 'Busy Here')
          .replaceFirst(branchOf(invite), 'z9hG4bKrewritten'));
      expect(failed.single, startsWith('486'));
    });

    test('no final response within Timer B fails the call with 408', () async {
      s.transactionTimeout = const Duration(milliseconds: 20);
      placeCall();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(failed.single, startsWith('408'));
      expect(s.hasActiveDialog, isFalse);
    });

    test('a provisional response stops Timer B: ringing can last', () async {
      s.transactionTimeout = const Duration(milliseconds: 20);
      final invite = placeCall();
      s.debugReceive(respond(invite, 180, 'Ringing'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(failed, isEmpty);
    });
  });

  group('INVITE digest (#16)', () {
    test('a 407 is ACKed, then answered once with opaque echoed; a second 407 fails the call', () {
      final invite = placeCall();
      s.debugReceive(respond(invite, 407, 'Proxy Authentication Required', headers: <String>[_challenge407]));
      expect(methods(sent), <String>['ACK', 'INVITE']);
      final retry = sent.last;
      expect(headerOf(retry, 'Proxy-Authorization'), contains('opaque="op-1"'));
      expect(branchOf(retry), isNot(branchOf(invite)));
      sent.clear();
      s.debugReceive(respond(retry, 407, 'Proxy Authentication Required', headers: <String>[_challenge407]));
      expect(methods(sent), <String>['ACK']);
      expect(failed.single, startsWith('407 Call authentication failed'));
    });

    test('stale=true earns exactly one more try', () {
      final invite = placeCall();
      s.debugReceive(respond(invite, 407, 'Proxy Authentication Required', headers: <String>[_challenge407]));
      final retry = sent.last;
      s.debugReceive(respond(retry, 407, 'Proxy Authentication Required',
          headers: <String>['$_challenge407, stale=true']));
      final staleRetry = sent.last;
      expect(firstLine(staleRetry), startsWith('INVITE'));
      s.debugReceive(respond(staleRetry, 407, 'Proxy Authentication Required',
          headers: <String>['$_challenge407, stale=TRUE']));
      expect(sent.where((m) => m.startsWith('INVITE')), hasLength(2));
      expect(failed, hasLength(1));
    });

    test('an unsupported algorithm is not answered with an MD5 digest', () {
      final invite = placeCall();
      s.debugReceive(respond(invite, 401, 'Unauthorized', headers: <String>[
        'WWW-Authenticate: Digest realm="r", nonce="n", algorithm=SHA-256',
      ]));
      expect(methods(sent), <String>['ACK']);
      expect(failed.single, contains('Could not parse'));
    });
  });

  group('SipDigestAuth', () {
    test('echoes opaque, keeps qop=auth from a list, and ignores cnonce-like keys', () {
      final header = SipDigestAuth.buildAuthHeader(
        wwwAuthenticate: 'Digest realm="r", nonce="abc", qop="auth,auth-int", opaque="xyz"',
        method: 'REGISTER',
        uri: 'sip:r',
        username: 'u',
        password: 'p',
      )!;
      expect(header, contains('opaque="xyz"'));
      expect(header, contains('qop=auth,'));
      expect(header, contains('nonce="abc"'));
    });

    test('reads stale both quoted and bare', () {
      expect(SipDigestAuth.isStale('Digest realm="r", stale=true'), isTrue);
      expect(SipDigestAuth.isStale('Digest realm="r", stale="TRUE"'), isTrue);
      expect(SipDigestAuth.isStale('Digest realm="r", stale=false'), isFalse);
      expect(SipDigestAuth.isStale('Digest realm="r"'), isFalse);
    });
  });

  group('BYE (#24)', () {
    String connect() {
      final invite = placeCall();
      s.debugReceive(respond(invite, 200, 'OK',
          headers: <String>['Contact: <sip:Vobiz@10.0.2.9:5060>'], body: 'v=0'));
      sent.clear();
      return invite;
    }

    test('a challenged BYE is re-sent once with credentials, then left alone', () {
      connect();
      s.hangup();
      final bye = sent.single;
      sent.clear();
      s.debugReceive(respond(bye, 407, 'Proxy Authentication Required', headers: <String>[_challenge407]));
      final retry = sent.single;
      expect(firstLine(retry), firstLine(bye));
      expect(headerOf(retry, 'Proxy-Authorization'), contains('uri="sip:Vobiz@10.0.2.9:5060"'));
      expect(int.parse(headerOf(retry, 'CSeq').split(' ').first),
          greaterThan(int.parse(headerOf(bye, 'CSeq').split(' ').first)));
      sent.clear();
      s.debugReceive(respond(retry, 407, 'Proxy Authentication Required', headers: <String>[_challenge407]));
      expect(sent, isEmpty);
    });

    test('a 200 for the BYE is not taken for anything else', () {
      connect();
      s.hangup();
      final bye = sent.single;
      sent.clear();
      s.debugReceive(respond(bye, 200, 'OK'));
      expect(sent, isEmpty);
      expect(answered, hasLength(1));
    });
  });

  group('DTMF INFO (#49)', () {
    late String invite;
    setUp(() {
      invite = inboundInvite(callId: 'c2');
      s.debugReceive(invite);
      s.answer('v=0');
      sent.clear();
    });

    test('tones go one at a time; a challenge on the first re-sends the first tone', () {
      expect(s.sendDtmf('1'), isTrue);
      expect(s.sendDtmf('2'), isTrue);
      expect(sent, hasLength(1), reason: 'the second tone waits for the first');
      final info1 = sent.single;
      expect(info1, contains('Signal=1'));
      sent.clear();
      s.debugReceive(respond(info1, 407, 'Proxy Authentication Required', headers: <String>[_challenge407]));
      final retried = sent.single;
      expect(retried, contains('Proxy-Authorization'));
      expect(retried, contains('Signal=1'), reason: 'retry carried: ${retried.split('\r\n\r\n').last}');
      sent.clear();
      s.debugReceive(respond(retried, 200, 'OK'));
      expect(sent.single, contains('Signal=2'));
      expect(sent.single, isNot(contains('Proxy-Authorization')));
    });

    test('a tone with no answer is given up after the timeout and the next one goes', () async {
      s.transactionTimeout = const Duration(milliseconds: 20);
      s.sendDtmf('1');
      s.sendDtmf('2');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sent.last, contains('Signal=2'));
    });

    test('no DTMF on an outbound call before it is answered', () {
      s.hangup();
      s.call('919000000000', 'v=0');
      expect(s.hasActiveDialog, isFalse);
      expect(s.sendDtmf('1'), isFalse);
    });
  });

  group('an inbound INVITE while an outbound call is being prepared (#25)', () {
    test('turned away with 486 while the line is reserved', () {
      s.reserveForOutgoingCall();
      s.debugReceive(inboundInvite());
      expect(firstLine(sent.single), 'SIP/2.0 486 Busy Here');
    });

    test('one that slipped in before the reservation gets 486 when the call is placed, and leaves no state behind', () {
      final incoming = <String>[];
      s.onIncomingCall = (caller, _, __) => incoming.add(caller);
      s.debugReceive(inboundInvite());
      sent.clear();
      s.call('919000000000', 'v=0');
      expect(methods(sent), <String>['SIP/2.0', 'INVITE']);
      expect(firstLine(sent.first), 'SIP/2.0 486 Busy Here');
      final invite = sent.last;
      sent.clear();
      s.debugReceive(respond(invite, 200, 'OK',
          headers: <String>['Contact: <sip:far@10.0.2.9>'], body: 'v=0'));
      final ack = sent.single;
      expect(firstLine(ack), 'ACK sip:far@10.0.2.9 SIP/2.0');
      expect(headerOf(ack, 'Route'), isEmpty, reason: 'no Record-Route left over from the inbound INVITE');
      expect(s.hasActiveDialog, isTrue);
      expect(s.sendDtmf('5'), isTrue);
    });

    test('hangup() ends the reservation', () {
      s.reserveForOutgoingCall();
      s.hangup();
      s.debugReceive(inboundInvite());
      expect(firstLine(sent.single), 'SIP/2.0 180 Ringing');
    });

    test('the reservation lapses by itself', () async {
      s.outgoingReservation = const Duration(milliseconds: 20);
      s.reserveForOutgoingCall();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      s.debugReceive(inboundInvite());
      expect(firstLine(sent.single), 'SIP/2.0 180 Ringing');
    });
  });

  group('ending an inbound call (#26)', () {
    test('hanging up while ringing answers the INVITE with 486 and sends no BYE', () {
      s.debugReceive(inboundInvite());
      sent.clear();
      s.hangup();
      expect(methods(sent), <String>['SIP/2.0']);
      expect(firstLine(sent.single), 'SIP/2.0 486 Busy Here');
      expect(headerOf(sent.single, 'Via'), contains('z9hG4bKkam.1'));
      expect(ended, <String?>['Hung up']);
    });

    test('hanging up after answering still sends BYE', () {
      s.debugReceive(inboundInvite());
      s.answer('v=0');
      sent.clear();
      s.hangup();
      expect(methods(sent), <String>['BYE']);
    });

    test('a declined INVITE frees the line: the next call rings instead of getting 486', () {
      s.debugReceive(inboundInvite());
      s.reject(480, 'Temporarily Unavailable');
      expect(firstLine(sent.last), 'SIP/2.0 480 Temporarily Unavailable');
      sent.clear();
      s.debugReceive(inboundInvite(callId: 'in-call-2', branch: 'z9hG4bKkam.2'));
      expect(firstLine(sent.single), 'SIP/2.0 180 Ringing');
    });

    test('reject() on an answered call hangs up with BYE', () {
      s.debugReceive(inboundInvite());
      s.answer('v=0');
      sent.clear();
      s.reject();
      expect(methods(sent), <String>['BYE']);
    });
  });
}
