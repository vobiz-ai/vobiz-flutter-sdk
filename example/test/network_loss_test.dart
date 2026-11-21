import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// The SDK's dropped-connection events, and a call that ends while the
/// network is down.
void main() {
  late FakeClient client;
  late PlaygroundController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    client = FakeClient();
    controller = PlaygroundController(
        client: client, callScreen: FakeCallScreen(), platform: FakeCallPlatform());
    await controller.init();
  });

  tearDown(() => controller.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  int answers() => controller.logs.where((l) => l.message.contains('Call answered')).length;

  Future<void> signIn() async {
    controller
      ..authId = 'MA_X'
      ..authToken = 'tok';
    await controller.connect();
    await settle();
    expect(controller.status, PhoneStatus.online);
  }

  /// What the SDK reports when its socket drops: it reconnects by itself.
  void dropSocket() {
    client.connected = false;
    client.connection = ConnectionStateStatus.reconnecting;
    client.fakeConnections.add(ConnectionEvent(
      connectionState: ConnectionStateStatus.reconnecting,
      registrationState: RegistrationState.unregistered,
      message: 'Socket error: Connection reset by peer',
    ));
  }

  void registerAgain() {
    client.connected = true;
    client.connection = null;
    client.fakeConnections.add(ConnectionEvent(
      connectionState: ConnectionStateStatus.connected,
      registrationState: RegistrationState.registered,
    ));
  }

  /// What the SDK reports when its reconnects give up.
  void giveUp() {
    client.connection = ConnectionStateStatus.failed;
    client.fakeConnections.add(ConnectionEvent(
      connectionState: ConnectionStateStatus.failed,
      registrationState: RegistrationState.failed,
      message: 'Gave up after 10 attempts: timeout',
    ));
    client.fakeErrors.add(ErrorEvent(code: 'reconnect_failed', message: 'Gave up after 10 attempts: timeout'));
  }

  group('a connection lost while idle', () {
    test('shows Reconnecting..., and Disconnect stays reachable', () async {
      await signIn();
      dropSocket();
      await settle();
      expect(controller.status, PhoneStatus.connecting);
      expect(controller.statusText, 'Reconnecting...');
      expect(controller.isSignedIn, isTrue, reason: 'the connected card, with Disconnect, stays');
    });

    test('coming back shows Registered without pulling the user to another tab', () async {
      await signIn();
      final tabs = <int>[];
      controller.onTabRequest = tabs.add;
      dropSocket();
      await settle();
      registerAgain();
      await settle();
      expect(controller.status, PhoneStatus.online);
      expect(controller.statusText, 'Registered');
      expect(tabs, isEmpty);
    });

    test('a reconnect that gives up shows an error, and Connect works again', () async {
      await signIn();
      dropSocket();
      await settle();
      giveUp();
      await settle();
      expect(controller.status, PhoneStatus.error);
      expect(controller.isSignedIn, isFalse, reason: 'the sign-in form, with Connect, is back');
      expect(controller.connectError, contains('Gave up after 10 attempts'));
    });

    test('one failed attempt is not the end: the reconnect goes on', () async {
      await signIn();
      dropSocket();
      await settle();
      client.fakeConnections.add(ConnectionEvent(
        connectionState: ConnectionStateStatus.failed,
        registrationState: RegistrationState.failed,
        message: 'Connection failed: SocketException',
      ));
      client.fakeErrors.add(ErrorEvent(code: 'connect_failed', message: 'Could not connect'));
      await settle();
      expect(controller.status, PhoneStatus.connecting);
      expect(controller.statusText, 'Reconnecting...');
    });
  });

  test('a dropped connection and its recovery are not new answers', () async {
    client.connected = true;
    client.emit(CallStateStatus.active, dir: CallDirection.outbound);
    await settle();
    expect(answers(), 1);

    client.emit(CallStateStatus.active, dir: CallDirection.outbound, reason: 'reconnecting');
    await settle();
    expect(controller.status, PhoneStatus.inCall);
    expect(controller.statusText, 'Reconnecting...');

    client.emit(CallStateStatus.active, dir: CallDirection.outbound, reason: 'reconnected');
    await settle();
    expect(controller.statusText, 'In Call');
    expect(answers(), 1);
    client.emit(CallStateStatus.ended, dir: CallDirection.outbound);
    await settle();
  });

  test('a call that ends while the network is down leaves the call screen', () async {
    client.connected = true;
    client.emit(CallStateStatus.active, dir: CallDirection.outbound);
    await settle();

    // The SDK lost its network and gave up on the call.
    client.connected = false;
    client.connection = ConnectionStateStatus.reconnecting;
    client.emit(CallStateStatus.ended, dir: CallDirection.outbound, reason: 'network_lost');
    await settle();
    expect(controller.status, PhoneStatus.connecting);
    expect(controller.statusText, 'Reconnecting...');
    expect(controller.isSignedIn, isTrue, reason: 'Disconnect stays reachable while it reconnects');

    // Registered again: back to the dial pad.
    registerAgain();
    await settle();
    expect(controller.status, PhoneStatus.online);
  });

  test('a call that ended while offline, then a reconnect that gives up: Connect works again', () async {
    client.connected = true;
    client.emit(CallStateStatus.active, dir: CallDirection.outbound);
    await settle();
    client.connected = false;
    client.connection = ConnectionStateStatus.reconnecting;
    client.emit(CallStateStatus.ended, dir: CallDirection.outbound, reason: 'network_lost');
    await settle();
    giveUp();
    await settle();
    expect(controller.status, PhoneStatus.error);
    expect(controller.isSignedIn, isFalse);
  });

  // Seen live 2026-10-26: the network went while an outgoing call rang. The
  // SDK ended the call, but the app stayed on "Ringing" for good: re-registering
  // leaves a ringing screen alone, as if a call were still up.
  test('an outgoing call still ringing when the network drops leaves the ringing screen', () async {
    client.connected = true;
    client.emit(CallStateStatus.ringing, dir: CallDirection.outbound);
    await settle();
    expect(controller.status, PhoneStatus.ringing);

    // The socket dropped: the SDK reports reconnecting, then ends a call not
    // yet answered at once.
    client.connected = false;
    client.connection = ConnectionStateStatus.reconnecting;
    client.emit(CallStateStatus.ended, dir: CallDirection.outbound, reason: 'network_lost');
    await settle();
    expect(controller.status, PhoneStatus.connecting);
    expect(controller.statusText, 'Reconnecting...');

    registerAgain();
    await settle();
    expect(controller.status, PhoneStatus.online);
  });
}
