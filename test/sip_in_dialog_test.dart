// Requests the far end sends inside a call: re-INVITE, UPDATE, and methods
// this client does not take part in. Each gets its own final response.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'sip_test_support.dart';

const String _remoteSdp = 'v=0\r\no=- 1 1 IN IP4 10.0.2.9\r\ns=-';
const String _localSdp = 'v=0\r\no=- 7 1 IN IP4 0.0.0.0\r\ns=-';

String _inDialog(String method,
        {int cseq = 102, String branch = 'z9hG4bKkam.re', String sdp = '', String callId = 'in-call-1'}) =>
    '$method sip:abcd1234@203.0.113.5:40000;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=$branch.$cseq\r\n'
    'Via: SIP/2.0/UDP 10.0.2.9:5060;branch=z9hG4bKms.$cseq\r\n'
    'From: "+918000000000" <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\n'
    'To: <sip:play1@registrar.vobiz.ai>;tag=ours\r\n'
    'Call-ID: $callId\r\n'
    'CSeq: $cseq $method\r\n'
    '${sdp.isEmpty ? '' : 'Content-Type: application/sdp\r\n'}'
    'Content-Length: ${sdp.length}\r\n'
    '\r\n'
    '$sdp';

void main() {
  late List<String> sent;
  late SIPService s;
  late List<String?> ended;

  setUp(() {
    sent = <String>[];
    ended = <String?>[];
    s = sipService(sent)..onCallEnded = ended.add;
    s.debugReceive(inboundInvite(sdp: _remoteSdp));
    s.answer(_localSdp);
    sent.clear();
  });

  group('re-INVITE (#6)', () {
    test('a session refresh (same o= version) gets 200 with its own Via and CSeq and our SDP unchanged', () {
      s.debugReceive(_inDialog('INVITE', sdp: _remoteSdp));
      final reply = sent.single;
      expect(firstLine(reply), 'SIP/2.0 200 OK');
      expect(headerOf(reply, 'CSeq'), '102 INVITE');
      expect(headerOf(reply, 'Via'), 'SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKkam.re.102');
      expect(reply.split('\r\n').where((l) => l.startsWith('Via:')), hasLength(2));
      expect(reply, endsWith(_localSdp));
      expect(reply, isNot(contains('Supported: timer')));
    });

    test('an offer-less re-INVITE gets our current SDP as the offer', () {
      s.debugReceive(_inDialog('INVITE'));
      expect(firstLine(sent.single), 'SIP/2.0 200 OK');
      expect(sent.single, endsWith(_localSdp));
    });

    test('a repeat of the same re-INVITE gets the same answer', () {
      s.debugReceive(_inDialog('INVITE', sdp: _remoteSdp));
      s.debugReceive(_inDialog('INVITE', sdp: _remoteSdp));
      expect(sent, hasLength(2));
      expect(sent[0], sent[1]);
    });

    test('the first INVITE sent again still gets the original 200', () {
      s.debugReceive(inboundInvite(sdp: _remoteSdp));
      expect(headerOf(sent.single, 'CSeq'), '101 INVITE');
      expect(sent.single, endsWith(_localSdp));
    });

    test('a changed session with no handler is refused with 488, and the call stays up', () {
      s.debugReceive(_inDialog('INVITE', sdp: 'v=0\r\no=- 1 2 IN IP4 10.0.2.9\r\na=sendonly'));
      expect(firstLine(sent.single), 'SIP/2.0 488 Not Acceptable Here');
      expect(headerOf(sent.single, 'CSeq'), '102 INVITE');
      expect(ended, isEmpty);
      expect(s.hasActiveDialog, isTrue);
    });

    test('a changed session goes to onSessionOffer, and its answer is sent', () async {
      final offers = <String>[];
      s.onSessionOffer = (offer) async {
        offers.add(offer);
        return 'v=0\r\no=- 7 2 IN IP4 0.0.0.0';
      };
      s.debugReceive(_inDialog('INVITE', sdp: 'v=0\r\no=- 1 2 IN IP4 10.0.2.9'));
      await Future<void>.delayed(Duration.zero);
      expect(offers, hasLength(1));
      expect(firstLine(sent.single), 'SIP/2.0 200 OK');
      expect(sent.single, endsWith('o=- 7 2 IN IP4 0.0.0.0'));
      // The new versions are now the session: a refresh of it gets the new answer.
      sent.clear();
      s.debugReceive(_inDialog('INVITE', cseq: 103, sdp: 'v=0\r\no=- 1 2 IN IP4 10.0.2.9'));
      expect(sent.single, endsWith('o=- 7 2 IN IP4 0.0.0.0'));
      expect(offers, hasLength(1));
    });

    test('onSessionOffer returning null is a 488', () async {
      s.onSessionOffer = (_) async => null;
      s.debugReceive(_inDialog('INVITE', sdp: 'v=0\r\no=- 1 2 IN IP4 10.0.2.9'));
      await Future<void>.delayed(Duration.zero);
      expect(firstLine(sent.single), 'SIP/2.0 488 Not Acceptable Here');
    });

    test('on an outbound call a re-INVITE is answered, not refused with 486', () {
      s.hangup();
      s.call('919000000000', _localSdp);
      final invite = sent.last;
      s.debugReceive(respond(invite, 200, 'OK',
          headers: <String>['Contact: <sip:Vobiz@10.0.2.9:5060>'], body: _remoteSdp));
      sent.clear();
      s.debugReceive(_inDialog('INVITE', callId: headerOf(invite, 'Call-ID'), cseq: 5, sdp: _remoteSdp));
      expect(firstLine(sent.single), 'SIP/2.0 200 OK');
      expect(headerOf(sent.single, 'CSeq'), '5 INVITE');
      expect(sent.single, endsWith(_localSdp));
    });

    test('an INVITE for another call is still busy', () {
      s.debugReceive(inboundInvite(callId: 'other', branch: 'z9hG4bKother'));
      expect(firstLine(sent.single), 'SIP/2.0 486 Busy Here');
    });
  });

  group('other in-dialog requests (#6)', () {
    test('UPDATE without a body (a refresh) gets 200', () {
      s.debugReceive(_inDialog('UPDATE', cseq: 103));
      expect(firstLine(sent.single), 'SIP/2.0 200 OK');
      expect(headerOf(sent.single, 'CSeq'), '103 UPDATE');
    });

    test('UPDATE with the same session gets 200 with our SDP', () {
      s.debugReceive(_inDialog('UPDATE', cseq: 103, sdp: _remoteSdp));
      expect(firstLine(sent.single), 'SIP/2.0 200 OK');
      expect(sent.single, endsWith(_localSdp));
    });

    test('UPDATE for an unknown call gets 481', () {
      s.debugReceive(_inDialog('UPDATE', callId: 'nope'));
      expect(firstLine(sent.single), 'SIP/2.0 481 Call/Transaction Does Not Exist');
    });

    for (final method in <String>['REFER', 'NOTIFY', 'SUBSCRIBE', 'MESSAGE']) {
      test('$method gets 405 with Allow', () {
        s.debugReceive(_inDialog(method, cseq: 104));
        expect(firstLine(sent.single), 'SIP/2.0 405 Method Not Allowed');
        expect(headerOf(sent.single, 'Allow'), SipBuilder.allow);
        expect(headerOf(sent.single, 'CSeq'), '104 $method');
      });
    }

    test('an unknown method gets 501', () {
      s.debugReceive(_inDialog('FROB', cseq: 105));
      expect(firstLine(sent.single), 'SIP/2.0 501 Not Implemented');
    });

    test('ACK gets no response', () {
      s.debugReceive(_inDialog('ACK', cseq: 101));
      expect(sent, isEmpty);
    });

    test('a CANCEL after the call was answered changes nothing', () {
      s.debugReceive(_inDialog('CANCEL', cseq: 101));
      expect(firstLine(sent.single), 'SIP/2.0 200 OK');
      expect(ended, isEmpty);
      expect(s.hasActiveDialog, isTrue);
    });
  });

  test('no message advertises session timers that are not implemented (#6)', () {
    s.hangup();
    s.call('919000000000', _localSdp);
    expect(sent.last, isNot(contains('Supported: timer')));
    s.hangup();
    sent.clear();
    s.debugReceive(inboundInvite(callId: 'x', branch: 'z9hG4bKx'));
    s.answer(_localSdp);
    expect(sent.last, isNot(contains('timer')));
  });
}
