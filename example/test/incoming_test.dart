import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/call_history.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// Incoming calls over SIP: the call screen, the call service and the log.
void main() {
  late FakeClient client;
  late FakeCallScreen screen;
  late FakeCallPlatform platform;
  late PlaygroundController controller;
  late List<http.Request> requests;

  Future<void> start({Map<String, String> secure = const <String, String>{}, Map<String, Object> prefs = const <String, Object>{}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'vobiz_auth_id': 'MA_X',
      'vobiz_auth_token': 'tok',
      ...secure,
    });
    client = FakeClient();
    screen = FakeCallScreen();
    platform = FakeCallPlatform();
    requests = <http.Request>[];
    controller = PlaygroundController(
      client: client,
      callScreen: screen,
      platform: platform,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    );
    await controller.init();
  }

  Future<void> signIn() async {
    await controller.connect();
    await pumpEventQueue();
  }

  List<String> missedNotifications() => platform.requests.where((r) => r.startsWith('missed:')).toList();

  tearDown(() => controller.dispose());

  group('missed calls over SIP, with the app open (#19)', () {
    test('a direct call the caller gave up on is missed at once', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      client.emit(CallStateStatus.ended, reason: 'Caller cancelled');
      await pumpEventQueue();
      expect(missedNotifications(), <String>['missed:sip-1']);
    });

    test('a call rung by the sample server (PushRef) the caller gives up on is missed at once, under its PushRef',
        () async {
      await start();
      await signIn();
      client.ring(headers: <String, String>{'X-VH-PushRef': 'c1'});
      await pumpEventQueue();
      client.emit(CallStateStatus.ended, reason: 'Caller cancelled');
      await pumpEventQueue();
      expect(missedNotifications(), <String>['missed:c1']);
      expect(controller.history.byId('c1')!.outcome, CallOutcome.missed);
      expect(screen.ended, contains('c1'), reason: 'its call screen stops ringing');
    });

    test('CANCEL with Reason cause=200 is answered elsewhere, not missed', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      client.emit(CallStateStatus.ended, reason: 'Call completed elsewhere (SIP 200)');
      await pumpEventQueue();
      expect(missedNotifications(), isEmpty);
      expect(controller.history.byId('sip-1')!.outcome, CallOutcome.answeredElsewhere);
    });

    test('a declined call is not missed', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      await controller.reject();
      client.emit(CallStateStatus.ended);
      await pumpEventQueue();
      expect(missedNotifications(), isEmpty);
      expect(controller.history.byId('sip-1')!.outcome, CallOutcome.declined);
    });
  });

  group('the app open (#40)', () {
    test('a SIP call rings the system call screen in the foreground too', () async {
      await start();
      await signIn();
      controller.setForeground(true);
      client.ring(headers: <String, String>{'X-VH-PushRef': 'c9'});
      await pumpEventQueue();
      expect(screen.shown, contains('c9'));
      expect(controller.showIncoming, isTrue);
    });
  });

  group('the system call screen for a call ringing over SIP', () {
    ck.CallKitParams sipScreen(String id) =>
        ck.CallKitParams(id: id, extra: <String, dynamic>{'source': 'sip', 'call': 'sip-1'});

    test('Accept answers the call', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      expect(screen.shown, <String>['sip-sip-1']);
      screen.controller.add(ck.CallEventActionCallAccept(sipScreen('sip-sip-1')));
      await pumpEventQueue();
      expect(client.actions.where((a) => a == 'acceptCall'), hasLength(1));
      expect(platform.requests, contains(startsWith('start:')), reason: 'the call service starts on the tap');
    });

    test('Decline turns the call away once, logs it declined, and tells no server', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      screen.controller.add(ck.CallEventActionCallDecline(sipScreen('sip-sip-1')));
      await pumpEventQueue();
      client.emit(CallStateStatus.ended);
      await pumpEventQueue();
      expect(client.actions.where((a) => a == 'rejectCall'), hasLength(1));
      expect(controller.history.byId('sip-1')!.outcome, CallOutcome.declined);
      expect(missedNotifications(), isEmpty);
      expect(requests, isEmpty);
    });

    test('the screen ringing out turns the call away and logs it missed', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      screen.controller.add(const ck.CallEventActionCallTimeout('sip-sip-1'));
      await pumpEventQueue();
      expect(client.actions, contains('rejectCall'));
      expect(controller.history.byId('sip-1')!.outcome, CallOutcome.missed);
      expect(missedNotifications(), <String>['missed:sip-1']);
    });

    test('Accept on another call\'s screen never answers the call ringing over SIP (#46)', () async {
      await start();
      await signIn();
      client.ring(callId: 'sip-9', headers: <String, String>{'X-VH-PushRef': 'other-call'});
      await pumpEventQueue();
      screen.controller.add(ck.CallEventActionCallAccept(
          ck.CallKitParams(id: 'ref-1', extra: <String, dynamic>{'source': 'sip', 'call': 'sip-1'})));
      await pumpEventQueue();
      expect(client.actions, isNot(contains('acceptCall')));
      expect(screen.ended, contains('ref-1'), reason: 'the stray screen is taken down');
      expect(controller.showIncoming, isTrue, reason: 'the real call still rings');
      expect(platform.requests, contains('leaveLockScreen'), reason: 'Accept opened the app over the lock screen');
    });

    test('the app leaves the lock screen when the call accepted there ends', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      screen.controller.add(ck.CallEventActionCallAccept(sipScreen('sip-sip-1')));
      await pumpEventQueue();
      client.emit(CallStateStatus.active);
      await pumpEventQueue();
      expect(platform.requests, isNot(contains('stop')));
      client.emit(CallStateStatus.ended);
      await pumpEventQueue();
      expect(platform.requests.last, 'stop', reason: 'stopCallService also takes the app off the lock screen');
    });
  });

  group('the call service (#15, #47)', () {
    test('an outgoing call runs under the service from the tap to the end', () async {
      await start();
      await signIn();
      controller
        ..callerIdNumber = '9999999999'
        ..destNumber = '9876543210';
      await controller.call();
      expect(platform.requests.first, startsWith('start:'));
      client.emit(CallStateStatus.active, dir: CallDirection.outbound);
      await pumpEventQueue();
      expect(platform.requests.where((r) => r.startsWith('start:')), hasLength(1));
      client.emit(CallStateStatus.ended, dir: CallDirection.outbound);
      await pumpEventQueue();
      expect(platform.requests.last, 'stop');
      expect(controller.history.records.first.outcome, CallOutcome.outgoing);
    });

    test('a call answered in the app runs under the service', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      await controller.answer();
      expect(platform.requests, <String>['start:+918000000000']);
      client.emit(CallStateStatus.active);
      await pumpEventQueue();
      client.emit(CallStateStatus.ended);
      await pumpEventQueue();
      expect(platform.requests.last, 'stop');
      expect(controller.history.byId('sip-1')!.outcome, CallOutcome.answered);
    });

    test('"Hang up" on the ongoing-call notification hangs up', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      await controller.answer();
      client.emit(CallStateStatus.active);
      await pumpEventQueue();
      platform.hangUpController.add(null);
      await pumpEventQueue();
      expect(client.actions, contains('hangup'));
    });
  });

  test('start-up removes the device token and switch left by the version that paired with the server',
      () async {
    await start(
      secure: <String, String>{'vobiz_push_device_token': 'dev.secret'},
      prefs: <String, Object>{'vobiz_playground_receive_calls': true},
    );
    expect(await const FlutterSecureStorage().read(key: 'vobiz_push_device_token'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('vobiz_playground_receive_calls'), isFalse);
  });
}
