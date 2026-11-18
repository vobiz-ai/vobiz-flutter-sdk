import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/push/push_bridge_api.dart';
import 'package:vobiz_webrtc_example/src/push/push_call.dart';

void main() {
  group('PushCall', () {
    final data = <String, dynamic>{
      'type': 'incoming_call',
      'call_id': '3f2b6c1e-0000-4000-8000-000000000001',
      'call_key': 'k123',
      'caller': '+919876543210',
      'callee': '+918000000000',
      'server': 'https://bridge.example',
      'sent_at': '1700000000000',
      'expires_at': '${DateTime.now().add(const Duration(seconds: 40)).millisecondsSinceEpoch}',
    };

    test('reads an incoming-call push', () {
      final call = PushCall.fromData(data)!;
      expect(call.kind, PushKind.incomingCall);
      expect(call.callId, '3f2b6c1e-0000-4000-8000-000000000001');
      expect(call.callKey, 'k123');
      expect(call.caller, '+919876543210');
      expect(call.callee, '+918000000000');
      expect(call.server, 'https://bridge.example');
      expect(call.isExpired, isFalse);
      expect(call.isTest, isFalse);
    });

    test('ignores messages that are not from the bridge', () {
      expect(PushCall.fromData(<String, dynamic>{'type': 'promo', 'call_id': 'x'}), isNull);
      expect(PushCall.fromData(<String, dynamic>{'type': 'incoming_call'}), isNull);
    });

    test('a push past its expiry is stale', () {
      final stale = PushCall.fromData(<String, dynamic>{
        ...data,
        'expires_at': '${DateTime.now().subtract(const Duration(seconds: 1)).millisecondsSinceEpoch}',
      })!;
      expect(stale.isExpired, isTrue);
    });

    test('survives the round trip through the call screen', () {
      final call = PushCall.fromData(<String, dynamic>{...data, 'test': '1'})!;
      final back = PushCall.fromExtra(call.toExtra())!;
      expect(back.callId, call.callId);
      expect(back.callKey, call.callKey);
      expect(back.caller, call.caller);
      expect(back.server, call.server);
      expect(back.isTest, isTrue);
      expect(PushCall.fromExtra(<String, dynamic>{'source': 'sip', 'call_id': 'x'}), isNull);
      expect(PushCall.fromExtra(null), isNull);
    });

    test('expires ttl_ms after it arrived, whatever the bridge clock says (#50)', () {
      final arrived = DateTime(2026, 1, 1, 12);
      final call = PushCall.fromData(<String, dynamic>{
        ...data,
        'ttl_ms': '30000',
        // A bridge clock an hour behind this phone's: ignored with ttl_ms.
        'expires_at': '${arrived.subtract(const Duration(hours: 1)).millisecondsSinceEpoch}',
      }, receivedAt: arrived)!;
      expect(call.expiresAt, arrived.add(const Duration(seconds: 30)));
    });

    test('reads line_busy (call waiting)', () {
      expect(PushCall.fromData(<String, dynamic>{...data, 'line_busy': '1'})!.lineBusy, isTrue);
      expect(PushCall.fromData(data)!.lineBusy, isFalse);
    });

    test('reads cancel pushes in both spellings, with the reason', () {
      final elsewhere = PushCall.fromData(<String, dynamic>{
        'type': 'call_ended',
        'call_id': 'abc',
        'reason': 'answered_elsewhere',
        'answered_by': 'play2',
      })!;
      expect(elsewhere.kind, PushKind.cancel);
      expect(elsewhere.answeredElsewhere, isTrue);
      expect(elsewhere.answeredBy, 'play2');
      final cancel = PushCall.fromData(<String, dynamic>{'type': 'cancel', 'call_id': 'abc', 'reason': 'missed'})!;
      expect(cancel.kind, PushKind.cancel);
      expect(cancel.answeredElsewhere, isFalse);
    });

    test('reads a call-ended push', () {
      final ended = PushCall.fromData(<String, dynamic>{
        'type': 'call_ended',
        'call_id': 'abc',
        'reason': 'caller_hung_up',
      })!;
      expect(ended.kind, PushKind.cancel);
      expect(ended.reason, 'caller_hung_up');
    });
  });

  group('matching an INVITE to a push', () {
    final push = PushCall.fromData(<String, dynamic>{
      'type': 'incoming_call',
      'call_id': 'ref-1',
      'caller': '+919876543210',
      'callee': '+918000000000',
    })!;

    test('phone numbers compare by their last ten digits', () {
      expect(samePhoneNumber('+919876543210', '09876543210'), isTrue);
      expect(samePhoneNumber('919876543210', '+919876543210'), isTrue);
      expect(samePhoneNumber('+919876543210', '+919876543211'), isFalse);
      expect(samePhoneNumber('', '+919876543210'), isFalse);
      expect(samePhoneNumber('Unknown', 'Unknown'), isFalse);
    });

    test('the call reference decides, in either spelling', () {
      expect(inviteMatchesPush(push, headers: <String, String>{'X-VH-PushRef': 'ref-1'}), isTrue);
      expect(inviteMatchesPush(push, headers: <String, String>{'X-VH-PushRefX-VH': 'ref-1'}), isTrue);
      expect(inviteMatchesPush(push, headers: <String, String>{'X-VH-PushRef': 'ref-2'}), isFalse);
    });

    test('a number is never enough to match (#46)', () {
      // CALLER_ID_MODE=number: every call shows the Vobiz number, so a number
      // match would auto-answer whichever call came next.
      expect(inviteMatchesPush(push, headers: const <String, String>{}), isFalse);
      expect(inviteMatchesPush(push, headers: <String, String>{'X-VH-Caller': '919876543210'}), isFalse);
    });

    test('reads the real caller the bridge passed', () {
      expect(callerFromHeaders(<String, String>{'X-VH-Caller': '919876543210'}), '+919876543210');
      expect(callerFromHeaders(const <String, String>{}), isNull);
    });
  });

  group('PushBridgeConfig', () {
    test('reads the line the bridge prints', () {
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

    test('allows plain http for a bridge on the local network', () {
      final config = PushBridgeConfig.parse('http://10.0.2.2:8787#key=abc')!;
      expect(config.isHttps, isFalse);
    });
  });

  group('PushBridgeApi', () {
    final config = PushBridgeConfig.parse('https://bridge.example#key=abc123')!;

    test('registers with the bridge key and the device token', () async {
      late http.Request seen;
      final api = PushBridgeApi(config, client: MockClient((request) async {
        seen = request;
        return http.Response(jsonEncode(<String, Object>{'ok': true, 'username': 'play1', 'push': true}), 200);
      }));
      final registration = await api.register(username: 'play1', token: 'fcm-token');
      expect(seen.url.toString(), 'https://bridge.example/push/register');
      expect(seen.headers['X-Bridge-Key'], 'abc123');
      expect(jsonDecode(seen.body), <String, Object?>{
        'username': 'play1',
        'token': 'fcm-token',
        'platform': 'android',
        'app': '',
      });
      expect(registration.push, isTrue);
    });

    test('explains a wrong key', () async {
      final api = PushBridgeApi(config,
          client: MockClient((_) async => http.Response('{"error":"Wrong or missing bridge key"}', 401)));
      await expectLater(
        api.register(username: 'play1'),
        throwsA(isA<PushBridgeException>().having((e) => e.message, 'message', contains('#key='))),
      );
    });

    test('pairs with the bridge key and keeps the device token it returns', () async {
      late http.Request seen;
      final api = PushBridgeApi(config, client: MockClient((request) async {
        seen = request;
        return http.Response(
            jsonEncode(<String, Object>{'ok': true, 'username': 'play1', 'push': true, 'device_token': 'd1.s'}),
            200);
      }));
      final registration = await api.register(username: 'play1', token: 'fcm-token');
      expect(seen.headers['X-Bridge-Key'], 'abc123');
      expect(seen.headers['Authorization'], isNull);
      expect(registration.deviceToken, 'd1.s');
    });

    test('once paired, sends only the device token; pairs again if the bridge forgot it', () async {
      final seen = <http.Request>[];
      final api = PushBridgeApi(config, deviceToken: 'd1.s', client: MockClient((request) async {
        seen.add(request);
        if (seen.length == 1) return http.Response('{"error":"unknown device"}', 401);
        return http.Response('{"ok":true,"push":true,"device_token":"d2.t"}', 200);
      }));
      final registration = await api.register(username: 'play1', token: 'fcm-token');
      expect(seen.first.headers['Authorization'], 'Bearer d1.s');
      expect(seen.first.headers['X-Bridge-Key'], isNull);
      expect(seen.last.headers['X-Bridge-Key'], 'abc123');
      expect(registration.deviceToken, 'd2.t');
    });

    test('unregister and test calls send the device token, not the bridge key', () async {
      final seen = <http.Request>[];
      final api = PushBridgeApi(config, deviceToken: 'd1.s', client: MockClient((request) async {
        seen.add(request);
        return http.Response('{"ok":true}', 200);
      }));
      await api.unregister();
      await api.sendTestCall(delaySeconds: 5);
      expect(seen.map((r) => r.url.path), <String>['/push/unregister', '/push/test']);
      expect(seen.every((r) => r.headers['Authorization'] == 'Bearer d1.s'), isTrue);
      expect(seen.every((r) => r.headers['X-Bridge-Key'] == null), isTrue);
      expect(jsonDecode(seen.last.body), <String, Object>{'delay_seconds': 5});
    });

    test('registered posts the call key; accept reports a call that is already over', () async {
      final call = PushCall.fromData(<String, dynamic>{
        'type': 'incoming_call',
        'call_id': 'c1',
        'call_key': 'per-call',
        'server': 'https://bridge.example',
      })!;
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return request.url.path == '/push/accept'
            ? http.Response('{"ok":true,"finished":true,"reason":"answered_elsewhere"}', 200)
            : http.Response('{"ok":true,"redial":"transferred","finished":false}', 200);
      });
      final registered = await PushBridgeApi.registered(call, client: client);
      expect(registered.finished, isFalse);
      expect(seen.single.url.path, '/push/registered');
      expect(jsonDecode(seen.single.body), <String, String>{'call_id': 'c1', 'call_key': 'per-call'});
      final accepted = await PushBridgeApi.accept(call, client: client);
      expect(accepted.finished, isTrue);
      expect(accepted.reason, 'answered_elsewhere');
    });

    test('accept and decline use the call key, not the bridge key', () async {
      final call = PushCall.fromData(<String, dynamic>{
        'type': 'incoming_call',
        'call_id': 'c1',
        'call_key': 'per-call',
        'server': 'https://bridge.example',
      })!;
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return http.Response('{"ok":true}', 200);
      });
      await PushBridgeApi.accept(call, client: client);
      await PushBridgeApi.decline(call, client: client);
      expect(seen.map((r) => r.url.path), <String>['/push/accept', '/push/decline']);
      expect(seen.every((r) => r.headers['X-Bridge-Key'] == null), isTrue);
      expect(jsonDecode(seen.first.body), <String, String>{'call_id': 'c1', 'call_key': 'per-call'});
    });
  });

  group('Incoming calls panel', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    void usePhoneScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(1236, 2745);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('is off until a push server is pasted, and rejects a bad line', (tester) async {
      usePhoneScreen(tester);
      final controller = PlaygroundController();
      await tester.pumpWidget(PlaygroundApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('INCOMING CALLS'));
      // Both ways of ringing a closed app start off: the push server, and Vobiz push.
      expect(find.text('OFF'), findsNWidgets(2));
      final toggle = tester.widget<Switch>(find.byKey(const Key('receiveCalls')));
      expect(toggle.onChanged, isNull);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('testCall'))).onPressed, isNull);

      expect(await controller.setPushServer('https://abc.trycloudflare.com'), contains('#key='));
      expect(controller.pushServer, isEmpty);
    });
  });
}
