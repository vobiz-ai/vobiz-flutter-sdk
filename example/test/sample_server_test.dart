import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// What the app sends the sample server (example/push_bridge) besides
/// tokens: the connection watch and Conference, with its key and the SIP
/// user the app is signed in as.
void main() {
  late FakeClient client;
  late PlaygroundController controller;
  late List<http.Request> requests;
  late http.Response Function(http.Request request) reply;

  Future<void> start({Map<String, Object> prefs = const <String, Object>{}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'vobiz_sip_username': 'play1',
      'vobiz_sip_password': 'pw',
      'vobiz_push_server': 'https://bridge.example#key=k1',
    });
    client = FakeClient();
    requests = <http.Request>[];
    reply = (_) => http.Response('{"ok":true}', 200);
    controller = PlaygroundController(
      client: client,
      callScreen: FakeCallScreen(),
      platform: FakeCallPlatform(),
      httpClient: MockClient((request) async {
        requests.add(request);
        return reply(request);
      }),
    );
    await controller.init();
    controller.setAuthTab(AuthTab.sipDirect);
    await controller.connect();
  }

  /// A call the sample server rang (its PushRef on the INVITE), answered.
  void answerServerCall() {
    client.ring(headers: <String, String>{'X-VH-PushRef': 'ref-1'});
    client.emit(CallStateStatus.active, dir: CallDirection.inbound);
  }

  Iterable<http.Request> alive() => requests.where((r) => r.url.path == '/call/alive');
  Iterable<http.Request> ended() => requests.where((r) => r.url.path == '/call/ended');

  group('the connection watch', () {
    test('is off unless turned on: an answered call reports nothing', () async {
      await start();
      await pumpEventQueue();
      expect(controller.connectionWatch, isFalse);
      answerServerCall();
      await pumpEventQueue();
      expect(alive(), isEmpty);
      client.emit(CallStateStatus.ended);
      await pumpEventQueue();
      expect(ended(), isEmpty);
      controller.dispose();
    });

    test('turned on, an answered call reports alive with the key and the SIP user, then that it ended', () async {
      await start();
      await pumpEventQueue();
      await controller.setConnectionWatch(true);
      answerServerCall();
      await pumpEventQueue();
      final first = alive().first;
      expect(first.url.toString(), 'https://bridge.example/call/alive');
      expect(first.headers['X-Bridge-Key'], 'k1');
      expect(first.headers['X-Bridge-User'], 'play1');
      expect(first.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(first.body), <String, Object?>{'call_uuid': 'ref-1'});
      client.emit(CallStateStatus.ended);
      await pumpEventQueue();
      expect(ended().single.headers['X-Bridge-User'], 'play1');
      controller.dispose();
    });

    test('the switch is remembered', () async {
      await start();
      await pumpEventQueue();
      await controller.setConnectionWatch(true);
      controller.dispose();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('vobiz_playground_connection_watch'), isTrue);
    });

    test('turned off during a call, the server is told the call is no longer watched', () async {
      await start();
      await pumpEventQueue();
      await controller.setConnectionWatch(true);
      answerServerCall();
      await pumpEventQueue();
      await controller.setConnectionWatch(false);
      await pumpEventQueue();
      expect(ended(), hasLength(1));
      controller.dispose();
    });

    test('stops reporting a call the server refuses (403)', () {
      fakeAsync((async) {
        start(prefs: <String, Object>{'vobiz_playground_connection_watch': true});
        async.flushMicrotasks();
        reply = (r) => r.url.path == '/call/alive'
            ? http.Response('{"error":"Not a call of this SIP user"}', 403)
            : http.Response('{"ok":true}', 200);
        answerServerCall();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        expect(alive(), hasLength(1));
        expect(controller.logs.map((l) => l.message), contains(contains('refused this call (HTTP 403')));
        controller.dispose();
      });
    });

    test('keeps reporting through a server error, which may pass', () {
      fakeAsync((async) {
        start(prefs: <String, Object>{'vobiz_playground_connection_watch': true});
        async.flushMicrotasks();
        reply = (r) => http.Response('{"error":"busy"}', 502);
        answerServerCall();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 3500));
        expect(alive().length, greaterThanOrEqualTo(3));
        controller.dispose();
      });
    });
  });

  test('Conference sends the key and the SIP user, and the call the server knows', () async {
    await start();
    await pumpEventQueue();
    answerServerCall();
    await pumpEventQueue();
    reply = (_) => http.Response('{"error":"not now"}', 409);
    controller
      ..conferenceTarget = TransferTarget.number
      ..conferenceNumber = '9876543210';
    await controller.conferenceAdd();
    final add = requests.singleWhere((r) => r.url.path == '/conference/add');
    expect(add.url.toString(), 'https://bridge.example/conference/add');
    expect(add.headers['X-Bridge-Key'], 'k1');
    expect(add.headers['X-Bridge-User'], 'play1');
    expect(add.headers.containsKey('Authorization'), isFalse);
    expect((jsonDecode(add.body) as Map<String, Object?>)['call_uuid'], 'ref-1');
    expect(controller.conferenceError, 'not now');

    // The next call starts clean: no error and no half-typed target from this one.
    client.emit(CallStateStatus.ended);
    await pumpEventQueue();
    expect(controller.conferenceError, isEmpty);
    expect(controller.conferenceNumber, isEmpty);
    expect(controller.conferenceBusy, isFalse);
    controller.dispose();
  });

  test('Conference without a sample server says where to paste its line', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final c = PlaygroundController(client: FakeClient(), callScreen: FakeCallScreen(), platform: FakeCallPlatform());
    await c.init();
    expect(c.conferenceBlocker, contains('Sample server'));
    c.dispose();
  });
}
