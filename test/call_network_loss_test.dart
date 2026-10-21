// #3: a call is never left 'active' with nobody able to end it. Signing out
// or disposing hangs up first; a dropped socket or lost media gets a grace
// period to recover, then the call ends as network_lost.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';

void main() {
  group('#3 zombie call: disconnect, dispose, socket drop, ICE loss', () {
    test('disconnect() during a connected call sends BYE before closing', () async {
      final h = await answeredCall();
      await h.client.disconnect();
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'disconnected');
      await h.dispose();
    });

    test('dispose() during a connected call sends BYE and reports the end', () async {
      final h = await answeredCall();
      await h.dispose();
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.events.map((e) => e.state), contains(CallStateStatus.ended));
    });

    test('disconnect() while a call is ringing here declines it (480)', () async {
      final h = Harness();
      h.invite('in-1');
      await h.client.disconnect();
      expect(h.sentStatus(480), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.sentRequest('BYE'), isFalse);
      await h.dispose();
    });

    test('a socket drop that does not recover ends the call as network_lost', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 50));
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      // Media may still be flowing: the call is not ended at once.
      expect(h.client.callState, CallStateStatus.active);
      await h.settle();
      expect(h.events.last.reason, 'reconnecting');
      await h.settle(120);
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'network_lost');
      expect(h.errors.map((e) => e.code), contains('network_lost'));
      // A new call can be placed or received again.
      h.invite('in-2', branch: 'z9hG4bKb');
      expect(h.client.callState, CallStateStatus.incoming);
      await h.dispose();
    });

    test('a socket drop followed by re-registration keeps the call, and it can still be hung up', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 80));
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      // What the reconnect does: close the old socket keeping the dialog, then
      // register again.
      h.sip.disconnect(keepCall: true);
      h.registered();
      await h.settle();
      expect(h.events.last.reason, 'reconnected');
      await h.settle(150);
      expect(h.client.callState, CallStateStatus.active);
      await h.client.hangup();
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.lastEnded.reason, 'Hung up');
      await h.dispose();
    });

    test('a socket drop while a call is still ringing ends it at once', () async {
      final h = Harness();
      h.invite('in-1');
      h.sip.onSocketError!('SIP socket error');
      await h.settle();
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'network_lost');
      await h.dispose();
    });

    test('ICE failed on a connected call ends it as network_lost after the grace period', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 50));
      h.peer.ice(h.client.currentCallId!, RTCIceConnectionState.RTCIceConnectionStateFailed);
      expect(h.client.callState, CallStateStatus.active);
      await h.settle(120);
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'network_lost');
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });

    test('ICE disconnected then connected again keeps the call', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 80));
      final id = h.client.currentCallId!;
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateConnected);
      await h.settle();
      expect(h.events.last.reason, 'reconnected');
      await h.settle(150);
      expect(h.client.callState, CallStateStatus.active);
      await h.dispose();
    });
  });
}
