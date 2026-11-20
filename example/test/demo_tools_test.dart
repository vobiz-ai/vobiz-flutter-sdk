import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/demo_client.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// The release gate: demo and test-only tools (Zero-Config, account
/// credentials for push sign-up, the test call) only with kDemoTools.
void main() {
  /// Everything a debug build may have saved: the Zero-Config pair, the push
  /// account, an endpoint login, and the Zero-Config tab.
  const saved = <String, String>{
    'vobiz_auth_id': 'MA_X',
    'vobiz_auth_token': 'account-token',
    'vobiz_push_auth_id': 'MA_X',
    'vobiz_push_auth_token': 'account-token',
    'vobiz_sip_username': 'play1',
    'vobiz_sip_password': 'pw',
  };

  late List<http.Request> requests;

  PlaygroundController make({required bool demoTools, Map<String, String> secure = saved}) {
    SharedPreferences.setMockInitialValues(<String, Object>{'vobiz_playground_mode': 'api'});
    FlutterSecureStorage.setMockInitialValues(secure);
    requests = <http.Request>[];
    return PlaygroundController(
      client: FakeClient(),
      callScreen: FakeCallScreen(),
      platform: FakeCallPlatform(),
      push: FakePush(),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{"message":"ok"}', 200);
      }),
      demoTools: demoTools,
    );
  }

  test('debug builds and tests have the tools; the SDK\'s demo gate follows the switch', () {
    expect(kDemoTools, isTrue);
    expect(playgroundConfig().unsafeDemoZeroConfig, isTrue);
    expect(playgroundConfig(demoTools: false).unsafeDemoZeroConfig, isFalse);
  });

  group('without the demo tools (a release build)', () {
    test('no Zero-Config: SIP Direct by default, also for a saved Zero-Config tab, and it cannot be chosen', () async {
      final c = make(demoTools: false);
      expect(c.authTab, AuthTab.sipDirect);
      await c.init();
      expect(c.authTab, AuthTab.sipDirect);
      c.setAuthTab(AuthTab.zeroConfig);
      expect(c.authTab, AuthTab.sipDirect);
      c.dispose();
    });

    test('the account\'s saved credentials are not read, and the push account is not saved', () async {
      final c = make(demoTools: false);
      await c.init();
      expect(c.authId, isEmpty);
      expect(c.authToken, isEmpty);
      expect(c.pushAuthId, isEmpty);
      expect(c.pushAuthToken, isEmpty);
      expect(c.sipUsername, 'play1', reason: 'an endpoint login is not an account credential');
      await c.setPushAccount(authId: 'MA_Y', authToken: 'other');
      expect(c.pushAuthToken, isEmpty);
      expect(await const FlutterSecureStorage().read(key: 'vobiz_push_auth_id'), 'MA_X');
      c.dispose();
    });

    test('Vobiz push without a sample server asks for its line and sends nothing to Vobiz', () async {
      final c = make(demoTools: false);
      await c.init();
      await c.connect();
      await pumpEventQueue();
      await c.setVobizPush(true);
      await pumpEventQueue();
      expect(c.vobizPushState, PushState.failed);
      expect(c.vobizPushDetail, contains('sample server'));
      expect(c.vobizPushDetail, isNot(contains('Auth Token')));
      expect(requests, isEmpty);
      c.dispose();
    });

    test('Vobiz push with a sample server signs up through it', () async {
      final c = make(demoTools: false, secure: <String, String>{
        ...saved,
        'vobiz_push_server': 'https://bridge.example#key=k1',
      });
      await c.init();
      await c.connect();
      await pumpEventQueue();
      await c.setVobizPush(true);
      await pumpEventQueue();
      expect(c.vobizPushState, PushState.ready);
      expect(requests.single.url.host, 'bridge.example');
      c.dispose();
    });

    test('"Call this phone through Vobiz" does nothing', () async {
      final c = make(demoTools: false, secure: <String, String>{
        ...saved,
        'vobiz_push_server': 'https://bridge.example#key=k1',
      });
      await c.init();
      await c.connect();
      await pumpEventQueue();
      await c.setVobizPush(true);
      await pumpEventQueue();
      await c.setVobizCallTest(from: '14155551234', answerUrl: 'https://example.com/answer');
      requests.clear();
      await c.callThisPhoneThroughVobiz();
      expect(requests, isEmpty);
      expect(c.status, PhoneStatus.online, reason: 'the connection was not dropped');
      c.dispose();
    });
  });

  group('the Identity tab', () {
    void usePhoneScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(1236, 2745);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
    }

    for (final demoTools in <bool>[true, false]) {
      testWidgets(demoTools ? 'with the demo tools: Zero-Config and the test tools are offered' : 'without them: none of them is built',
          (tester) async {
        usePhoneScreen(tester);
        final c = make(demoTools: demoTools);
        await tester.pumpWidget(PlaygroundApp(controller: c));
        await tester.pumpAndSettle();
        await c.setVobizPush(true);
        await tester.pumpAndSettle();

        final shown = demoTools ? findsOneWidget : findsNothing;
        expect(find.text('Zero-Config Setup'), shown);
        expect(find.text('SIP Direct'), findsOneWidget);
        expect(find.byKey(const Key('pushAuthId'), skipOffstage: false), shown);
        expect(find.byKey(const Key('pushAuthToken'), skipOffstage: false), shown);
        expect(find.byKey(const Key('testCallFrom'), skipOffstage: false), shown);
        expect(find.byKey(const Key('vobizTestCall'), skipOffstage: false), shown);
        expect(find.byKey(const Key('vobizPush'), skipOffstage: false), findsOneWidget);
      });
    }
  });
}
