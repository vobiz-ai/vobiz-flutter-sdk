import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/push/push_service.dart';

import 'fakes.dart';

/// A Zero-Config sign-in saved with Remember me: enough for a push to sign
/// the closed app in.
const Map<String, String> savedZeroConfig = <String, String>{
  'vobiz_auth_id': 'MA_X',
  'vobiz_auth_token': 'tok',
};

/// A phone-sized screen (412 x 915 logical pixels), like the emulator.
void usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1236, 2745);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// A controller on the fakes, started as the app starts it, on a device that
/// had saved [secure] and [prefs].
Future<PlaygroundController> startController({
  required FakeClient client,
  required FakeCallScreen screen,
  required FakeCallPlatform platform,
  Map<String, String> secure = const <String, String>{},
  Map<String, Object> prefs = const <String, Object>{},
  PushService? push,
  http.Client? httpClient,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  FlutterSecureStorage.setMockInitialValues(secure);
  final controller = PlaygroundController(
    client: client,
    callScreen: screen,
    platform: platform,
    push: push,
    httpClient: httpClient,
  );
  await controller.init();
  return controller;
}
