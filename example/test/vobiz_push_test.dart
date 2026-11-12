import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/call_history.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/push/push_call.dart';

import 'support/fakes.dart';

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
      expect(call.isExpired, isFalse, reason: 'seconds read as milliseconds would be 1970');
      expect(call.displayCaller, 'Asha');
      expect(call.callerNumber, '+919876543210');
      expect(call.sdkPush!.hold!.registerHeaders['X-Index'], '4211');
    });

    test('keeps its hold through the call screen, so Accept after a cold start can claim it', () {
      final call = PushCall.fromData(vobizPush())!;
      final back = PushCall.fromExtra(call.toExtra())!;
      expect(back.isVobiz, isTrue);
      expect(back.registrar, '203.0.113.10');
      expect(back.expiresAt, call.expiresAt);
      expect(back.sdkPush!.isHeldByVobiz, isTrue);
    });

    test('matches its INVITE by SIP Call-ID only', () {
      final call = PushCall.fromData(vobizPush())!;
      expect(inviteMatchesPush(call, headers: const <String, String>{}, sipCallId: 'held-1@10.0.2.9'), isTrue);
      expect(inviteMatchesPush(call, headers: const <String, String>{}, sipCallId: 'other'), isFalse);
      expect(inviteMatchesPush(call, headers: <String, String>{'X-VH-PushRef': 'held-1@10.0.2.9'}), isFalse);
    });

    test('a bridge push is not a Vobiz one', () {
      final bridge = PushCall.fromData(<String, String>{'type': 'incoming_call', 'call_id': 'c1', 'ttl_ms': '40000'})!;
      expect(bridge.isVobiz, isFalse);
      expect(bridge.sdkPush, isNull);
    });
  });

  group('the app with a Vobiz push', () {
    late FakeClient client;
    late FakeCallScreen screen;
    late FakeCallPlatform platform;
    late PlaygroundController controller;

    Future<void> start({bool saved = true}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        if (saved) 'vobiz_auth_id': 'MA_X',
        if (saved) 'vobiz_auth_token': 'tok',
      });
      client = FakeClient();
      screen = FakeCallScreen();
      platform = FakeCallPlatform();
      controller = PlaygroundController(client: client, callScreen: screen, platform: platform);
      await controller.init();
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
      // Not a bridge call: nothing is sent to a push server.
      expect(client.actions.where((a) => a.startsWith('report')), isEmpty);
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
      final shownBefore = screen.shown.length;
      client.ring(callId: 'in_1', from: '+919876543210', sipCallId: 'held-1@10.0.2.9');
      await pumpEventQueue();
      expect(screen.shown.length, shownBefore, reason: 'the push\'s screen is this call\'s');
      expect(controller.statusText, 'Answering...');
      expect(client.actions.where((a) => a == 'acceptCall'), isEmpty, reason: 'the SDK answers, not the app');
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
      platform.pushController.add(vobizPush(inSeconds: -5));
      await pumpEventQueue();
      expect(screen.shown, isEmpty);
      expect(client.actions.where((a) => a.startsWith('handleIncomingPush')), isEmpty);
    });

    test('turning Vobiz push on without Firebase says so, and registers nothing', () async {
      await start();
      await controller.connect();
      await pumpEventQueue();
      await controller.setVobizPush(true);
      await pumpEventQueue();
      expect(controller.vobizPushState, PushState.failed);
      expect(controller.vobizPushDetail, isNotEmpty);
    });
  });
}
