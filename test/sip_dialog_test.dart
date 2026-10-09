// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

/// An INVITE the way Vobiz's registrar delivers it to a WebSocket client:
/// two Vias (the registrar's on top, the media server's below) and the
/// registrar's double Record-Route.
const String _kInvite = 'INVITE sip:abcd1234@203.0.113.5:40000;transport=ws SIP/2.0\r\n'
    'Record-Route: <sip:10.0.1.5:443;transport=ws;r2=on;lr;ftag=ms-tag;nat=yes>\r\n'
    'Record-Route: <sip:10.0.1.5:5060;r2=on;lr;ftag=ms-tag;nat=yes>\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKkam.1\r\n'
    'Via: SIP/2.0/UDP 10.0.2.9:5060;received=10.0.2.9;rport=5060;branch=z9hG4bKms.1\r\n'
    'Max-Forwards: 69\r\n'
    'From: "+918000000000" <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\n'
    'To: <sip:play1@registrar.vobiz.ai>\r\n'
    'Call-ID: in-call-1\r\n'
    'CSeq: 101 INVITE\r\n'
    'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
    'X-VH-PushRefX-VH: ref-1\r\n'
    'Content-Type: application/sdp\r\n'
    'Content-Length: 3\r\n'
    '\r\n'
    'v=0';

String _request(String method, {String callId = 'in-call-1', int cseq = 101, String toTag = ''}) =>
    '$method sip:abcd1234@203.0.113.5:40000;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKkam.$method\r\n'
    'Via: SIP/2.0/UDP 10.0.2.9:5060;branch=z9hG4bKms.$method\r\n'
    'From: "+918000000000" <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\n'
    'To: <sip:play1@registrar.vobiz.ai>$toTag\r\n'
    'Call-ID: $callId\r\n'
    'CSeq: $cseq $method\r\n'
    'Content-Length: 0\r\n'
    '\r\n';

List<String> _lines(String message, String header) => message
    .split('\r\n')
    .where((l) => l.toLowerCase().startsWith('${header.toLowerCase()}:'))
    .map((l) => l.substring(l.indexOf(':') + 1).trim())
    .toList();

