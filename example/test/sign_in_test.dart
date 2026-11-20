import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
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

  group('Sign-out with Vobiz push', () {
    late List<http.Request> requests;
    late Completer<void> logoutGate;

    PlaygroundController makeWithPush() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'vobiz_sip_username': 'play1',
        'vobiz_sip_password': 'pw',
        'vobiz_push_server': 'https://bridge.example#key=k1',
      });
      requests = <http.Request>[];
      logoutGate = Completer<void>();
      return PlaygroundController(
        client: client,
        callScreen: FakeCallScreen(),
        platform: FakeCallPlatform(),
        push: FakePush(),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.method == 'DELETE') await logoutGate.future;
          return http.Response('{"message":"ok"}', 200);
        }),
      );
    }

    test('signs out locally first, then takes the phone off Vobiz push as the SIP user it was', () async {
      final controller = makeWithPush();
      await controller.init();
      controller.setAuthTab(AuthTab.sipDirect);
      await controller.connect();
      await pumpEventQueue();
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect(controller.vobizPushState, PushState.ready);

      final signingOut = controller.disconnect();
      await pumpEventQueue();
      // The push sign-out is still on its way; the phone is already signed out.
      expect(client.actions, contains('disconnect'));
      expect(controller.status, PhoneStatus.offline);
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'vobiz_sip_password'), isNull);
      expect(await storage.read(key: 'vobiz_push_server'), isNull, reason: 'the line carries the server key');
      expect(controller.pushServer, isEmpty);
      final logout = requests.singleWhere((r) => r.method == 'DELETE');
      expect(logout.url.toString(), 'https://bridge.example/push/devices/logout');
      expect(logout.headers['X-Bridge-User'], 'play1', reason: 'read before the client let go of the user');

      logoutGate.complete();
      await signingOut;
      controller.dispose();
    });

    test('a second Disconnect while one runs joins it', () async {
      final controller = makeWithPush();
      await controller.init();
      controller.setAuthTab(AuthTab.sipDirect);
      await controller.connect();
      await pumpEventQueue();
      await controller.setVobizPush(true);
      await pumpEventQueue();
      final first = controller.disconnect();
      final second = controller.disconnect();
      logoutGate.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(client.actions.where((a) => a == 'disconnect'), hasLength(1));
      expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
      controller.dispose();
    });

    test('turning Vobiz push off before signing in (after a restart) still removes the device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'vobiz_playground_vobiz_push': true,
        'vobiz_push_install_id': 'vobiz-example-0011',
      });
      final controller = makeWithPush();
      await controller.init();
      logoutGate.complete();
      await controller.setVobizPush(false);
      final logout = requests.single;
      expect(logout.method, 'DELETE');
      expect(jsonDecode(logout.body), <String, Object?>{'device_id': 'vobiz-example-0011'});
      expect(logout.headers['X-Bridge-Key'], 'k1');
      expect(logout.headers.containsKey('X-Bridge-User'), isFalse, reason: 'not signed in');
      controller.dispose();
    });
  });

  group('Remember me', () {
    test('unticked, the push account saved earlier goes too', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'vobiz_push_auth_id': 'MA_X',
        'vobiz_push_auth_token': 'account-token',
      });
      final controller = make();
      await controller.init();
      expect(controller.pushAuthToken, 'account-token');
      controller
        ..rememberMe = false
        ..authId = 'MA_X'
        ..authToken = 'tok';
      await controller.connect();
      await pumpEventQueue();
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'vobiz_push_auth_token'), isNull);
      expect(await storage.read(key: 'vobiz_push_auth_id'), isNull);
      expect(controller.pushAuthToken, 'account-token', reason: 'still usable in this session');
      controller.dispose();
    });

    test('unticking it removes what was saved at once, without signing in again', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'vobiz_auth_id': 'MA_X',
        'vobiz_auth_token': 'tok',
        'vobiz_sip_username': 'play1',
        'vobiz_sip_password': 'pw',
        'vobiz_push_auth_id': 'MA_X',
        'vobiz_push_auth_token': 'account-token',
      });
      final controller = make();
      await controller.init();
      await controller.setRememberMe(false);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('vobiz_playground_remember'), isFalse);
      controller.dispose();
    });

    test('saving the push account with a field emptied removes the saved one', () async {
      final controller = make();
      await controller.init();
      await controller.setPushAccount(authId: 'MA_X', authToken: 'account-token');
      expect(await const FlutterSecureStorage().read(key: 'vobiz_push_auth_token'), 'account-token');
      await controller.setPushAccount(authId: 'MA_X', authToken: '');
      expect(await const FlutterSecureStorage().read(key: 'vobiz_push_auth_token'), isNull);
      controller.dispose();
    });

    test('a sign-in whose first attempt failed but that the SDK completed by itself is remembered', () async {
      final controller = make();
      await controller.init();
      controller.setAuthTab(AuthTab.sipDirect);
      controller
        ..sipUsername = 'play1'
        ..sipPassword = 'pw';
      client.failConnect = StateError('socket closed');
      await controller.connect();
      expect(controller.status, PhoneStatus.error);
      // The SDK's own reconnect then registers.
      client.connected = true;
      client.username = 'play1';
      client.fakeConnections.add(ConnectionEvent(
        connectionState: ConnectionStateStatus.connected,
        registrationState: RegistrationState.registered,
      ));
      await pumpEventQueue();
      expect(controller.status, PhoneStatus.online);
      expect(await const FlutterSecureStorage().read(key: 'vobiz_sip_password'), 'pw');
      controller.dispose();
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
