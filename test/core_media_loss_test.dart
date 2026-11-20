// A call whose audio fails while signalling is up gets one ICE restart; a
// socket replaced under a call is treated as lost signalling; and a
// re-INVITE in flight when the socket goes is failed at once, so the call
// can renegotiate on the new connection.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';
import 'network_fakes.dart';
import 'sip_test_support.dart' show inboundInvite, sipService;

int _reInvites(Harness h) => h.firstLines.where((l) => l.startsWith('INVITE ')).length;

void main() {
  group('lost audio with signalling up', () {
    test('ICE failed: one ICE restart, and the call survives once ICE connects', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 300));
      final id = h.client.currentCallId!;
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateFailed);
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin']);
      final reInvite = h.sent.lastWhere((m) => m.startsWith('INVITE '));
      expect(reInvite, contains('Call-ID: in-1'));
      expect(reInvite, contains('a=ice-ufrag:new'));

      // The same loss reported again does not restart again.
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateFailed);
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin']);

      h.respondToReInvite(200, 'OK', body: 'v=0\r\nanswer');
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin', 'complete']);
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateConnected);
      await h.settle(400);
      expect(h.client.callState, CallStateStatus.active);
      expect(h.events.last.reason, 'reconnected');
      await h.dispose();
    });

    test('ICE disconnected longer than the delay: restarted; back within it: not', () async {
      final h = await answeredCall(
          grace: const Duration(seconds: 2), mediaRestartDelay: const Duration(milliseconds: 50));
      final id = h.client.currentCallId!;
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateConnected);
      await h.settle(100);
      expect(h.peer.iceRestarts, isEmpty, reason: 'it healed by itself');

      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      await h.settle(100);
      expect(h.peer.iceRestarts, <String>['begin']);
      await h.dispose();
    });

    test('with the socket down too, nothing is restarted until the client registers again', () async {
      final h = await answeredCall(grace: const Duration(seconds: 2));
      final id = h.client.currentCallId!;
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateFailed);
      await h.settle();
      expect(h.peer.iceRestarts, isEmpty);
      h.sip.disconnect(keepCall: true);
      h.sip.register('play1', 'secret');
      h.registered();
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin']);
      await h.dispose();
    });

    test('a restart still unanswered when the socket goes does not block the one after the reconnect',
        () async {
      final h = await answeredCall(grace: const Duration(seconds: 2));
      final id = h.client.currentCallId!;
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateFailed);
      await h.settle();
      expect(_reInvites(h), 1);
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      h.sip.disconnect(keepCall: true);
      await h.settle();
      h.sip.register('play1', 'secret');
      h.registered();
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin', 'abort', 'begin']);
      expect(_reInvites(h), 2);
      await h.dispose();
    });
  });

  test('SIPService: our re-INVITE in flight fails at once when the socket is replaced under the call', () async {
    final sent = <String>[];
    final s = sipService(sent);
    s.debugReceive(inboundInvite());
    s.answer('v=0');
    final renegotiating = s.reInvite('v=0\r\na=sendonly');
    unawaited(s.disconnect(keepCall: true, unregister: false));
    await expectLater(renegotiating.timeout(const Duration(seconds: 1)), throwsA(isA<SipRequestFailed>()));
    expect(s.hasActiveDialog, isTrue, reason: 'the call is kept');
  });

  group('a socket replaced under a call', () {
    late FakeSipServer server;
    late VobizClient client;
    late SIPService sip;
    late FakePeer peer;
    late List<CallEvent> events;

    setUp(() async {
      server = FakeSipServer();
      await server.start();
      peer = FakePeer();
      events = <CallEvent>[];
      sip = SIPService(wsUrl: server.url, sipServer: sipServer);
      client = VobizClient.withServices(
        sip: sip,
        peer: peer,
        config: SdkConfig(
            wsUrl: server.url,
            reconnectPolicy: const ReconnectPolicy(initialDelay: Duration(milliseconds: 50), jitter: 0)),
        networkLossGrace: const Duration(seconds: 5),
        connectivityMonitor: FakeConnectivityMonitor(),
      );
      client.callEvents.listen(events.add);
      await client.connectWithCredentials(const CredentialConfig(username: 'play1', password: 'secret'));
      await eventually(() => client.isConnected);
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test('a connected call is kept and moved with an ICE restart once registered again', () async {
      sip.debugReceive(inboundInvite());
      await client.acceptCall();
      client.reconnect();
      await eventually(() => server.connections == 2 && client.isConnected);
      await eventually(() => peer.iceRestarts.isNotEmpty, reason: 'the ICE restart after the REGISTER');
      expect(peer.iceRestarts, <String>['begin']);
      await eventually(() => server.received.any((m) => m.startsWith('INVITE ') && m.contains('Call-ID: in-call-1')));
      expect(client.callState, CallStateStatus.active);
    });

    test('a call still ringing ends, and its caller gets a final answer', () async {
      sip.debugReceive(inboundInvite());
      expect(client.callState, CallStateStatus.incoming);
      client.reconnect();
      await eventually(() => client.callState == CallStateStatus.idle);
      await Future<void>.delayed(Duration.zero);
      expect(events.lastWhere((e) => e.state == CallStateStatus.ended).reason, 'network_lost');
      await eventually(() => server.received.any((m) => m.startsWith('SIP/2.0 486 ')));
      await eventually(() => server.connections == 2 && client.isConnected);
    });
  });
}