void main() {
  group('SipParser keeps repeated headers', () {
    test('every Via and Record-Route, in order', () {
      final msg = SipParser.parse(_kInvite);
      expect(msg.headerValues('Via'), <String>[
        'SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKkam.1',
        'SIP/2.0/UDP 10.0.2.9:5060;received=10.0.2.9;rport=5060;branch=z9hG4bKms.1',
      ]);
      expect(msg.headerValues('record-route'), hasLength(2));
      expect(msg.headerValues('Record-Route').first, contains('transport=ws'));
      expect(msg.body, 'v=0');
    });

    test('compact header forms count too', () {
      final msg = SipParser.parse('SIP/2.0 200 OK\r\nv: SIP/2.0/WSS a;branch=z9hG4bK1\r\nVia: SIP/2.0/UDP b;branch=z9hG4bK2\r\n\r\n');
      expect(msg.headerValues('Via'), hasLength(2));
    });

    test('splits address lists without breaking quoted names or URI params', () {
      expect(
        SipParser.splitAddressList('<sip:a;lr>, "Smith, J" <sip:b;lr>,<sip:c;lr;x=1,2>'),
        <String>['<sip:a;lr>', '"Smith, J" <sip:b;lr>', '<sip:c;lr;x=1,2>'],
      );
    });
  });

  group('answering a call (UAS)', () {
    late SIPService service;
    late List<String> sent;
    final ended = <String?>[];

    setUp(() {
      sent = <String>[];
      ended.clear();
      service = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
        ..debugOnSend = sent.add
        ..onCallEnded = ended.add;
      service.register('play1', 'secret');
      sent.clear();
    });

    test('180 Ringing copies every Via and Record-Route, in order', () {
      service.debugReceive(_kInvite);
      final ringing = sent.single;
      expect(ringing, startsWith('SIP/2.0 180 Ringing'));
      expect(_lines(ringing, 'Via'), SipParser.parse(_kInvite).headerValues('Via'));
      expect(_lines(ringing, 'Record-Route'), SipParser.parse(_kInvite).headerValues('Record-Route'));
      expect(_lines(ringing, 'To').single, matches(RegExp(r';tag=\w+$')));
      expect(_lines(ringing, 'Contact').single, contains('.invalid'));
    });

    test('200 OK copies every Via and Record-Route and keeps the same To tag', () {
      service.debugReceive(_kInvite);
      final ringingTo = _lines(sent.single, 'To').single;
      sent.clear();
      service.answer('v=0 answer');
      final ok = sent.single;
      expect(ok, startsWith('SIP/2.0 200 OK'));
      expect(_lines(ok, 'Via'), hasLength(2));
      expect(_lines(ok, 'Via').first, contains('branch=z9hG4bKkam.1'));
      expect(_lines(ok, 'Record-Route'), hasLength(2));
      expect(_lines(ok, 'To').single, ringingTo);
      expect(ok, endsWith('v=0 answer'));
    });

    test('BYE follows the route set and reaches the caller\'s contact', () {
      service.debugReceive(_kInvite);
      service.answer('v=0 answer');
      sent.clear();
      service.hangup();
      final bye = sent.single;
      expect(bye, startsWith('BYE sip:Vobiz@10.0.2.9:5060 SIP/2.0'));
      expect(_lines(bye, 'Route'), SipParser.parse(_kInvite).headerValues('Record-Route'));
      expect(_lines(bye, 'To').single, contains('tag=ms-tag'));
      expect(_lines(bye, 'From').single, matches(RegExp(r'tag=\w+$')));
      expect(ended, <String?>['Hung up']);
    });

    test('a CANCEL ends the ringing call with 200 for the CANCEL and 487 for the INVITE', () {
      service.debugReceive(_kInvite);
      sent.clear();
      service.debugReceive(_request('CANCEL'));
      expect(sent, hasLength(2));
      expect(sent[0], startsWith('SIP/2.0 200 OK'));
      expect(_lines(sent[0], 'CSeq').single, '101 CANCEL');
      expect(_lines(sent[0], 'Via'), hasLength(2));
      expect(sent[1], startsWith('SIP/2.0 487 Request Terminated'));
      expect(_lines(sent[1], 'CSeq').single, '101 INVITE');
      expect(_lines(sent[1], 'Via').first, contains('branch=z9hG4bKkam.1'));
      expect(ended, hasLength(1));
    });

    test('a CANCEL or BYE for another call does not end this one', () {
      service.debugReceive(_kInvite);
      sent.clear();
      service.debugReceive(_request('CANCEL', callId: 'old-call'));
      service.debugReceive(_request('BYE', callId: 'old-call', cseq: 7, toTag: ';tag=x'));
      expect(sent.where((m) => m.startsWith('SIP/2.0 200 OK')), hasLength(2));
      expect(sent.any((m) => m.startsWith('SIP/2.0 487')), isFalse);
      expect(ended, isEmpty);
      // ...and the call can still be answered.
      sent.clear();
      service.answer('v=0');
      expect(sent.single, startsWith('SIP/2.0 200 OK'));
    });

    test('a BYE from the caller is answered with every Via', () {
      service.debugReceive(_kInvite);
      service.answer('v=0');
      sent.clear();
      service.debugReceive(_request('BYE', cseq: 102, toTag: ';tag=x'));
      expect(sent.single, startsWith('SIP/2.0 200 OK'));
      expect(_lines(sent.single, 'Via'), hasLength(2));
      expect(ended, hasLength(1));
    });
  });

  group('placing a call (UAC)', () {
    test('ACK and BYE carry the Record-Routes of the 200 OK reversed', () {
      final sent = <String>[];
      final service = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
        ..debugOnSend = sent.add;
      service.register('play1', 'secret');
      sent.clear();
      service.call('+919876543210', 'v=0');
      final invite = SipParser.parse(sent.single);
      final callId = invite.header('Call-ID');
      sent.clear();

      service.debugReceive('SIP/2.0 200 OK\r\n'
          '${invite.headerValues('Via').map((v) => 'Via: $v').join('\r\n')}\r\n'
          'Record-Route: <sip:10.0.1.5:5060;r2=on;lr>\r\n'
          'Record-Route: <sip:10.0.1.5:443;transport=ws;r2=on;lr>\r\n'
          'From: ${invite.header('From')}\r\n'
          'To: ${invite.header('To')};tag=far\r\n'
          'Call-ID: $callId\r\n'
          'CSeq: ${invite.header('CSeq')}\r\n'
          'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
          'Content-Type: application/sdp\r\n'
          'Content-Length: 3\r\n'
          '\r\n'
          'v=0');
      final ack = sent.single;
      expect(ack, startsWith('ACK sip:Vobiz@10.0.2.9:5060 SIP/2.0'));
      expect(_lines(ack, 'Route'), <String>[
        '<sip:10.0.1.5:443;transport=ws;r2=on;lr>',
        '<sip:10.0.1.5:5060;r2=on;lr>',
      ]);

      sent.clear();
      service.hangup();
      expect(_lines(sent.single, 'Route'), _lines(ack, 'Route'));
    });

    test('a late 200 OK for a call that has ended is ignored', () {
      final sent = <String>[];
      final service = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
        ..debugOnSend = sent.add;
      service.register('play1', 'secret');
      sent.clear();
      expect(
        () => service.debugReceive('SIP/2.0 200 OK\r\nVia: SIP/2.0/WSS a;branch=z9hG4bK1\r\n'
            'Call-ID: gone\r\nCSeq: 5 INVITE\r\nContent-Length: 0\r\n\r\n'),
        returnsNormally,
      );
      expect(sent, isEmpty);
    });
  });
}
