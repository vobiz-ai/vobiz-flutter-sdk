import 'package:fake_async/fake_async.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/call_history.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// Incoming calls: pushes, the call screen, the call service and the log.
void main() {
  late FakeClient client;
  late FakeCallScreen screen;
  late FakeCallPlatform platform;
  late PlaygroundController controller;

  Map<String, String> incoming(String id, {bool lineBusy = false}) => <String, String>{
        'type': 'incoming_call',
        'call_id': id,
        'call_key': 'k-$id',
        'caller': '+919876543210',
        'callee': '+918000000000',
        'ttl_ms': '40000',
        if (lineBusy) 'line_busy': '1',
      };

  Map<String, String> ended(String id, String reason) =>
      <String, String>{'type': 'call_ended', 'call_id': id, 'reason': reason};

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

  Future<void> signIn() async {
    await controller.connect();
    await pumpEventQueue();
  }

  List<String> missedNotifications() => platform.requests.where((r) => r.startsWith('missed:')).toList();

  tearDown(() => controller.dispose());

  group('push while the app is closed or signed out (#8)', () {
    test('rings the call screen and signs in at once, before any Accept', () async {
      await start();
      platform.pushController.add(incoming('c1'));
      await pumpEventQueue();

      expect(screen.shown, contains('c1'));
      expect(client.actions, contains('connectWithAuthToken'));
      expect(client.isConnected, isTrue);
      expect(controller.logs.map((l) => l.message),
          contains(contains('asking the push server to ring this phone now')));
    });

    test('the same push from Firebase and from the receiver is handled once', () async {
      await start();
      platform.pushController.add(incoming('c1'));
      platform.pushController.add(incoming('c1'));
      await pumpEventQueue();
      expect(screen.shown.where((id) => id == 'c1'), hasLength(1));
      expect(client.actions.where((a) => a == 'connectWithAuthToken'), hasLength(1));
    });

    test('a stale push (ttl_ms already over) does not ring', () async {
      await start();
      platform.pushController.add(<String, String>{...incoming('c1'), 'ttl_ms': '0'});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await pumpEventQueue();
      expect(screen.shown, isEmpty);
    });
  });

  group('call_ended pushes (#9, #19)', () {
    test('answered elsewhere: stops ringing, no missed call', () async {
      await start();
      platform.pushController.add(incoming('c1'));
      await pumpEventQueue();
      platform.pushController.add(ended('c1', 'answered_elsewhere'));
      await pumpEventQueue();

      expect(screen.ended, contains('c1'));
      expect(missedNotifications(), isEmpty);
      expect(controller.history.byId('c1')!.outcome, CallOutcome.answeredElsewhere);

      // The plugin's own 45 s timeout can still fire: no false missed call.
      screen.controller.add(const ck.CallEventActionCallTimeout('c1'));
      await pumpEventQueue();
      expect(missedNotifications(), isEmpty);
    });

    test('answered elsewhere also stops a call ringing here over SIP', () async {
      await start();
      await signIn();
      platform.pushController.add(incoming('c1'));
      client.ring(headers: <String, String>{'X-VH-PushRef': 'c1'});
      await pumpEventQueue();
      platform.pushController.add(ended('c1', 'answered_elsewhere'));
      await pumpEventQueue();
      expect(client.actions, contains('rejectCall'));
      expect(missedNotifications(), isEmpty);
      expect(controller.history.byId('c1')!.outcome, CallOutcome.answeredElsewhere);
    });

    test('a phone already in the call ignores answered_elsewhere', () async {
      await start();
      await signIn();
      client.ring(headers: <String, String>{'X-VH-PushRef': 'c1'});
      await pumpEventQueue();
      await controller.answer();
      client.emit(CallStateStatus.active);
      await pumpEventQueue();
      platform.pushController.add(ended('c1', 'answered_elsewhere'));
      await pumpEventQueue();
      expect(client.actions, isNot(contains('rejectCall')));
      expect(controller.status, PhoneStatus.inCall);
    });

    test('caller hung up: one missed-call notification, however many signals follow', () async {
      await start();
      platform.pushController.add(incoming('c1'));
      await pumpEventQueue();
      platform.pushController.add(ended('c1', 'caller_hung_up'));
      await pumpEventQueue();
      screen.controller.add(const ck.CallEventActionCallTimeout('c1'));
      await pumpEventQueue();

      expect(missedNotifications(), <String>['missed:c1']);
      expect(controller.history.byId('c1')!.outcome, CallOutcome.missed);
      expect(controller.history.byId('c1')!.party, '+919876543210');
    });

    test('a call_ended for a push that never arrived still logs the missed call', () async {
      await start();
      platform.pushController.add(ended('lost', 'missed'));
      await pumpEventQueue();
      expect(missedNotifications(), <String>['missed:lost']);
    });
  });

  group('missed calls over SIP, with the app open (#19)', () {
    test('a direct call (no bridge) the caller gave up on is missed at once', () async {
      await start();
      await signIn();
      client.ring();
      await pumpEventQueue();
      client.emit(CallStateStatus.ended, reason: 'Caller cancelled');
      await pumpEventQueue();
      expect(missedNotifications(), <String>['missed:sip-1']);
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

    test('a bridge call between ringing attempts is missed only if nothing follows', () {
      fakeAsync((async) {
        start();
        async.flushMicrotasks();
        controller.connect();
        async.flushMicrotasks();
        client.ring(headers: <String, String>{'X-VH-PushRef': 'c1'});
        async.flushMicrotasks();
        client.emit(CallStateStatus.ended);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        // The bridge rings again: still the same call.
        client.ring(callId: 'sip-2', headers: <String, String>{'X-VH-PushRef': 'c1'});
        async.flushMicrotasks();
        client.emit(CallStateStatus.ended, callId: 'sip-2');
        async.flushMicrotasks();
        async.elapse(PlaygroundController.missedGrace - const Duration(seconds: 1));
        expect(missedNotifications(), isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(missedNotifications(), <String>['missed:c1']);
      });
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

  group('a second call during a call (#45)', () {
    test('no ringing screen; call waiting; the running call is left alone', () async {
      await start();
      await signIn();
      client.ring(headers: <String, String>{'X-VH-PushRef': 'first'});
      await pumpEventQueue();
      await controller.answer();
      client.emit(CallStateStatus.active);
      await pumpEventQueue();
      screen.shown.clear();
      platform.requests.clear();

      platform.pushController.add(incoming('second'));
      await pumpEventQueue();
      expect(screen.shown, isEmpty);
      expect(controller.callWaiting?.callId, 'second');
      expect(platform.requests, isNot(contains('stop')));

      platform.pushController.add(ended('second', 'busy'));
      await pumpEventQueue();
      expect(controller.callWaiting, isNull);
      expect(screen.ended, isNot(contains('second')));
      expect(controller.history.byId('second')!.outcome, CallOutcome.busy);
      expect(missedNotifications(), <String>['missed:second']);
      expect(platform.requests, isNot(contains('stop')));
      expect(controller.status, PhoneStatus.inCall);
    });

    test('line_busy from the bridge: call waiting, no full-screen screen', () async {
      await start();
      await signIn();
      platform.pushController.add(incoming('c1', lineBusy: true));
      await pumpEventQueue();
      expect(screen.shown, isEmpty);
      expect(controller.callWaiting?.callId, 'c1');
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

  test('sign-out forgets the push bridge device token (#27)', () async {
    await start();
    await const FlutterSecureStorage().write(key: 'vobiz_push_device_token', value: 'dev.secret');
    await signIn();
    await controller.disconnect();
    expect(await const FlutterSecureStorage().read(key: 'vobiz_push_device_token'), isNull);
  });
}
