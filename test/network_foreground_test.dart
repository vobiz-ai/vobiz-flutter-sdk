// Issue #18: back in the foreground, the SDK re-registers by itself, against
// an in-process SIP WebSocket server. The app lifecycle is a fake the test
// drives.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'call_harness.dart' show FakePeer;
import 'network_fakes.dart';

class FakeLifecycle implements AppLifecycleMonitor {
  final StreamController<bool> _changes = StreamController<bool>.broadcast(sync: true);

  @override
  Stream<bool> get foregroundChanges => _changes.stream;

  bool get hasListener => _changes.hasListener;

  void background() => _changes.add(false);
  void foreground() => _changes.add(true);

  /// Locked or backgrounded, then back.
  void resume() {
    background();
    foreground();
  }
}

void main() {
  late FakeSipServer server;
  late FakeLifecycle lifecycle;
  late SIPService sip;
  late VobizClient client;
  late List<ConnectionEvent> conn;
  late List<NetworkEvent> net;
  final subs = <StreamSubscription<Object>>[];

  VobizClient build({bool reregister = true, Duration retry = const Duration(seconds: 20)}) {
    sip = SIPService(wsUrl: server.url, sipServer: 'registrar.vobiz.ai')
      ..unregisterTimeout = const Duration(milliseconds: 50);
    client = VobizClient.withServices(
      sip: sip,
      peer: FakePeer(),
      config: SdkConfig(
        wsUrl: server.url,
        autoReconnect: true,
        reregisterOnForeground: reregister,
        // Long enough that only the foreground can reconnect within a test.
        reconnectPolicy: ReconnectPolicy(initialDelay: retry, maxDelay: retry, jitter: 0),
      ),
      connectivityMonitor: FakeConnectivityMonitor(),
      lifecycleMonitor: lifecycle,
    );
    subs
      ..add(client.connectionEvents.listen(conn.add))
      ..add(client.networkEvents.listen(net.add));
    return client;
  }

  Future<void> signIn({bool reregister = true}) async {
    build(reregister: reregister);
    await client.connectWithCredentials(
        const CredentialConfig(username: 'play1', password: 'secret'));
    await eventually(() => client.isConnected, reason: 'first REGISTER');
    expect(server.registers, hasLength(1));
  }

  Future<void> quiet() => Future<void>.delayed(const Duration(milliseconds: 300));

  setUp(() async {
    server = FakeSipServer();
    await server.start();
    lifecycle = FakeLifecycle();
    conn = <ConnectionEvent>[];
    net = <NetworkEvent>[];
  });

  tearDown(() async {
    await client.dispose();
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await server.stop();
  });

  test('resume while registered: exactly one new REGISTER on the same socket', () async {
    await signIn();
    lifecycle.resume();
    await eventually(() => server.registers.length == 2, reason: 'foreground REGISTER');
    await quiet();

    expect(server.registers, hasLength(2));
    expect(server.connections, 1, reason: 'the live socket is reused');
    expect(client.isConnected, isTrue);
    expect(conn.last.message, 'Reregistered on foreground');
    expect(sip.registrationRefreshDelay, isNotNull,
        reason: 'the refresh timer is re-armed from the new grant');
  });

  test('resume after the socket dropped: reconnects at once', () async {
    await signIn();
    await server.dropAll();
    await eventually(() => net.any((e) => e.type == NetworkEventType.reconnecting));
    expect(server.connections, 1, reason: 'backoff is 20 s');

    lifecycle.resume();
    await eventually(() => server.connections == 2, reason: 'foreground reconnect');
    await eventually(() => client.isConnected && server.registers.length == 2);
    expect(net.map((e) => e.reason), contains('App returned to the foreground'));
    expect(net.last.type, NetworkEventType.reconnected);
  });

  test('resume during a call: REGISTER on the live socket, call and dialog kept', () async {
    await signIn();
    sip.debugReceive('INVITE sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
        'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKa\r\n'
        'From: <sip:+918000000000@10.0.2.9>;tag=ms\r\n'
        'To: <sip:play1@registrar.vobiz.ai>\r\n'
        'Call-ID: in-1\r\nCSeq: 101 INVITE\r\n'
        'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
        'Content-Type: application/sdp\r\nContent-Length: 3\r\n\r\nv=0');
    await client.acceptCall();
    expect(client.callState, CallStateStatus.active);

    lifecycle.resume();
    await eventually(() => server.registers.length == 2, reason: 'foreground REGISTER');
    await quiet();

    expect(server.registers, hasLength(2));
    expect(server.connections, 1, reason: 'the call socket is not replaced');
    expect(client.callState, CallStateStatus.active);
    expect(sip.hasActiveDialog, isTrue);
    expect(server.received.where((m) => m.startsWith('BYE ')), isEmpty);
  });

  test('resumes within 2 s count as one', () async {
    await signIn();
    lifecycle
      ..resume()
      ..resume()
      ..foreground();
    await eventually(() => server.registers.length == 2);
    await eventually(() => client.isConnected);
    lifecycle.resume();
    await quiet();
    expect(server.registers, hasLength(2));
  });

  test('inactive-style repeats (foreground, foreground) do not re-register', () async {
    await signIn();
    lifecycle
      ..foreground()
      ..background()
      ..foreground();
    await eventually(() => server.registers.length == 2);
    lifecycle.foreground();
    await quiet();
    expect(server.registers, hasLength(2));
  });

  test('signed out: nothing is sent and the lifecycle is not watched', () async {
    build();
    expect(lifecycle.hasListener, isFalse);
    lifecycle.resume();
    await quiet();
    expect(server.connections, 0);

    await client.connectWithCredentials(
        const CredentialConfig(username: 'play1', password: 'secret'));
    await eventually(() => client.isConnected);
    expect(lifecycle.hasListener, isTrue);
    await client.disconnect();
    expect(lifecycle.hasListener, isFalse);
    final before = server.received.length;
    lifecycle.resume();
    await quiet();
    expect(server.received.length, before);
    expect(server.connections, 1);
  });

  test('reregisterOnForeground: false does nothing', () async {
    await signIn(reregister: false);
    expect(lifecycle.hasListener, isFalse);
    lifecycle.resume();
    await quiet();
    expect(server.registers, hasLength(1));
  });
}
