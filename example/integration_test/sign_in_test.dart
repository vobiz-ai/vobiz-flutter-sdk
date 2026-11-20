import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

/// Signs in for real, through the UI, on a device or emulator:
///
/// ```
/// flutter test integration_test/sign_in_test.dart -d DEVICE_ID \
///   --dart-define-from-file=PATH_TO_JSON
/// ```
///
/// where the JSON file (kept outside the repository) holds `VOBIZ_AUTH_ID` and
/// `VOBIZ_AUTH_TOKEN`. The credentials come from the command line, never from this file.
/// Storage is replaced by in-memory fakes, so the test neither reads nor
/// erases a sign-in saved on the device. Without the credentials the test is
/// skipped.
///
/// Zero-Config Setup rotates the password of the account's "Vobiz WebRTC
/// Playground Endpoint", exactly as signing in on the web Playground does.
const String authId = String.fromEnvironment('VOBIZ_AUTH_ID');
const String authToken = String.fromEnvironment('VOBIZ_AUTH_TOKEN');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(WidgetTester tester, bool Function() done,
      {Duration timeout = const Duration(seconds: 45)}) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(end)) return;
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  bool settled(PlaygroundController c) =>
      c.status == PhoneStatus.online ||
      c.status == PhoneStatus.error ||
      (c.status == PhoneStatus.offline && c.statusText == 'Error');

  testWidgets(
    'Zero-Config Setup, then SIP Direct with the endpoint it provisioned',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final controller = PlaygroundController();
      await tester.pumpWidget(PlaygroundApp(controller: controller));
      await tester.pumpAndSettle();
      controller.update(() => controller.rememberMe = false);

      // ── Zero-Config Setup, typed into the form ──────────────────────────────
      await tester.enterText(find.byKey(const Key('authId')), authId);
      await tester.enterText(find.byKey(const Key('authToken')), authToken);
      await tester.ensureVisible(find.byKey(const Key('connect')));
      await tester.tap(find.byKey(const Key('connect')));
      await waitFor(tester, () => settled(controller));

      expect(controller.status, PhoneStatus.online, reason: controller.logsText());
      expect(controller.authMode, VobizAuthMode.zeroConfig);
      expect(controller.logs.map((l) => l.message),
          contains(predicate<String>((m) => m.startsWith('Provisioned App ID'))));
      expect(controller.logs.map((l) => l.message),
          contains(predicate<String>((m) => m.startsWith('Registered successfully as'))));
      final provisioned = controller.connectedAs;
      expect(provisioned, isNotNull);
      // Sign-out forgets the password, so keep the one Zero-Config provisioned.
      final password = controller.sipPassword;
      // ignore: avoid_print
      print('Zero-Config: registered as $provisioned');

      // ── Disconnect from the Identity tab ────────────────────────────────────
      await tester.tap(find.text('Identity'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('disconnect')));
      await tester.tap(find.byKey(const Key('disconnect')));
      await tester.pumpAndSettle();
      expect(controller.status, PhoneStatus.offline);
      expect(controller.authMode, VobizAuthMode.none);

      // ── SIP Direct with the provisioned endpoint ────────────────────────────
      // Zero-Config filled the SIP Direct username, as the web Playground
      // does; the password was forgotten at sign-out, so type it back.
      await tester.tap(find.text('SIP Direct'));
      await tester.pumpAndSettle();
      expect(controller.sipUsername, provisioned);
      await tester.enterText(find.byKey(const Key('sipPassword')), password);
      await tester.ensureVisible(find.byKey(const Key('connect')));
      await tester.tap(find.byKey(const Key('connect')));
      await waitFor(tester, () => settled(controller));

      expect(controller.status, PhoneStatus.online, reason: controller.logsText());
      expect(controller.authMode, VobizAuthMode.sipDirect);
      // ignore: avoid_print
      print('SIP Direct: registered as ${controller.client.sipUsername}');

      await controller.disconnect();
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('Trace:\n${controller.logsText()}');
    },
    skip: authId.isEmpty || authToken.isEmpty,
  );
}
