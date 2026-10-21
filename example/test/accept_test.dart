import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/push/push_call.dart';

import 'support/fakes.dart';

/// Accept on the system call screen, for a pushed call.
void main() {
  late FakeClient client;
  late FakeCallScreen screen;
  late PlaygroundController controller;

  final pushed = PushCall.fromData(<String, dynamic>{
    'type': 'incoming_call',
    'call_id': 'ref-1',
    'call_key': 'k',
    'caller': '+919876543210',
    'callee': '+918000000000',
  })!;

  ck.CallEvent accept(PushCall call) =>
      ck.CallEventActionCallAccept(ck.CallKitParams(id: call.callId, extra: call.toExtra()));

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'vobiz_auth_id': 'MA_X',
      'vobiz_auth_token': 'tok',
    });
    client = FakeClient();
    screen = FakeCallScreen();
    controller = PlaygroundController(client: client, callScreen: screen, platform: FakeCallPlatform());
    await controller.init();
  });

  tearDown(() => controller.dispose());

  int acceptedLogs() => controller.logs.where((l) => l.message.startsWith('📲 Accepted the call from')).length;

  test('a replayed Accept takes the call once: one sign-in, one bridge accept (#35)', () async {
    screen.controller.add(accept(pushed));
    await pumpEventQueue();
    screen.controller.add(accept(pushed));
    await pumpEventQueue();

    expect(acceptedLogs(), 1);
    expect(client.actions.where((a) => a.startsWith('connect')), hasLength(1));
  });

  test('after an Accept, a call from the same Vobiz number without the reference is not answered (#46)',
      () async {
    screen.controller.add(accept(pushed));
    await pumpEventQueue();
    expect(client.isConnected, isTrue);

    client.ring(from: '+918000000000', headers: <String, String>{'X-VH-Caller': '919876543210'});
    await pumpEventQueue();
    expect(client.actions, isNot(contains('acceptCall')));
    expect(controller.showIncoming, isTrue);

    client.emit(CallStateStatus.ended);
    await pumpEventQueue();
    client.ring(callId: 'sip-2', headers: <String, String>{'X-VH-PushRef': 'ref-1'});
    await pumpEventQueue();
    expect(client.actions, contains('acceptCall'));
  });

  test('Accept on one call screen never answers a different call ringing over SIP (#46)', () async {
    await controller.connect();
    await pumpEventQueue();
    client.ring(callId: 'sip-9', headers: <String, String>{'X-VH-PushRef': 'other-call'});
    await pumpEventQueue();

    screen.controller.add(accept(pushed));
    await pumpEventQueue();
    expect(client.actions, isNot(contains('acceptCall')));
  });
}
