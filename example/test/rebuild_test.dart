import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// #55: the whole MaterialApp used to rebuild on every notifyListeners,
/// twice a second during a call.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('a log line does not rebuild the MaterialApp; a theme change does', (tester) async {
    final controller = PlaygroundController(
        client: FakeClient(), callScreen: FakeCallScreen(), platform: FakeCallPlatform());
    await tester.pumpWidget(PlaygroundApp(controller: controller));
    await tester.pumpAndSettle();
    final before = tester.widget<MaterialApp>(find.byType(MaterialApp));

    controller.log('hello', LogType.info);
    await tester.pump();
    expect(identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), before), isTrue);

    controller.setThemeMode(ThemeMode.dark);
    await tester.pump();
    final after = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(after.themeMode, ThemeMode.dark);
  });

  testWidgets('the call clock ticks without notifying the controller', (tester) async {
    final client = FakeClient();
    final controller = PlaygroundController(
        client: client, callScreen: FakeCallScreen(), platform: FakeCallPlatform());
    await tester.pumpWidget(PlaygroundApp(controller: controller));
    await tester.pumpAndSettle();

    client.direction = CallDirection.outbound;
    client.emit(CallStateStatus.active, dir: CallDirection.outbound);
    await tester.pump();
    expect(controller.status, PhoneStatus.inCall);

    var notified = 0;
    var ticks = 0;
    controller.addListener(() => notified++);
    controller.callTicker.addListener(() => ticks++);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 10));
    expect(ticks, greaterThanOrEqualTo(3));
    expect(notified, 0);
    expect(controller.callDuration, const Duration(seconds: 3));

    client.emit(CallStateStatus.ended, dir: CallDirection.outbound);
    await tester.pumpAndSettle();
  });
}
