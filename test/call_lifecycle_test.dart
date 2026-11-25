// Call lifecycle: every way a call can end leaves the client idle, tells the
// far end, and says why. Driven through VobizClient with a real SIPService
// and a fake WebRTC engine (see call_harness.dart).
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';

void main() {
  group('#5 / #54 outbound setup timer', () {
    test('a call that has had a provisional response keeps ringing past the setup timer', () async {
      final h = Harness(setupTimeout: const Duration(milliseconds: 50));
      await h.dial();
      h.respond(100, 'Trying');
      h.respond(180, 'Ringing');
      await h.settle(150);
      expect(h.client.callState, CallStateStatus.ringing);
      expect(h.events.map((e) => e.state), isNot(contains(CallStateStatus.ended)));
      expect(h.sentRequest('BYE'), isFalse);
      await h.dispose();
    });

    test('100 Trying alone is enough to stop the setup timer', () async {
      final h = Harness(setupTimeout: const Duration(milliseconds: 50));
      await h.dial();
      h.respond(100, 'Trying');
      await h.settle(150);
      expect(h.client.callState, CallStateStatus.ringing);
      await h.dispose();
    });

    test('an INVITE with no response at all ends as setup_timeout, not "Hung up"', () async {
      final h = Harness(setupTimeout: const Duration(milliseconds: 50));
      await h.dial();
      await h.settle(150);
      expect(h.client.callState, CallStateStatus.idle);
      final ended = h.lastEnded;
      expect(ended.reason, 'setup_timeout');
      expect(ended.message, 'Call setup timed out');
      expect(h.events.where((e) => e.state == CallStateStatus.ended), hasLength(1));
      expect(h.errors.map((e) => e.code), contains('call_timeout'));
      await h.dispose();
    });
  });

  group('#7 CANCEL while answering', () {
    test('a call cancelled during answer never becomes active and does not block the next call', () async {
      final h = Harness();
      h.invite('in-1');
      h.peer.localDescriptionGate = Completer<RTCSessionDescription?>();
      final answering = h.client.acceptCall();
      // Wait until the answer is parked on getLocalDescription().
      await h.settle(200);
      expect(h.client.callState, CallStateStatus.connecting);
      h.cancel('in-1');
      h.peer.localDescriptionGate!.complete(RTCSessionDescription('v=0\r\nlocal', 'answer'));
      await answering;

      expect(h.sentStatus(487), isTrue);
      expect(
          h.sent.any((m) =>
              m.startsWith('SIP/2.0 200 OK') && m.contains('CSeq: 101 INVITE')),
          isFalse,
          reason: 'no 200 OK may answer the cancelled INVITE');
      expect(h.events.map((e) => e.state), isNot(contains(CallStateStatus.active)));
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.client.currentCallId, isNull);

      h.sent.clear();
      h.invite('in-2', branch: 'z9hG4bKb');
      expect(h.sentStatus(180), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.client.callState, CallStateStatus.incoming);
      await h.dispose();
    });
  });

  group('#38 a failed answer sends a final response', () {
    test('microphone unavailable: 480, a reason, and the next call rings', () async {
      final h = Harness();
      h.invite('in-1');
      h.peer.initializeError = Exception('Permission denied');
      await h.client.acceptCall();
      await h.settle();
      expect(h.sentStatus(480), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'answer_failed');
      expect(h.errors.last.code, 'answer_failed');
      expect(h.errors.last.message, contains('microphone'));

      h.peer.initializeError = null;
      h.sent.clear();
      h.invite('in-2', branch: 'z9hG4bKb');
      expect(h.sentStatus(486), isFalse, reason: 'sent: ${h.firstLines}');
      expect(h.sentStatus(180), isTrue);
      expect(h.client.callState, CallStateStatus.incoming);
      await h.dispose();
    });

    test('no microphone permission: 480 at once, without opening the microphone', () async {
      final h = Harness();
      h.invite('in-1');
      h.client.canOpenMicrophone = () async => false;
      // Opening the microphone would fail differently: it must not be tried.
      h.peer.initializeError = Exception('opened the microphone');
      await h.client.acceptCall();
      await h.settle();
      expect(h.sentStatus(480), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'answer_failed');
      expect(h.errors.last.code, VobizErrorCode.microphonePermissionDenied);

      h.client.canOpenMicrophone = () async => true;
      h.peer.initializeError = null;
      h.sent.clear();
      h.invite('in-2', branch: 'z9hG4bKb');
      await h.client.acceptCall();
      await h.settle();
      expect(h.client.callState, CallStateStatus.active);
      await h.dispose();
    });

    test('an INVITE without SDP is declined with 488', () async {
      final h = Harness();
      h.invite('in-1', sdp: '');
      await h.client.acceptCall();
      expect(h.sentStatus(488), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.client.callState, CallStateStatus.idle);
      await h.dispose();
    });

    test('an offer the engine rejects is declined with 488', () async {
      final h = Harness();
      h.invite('in-1');
      h.peer.remoteDescriptionError = Exception('bad SDP');
      await h.client.acceptCall();
      expect(h.sentStatus(488), isTrue, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });
  });

  group('#39 a 200 OK whose SDP cannot be applied', () {
    test('is ACKed, then hung up with BYE, and ends as answer_failed', () async {
      final h = Harness();
      await h.dial();
      h.respond(180, 'Ringing');
      h.peer.remoteDescriptionError = Exception('bad answer');
      h.respond(200, 'OK', body: 'v=0');
      await h.settle();
      final ack = h.firstLines.indexWhere((l) => l.startsWith('ACK '));
      final bye = h.firstLines.indexWhere((l) => l.startsWith('BYE '));
      expect(ack, isNonNegative, reason: 'sent: ${h.firstLines}');
      expect(bye, greaterThan(ack));
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'answer_failed');
      await h.dispose();
    });

    test('a retransmitted 200 OK is not applied twice or reported as a failure', () async {
      final h = Harness();
      await h.dial();
      h.respond(200, 'OK', body: 'v=0');
      await h.settle();
      h.respond(200, 'OK', body: 'v=0');
      await h.settle();
      expect(h.peer.remoteDescriptions, hasLength(1));
      expect(h.errors.map((e) => e.code), isNot(contains('answer_failed')));
      expect(h.client.callState, CallStateStatus.active);
      expect(h.firstLines.where((l) => l.startsWith('ACK ')), hasLength(2));
      await h.dispose();
    });
  });

  group('#52 rejectCall() on an answered call', () {
    test('hangs it up with a BYE', () async {
      final h = await answeredCall();
      await h.client.rejectCall();
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.client.callState, CallStateStatus.idle);
      await h.dispose();
    });

    test('still declines a ringing call with 486', () async {
      final h = Harness();
      h.invite('in-1');
      await h.client.rejectCall();
      await h.settle();
      expect(h.sentStatus(486), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.lastEnded.reason, 'Rejected');
      await h.dispose();
    });
  });
}
