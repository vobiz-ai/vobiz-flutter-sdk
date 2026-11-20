import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/screens/identity_panel.dart';

import 'support/fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A phone-sized screen (412 x 915 logical pixels), like the emulator.
  void usePhoneScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1236, 2745);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  /// The Identity list builds lazily: scroll back to its top, where the
  /// sign-in form is, before looking for the form's buttons.
  Future<void> scrollIdentityToTop(WidgetTester tester) async {
    final list = find.descendant(of: find.byType(IdentityPanel), matching: find.byType(Scrollable)).first;
    tester.state<ScrollableState>(list).position.jumpTo(0);
    await tester.pumpAndSettle();
  }

  testWidgets('offers both sign-in modes and nothing is pre-filled', (tester) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(const PlaygroundApp());
    await tester.pumpAndSettle();

    expect(find.text('Zero-Config Setup'), findsOneWidget);
    expect(find.text('SIP Direct'), findsOneWidget);
    expect(find.text('PRODUCTION WEBHOOK CALLBACK'), findsOneWidget);
    expect(find.text('https://rtc-demo.vobiz.ai'), findsOneWidget);

    final authId = tester.widget<TextField>(find.byKey(const Key('authId')));
    final authToken = tester.widget<TextField>(find.byKey(const Key('authToken')));
    expect(authId.controller!.text, isEmpty);
    expect(authToken.controller!.text, isEmpty);

    await tester.tap(find.text('SIP Direct'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sipUsername')), findsOneWidget);
    expect(find.byKey(const Key('sipPassword')), findsOneWidget);
  });

  testWidgets('refuses to connect without credentials, and says why', (tester) async {
    usePhoneScreen(tester);
    final controller = PlaygroundController();
    await tester.pumpWidget(PlaygroundApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('connect')));
    await tester.tap(find.byKey(const Key('connect')));
    await tester.pumpAndSettle();
    expect(controller.logs.last.message, 'Please enter Auth ID and Auth Token');
    expect(controller.status, PhoneStatus.offline);

    controller.setAuthTab(AuthTab.sipDirect);
    await tester.pumpAndSettle();
    await scrollIdentityToTop(tester);
    await tester.ensureVisible(find.byKey(const Key('connect')));
    await tester.tap(find.byKey(const Key('connect')));
    await tester.pumpAndSettle();
    expect(controller.logs.last.message, 'Please enter both SIP username and password');
  });

  testWidgets('coming back to the app reads the call permissions again', (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final screen = FakeCallScreen();
    final controller = PlaygroundController(client: FakeClient(), callScreen: screen, platform: FakeCallPlatform());
    await tester.pumpWidget(PlaygroundApp(controller: controller));
    await tester.pumpAndSettle();
    expect(controller.fullScreenAllowed, isNull);

    // "Allow" opened Settings, and full-screen notifications were turned on there.
    screen.fullScreen = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.fullScreenAllowed, isTrue);
  });

  test('the header editor reports every rejected row, like the web Playground', () {
    final controller = PlaygroundController();
    controller.addHeaderRow(name: 'X-VH-Order-Id', value: 'A1234');
    controller.addHeaderRow(name: 'Order', value: 'x');
    controller.addHeaderRow(name: 'X-VH-Plan', value: 'has space');
    controller.addHeaderRow(); // pristine: ignored
    final built = controller.buildRowHeaders();
    expect(built.headers, <String, String>{'X-VH-Order-Id': 'A1234'});
    expect(built.errors, hasLength(2));
  });
}
