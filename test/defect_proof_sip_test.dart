// Review proofs, now fixed: each test asserts the RFC 3261 behaviour that the
// review found missing. They run with the rest of the suite.
import 'package:flutter_test/flutter_test.dart';

import 'sip_test_support.dart';

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
    'v=0';

void main() {
  test('P1 (#4): hanging up a ringing outbound call sends CANCEL, not BYE', () {
    final sent = <String>[];
    final s = sipService(sent);
    s.call('919000000000', 'v=0');
    final invite = sent.single;
    s.debugReceive(respond(invite, 100, 'Trying', toTag: ''));
    sent.clear();
    s.hangup();
    expect(sent, isNotEmpty);
    expect(firstLine(sent.first), startsWith('CANCEL '), reason: 'got: ${firstLine(sent.first)}');
    expect(sent.any((m) => m.startsWith('BYE')), isFalse);
  });

  test('P1b (#4): a 200 OK that arrives after a local hangup is ACKed and then BYEd', () {
    final sent = <String>[];
    final s = sipService(sent);
    s.call('919000000000', 'v=0');
    final invite = sent.single;
    s.hangup();
    sent.clear();
    s.debugReceive(respond(invite, 200, 'OK',
        headers: <String>['Contact: <sip:ms@10.0.2.9>'], body: 'v=0'));
    expect(methods(sent), containsAllInOrder(<String>['ACK', 'BYE']), reason: 'sent: ${methods(sent)}');
  });

  test('P3 (#6): a re-INVITE on an answered call gets a 200 for the NEW CSeq and Via', () {
    final sent = <String>[];
    final s = sipService(sent);
    s.debugReceive(_invite);
    s.answer('v=0');
    sent.clear();
    s.debugReceive(_reInvite(toTag: ';tag=x'));
    expect(sent, isNotEmpty);
    final reply = sent.last;
    expect(firstLine(reply), 'SIP/2.0 200 OK');
    expect(headerOf(reply, 'CSeq'), '102 INVITE', reason: 'replied with CSeq ${headerOf(reply, 'CSeq')}');
    expect(headerOf(reply, 'Via'), contains('z9hG4bKkam.reinv'));
  });

  test('P3b (#6): an unknown in-dialog request (UPDATE) gets a final response', () {
    final sent = <String>[];
    final s = sipService(sent);
    s.debugReceive(_invite);
    s.answer('v=0');
    sent.clear();
    s.debugReceive('UPDATE sip:abcd1234@203.0.113.5 SIP/2.0\r\n'
        'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKupd\r\n'
        'From: <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\nTo: <sip:play1@registrar.vobiz.ai>;tag=x\r\n'
        'Call-ID: in-call-1\r\nCSeq: 103 UPDATE\r\nContent-Length: 0\r\n\r\n');
    expect(sent, isNotEmpty, reason: 'UPDATE got no response at all');
    expect(firstLine(sent.single), 'SIP/2.0 200 OK');
  });

  test('P4 (#21): a 486 to our INVITE is ACKed', () {
    final sent = <String>[];
    final s = sipService(sent);
    s.call('919000000000', 'v=0');
    final invite = sent.single;
    sent.clear();
    s.debugReceive(respond(invite, 486, 'Busy Here'));
    expect(methods(sent), contains('ACK'));
  });

  test('P5 (#16): repeated 407s on INVITE stop after a bounded number of retries', () {
    final sent = <String>[];
    final s = sipService(sent);
    final failures = <int?>[];
    s.onCallFailed = (_, code) => failures.add(code);
    s.call('919000000000', 'v=0');
    for (var i = 0; i < 5; i++) {
      final lastInvite = sent.lastWhere((m) => m.startsWith('INVITE '));
      s.debugReceive(respond(lastInvite, 407, 'Proxy Authentication Required', headers: <String>[
        'Proxy-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n$i", qop="auth"',
      ]));
    }
    final invites = sent.where((m) => m.startsWith('INVITE ')).length;
    expect(invites, lessThanOrEqualTo(2), reason: 're-sent INVITE $invites times for 5 challenges');
    expect(failures, <int?>[407]);
  });

  test('M13 (#26): hanging up an unanswered INBOUND call sends a final response, not BYE', () {
    final sent = <String>[];
    final s = sipService(sent);
    s.debugReceive(_invite);
    sent.clear();
    s.hangup();
    expect(sent, isNotEmpty);
    expect(firstLine(sent.first), isNot(startsWith('BYE')),
        reason: 'callee sent BYE on an early dialog');
    expect(firstLine(sent.single), 'SIP/2.0 486 Busy Here');
    expect(headerOf(sent.single, 'CSeq'), '101 INVITE');
  });

}
