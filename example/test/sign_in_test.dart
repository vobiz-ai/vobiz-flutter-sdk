import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/screens/identity_panel.dart';

import 'support/fakes.dart';

void main() {
  late FakeClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    client = FakeClient();
  });

  PlaygroundController make() => PlaygroundController(
        client: client,
        callScreen: FakeCallScreen(),
        platform: FakeCallPlatform(),
      );

  void usePhoneScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1236, 2745);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  group('Connect shows what is wrong on the Identity tab (#57)', () {
    testWidgets('empty fields: an error under each, and the reason under Connect', (tester) async {
      usePhoneScreen(tester);
      final controller = make();
      await tester.pumpWidget(PlaygroundApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('connect')));
      await tester.tap(find.byKey(const Key('connect')));
      await tester.pumpAndSettle();

      final identity = find.byType(IdentityPanel);
      expect(find.descendant(of: identity, matching: find.text('Please enter Auth ID and Auth Token')),
          findsOneWidget);
      final list = find.descendant(of: identity, matching: find.byType(Scrollable)).first;
      tester.state<ScrollableState>(list).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.descendant(of: identity, matching: find.text('Required')), findsNWidgets(2));
      // Still in the Trace as well.
      expect(controller.logs.last.message, 'Please enter Auth ID and Auth Token');

      // Typing clears that field's error.
      await tester.enterText(find.byKey(const Key('authId')), 'MA_X');
      await tester.pumpAndSettle();
      expect(find.descendant(of: identity, matching: find.text('Required')), findsOneWidget);
    });

    testWidgets('a failed sign-in is shown under Connect too', (tester) async {
      usePhoneScreen(tester);
      final controller = make();
      await tester.pumpWidget(PlaygroundApp(controller: controller));
      await tester.pumpAndSettle();
      controller.update(() => controller
        ..authId = 'MA_X'
        ..authToken = 'tok'
        ..webhookUrl = 'http://localhost:3000');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('connect')));
      await tester.tap(find.byKey(const Key('connect')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connectError')), findsOneWidget);
      expect(controller.connectError, contains('Public Webhook URL is required'));
    });
  });

  group('Sign-out (#27)', () {
    test('removes the saved Auth Token and SIP password from secure storage', () async {
      final controller = make();
      await controller.init();
      controller
        ..authId = 'MA_X'
        ..authToken = 'master-token';
      await controller.connect();
      await pumpEventQueue();
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'vobiz_auth_token'), 'master-token');

      await controller.disconnect();
      expect(await storage.read(key: 'vobiz_auth_token'), isNull);
      expect(await storage.read(key: 'vobiz_auth_id'), isNull);
      expect(await storage.read(key: 'vobiz_sip_password'), isNull);
      expect(controller.authToken, isEmpty);
      expect(controller.sipPassword, isEmpty);
    });

    test('a sign-in still waiting for /api/setup does not come back after sign-out', () async {
      final controller = make();
      await controller.init();
      controller
        ..authId = 'MA_X'
        ..authToken = 'master-token';
      client.setupGate = Completer<void>();
      final signingIn = controller.connect();
      await controller.disconnect();
      client.setupGate!.complete();
      await signingIn;
      await pumpEventQueue();

      expect(client.actions.last, 'disconnect');
      expect(controller.status, PhoneStatus.offline);
      expect(await const FlutterSecureStorage().read(key: 'vobiz_auth_token'), isNull);
    });
  });

  test('a second Connect while one runs joins it: one sign-in, one socket (#35)', () async {
    final controller = make();
    await controller.init();
    controller
      ..authId = 'MA_X'
      ..authToken = 'tok';
    client.setupGate = Completer<void>();
    final first = controller.connect();
    final second = controller.connect();
    client.setupGate!.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(client.actions.where((a) => a == 'connectWithAuthToken'), hasLength(1));
  });
}
