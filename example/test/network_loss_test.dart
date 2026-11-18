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

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  int answers() => controller.logs.where((l) => l.message.contains('Call answered')).length;

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

    // Registered again: back to the dial pad.
    client.connected = true;
    client.connection = null;
    client.fakeConnections.add(ConnectionEvent(
      connectionState: ConnectionStateStatus.connected,
      registrationState: RegistrationState.registered,
    ));
    await settle();
    expect(controller.status, PhoneStatus.online);
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

    client.connected = true;
    client.connection = null;
    client.fakeConnections.add(ConnectionEvent(
      connectionState: ConnectionStateStatus.connected,
      registrationState: RegistrationState.registered,
    ));
    await settle();
    expect(controller.status, PhoneStatus.online);
  });
}
