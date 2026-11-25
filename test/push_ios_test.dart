import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

/// The client as VobizIosPush sees it: calls and pushes in, call control
/// recorded.
class _Client extends VobizClient {
  _Client() : super(config: const SdkConfig(autoReconnect: false));

  final StreamController<CallEvent> calls = StreamController<CallEvent>.broadcast();
  final StreamController<VobizPushCallUpdate> updates = StreamController<VobizPushCallUpdate>.broadcast();
  final List<String> did = <String>[];
  bool claim = true;
  CallStateStatus state = CallStateStatus.idle;
  String? current;
  bool muted = false;

  @override
  Stream<CallEvent> get callEvents => calls.stream;
  @override
  Stream<VobizPushCallUpdate> get pushCallUpdates => updates.stream;
  @override
  CallStateStatus get callState => state;
  @override
  String? get currentCallId => current;
  @override
  bool get isMuted => muted;
  @override
  VobizIncomingPush? get pushedCall => null;
  @override
  bool isPushedCall(String callId) => false;

  @override
  bool handleIncomingPush(VobizIncomingPush push) {
    did.add('claim:${push.callId}');
    return claim;
  }

  @override
  void reportCallScreenAccepted(VobizIncomingPush push) => did.add('accepted:${push.callId}');
  @override
  void reportCallScreenDeclined(VobizIncomingPush push) => did.add('declined:${push.callId}');
  @override
  Future<void> acceptCall([String? callId]) async => did.add('accept:$callId');
  @override
  Future<void> rejectCall([String? callId]) async => did.add('reject:$callId');
  @override
  Future<void> hangup([String? callId]) async => did.add('hangup:$callId');
  @override
  Future<void> mute([String? callId]) async => did.add('mute:$callId');
  @override
  Future<void> unmute([String? callId]) async => did.add('unmute:$callId');

  void emit(String callId, CallStateStatus s, {CallDirection? direction, String? sipCallId, int? sipCode}) {
    state = s;
    current = callId;
    calls.add(CallEvent(
      callId: callId,
      state: s,
      direction: direction,
      sipCallId: sipCallId,
      remoteIdentity: '+911234567890',
      sipCode: sipCode,
    ));
  }
}

