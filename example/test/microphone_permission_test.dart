import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// A call answered without microphone access (iOS, from CallKit).
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

  test('says how to turn the microphone on', () async {
    client.fakeErrors.add(ErrorEvent(
        code: VobizErrorCode.microphonePermissionDenied, message: 'This app may not use the microphone'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.microphoneAllowed, isFalse);
    expect(controller.logs.last.message, contains('Settings → this app → Microphone'));
  });
}
