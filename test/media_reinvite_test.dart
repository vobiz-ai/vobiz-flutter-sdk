// Hold/resume re-INVITE on the SIP dialog (#30).
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

const String _invite = 'INVITE sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
    'Record-Route: <sip:10.0.1.5:443;transport=ws;r2=on;lr>\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKa\r\n'
    'From: <sip:+918000000000@10.0.2.9>;tag=ms\r\n'
    'To: <sip:play1@registrar.vobiz.ai>\r\n'
    'Call-ID: call-1\r\nCSeq: 101 INVITE\r\n'
    'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
    'Content-Type: application/sdp\r\nContent-Length: 3\r\n\r\nv=0';

String _response(int code, String reason, int cseq,
        {String body = '', String extra = ''}) =>
    'SIP/2.0 $code $reason\r\n'
    'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKx\r\n'
    'From: <sip:play1@registrar.vobiz.ai>;tag=t\r\n'
    'To: <sip:+918000000000@10.0.2.9>;tag=ms\r\n'
    'Call-ID: call-1\r\nCSeq: $cseq INVITE\r\n$extra'
    'Content-Length: ${body.length}\r\n\r\n$body';

String _line(String msg, String header) => msg
    .split('\r\n')
    .firstWhere((l) => l.toLowerCase().startsWith('${header.toLowerCase()}:'),
        orElse: () => '')
    .split(':')
    .skip(1)
    .join(':')
    .trim();

int _cseq(String msg) => int.parse(_line(msg, 'CSeq').split(' ').first);

void main() {
  late List<String> sent;
  late SIPService sip;

  setUp(() {
    sent = <String>[];
    sip = SIPService(wsUrl: 'wss://t', sipServer: 'registrar.vobiz.ai')
      ..debugOnSend = sent.add;
    sip.register('play1', 'secret');
    sip.debugReceive(_invite);
    sip.answer('v=0');
    sent.clear();
  });

  test('sends an in-dialog INVITE with the offer and route set', () async {
    final answer = sip.reInvite('v=0\r\na=sendonly\r\n');
    final reinvite = sent.single;
    expect(reinvite.split('\r\n').first, 'INVITE sip:Vobiz@10.0.2.9:5060 SIP/2.0');
    expect(_line(reinvite, 'Call-ID'), 'call-1');
    expect(_line(reinvite, 'Route'), '<sip:10.0.1.5:443;transport=ws;r2=on;lr>');
    expect(_line(reinvite, 'To'), contains('tag=ms'));
    expect(reinvite, contains('a=sendonly'));

    sip.debugReceive(_response(200, 'OK', _cseq(reinvite), body: 'v=0\r\na=recvonly'));
    expect(await answer, 'v=0\r\na=recvonly');
    final ack = sent.last;
    expect(ack.split(' ').first, 'ACK');
    expect(_cseq(ack), _cseq(reinvite));
  });

  test('a refusal fails the request but keeps the call', () async {
    var ended = false;
    sip.onCallEnded = (_) => ended = true;
    final answer = sip.reInvite('v=0');
    sip.debugReceive(_response(488, 'Not Acceptable Here', _cseq(sent.single)));
    await expectLater(
        answer,
        throwsA(isA<SipRequestFailed>()
            .having((e) => e.statusCode, 'statusCode', 488)));
    expect(ended, isFalse);
    expect(sip.hasActiveDialog, isTrue);
  });

  test('a digest challenge is answered once', () async {
    final answer = sip.reInvite('v=0');
    final first = sent.single;
    sip.debugReceive(_response(407, 'Proxy Authentication Required', _cseq(first),
        extra: 'Proxy-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n"\r\n'));
    final retry = sent.last;
    expect(retry, contains('Proxy-Authorization: Digest'));
    expect(_cseq(retry), greaterThan(_cseq(first)));
    sip.debugReceive(_response(200, 'OK', _cseq(retry), body: 'v=0'));
    expect(await answer, 'v=0');
  });

  test('the call ending fails a pending re-INVITE', () async {
    final answer = sip.reInvite('v=0');
    sip.hangup();
    await expectLater(answer, throwsA(isA<SipRequestFailed>()));
  });

  test('no answer times out', () async {
    sip.transactionTimeout = const Duration(milliseconds: 20);
    final answer = sip.reInvite('v=0');
    await expectLater(answer, throwsA(isA<SipRequestFailed>()));
  });

  test('refused without a call, or while one is in flight', () async {
    final idle = SIPService(wsUrl: 'wss://t', sipServer: 'registrar.vobiz.ai');
    await expectLater(idle.reInvite('v=0'), throwsStateError);
    final first = sip.reInvite('v=0');
    await expectLater(sip.reInvite('v=0'), throwsStateError);
    sip.hangup();
    await expectLater(first, throwsA(anything));
  });
}