Map<String, Object?> _pushData(String callId) => <String, Object?>{
      'type': 'incoming_call',
      'call_id': callId,
      'caller_number': '+911234567890',
      'callee': 'alice',
      'index': '1',
      'label': '2',
      'registrar': '15.207.232.91',
      'expires_at': '${DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch ~/ 1000}',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(VobizIosPush.channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _Client client;
  late VobizIosPush ios;
  late List<MethodCall> native;
  late List<Object?> startEvents;

  Future<void> fromNative(Map<String, Object?> event) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('event', event));
    await messenger.handlePlatformMessage(channel.name, data, (_) {});
  }

  setUp(() {
    client = _Client();
    native = <MethodCall>[];
    startEvents = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      native.add(call);
      if (call.method == 'start') return <String, Object?>{'voipToken': 'tok-1', 'events': startEvents};
      return null;
    });
    ios = VobizIosPush(client, supported: true);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await ios.dispose();
  });

  Iterable<String> calls(String method) =>
      native.where((c) => c.method == method).map((c) => '${(c.arguments as Map?)?['key'] ?? ''}');

  test('start saves the CallKit settings and reads the token', () async {
    await ios.start();
    expect(native.first.method, 'start');
    expect((native.first.arguments as Map)['includesCallsInRecents'], true);
    expect(ios.voipToken, 'tok-1');
    expect(await ios.waitForVoipToken(), 'tok-1');
  });

  test('the push that launched the app is claimed at start', () async {
    startEvents = <Object?>[
      <String, Object?>{'type': 'push', 'data': _pushData('held-1')},
    ];
    final pushes = <VobizIncomingPush>[];
    ios.pushes.listen(pushes.add);
    await ios.start();
    await pumpEventQueue();
    expect(client.did, <String>['claim:held-1']);
    expect(pushes.single.callId, 'held-1');
  });

  test('a stale push is ended on CallKit', () async {
    client.claim = false;
    await ios.start();
    await fromNative(<String, Object?>{'type': 'push', 'data': _pushData('held-2')});
    expect(calls('end'), <String>['held-2']);
  });

  test('a new VoIP token is reported', () async {
    await ios.start();
    final tokens = <String>[];
    ios.voipTokenChanges.listen(tokens.add);
    await fromNative(<String, Object?>{'type': 'token', 'token': 'tok-2'});
    await pumpEventQueue();
    expect(tokens, <String>['tok-2']);
    expect(ios.voipToken, 'tok-2');
  });

  group('CallKit buttons', () {
    test('Accept before the held call arrives answers it when it does', () async {
      await ios.start();
      await fromNative(<String, Object?>{'type': 'push', 'data': _pushData('held-3')});
      await fromNative(<String, Object?>{'type': 'action', 'action': 'accept', 'key': 'held-3'});
      expect(client.did.last, 'accepted:held-3');
    });

    test('Decline before the held call arrives turns it away', () async {
      await ios.start();
      await fromNative(<String, Object?>{'type': 'push', 'data': _pushData('held-4')});
      await fromNative(<String, Object?>{'type': 'action', 'action': 'decline', 'key': 'held-4'});
      expect(client.did.last, 'declined:held-4');
    });

    test('Accept on a call that rings over SIP answers it', () async {
      await ios.start();
      client.emit('c1', CallStateStatus.incoming, direction: CallDirection.inbound, sipCallId: 'sip-call-1');
      await pumpEventQueue();
      expect(calls('reportIncoming'), <String>['sip-sip-call-1']);
      await fromNative(<String, Object?>{'type': 'action', 'action': 'accept', 'key': 'sip-sip-call-1'});
      expect(client.did.last, 'accept:c1');
    });

    test('End during a call hangs up; mute follows CallKit', () async {
      await ios.start();
      client.emit('c2', CallStateStatus.incoming, direction: CallDirection.inbound, sipCallId: 's2');
      await pumpEventQueue();
      client.emit('c2', CallStateStatus.active, direction: CallDirection.inbound, sipCallId: 's2');
      await fromNative(<String, Object?>{'type': 'action', 'action': 'mute', 'key': 'sip-s2', 'muted': true});
      expect(client.did.last, 'mute:c2');
      await fromNative(<String, Object?>{'type': 'action', 'action': 'end', 'key': 'sip-s2'});
      expect(client.did.last, 'hangup:c2');
    });
  });

  group('calls', () {
    test('a pushed call is not shown twice, and ends on CallKit', () async {
      await ios.start();
      await fromNative(<String, Object?>{'type': 'push', 'data': _pushData('held-5')});
      client.emit('c3', CallStateStatus.incoming, direction: CallDirection.inbound, sipCallId: 'held-5');
      await pumpEventQueue();
      expect(calls('reportIncoming'), isEmpty);
      client.emit('c3', CallStateStatus.active, direction: CallDirection.inbound, sipCallId: 'held-5');
      await pumpEventQueue();
      expect(calls('answered'), <String>['held-5']);
      expect(native.where((c) => c.method == 'audioStart'), isEmpty);
      client.emit('c3', CallStateStatus.ended, direction: CallDirection.inbound, sipCallId: 'held-5');
      await pumpEventQueue();
      expect(calls('end'), <String>['held-5']);
    });

    test('an outgoing call starts and stops its own audio', () async {
      await ios.start();
      client.emit('o1', CallStateStatus.connecting, direction: CallDirection.outbound);
      client.emit('o1', CallStateStatus.ringing, direction: CallDirection.outbound);
      client.emit('o1', CallStateStatus.active, direction: CallDirection.outbound);
      client.emit('o1', CallStateStatus.ended, direction: CallDirection.outbound);
      await pumpEventQueue();
      expect(native.where((c) => c.method == 'audioStart').length, 1);
      expect(native.where((c) => c.method == 'audioStop').length, 1);
      expect(calls('reportIncoming'), isEmpty);
    });

    test('a held call that never came is ended as missed', () async {
      await ios.start();
      await fromNative(<String, Object?>{'type': 'push', 'data': _pushData('held-6')});
      final push = VobizIncomingPush.tryParse(_pushData('held-6'))!;
      client.updates.add(VobizPushCallUpdate(push: push, status: VobizPushCallStatus.expired));
      await pumpEventQueue();
      final end = native.lastWhere((c) => c.method == 'end');
      expect((end.arguments as Map)['key'], 'held-6');
      expect((end.arguments as Map)['reason'], 'unanswered');
    });

    test('with showCallsOnCallKit off, a SIP call is not put on CallKit', () async {
      await ios.dispose();
      ios = VobizIosPush(client, supported: true, showCallsOnCallKit: false);
      await ios.start();
      client.emit('c4', CallStateStatus.incoming, direction: CallDirection.inbound, sipCallId: 's4');
      await pumpEventQueue();
      expect(calls('reportIncoming'), isEmpty);
    });
  });

  test('does nothing where it is not supported', () async {
    final off = VobizIosPush(client, supported: false);
    await off.start();
    expect(native, isEmpty);
    expect(await off.waitForVoipToken(), isNull);
    await off.dispose();
  });
}
