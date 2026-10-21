// Every message this client sends ends each line in CRLF (RFC 3261 7).
// REGISTER used to be built with writeln, so its lines ended in a bare LF.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';

import 'sip_test_support.dart';

/// The start line and headers of [message]: everything before the blank line.
String _head(String message) => message.substring(0, message.indexOf('\r\n\r\n') + 2);

void expectCrlf(String message) {
  final head = _head(message);
  expect(message.contains('\r\n\r\n'), isTrue, reason: 'no CRLF blank line in: $message');
  expect(RegExp(r'(?<!\r)\n').hasMatch(head), isFalse,
      reason: 'bare LF in ${firstLine(message)}');
}

void main() {
  test('every message sent across a registration and both kinds of call uses CRLF', () async {
    final sent = <String>[];
    final s = sipService(sent);
    s.register('play1', 'secret');
    s.debugReceive(respond(sent.last, 401, 'Unauthorized',
        headers: <String>['WWW-Authenticate: Digest realm="r", nonce="n", qop="auth"']));
    s.debugReceive(respond(sent.last, 200, 'OK'));

    // Outbound: INVITE, 407 ACK + retry, CANCEL, then a call with ACK, INFO, BYE.
    s.call('919000000000', 'v=0');
    s.debugReceive(respond(sent.last, 407, 'Proxy Authentication Required',
        headers: <String>['Proxy-Authenticate: Digest realm="r", nonce="n"']));
    s.debugReceive(respond(sent.last, 180, 'Ringing'));
    s.hangup();
    s.call('919000000000', 'v=0');
    s.debugReceive(respond(sent.last, 200, 'OK',
        headers: <String>['Contact: <sip:f@10.0.2.9>'], body: 'v=0'));
    s.sendDtmf('1');
    s.hangup();

    // Inbound: 180, 200, re-INVITE answer, 405, BYE; then 486 and 487.
    s.debugReceive(inboundInvite());
    s.answer('v=0');
    s.debugReceive(inboundInvite(cseq: 102, branch: 'z9hG4bKre'));
    s.hangup();
    s.debugReceive(inboundInvite(callId: 'c2', branch: 'z9hG4bKc2'));
    s.hangup();
    s.debugReceive(inboundInvite(callId: 'c3', branch: 'z9hG4bKc3'));
    s.debugReceive(inboundInvite(callId: 'c3', branch: 'z9hG4bKc3')
        .replaceFirst('INVITE sip', 'CANCEL sip')
        .replaceFirst('101 INVITE', '101 CANCEL'));

    s.unregisterTimeout = const Duration(milliseconds: 10);
    await s.disconnect();

    final kinds = sent.map((m) => firstLine(m).split(' ').take(2).join(' ')).toSet();
    expect(kinds, containsAll(<String>[
      'REGISTER sip:registrar.vobiz.ai', 'ACK sip:919000000000@registrar.vobiz.ai',
      'SIP/2.0 180', 'SIP/2.0 200', 'SIP/2.0 486', 'SIP/2.0 487',
    ]));
    expect(sent.map((m) => m.split(' ').first),
        containsAll(<String>['REGISTER', 'INVITE', 'ACK', 'CANCEL', 'INFO', 'BYE', 'SIP/2.0']));
    sent.forEach(expectCrlf);
  });
}
