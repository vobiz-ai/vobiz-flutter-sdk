// Signing in keeps going through temporary REGISTER failures (no answer,
// 408, 480, 5xx) and stops only for a refusal; and a sign-in or sign-out
// that overtakes a sign-in still connecting leaves nothing behind.
// End to end through VobizClient, against an in-process SIP WebSocket server.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/src/webrtc/peer_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart' show FakePeer;
import 'network_fakes.dart';
import 'sip_test_support.dart' show inboundInvite;

const ReconnectPolicy _fast = ReconnectPolicy(
    initialDelay: Duration(milliseconds: 50), maxDelay: Duration(milliseconds: 200), jitter: 0, maxAttempts: 3);

void main() {
  late FakeSipServer server;
  late FakeConnectivityMonitor monitor;
  late VobizClient client;
  VobizClient? created;
  late SIPService sip;
  late List<ConnectionEvent> conn;
  late List<ErrorEvent> errors;
  final subs = <StreamSubscription<Object>>[];

  /// A client on the in-process registrar. [peer] defaults to the real
  /// PeerService, which these tests never ask for media.
  VobizClient makeClient({PeerService? peer, Duration? transactionTimeout}) {
    sip = SIPService(wsUrl: server.url, sipServer: 'registrar.vobiz.ai');
    if (transactionTimeout != null) sip.transactionTimeout = transactionTimeout;
    client = VobizClient.withServices(
      sip: sip,
      peer: peer ?? PeerService(iceConfig: const IceConfig(), mediaConstraints: const MediaConstraints()),
      config: SdkConfig(wsUrl: server.url, reconnectPolicy: _fast),
      connectivityMonitor: monitor,
    );
    created = client;
    subs
      ..add(client.connectionEvents.listen(conn.add))
      ..add(client.errorEvents.listen(errors.add));
    return client;
  }

  Future<void> signIn([String user = 'play1']) =>
      client.connectWithCredentials(CredentialConfig(username: user, password: 'secret'));

  bool sawFailedState() => conn.any((e) =>
      e.connectionState == ConnectionStateStatus.failed || e.registrationState == RegistrationState.failed);

  setUp(() async {
    server = FakeSipServer();
    await server.start();
    monitor = FakeConnectivityMonitor();
    conn = <ConnectionEvent>[];
    errors = <ErrorEvent>[];
    created = null;
  });

  tearDown(() async {
    await created?.dispose();
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await server.stop();
  });

  group('a REGISTER the registrar cannot take now is tried again', () {
    test('a 503 at sign-in: reconnecting with backoff, never failed, then registered', () async {
      makeClient();
      server.registerStatus = 503;
      await signIn();
      await eventually(() => conn.any((e) => e.message?.contains('Trying again') ?? false),
          reason: 'the 503 is reported as a retry');
      expect(client.connectionState, ConnectionStateStatus.reconnecting);
      await eventually(() => server.registers.length >= 2, reason: 'a second REGISTER after the backoff');

      server.registerStatus = 200;
      await eventually(() => client.isConnected, reason: 'registered once the registrar answers 200');
      expect(sawFailedState(), isFalse);
      expect(errors.map((e) => e.code), isNot(contains('registration_failed')));
    });

    test('no answer to the sign-in REGISTER: tried again on a new socket', () async {
      makeClient(transactionTimeout: const Duration(milliseconds: 300));
      server.answerRegister = false;
      await signIn();
      await eventually(() => conn.any((e) => e.message?.contains('timed out') ?? false),
          reason: 'the REGISTER times out');
      server.answerRegister = true;
      await eventually(() => client.isConnected);
      expect(server.connections, greaterThanOrEqualTo(2));
      expect(sawFailedState(), isFalse);
    });

    test('a refused REGISTER (401 without a usable challenge) stays final', () async {
      makeClient();
      server.registerStatus = 401;
      await signIn();
      await eventually(() => client.connectionState == ConnectionStateStatus.failed);
      expect(errors.map((e) => e.code), contains('registration_failed'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(server.connections, 1, reason: 'a refusal is not retried');
    });

    test('a 503 to a refresh during a call: the call goes on, and the client reconnects once it ends',
        () async {
      makeClient(peer: FakePeer());
      await signIn();
      await eventually(() => client.isConnected);
      sip.debugReceive(inboundInvite());
      await client.acceptCall();
      expect(client.callState, CallStateStatus.active);

      server.registerStatus = 503;
      expect(sip.refreshRegistration(), isTrue);
      await eventually(() => client.connectionState == ConnectionStateStatus.reconnecting);
      expect(client.callState, CallStateStatus.active, reason: 'a failed refresh does not end the call');
      expect(server.connections, 1, reason: 'the call keeps its socket');

      server.registerStatus = 200;
      await client.hangup();
      await eventually(() => client.isConnected && server.connections == 2,
          reason: 'reconnected after the call');
      expect(sawFailedState(), isFalse);
      expect(errors.map((e) => e.code), isNot(contains('registration_failed')));
    });

    test('a reconnect attempt that fails reports reconnecting, not failed, until the last one', () async {
      makeClient();
      await signIn();
      await eventually(() => client.isConnected);
      server.acceptConnections = false;
      await server.dropAll();

      await eventually(() => errors.any((e) => e.code == 'reconnect_failed'));
      final failed = conn.where((e) => e.connectionState == ConnectionStateStatus.failed).toList();
      expect(failed, hasLength(1), reason: 'only the terminal event: ${failed.map((e) => e.message)}');
      expect(errors.map((e) => e.code), isNot(contains('connect_failed')));

      server.acceptConnections = true;
      client.reconnect();
      await eventually(() => client.isConnected);
    });
  });

  group('a sign-in overtaken while it connects', () {
    test('signing out stops it: no connection, no error, nothing after Disconnected', () async {
      makeClient();
      final signingIn = signIn();
      await client.disconnect();
      await signingIn;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.connections, 0);
      expect(conn.last.message, 'Disconnected');
      expect(errors, isEmpty);
      expect(client.connectionState, ConnectionStateStatus.disconnected);
    });

    test('a second sign-in wins: only its user registers, with no error', () async {
      makeClient();
      final first = signIn('alice');
      final second = signIn('bob');
      await Future.wait(<Future<void>>[first, second]);
      await eventually(() => client.isConnected);
      expect(client.sipUsername, 'bob');
      expect(server.registers, isNotEmpty);
      expect(server.registers.every((m) => m.contains('sip:bob@')), isTrue,
          reason: 'alice never registered: ${server.registers.map((m) => m.split('\r\n')[3])}');
      expect(errors, isEmpty);
    });
  });

  group('SIPService.connect overtaken before its handshake', () {
    test('by disconnect(): it stops with SipConnectSuperseded and leaves the state alone', () async {
      final s = SIPService(wsUrl: server.url, sipServer: 'registrar.vobiz.ai');
      final connecting = s.connect();
      await s.disconnect();
      await expectLater(connecting, throwsA(isA<SipConnectSuperseded>()));
      expect(s.connectionState.value, SipConnectionState.disconnected);
    });

    test('by a second connect(): the first stops, the second is listened to and registers', () async {
      final s = SIPService(wsUrl: server.url, sipServer: 'registrar.vobiz.ai');
      final first = s.connect();
      final second = s.connect();
      await expectLater(first, throwsA(isA<SipConnectSuperseded>()));
      await second;
      expect(s.connectionState.value, SipConnectionState.connected);
      s.register('play1', 'secret');
      await eventually(() => s.registrationState.value == SipRegistrationState.registered);
      s.unregisterTimeout = const Duration(milliseconds: 10);
      await s.disconnect();
    });
  });
}
