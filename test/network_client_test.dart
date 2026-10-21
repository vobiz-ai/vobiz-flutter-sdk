// Issue #18 end to end through VobizClient, against an in-process SIP
// WebSocket server: drops, offline, Wi-Fi <-> mobile, giving up.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'network_fakes.dart';

void main() {
  late FakeSipServer server;
  late FakeConnectivityMonitor monitor;
  late VobizClient client;
  late List<ConnectionEvent> conn;
  late List<NetworkEvent> net;
  late List<ErrorEvent> errors;
  final subs = <StreamSubscription<Object>>[];

  Future<void> signIn({ReconnectPolicy? policy}) async {
    client = VobizClient(
      config: SdkConfig(
        wsUrl: server.url,
        reconnectPolicy: policy ??
            const ReconnectPolicy(
                initialDelay: Duration(milliseconds: 50),
                maxDelay: Duration(milliseconds: 200),
                jitter: 0,
                maxAttempts: 3),
      ),
      connectivityMonitor: monitor,
    );
    subs
      ..add(client.connectionEvents.listen(conn.add))
      ..add(client.networkEvents.listen(net.add))
      ..add(client.errorEvents.listen(errors.add));
    await client.connectWithCredentials(
        const CredentialConfig(username: 'play1', password: 'secret'));
    await eventually(() => client.isConnected, reason: 'first REGISTER');
  }

  setUp(() async {
    server = FakeSipServer();
    await server.start();
    monitor = FakeConnectivityMonitor();
    conn = <ConnectionEvent>[];
    net = <NetworkEvent>[];
    errors = <ErrorEvent>[];
  });

  tearDown(() async {
    await client.disconnect();
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await server.stop();
  });

  test('a dropped socket emits reconnecting, reconnects and re-REGISTERs', () async {
    await signIn();
    expect(server.registers, hasLength(1));

    await server.dropAll();
    await eventually(() => server.registers.length == 2, reason: 're-REGISTER');
    await eventually(() => client.isConnected);

    expect(conn.map((e) => e.connectionState),
        contains(ConnectionStateStatus.reconnecting),
        reason: 'reconnecting existed but was never emitted');
    expect(net.map((e) => e.type), containsAllInOrder(<NetworkEventType>[
      NetworkEventType.reconnecting,
      NetworkEventType.reconnected,
    ]));
    expect(client.signalingQuality, SignalingQuality.good);
  });

  test('offline: makeCall fails at once instead of writing to a dead socket', () async {
    await signIn();
    monitor.goOffline();

    expect(client.isConnected, isFalse);
    expect(client.connectionState, ConnectionStateStatus.reconnecting);
    expect(client.signalingQuality, SignalingQuality.unavailable);
    await Future<void>.delayed(Duration.zero);
    expect(net.last.type, NetworkEventType.offline);
    await expectLater(client.makeCall('+919876543210'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('No network'))));
  });

  test('network back after offline: new socket and REGISTER without waiting for a ping', () async {
    await signIn();
    monitor.goOffline();
    final connectionsBefore = server.connections;
    monitor.mobile();
    await eventually(() => server.connections == connectionsBefore + 1);
    await eventually(() => client.isConnected && server.registers.length == 2);
    expect(net.map((e) => e.type), containsAllInOrder(<NetworkEventType>[
      NetworkEventType.offline,
      NetworkEventType.online,
      NetworkEventType.reconnected,
    ]));
  });

  test('Wi-Fi to mobile with no call: the socket is replaced and re-registered', () async {
    await signIn();
    monitor.mobile();
    await eventually(() => server.registers.length == 2);
    await eventually(() => client.isConnected);
    final changed = net.firstWhere((e) => e.type == NetworkEventType.networkChanged);
    expect(changed.previousNetwork!.primary, NetworkType.wifi);
    expect(changed.network.primary, NetworkType.mobile);
    expect(server.connections, 2);
  });

  test('gives up after the policy cap with reconnect_failed, then retries on reconnect()', () async {
    await signIn();
    server.acceptConnections = false;
    await server.dropAll();

    await eventually(() => errors.any((e) => e.code == 'reconnect_failed'),
        reason: 'terminal event after the last attempt');
    expect(client.connectionState, ConnectionStateStatus.failed);
    expect(net.last.type, NetworkEventType.reconnectFailed);
    expect(net.last.attempt, 3);
    final refusedSoFar = net.where((e) => e.type == NetworkEventType.reconnecting).length;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(net.where((e) => e.type == NetworkEventType.reconnecting).length, refusedSoFar,
        reason: 'no attempts after giving up');

    server.acceptConnections = true;
    client.reconnect();
    await eventually(() => client.isConnected);
    expect(net.last.type, NetworkEventType.reconnected);
  });

  test('wrong credentials are not retried', () async {
    server.answerRegister = false;
    client = VobizClient(
      config: SdkConfig(wsUrl: server.url),
      connectivityMonitor: monitor,
    );
    subs.add(client.networkEvents.listen(net.add));
    await client.connectWithCredentials(
        const CredentialConfig(username: 'play1', password: 'secret'));
    await eventually(() => server.registers.isNotEmpty);
    // Nothing answers: a 403 arrives instead.
    final ws = server.sockets.single;
    final reg = server.registers.single;
    String h(String n) => reg
        .split(RegExp(r'\r?\n'))
        .firstWhere((l) => l.startsWith('$n:'))
        .substring(n.length + 1)
        .trim();
    ws.add('SIP/2.0 403 Forbidden\r\nVia: ${h('Via')}\r\nFrom: ${h('From')}\r\n'
        'To: ${h('To')};tag=x\r\nCall-ID: ${h('Call-ID')}\r\nCSeq: ${h('CSeq')}\r\n'
        'Content-Length: 0\r\n\r\n');
    await eventually(() => client.connectionState == ConnectionStateStatus.failed);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(server.connections, 1);
    expect(net.where((e) => e.type == NetworkEventType.reconnecting), isEmpty);
  });
}
