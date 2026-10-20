// Review proofs: each test asserts the CORRECT behaviour (RFC 3261). A failing
// test here proves a defect in the current SDK.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

const String _invite = 'INVITE sip:abcd1234@203.0.113.5:40000;transport=ws SIP/2.0\r\n'
    'Record-Route: <sip:10.0.1.5:443;transport=ws;r2=on;lr>\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKkam.1\r\n'
    'From: "+918000000000" <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\n'
    'To: <sip:play1@registrar.vobiz.ai>\r\n'
    'Call-ID: in-call-1\r\n'
    'CSeq: 101 INVITE\r\n'
    'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
    'Content-Type: application/sdp\r\n'
    'Content-Length: 3\r\n'
    '\r\n'
    'v=0';

String _reInvite({int cseq = 102, String branch = 'z9hG4bKkam.reinv', String toTag = ''}) =>
    'INVITE sip:abcd1234@203.0.113.5:40000;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=$branch\r\n'
    'From: "+918000000000" <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\n'
    'To: <sip:play1@registrar.vobiz.ai>$toTag\r\n'
    'Call-ID: in-call-1\r\n'
    'CSeq: $cseq INVITE\r\n'
    'Content-Type: application/sdp\r\n'
    'Content-Length: 3\r\n'
    '\r\n'
    'v=1';

String _line(String msg, String header) => msg
    .split('\r\n')
    .firstWhere((l) => l.toLowerCase().startsWith('${header.toLowerCase()}:'), orElse: () => '')
    .split(':')
    .skip(1)
    .join(':')
    .trim();

SIPService _svc(List<String> sent) {
  final s = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')..debugOnSend = sent.add;
  s.register('play1', 'secret');
  sent.clear();
  return s;
}

/// Each test here proves an open defect: it fails until that issue is fixed,
/// and then passes. Skipped by default so `flutter test` stays green; run
///   flutter test --dart-define=PROVE_DEFECTS=true test/defect_proof_*
/// to see them fail, and remove the skip when the issue is closed.
Object _open(String issue) => const bool.fromEnvironment('PROVE_DEFECTS')
    ? false
    : 'Open defect $issue (vobiz-ai/vobiz-flutter-sdk): passes once it is fixed';

void main() {
  test('P1: hanging up an outbound call before any response sends CANCEL, not BYE', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.call('919000000000', 'v=0');
    sent.clear();
    s.hangup();
    expect(sent, isNotEmpty);
    expect(sent.first.split('\r\n').first, startsWith('CANCEL '),
        reason: 'got: ${sent.first.split('\r\n').first}');
  }, skip: _open('#4'));

  test('P1b: a 200 OK that arrives after a local hangup is ACKed and then BYEd', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.call('919000000000', 'v=0');
    final callId = _line(sent.last, 'Call-ID');
    s.hangup();
    sent.clear();
    s.debugReceive('SIP/2.0 200 OK\r\n'
        'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKx\r\n'
        'From: <sip:play1@registrar.vobiz.ai>;tag=t\r\n'
        'To: <sip:919000000000@registrar.vobiz.ai>;tag=remote\r\n'
        'Call-ID: $callId\r\nCSeq: 1 INVITE\r\nContact: <sip:ms@10.0.2.9>\r\n'
        'Content-Type: application/sdp\r\nContent-Length: 3\r\n\r\nv=0');
    final methods = sent.map((m) => m.split(' ').first).toList();
    expect(methods, containsAllInOrder(<String>['ACK', 'BYE']), reason: 'sent: $methods');
  }, skip: _open('#4'));

  test('P3: a re-INVITE on an answered call gets a 200 for the NEW CSeq and Via', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.debugReceive(_invite);
    s.answer('v=0');
    sent.clear();
    s.debugReceive(_reInvite(toTag: ';tag=x'));
    expect(sent, isNotEmpty);
    final reply = sent.last;
    expect(reply.split('\r\n').first, 'SIP/2.0 200 OK');
    expect(_line(reply, 'CSeq'), '102 INVITE', reason: 'replied with CSeq ${_line(reply, 'CSeq')}');
    expect(_line(reply, 'Via'), contains('z9hG4bKkam.reinv'));
  }, skip: _open('#6'));

  test('P3b: an unknown in-dialog request (UPDATE) gets a final response', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.debugReceive(_invite);
    s.answer('v=0');
    sent.clear();
    s.debugReceive('UPDATE sip:abcd1234@203.0.113.5 SIP/2.0\r\n'
        'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKupd\r\n'
        'From: <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\nTo: <sip:play1@registrar.vobiz.ai>;tag=x\r\n'
        'Call-ID: in-call-1\r\nCSeq: 103 UPDATE\r\nContent-Length: 0\r\n\r\n');
    expect(sent, isNotEmpty, reason: 'UPDATE got no response at all');
  }, skip: _open('#6'));

  test('P4: a 486 to our INVITE is ACKed', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.call('919000000000', 'v=0');
    final callId = _line(sent.last, 'Call-ID');
    sent.clear();
    s.debugReceive('SIP/2.0 486 Busy Here\r\n'
        'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKx\r\n'
        'From: <sip:play1@registrar.vobiz.ai>;tag=t\r\nTo: <sip:919000000000@registrar.vobiz.ai>;tag=r\r\n'
        'Call-ID: $callId\r\nCSeq: 1 INVITE\r\nContent-Length: 0\r\n\r\n');
    expect(sent.map((m) => m.split(' ').first), contains('ACK'));
  }, skip: _open('#21'));

  test('P5: repeated 407s on INVITE stop after a bounded number of retries', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.call('919000000000', 'v=0');
    final callId = _line(sent.last, 'Call-ID');
    sent.clear();
    for (var i = 0; i < 5; i++) {
      s.debugReceive('SIP/2.0 407 Proxy Authentication Required\r\n'
          'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKx$i\r\n'
          'From: <sip:play1@registrar.vobiz.ai>;tag=t\r\nTo: <sip:919000000000@registrar.vobiz.ai>;tag=r\r\n'
          'Call-ID: $callId\r\nCSeq: ${i + 1} INVITE\r\n'
          'Proxy-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n$i", qop="auth"\r\n'
          'Content-Length: 0\r\n\r\n');
    }
    final invites = sent.where((m) => m.startsWith('INVITE ')).length;
    expect(invites, lessThanOrEqualTo(2), reason: 're-sent INVITE $invites times for 5 challenges');
  }, skip: _open('#16'));

  test('M13: hanging up an unanswered INBOUND call sends a final response, not BYE', () {
    final sent = <String>[];
    final s = _svc(sent);
    s.debugReceive(_invite);
    sent.clear();
    s.hangup();
    expect(sent, isNotEmpty);
    expect(sent.first.split('\r\n').first, isNot(startsWith('BYE')),
        reason: 'callee sent BYE on an early dialog');
  }, skip: _open('#26'));
}
