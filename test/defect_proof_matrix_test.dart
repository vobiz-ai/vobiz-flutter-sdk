// Matrix proofs (N-findings). Each test asserts CORRECT behaviour; FAIL = defect.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

String _inv(String callId, {String branch = 'z9hG4bKa'}) =>
    'INVITE sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=$branch\r\n'
    'From: <sip:+918000000000@10.0.2.9>;tag=ms\r\nTo: <sip:play1@registrar.vobiz.ai>\r\n'
    'Call-ID: $callId\r\nCSeq: 101 INVITE\r\nContact: <sip:Vobiz@10.0.2.9:5060>\r\n'
    'Content-Type: application/sdp\r\nContent-Length: 3\r\n\r\nv=0';

SIPService _svc(List<String> sent) {
  final s = SIPService(wsUrl: 'wss://t', sipServer: 'registrar.vobiz.ai')..debugOnSend = sent.add;
  s.register('play1', 'secret');
  sent.clear();
  return s;
}

// The defects these proved are fixed; the tests now run with the suite.
void main() {
  test('N2 (#38): a failed answer declines the INVITE, so the NEXT call rings instead of getting 486', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.debugReceive(_inv('first'));
    // VobizClient._answerInvite failed (e.g. mic denied): it now declines the
    // INVITE with a final response (see call_lifecycle_test.dart).
    s.reject(480, 'Temporarily Unavailable');
    expect(sent.map((m) => m.split('\r\n').first), contains('SIP/2.0 480 Temporarily Unavailable'));
    sent.clear();
    s.debugReceive(_inv('second', branch: 'z9hG4bKb'));
    final lines = sent.map((m) => m.split('\r\n').first);
    expect(lines, isNot(contains('SIP/2.0 486 Busy Here')),
        reason: 'second caller was refused busy because the failed first INVITE is still pending');
    expect(lines, contains('SIP/2.0 180 Ringing'));
  });

  test('N21: reject() on an answered call sends BYE', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.debugReceive(_inv('c1'));
    s.answer('v=0');
    sent.clear();
    s.reject();
    expect(sent.map((m) => m.split(' ').first), contains('BYE'), reason: 'sent: $sent');
  });

  test('N18 (#49): overlapping DTMF INFOs: a 407 on the first re-sends the FIRST digit', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.debugReceive(_inv('c2'));
    s.answer('v=0');
    sent.clear();
    s.sendDtmf('1');
    s.sendDtmf('2');
    // The 407 answers the first INFO: it echoes that INFO's Via and CSeq, as
    // a server does. (Tones now go one at a time, so only the first is out.)
    final info = sent.single;
    String header(String name) => info
        .split('\r\n')
        .firstWhere((l) => l.startsWith('$name:'))
        .substring(name.length + 1)
        .trim();
    s.debugReceive('SIP/2.0 407 Proxy Authentication Required\r\n'
        'Via: ${header('Via')}\r\nFrom: ${header('From')}\r\n'
        'To: ${header('To')}\r\nCall-ID: c2\r\nCSeq: ${header('CSeq')}\r\n'
        'Proxy-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n", qop="auth"\r\nContent-Length: 0\r\n\r\n');
    final retried = sent.last;
    expect(retried, contains('Proxy-Authorization'));
    expect(retried, contains('Signal=1'), reason: 'retry carried: ${retried.split('\r\n\r\n').last}');
  });
}
