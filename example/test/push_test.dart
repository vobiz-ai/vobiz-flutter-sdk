import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/push/push_bridge_api.dart';
import 'package:vobiz_webrtc_example/src/push/push_call.dart';

import 'support/setup.dart';

void main() {
  group('PushCall', () {
    Map<String, dynamic> vobiz({required DateTime expires}) => <String, dynamic>{
          'type': 'incoming_call',
          'call_id': 'held-1@10.0.2.9',
          'caller': 'Asha',
          'callee': 'play1',
          'index': '4211',
          'label': '1938273',
          'registrar': '203.0.113.10',
          'expires_at': '${expires.millisecondsSinceEpoch ~/ 1000}',
        };

    test('ignores messages that are not incoming-call pushes', () {
      expect(PushCall.fromData(<String, dynamic>{'type': 'promo', 'call_id': 'x'}), isNull);
      expect(PushCall.fromData(<String, dynamic>{'type': 'incoming_call'}), isNull);
      expect(PushCall.fromData(<String, dynamic>{'type': 'call_ended', 'call_id': 'x'}), isNull);
      expect(PushCall.fromData(<String, dynamic>{'type': 'cancel', 'call_id': 'x'}), isNull);
    });

    test('a push past its expiry is stale', () {
      // Well past expiry: the SDK still takes a push up to 30 s late (a fast phone clock).
      final stale = PushCall.fromData(vobiz(expires: DateTime.now().subtract(const Duration(minutes: 2))))!;
      expect(stale.sdkPush!.isExpired(), isTrue);
      final live = PushCall.fromData(vobiz(expires: DateTime.now().add(const Duration(seconds: 30))))!;
      expect(live.sdkPush!.isExpired(), isFalse);
    });
  });

  group('the sample server\'s SIP headers', () {
    test('pushRefFromHeaders reads both spellings', () {
      expect(pushRefFromHeaders(<String, String>{'X-VH-PushRef': 'ref-1'}), 'ref-1');
      expect(pushRefFromHeaders(<String, String>{'X-VH-PushRefX-VH': 'ref-2'}), 'ref-2');
      expect(pushRefFromHeaders(<String, String>{'X-VH-PushRef': 'a%20b'}), 'a b');
      expect(pushRefFromHeaders(const <String, String>{}), isNull);
    });

    test('reads the real caller the server passed', () {
      expect(callerFromHeaders(<String, String>{'X-VH-Caller': '919876543210'}), '+919876543210');
      expect(callerFromHeaders(const <String, String>{}), isNull);
    });
  });

  group('PushBridgeConfig', () {
    test('reads the line the server prints', () {
      final config = PushBridgeConfig.parse('  https://abc.trycloudflare.com/#key=s3cr3t_-x  ')!;
      expect(config.baseUrl, 'https://abc.trycloudflare.com');
      expect(config.key, 's3cr3t_-x');
      expect(config.isHttps, isTrue);
    });

    test('refuses lines without a key or address', () {
      expect(PushBridgeConfig.parse('https://abc.trycloudflare.com'), isNull);
      expect(PushBridgeConfig.parse('https://abc.trycloudflare.com#key='), isNull);
      expect(PushBridgeConfig.parse('#key=abc'), isNull);
      expect(PushBridgeConfig.parse('ftp://host#key=abc'), isNull);
    });

    test('allows plain http for a server on the local network, outside release builds only', () {
      expect(kAllowHttp, isTrue, reason: 'tests run as a debug build');
      final config = PushBridgeConfig.parse('http://10.0.2.2:8787#key=abc')!;
      expect(config.isHttps, isFalse);
      expect(PushBridgeConfig.parse('http://10.0.2.2:8787#key=abc', allowHttp: false), isNull);
      expect(PushBridgeConfig.parse('https://abc.trycloudflare.com#key=abc', allowHttp: false), isNotNull);
    });

    test('a release build refuses an http server line, and says why', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final controller = PlaygroundController(allowHttp: false);
      addTearDown(controller.dispose);
      expect(await controller.setPushServer('http://192.168.1.20:8787#key=abc'), contains('https://'));
      expect(controller.pushServer, isEmpty);
      expect(await controller.setPushServer('https://abc.trycloudflare.com#key=abc'), isNull);
      expect(controller.bridgeConfig, isNotNull);
    });
  });

  group('PushBridgeApi', () {
    final config = PushBridgeConfig.parse('https://bridge.example#key=abc123')!;

    test('sends X-Bridge-Key and X-Bridge-User, never Authorization', () async {
      final seen = <http.Request>[];
      final api = PushBridgeApi(config, sipUser: 'play1', client: MockClient((request) async {
        seen.add(request);
        return http.Response(jsonEncode(<String, Object>{'ok': true, 'token': 'a.b.c'}), 200);
      }));
      expect(await api.accessToken(sub: 'agent42', reason: 'sign_in'), 'a.b.c');
      await api.callAlive('uuid-1');
      await api.callEnded('uuid-1');
      expect(seen.map((r) => r.url.toString()), <String>[
        'https://bridge.example/token',
        'https://bridge.example/call/alive',
        'https://bridge.example/call/ended',
      ]);
      for (final r in seen) {
        expect(r.headers['X-Bridge-Key'], 'abc123');
        expect(r.headers['X-Bridge-User'], 'play1');
        expect(r.headers.containsKey('Authorization'), isFalse);
      }
      expect(jsonDecode(seen[0].body), <String, Object?>{'reason': 'sign_in', 'sub': 'agent42'});
      expect(jsonDecode(seen[1].body), <String, Object?>{'call_uuid': 'uuid-1'});
    });

    test('leaves out X-Bridge-User when the app is not signed in', () async {
      late http.Request seen;
      final api = PushBridgeApi(config, client: MockClient((request) async {
        seen = request;
        return http.Response('{"token":"a.b.c"}', 200);
      }));
      await api.accessToken(reason: 'sign_in');
      expect(seen.headers['X-Bridge-Key'], 'abc123');
      expect(seen.headers.containsKey('X-Bridge-User'), isFalse);
      expect(jsonDecode(seen.body), <String, Object?>{'reason': 'sign_in'});
      expect(PushBridgeApi.headers(config, sipUser: ''), <String, String>{'X-Bridge-Key': 'abc123'});
    });

    test('explains a wrong key', () async {
      final api = PushBridgeApi(config,
          client: MockClient((_) async => http.Response('{"error":"Wrong or missing bridge key"}', 401)));
      await expectLater(
        api.accessToken(reason: 'sign_in'),
        throwsA(isA<PushBridgeException>()
            .having((e) => e.message, 'message', contains('#key='))
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('a reply without a token is an error', () async {
      final api = PushBridgeApi(config, client: MockClient((_) async => http.Response('{"ok":true}', 200)));
      await expectLater(api.accessToken(reason: 'sign_in'), throwsA(isA<PushBridgeException>()));
    });

    test('does not close an HTTP client it was given', () async {
      var calls = 0;
      final web = MockClient((_) async {
        calls++;
        return http.Response('{"token":"t"}', 200);
      });
      PushBridgeApi(config, client: web).close();
      await PushBridgeApi(config, client: web).accessToken(reason: 'refresh');
      expect(calls, 1);
    });
  });

  group('Identity panel', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });


    testWidgets('Vobiz push starts off, the connection watch waits for a server line, and a bad line is refused',
        (tester) async {
      usePhoneScreen(tester);
      final controller = PlaygroundController();
      await tester.pumpWidget(PlaygroundApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('INCOMING CALLS'));
      expect(find.text('OFF'), findsOneWidget);
      expect(find.text('SAMPLE SERVER'), findsOneWidget);
      expect(find.byKey(const Key('receiveCalls')), findsNothing);
      expect(find.byKey(const Key('testCall')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('connectionWatch')));
      expect(tester.widget<Switch>(find.byKey(const Key('connectionWatch'))).onChanged, isNull);

      expect(await controller.setPushServer('https://abc.trycloudflare.com'), contains('#key='));
      expect(controller.pushServer, isEmpty);
    });
  });
}
