import 'dart:convert';

import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/call_history.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/push/push_call.dart';

import 'support/fakes.dart';
import 'support/setup.dart';

/// A call to a closed app through Vobiz's own push: its registrar holds the
/// call, pushes, and sends the held INVITE to the REGISTER that claims it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A push as Vobiz's registrar sends it.
  Map<String, String> vobizPush({String callId = 'held-1@10.0.2.9', int inSeconds = 30}) => <String, String>{
        'type': 'incoming_call',
        'call_id': callId,
        'call_uuid': '5f0c5c7e-0000-4000-8000-000000000001',
        'caller': 'Asha',
        'caller_number': '+919876543210',
        'callee': 'play1',
        'index': '4211',
        'label': '1938273',
        'registrar': '203.0.113.10',
        'expires_at': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + inSeconds}',
      };

  group('PushCall from Vobiz', () {
    test('reads the hold and an expiry in seconds, and is not stale on arrival', () {
      final call = PushCall.fromData(vobizPush())!;
      expect(call.isVobiz, isTrue);
      expect(call.sdkPush!.isExpired(), isFalse, reason: 'seconds read as milliseconds would be 1970');
      expect(call.displayCaller, 'Asha');
      expect(call.callerNumber, '+919876543210');
      expect(call.sdkPush!.hold.registerHeaders['X-Index'], '4211');
    });

    test('keeps its hold through the call screen, so Accept after a cold start can claim it', () {
      final call = PushCall.fromData(vobizPush())!;
      final back = PushCall.fromExtra(call.toExtra())!;
      expect(back.isVobiz, isTrue);
      expect(back.registrar, '203.0.113.10');
      expect(back.expiresAt, call.expiresAt);
      expect(back.sdkPush, isNotNull);
    });

    test('a call push without index, label and registrar is not a call Vobiz holds', () {
      final other = PushCall.fromData(<String, String>{'type': 'incoming_call', 'call_id': 'c1', 'ttl_ms': '40000'})!;
      expect(other.isVobiz, isFalse);
      expect(other.sdkPush, isNull);
    });
  });

  group('the app with a Vobiz push', () {
    late FakeClient client;
    late FakeCallScreen screen;
    late FakeCallPlatform platform;
    late PlaygroundController controller;

    Future<void> start({
      bool saved = true,
      List<Map<String, String>> queued = const <Map<String, String>>[],
      List<ck.CallKitParams> screens = const <ck.CallKitParams>[],
      http.Client? httpClient,
    }) async {
      client = FakeClient();
      screen = FakeCallScreen()..screens.addAll(screens);
      platform = FakeCallPlatform()..queued.addAll(queued);
      controller = await startController(
        client: client,
        screen: screen,
        platform: platform,
        secure: saved ? savedZeroConfig : const <String, String>{},
        httpClient: httpClient,
      );
    }

    tearDown(() => controller.dispose());

    ck.CallEvent accept(String id, Map<String, String> data) =>
        ck.CallEventActionCallAccept(ck.CallKitParams(id: id, extra: PushCall.fromData(data)!.toExtra()));
    ck.CallEvent decline(String id, Map<String, String> data) =>
        ck.CallEventActionCallDecline(ck.CallKitParams(id: id, extra: PushCall.fromData(data)!.toExtra()));

    test('closed app: rings the call screen, hands the push to the SDK and signs in to claim it', () async {
      await start();
      platform.pushController.add(vobizPush());
      await pumpEventQueue();
      expect(screen.shown, contains('held-1@10.0.2.9'));
      expect(client.actions, contains('handleIncomingPush:held-1@10.0.2.9'));
      expect(client.actions, contains('connectWithAuthToken'), reason: 'the sign-in carries the claim');
      expect(client.actions.where((a) => a.startsWith('report')), isEmpty, reason: 'nothing is tapped yet');
      expect(controller.logs.map((l) => l.message), isNot(contains(contains('push server'))),
          reason: 'Vobiz holds the call: no server is asked to ring this phone');
    });

    test('closed app started by the push: the push Android queued before Dart was ready rings and signs in',
        () async {
      await start(queued: <Map<String, String>>[vobizPush()]);
      await pumpEventQueue();
      expect(screen.shown, <String>['held-1@10.0.2.9']);
      expect(client.actions, contains('handleIncomingPush:held-1@10.0.2.9'));
      expect(client.actions, contains('connectWithAuthToken'));
    });

    test('closed app opened by Accept: the accepted call screen is taken without another tap', () async {
      final data = vobizPush();
      await start(
        queued: <Map<String, String>>[data],
        screens: <ck.CallKitParams>[
          ck.CallKitParams(id: 'held-1@10.0.2.9', extra: PushCall.fromData(data)!.toExtra(), isAccepted: true),
        ],
      );
      await pumpEventQueue();
      expect(screen.shown, isEmpty, reason: 'its call screen is already up');
      expect(client.actions, contains('reportAccepted:held-1@10.0.2.9'));
      expect(client.actions.where((a) => a == 'connectWithAuthToken'), hasLength(1));
      expect(platform.requests, contains('start:Asha'));
    });

    test('closed app with no saved sign-in: the call screen rings, and the Trace says why nothing connects',
        () async {
      await start(saved: false);
      platform.pushController.add(vobizPush());
      await pumpEventQueue();
      expect(screen.shown, contains('held-1@10.0.2.9'));
      expect(client.actions.where((a) => a.startsWith('connect')), isEmpty);
      expect(controller.logs.map((l) => l.message), contains(contains('no saved sign-in')));
    });

    test('signed in already: the SDK claims it on the open connection, no new sign-in', () async {
      await start();
      await controller.connect();
      await pumpEventQueue();
      client.actions.clear();
      platform.pushController.add(vobizPush());
      await pumpEventQueue();
      expect(client.actions, <String>['handleIncomingPush:held-1@10.0.2.9']);
    });

    test('Accept before the INVITE: reported to the SDK, which answers it; no second call screen', () async {
      await start();
      final data = vobizPush();
      platform.pushController.add(data);
      await pumpEventQueue();
      screen.controller.add(accept('held-1@10.0.2.9', data));
      await pumpEventQueue();
      expect(client.actions, contains('reportAccepted:held-1@10.0.2.9'));
      expect(platform.requests, contains('start:Asha'), reason: "the call's microphone service starts on the tap");
      expect(controller.logs.map((l) => l.message), contains(contains('Waiting for the call Vobiz is holding')));
      final shownBefore = screen.shown.length;
      client.ring(callId: 'in_1', from: '+919876543210', sipCallId: 'held-1@10.0.2.9');
      await pumpEventQueue();
      expect(screen.shown.length, shownBefore, reason: 'the push\'s screen is this call\'s');
      expect(controller.statusText, 'Answering...');
      expect(client.actions.where((a) => a == 'acceptCall'), isEmpty, reason: 'the SDK answers, not the app');
    });

    test('Accept after the INVITE rings: the SDK answers it at once, and the Trace does not say it is waiting',
        () async {
      await start();
      await controller.connect();
      await pumpEventQueue();
      final data = vobizPush();
      platform.pushController.add(data);
      await pumpEventQueue();
      client.ring(callId: 'in_1', from: '+919876543210', sipCallId: 'held-1@10.0.2.9');
      await pumpEventQueue();
      screen.controller.add(accept('held-1@10.0.2.9', data));
      await pumpEventQueue();
      expect(client.actions, contains('reportAccepted:held-1@10.0.2.9'));
      expect(client.callState, CallStateStatus.connecting, reason: 'the SDK answered the ringing call');
      expect(controller.logs.map((l) => l.message), isNot(contains(contains('Waiting for the call Vobiz is holding'))));
    });

    test('Decline before the INVITE: reported to the SDK, logged as declined', () async {
      await start();
      final data = vobizPush();
      platform.pushController.add(data);
      await pumpEventQueue();
      screen.controller.add(decline('held-1@10.0.2.9', data));
      await pumpEventQueue();
      expect(client.actions, contains('reportDeclined:held-1@10.0.2.9'));
      expect(controller.history.byId('held-1@10.0.2.9')!.outcome, CallOutcome.declined);
    });

    test('the SDK says the call never came: the screen goes, and it is a missed call', () async {
      await start();
      final data = vobizPush();
      platform.pushController.add(data);
      await pumpEventQueue();
      client.fakePushUpdates.add(VobizPushCallUpdate(
          push: VobizIncomingPush.tryParse(data)!, status: VobizPushCallStatus.expired));
      await pumpEventQueue();
      expect(screen.ended, contains('held-1@10.0.2.9'));
      expect(controller.history.byId('held-1@10.0.2.9')!.outcome, CallOutcome.missed);
      expect(controller.history.byId('held-1@10.0.2.9')!.party, 'Asha');
    });

    test('a stale Vobiz push rings nothing', () async {
      await start();
      // Well past expiry: the SDK still takes a push up to 30 s late (a fast phone clock).
      platform.pushController.add(vobizPush(inSeconds: -120));
      await pumpEventQueue();
      expect(screen.shown, isEmpty);
      expect(client.actions.where((a) => a.startsWith('handleIncomingPush')), isEmpty);
    });

    test('a call push without index, label and registrar rings nothing', () async {
      await start();
      platform.pushController.add(<String, String>{
        'type': 'incoming_call',
        'call_id': 'c1',
        'caller': '+919876543210',
        'expires_at': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30}',
      });
      await pumpEventQueue();
      expect(screen.shown, isEmpty);
      expect(client.actions, isEmpty, reason: 'no claim and no sign-in');
    });

    test('a replayed Accept is reported to the SDK once', () async {
      await start();
      final data = vobizPush();
      platform.pushController.add(data);
      await pumpEventQueue();
      screen.controller.add(accept('held-1@10.0.2.9', data));
      await pumpEventQueue();
      screen.controller.add(accept('held-1@10.0.2.9', data));
      await pumpEventQueue();
      expect(client.actions.where((a) => a == 'reportAccepted:held-1@10.0.2.9'), hasLength(1));
      expect(client.actions.where((a) => a.startsWith('connect')), hasLength(1));
    });

    for (final withRef in <bool>[false, true]) {
      test('a held call the caller cancels while it rings closes its call screen and is logged missed once'
          '${withRef ? ' (INVITE with PushRef)' : ''}', () async {
        await start();
        await controller.connect();
        await pumpEventQueue();
        platform.pushController.add(vobizPush());
        await pumpEventQueue();
        client.ring(
          callId: 'in_1',
          from: '+919876543210',
          sipCallId: 'held-1@10.0.2.9',
          headers: withRef ? <String, String>{'X-VH-PushRef': 'ref-1'} : const <String, String>{},
        );
        await pumpEventQueue();
        expect(controller.showIncoming, isTrue);
        client.emit(CallStateStatus.ended, callId: 'in_1', reason: 'Caller cancelled');
        await pumpEventQueue();
        expect(screen.ended, contains('held-1@10.0.2.9'), reason: 'the push\'s call screen stops ringing');
        expect(screen.screens, isEmpty);
        final id = withRef ? 'ref-1' : 'held-1@10.0.2.9';
        expect(controller.history.byId(id)!.outcome, CallOutcome.missed);
        expect(platform.requests.where((r) => r.startsWith('missed:')), <String>['missed:$id']);
      });
    }

    test('Decline before the INVITE: the INVITE the SDK turns away rings nothing and is not a missed call', () async {
      await start();
      await controller.connect();
      await pumpEventQueue();
      final data = vobizPush();
      platform.pushController.add(data);
      await pumpEventQueue();
      screen.controller.add(decline('held-1@10.0.2.9', data));
      await pumpEventQueue();
      final shownBefore = List<String>.of(screen.shown);
      // The SDK rejects the INVITE and forgets the push before the app hears
      // of it: by then isPushedCall is false.
      client.handledPush = null;
      client.ring(callId: 'in_1', from: '+919876543210', sipCallId: 'held-1@10.0.2.9');
      await pumpEventQueue();
      expect(controller.showIncoming, isFalse);
      expect(screen.shown, shownBefore, reason: 'no second call screen');
      client.emit(CallStateStatus.ended, callId: 'in_1', reason: 'Busy Here');
      await pumpEventQueue();
      expect(controller.history.records, hasLength(1));
      expect(controller.history.byId('held-1@10.0.2.9')!.outcome, CallOutcome.declined);
      expect(platform.requests.where((r) => r.startsWith('missed:')), isEmpty);
    });

    for (final from in <String>['the app', 'the ongoing-call notification']) {
      test('Hang up from $from while an accepted held call is still arriving turns it away', () async {
        await start();
        final data = vobizPush();
        platform.pushController.add(data);
        await pumpEventQueue();
        screen.controller.add(accept('held-1@10.0.2.9', data));
        await pumpEventQueue();
        expect(client.actions, contains('reportAccepted:held-1@10.0.2.9'));
        client.actions.clear();
        if (from == 'the app') {
          await controller.hangup();
        } else {
          screen.controller.add(ck.CallEventActionCallEnded(
              ck.CallKitParams(id: 'held-1@10.0.2.9', extra: PushCall.fromData(data)!.toExtra())));
        }
        await pumpEventQueue();
        expect(client.actions, contains('reportDeclined:held-1@10.0.2.9'));
        expect(screen.ended, contains('held-1@10.0.2.9'));
        expect(platform.requests.last, 'stop');
        expect(controller.history.byId('held-1@10.0.2.9')!.outcome, CallOutcome.declined);
        // The INVITE comes during the sign-in; the SDK turns it away.
        client.handledPush = null;
        client.ring(callId: 'in_1', from: '+919876543210', sipCallId: 'held-1@10.0.2.9');
        await pumpEventQueue();
        expect(controller.showIncoming, isFalse);
        expect(client.actions, isNot(contains('acceptCall')));
      });
    }

    test('a push while the SDK is reconnecting leaves the sign-in to it', () async {
      await start();
      await controller.connect();
      await pumpEventQueue();
      client.connected = false;
      client.connection = ConnectionStateStatus.reconnecting;
      client.actions.clear();
      final data = vobizPush();
      platform.pushController.add(data);
      await pumpEventQueue();
      screen.controller.add(accept('held-1@10.0.2.9', data));
      await pumpEventQueue();
      expect(client.actions, <String>['handleIncomingPush:held-1@10.0.2.9', 'reportAccepted:held-1@10.0.2.9'],
          reason: 'the SDK reconnects with its own sign-in and carries the claim: no second sign-in');
    });

    test('the same push delivered twice (queued before Dart was ready, then live) rings once', () async {
      await start();
      platform.pushController.add(vobizPush());
      platform.pushController.add(vobizPush());
      await pumpEventQueue();
      expect(screen.shown.where((id) => id == 'held-1@10.0.2.9'), hasLength(1));
      expect(client.actions.where((a) => a.startsWith('handleIncomingPush')), hasLength(1));
      expect(client.actions.where((a) => a == 'connectWithAuthToken'), hasLength(1));
    });

    test('turning Vobiz push on without Firebase says so, and registers nothing', () async {
      final requests = <http.Request>[];
      await start(httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }));
      await controller.connect();
      await pumpEventQueue();
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect(controller.vobizPushState, PushState.failed);
      expect(controller.vobizPushDetail, isNotEmpty);
      expect(requests, isEmpty);
    });
  });

  group('Vobiz push sign-up through the sample server', () {
    late FakeClient client;
    late FakeCallPlatform platform;
    late PlaygroundController controller;
    late List<http.Request> requests;
    late http.Response Function(http.Request request) reply;

    Future<void> start({String server = 'https://bridge.example#key=k1'}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'vobiz_auth_id': 'MA_X',
        'vobiz_auth_token': 'tok',
        'vobiz_push_server': server,
      });
      client = FakeClient();
      platform = FakeCallPlatform();
      requests = <http.Request>[];
      reply = (_) => http.Response('{"message":"ok"}', 200);
      controller = PlaygroundController(
        client: client,
        callScreen: FakeCallScreen(),
        platform: platform,
        push: FakePush(),
        httpClient: MockClient((request) async {
          requests.add(request);
          return reply(request);
        }),
      );
      await controller.init();
      await controller.connect();
      await pumpEventQueue();
    }

    tearDown(() => controller.dispose());

    test('signs up through the server with its key and the SIP user, never the account credentials', () async {
      await start();
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect(controller.vobizPushState, PushState.ready);
      final register = requests.single;
      expect(register.method, 'POST');
      expect(register.url.toString(), 'https://bridge.example/push/devices/register');
      expect(register.headers['X-Bridge-Key'], 'k1');
      expect(register.headers['X-Bridge-User'], 'play1');
      expect(register.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-auth-token')));
      expect(register.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-auth-id')));
      final body = jsonDecode(register.body) as Map<String, Object?>;
      expect(body['sip_username'], 'play1');
      expect(body['push_token'], 'fcm-token-1');
      expect(body['app_bundle_id'], 'ai.vobiz.vobiz_webrtc_example');
      expect(body['device_id'], startsWith('vobiz-example-'));
      expect(body.containsKey('auth_id'), isFalse, reason: 'the server sets its own account');
    });

    test('sends the application id Android runs the app as', () async {
      await start();
      platform.appId = 'com.example.renamed';
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect((jsonDecode(requests.single.body) as Map<String, Object?>)['app_bundle_id'], 'com.example.renamed');
    });

    test('a server reached under a path keeps that path', () async {
      await start(server: 'https://tunnel.example/vobiz#key=k1');
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect(requests.single.url.toString(), 'https://tunnel.example/vobiz/push/devices/register');
    });

    test('sign-out removes the device through the server, with the same device id', () async {
      await start();
      await controller.setVobizPush(true);
      await pumpEventQueue();
      final deviceId = (jsonDecode(requests.single.body) as Map<String, Object?>)['device_id'];
      requests.clear();
      await controller.disconnect();
      final logout = requests.single;
      expect(logout.method, 'DELETE');
      expect(logout.url.toString(), 'https://bridge.example/push/devices/logout');
      expect(logout.headers['X-Bridge-Key'], 'k1');
      expect(logout.headers['X-Bridge-User'], 'play1');
      expect(jsonDecode(logout.body), <String, Object?>{'device_id': deviceId});
    });

    test('a refusal from the server is shown', () async {
      await start();
      reply = (_) => http.Response('{"error":"play1 is not an endpoint of this account"}', 403);
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect(controller.vobizPushState, PushState.failed);
      expect(controller.vobizPushDetail, contains('403'));
      expect(controller.vobizPushDetail, contains('not an endpoint of this account'));
    });
  });

  group('Call this phone through Vobiz', () {
    late FakeClient client;
    late FakeCallPlatform platform;
    late PlaygroundController controller;
    late List<http.Request> requests;
    late FakePush push;
    late bool connectedAtCall;
    http.Response Function(http.Request request) reply = (_) => http.Response('{"message":"Call fired"}', 200);

    Map<String, Object?> body(http.Request r) => jsonDecode(r.body) as Map<String, Object?>;
    Iterable<http.Request> callRequests() => requests.where((r) => r.url.path.endsWith('/Call/'));

    Future<void> ready() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{'vobiz_auth_id': 'MA_X', 'vobiz_auth_token': 'tok'});
      client = FakeClient();
      platform = FakeCallPlatform();
      requests = <http.Request>[];
      connectedAtCall = true;
      reply = (_) => http.Response('{"message":"Call fired"}', 200);
      final web = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/Call/')) connectedAtCall = client.connected;
        return reply(request);
      });
      push = FakePush();
      controller = PlaygroundController(
        client: client,
        callScreen: FakeCallScreen(),
        platform: platform,
        push: push,
        httpClient: web,
      );
      await controller.init();
      await controller.connect();
      await pumpEventQueue();
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect(controller.vobizPushState, PushState.ready, reason: 'registered with Vobiz push');
      await controller.setVobizCallTest(from: '+1 (415) 555-1234', answerUrl: ' https://example.com/answer ');
    }

    tearDown(() => controller.dispose());

    Iterable<http.Request> deviceRequests() => requests.where((r) => r.url.path.startsWith('/api/v1/devices/'));

    test('without a sample server the phone signs up straight to Vobiz with the account headers', () async {
      await ready();
      final register = deviceRequests().single;
      expect(register.method, 'POST');
      expect(register.url.toString(), 'https://api.vobiz.ai/api/v1/devices/register');
      expect(register.headers['X-Auth-ID'], 'MA_X');
      expect(register.headers['X-Auth-Token'], 'tok');
      expect(body(register)['sip_username'], 'play1');
      expect(body(register)['push_token'], 'fcm-token-1');
    });

    test('a new Firebase token is signed up again, under the same device id', () async {
      await ready();
      final first = body(deviceRequests().single);
      requests.clear();
      push.pushToken = 'fcm-token-2';
      push.refreshes.add('fcm-token-2');
      await pumpEventQueue();
      final again = body(deviceRequests().single);
      expect(again['push_token'], 'fcm-token-2');
      expect(again['device_id'], first['device_id']);
    });

    test('sign-out and switching off each take the device off Vobiz push, by its device id', () async {
      await ready();
      final deviceId = body(deviceRequests().single)['device_id'];
      requests.clear();
      await controller.setVobizPush(false);
      final off = deviceRequests().single;
      expect(off.method, 'DELETE');
      expect(off.url.toString(), 'https://api.vobiz.ai/api/v1/devices/logout');
      expect(body(off), <String, Object?>{'device_id': deviceId});
      await controller.setVobizPush(true);
      await pumpEventQueue();
      requests.clear();
      await controller.disconnect();
      expect(deviceRequests().single.method, 'DELETE');
      expect(body(deviceRequests().single), <String, Object?>{'device_id': deviceId});
      expect(deviceRequests().single.headers['X-Auth-Token'], 'tok', reason: 'read before sign-out forgot it');
    });

    test('drops the connection without signing off, as a killed app does, then calls its SIP user', () async {
      await ready();
      client.actions.clear();
      await controller.callThisPhoneThroughVobiz();
      expect(client.actions, <String>['disconnect:keep-registration'],
          reason: 'a sign-off deletes the registration, and Vobiz then refuses the call instead of pushing');
      expect(connectedAtCall, isFalse, reason: 'the registrar pushes when the registration has no live connection');
      final call = callRequests().single;
      expect(call.method, 'POST');
      expect(call.url.toString(), 'https://api.vobiz.ai/api/v1/Account/MA_X/Call/');
      expect(call.headers['X-Auth-ID'], 'MA_X');
      expect(call.headers['X-Auth-Token'], 'tok');
      expect(body(call), <String, Object?>{
        'from': '14155551234',
        'to': 'sip:play1@registrar.vobiz.ai',
        'answer_url': 'https://example.com/answer',
        'answer_method': 'POST',
        'time_limit': 120,
      });
      expect(controller.status, PhoneStatus.offline);
      expect(controller.vobizPushState, PushState.ready, reason: 'still registered with Vobiz push');
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty, reason: 'this is not a sign-out');
      expect(controller.logs.map((l) => l.message), contains(startsWith('🧪 Vobiz is calling this phone')));
      expect(controller.vobizCallPlacing, isFalse);
    });

    test('keeps the saved sign-in, so the push that follows can claim the call', () async {
      await ready();
      await controller.callThisPhoneThroughVobiz();
      client.actions.clear();
      platform.pushController.add(<String, String>{
        'type': 'incoming_call',
        'call_id': 'held-9@10.0.2.9',
        'caller': 'Vobiz test call',
        'callee': 'play1',
        'index': '4211',
        'label': '1938273',
        'registrar': '203.0.113.10',
        'expires_at': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30}',
      });
      await pumpEventQueue();
      expect(client.actions, contains('handleIncomingPush:held-9@10.0.2.9'));
      expect(client.actions, contains('connectWithAuthToken'), reason: 'it signs itself in to claim the call');
    });

    test('refuses without a caller ID or an https answer URL: nothing goes offline, nothing is sent', () async {
      await ready();
      client.actions.clear();
      await controller.setVobizCallTest(from: '', answerUrl: 'https://example.com/answer');
      await controller.callThisPhoneThroughVobiz();
      await controller.setVobizCallTest(from: '14155551234', answerUrl: 'http://example.com/answer');
      await controller.callThisPhoneThroughVobiz();
      await controller.setVobizCallTest(from: '14155551234', answerUrl: 'not a url');
      await controller.callThisPhoneThroughVobiz();
      expect(client.actions, isEmpty);
      expect(callRequests(), isEmpty);
      expect(controller.status, PhoneStatus.online);
      expect(controller.logs.where((l) => l.type == LogType.error).length, greaterThanOrEqualTo(3));
    });

    test('refuses while not signed up with Vobiz push', () async {
      await ready();
      await controller.setVobizPush(false);
      client.actions.clear();
      await controller.callThisPhoneThroughVobiz();
      expect(client.actions, isEmpty);
      expect(callRequests(), isEmpty);
    });

    test('refuses while not signed in', () async {
      await ready();
      await controller.disconnect();
      client.actions.clear();
      await controller.callThisPhoneThroughVobiz();
      expect(client.actions, isEmpty);
      expect(callRequests(), isEmpty);
      expect(controller.logs.last.message, contains('Connect'));
    });

    test('Vobiz refusing the call is shown, and the phone stays offline waiting for a push', () async {
      await ready();
      reply = (_) => http.Response('{"error":"From number not owned by account"}', 400);
      await controller.callThisPhoneThroughVobiz();
      expect(controller.logs.map((l) => l.message), contains(contains('HTTP 400')));
      expect(controller.vobizCallPlacing, isFalse, reason: 'the button is usable again');
      expect(controller.status, PhoneStatus.offline);
    });

    test('the caller ID and answer URL are remembered, as digits and a trimmed address', () async {
      await ready();
      expect(controller.vobizCallFrom, '14155551234');
      expect(controller.vobizCallAnswerUrl, 'https://example.com/answer');
      final again = PlaygroundController(
          client: FakeClient(), callScreen: FakeCallScreen(), platform: FakeCallPlatform(), push: FakePush());
      addTearDown(again.dispose);
      await again.init();
      expect(again.vobizCallFrom, '14155551234');
      expect(again.vobizCallAnswerUrl, 'https://example.com/answer');
    });
  });
}
