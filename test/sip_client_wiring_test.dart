// VobizClient's use of the SIP layer's busy reservation (#25) and typed
// auth failure (#16).
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';

void main() {
  test('#25: an inbound INVITE while makeCall is preparing gets 486 and is never shown', () async {
    final h = Harness();
    h.peer.localDescriptionGate = Completer<RTCSessionDescription?>();
    final dialling = h.dial();
    await h.settle(50);
    h.invite('in-1');
    expect(h.sentStatus(486), isTrue, reason: 'sent: ${h.firstLines}');
    expect(h.events.map((e) => e.state), isNot(contains(CallStateStatus.incoming)));
    h.peer.localDescriptionGate!.complete(RTCSessionDescription('v=0\r\noffer', 'offer'));
    await dialling;
    expect(h.sentRequest('INVITE'), isTrue);
    await h.dispose();
  });

  test('#25: a makeCall that fails releases the line for inbound calls', () async {
    final h = Harness();
    h.peer.initializeError = Exception('no microphone');
    await expectLater(h.dial(), throwsA(isA<Exception>()));
    h.sent.clear();
    h.invite('in-1');
    expect(h.sentStatus(180), isTrue, reason: 'sent: ${h.firstLines}');
    expect(h.client.callState, CallStateStatus.incoming);
    await h.dispose();
  });

  test('#16: a refused call digest is reported as auth_failed, after one retry', () async {
    final h = Harness();
    await h.dial();
    void challenge() {
      final invite = h.sent.lastWhere((m) => m.startsWith('INVITE '));
      String header(String name) => invite
          .split('\r\n')
          .firstWhere((l) => l.startsWith('$name:'))
          .substring(name.length + 1)
          .trim();
      h.sip.debugReceive('SIP/2.0 407 Proxy Authentication Required\r\n'
          'Via: ${header('Via')}\r\nFrom: ${header('From')}\r\n'
          'To: ${header('To')};tag=far\r\nCall-ID: ${header('Call-ID')}\r\n'
          'CSeq: ${header('CSeq')}\r\n'
          'Proxy-Authenticate: Digest realm="$sipServer", nonce="n", qop="auth"\r\n'
          'Content-Length: 0\r\n\r\n');
    }

    challenge();
    challenge();
    await h.settle();
    expect(h.firstLines.where((l) => l.startsWith('INVITE ')), hasLength(2));
    expect(h.errors.map((e) => e.code), contains('auth_failed'));
    expect(h.errors.map((e) => e.code), isNot(contains('call_failed')));
    expect(h.client.callState, CallStateStatus.idle);
    await h.dispose();
  });
}
