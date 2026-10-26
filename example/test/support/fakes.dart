import 'dart:async';

import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/push/call_platform.dart';
import 'package:vobiz_webrtc_example/src/push/call_screen.dart';

/// A VobizClient that never opens a socket: tests drive its events and read
/// back what the app asked of it.
class FakeClient implements VobizClient {
  final StreamController<ConnectionEvent> fakeConnections = StreamController<ConnectionEvent>.broadcast();
  final StreamController<CallEvent> fakeCalls = StreamController<CallEvent>.broadcast();
  final StreamController<ErrorEvent> fakeErrors = StreamController<ErrorEvent>.broadcast();

  /// Every SDK method the app called, in order.
  final List<String> actions = <String>[];

  /// When set, Zero-Config sign-in waits for it (an in-flight /api/setup).
  Completer<void>? setupGate;

  /// Sign-in completes and registers at once.
  bool registerOnConnect = true;

  bool connected = false;
  CallStateStatus state = CallStateStatus.idle;
  Map<String, String> headers = const <String, String>{};
  CallDirection? direction;
  String? username;
  VobizAuthMode mode = VobizAuthMode.none;

  @override
  String backendUrl = '';

  @override
  Stream<ConnectionEvent> get connectionEvents => fakeConnections.stream;
  @override
  Stream<CallEvent> get callEvents => fakeCalls.stream;
  @override
  Stream<ErrorEvent> get errorEvents => fakeErrors.stream;
  @override
  Stream<MediaEvent> get mediaEvents => const Stream<MediaEvent>.empty();

  @override
  bool get isConnected => connected;

  /// Set to reconnecting to act as the SDK does while its network is down.
  ConnectionStateStatus? connection;
  @override
  ConnectionStateStatus get connectionState =>
      connection ?? (connected ? ConnectionStateStatus.connected : ConnectionStateStatus.disconnected);
  @override
  CallStateStatus get callState => state;
  @override
  Map<String, String> get callHeaders => headers;
  @override
  CallDirection? get callDirection => direction;
  @override
  String? get sipUsername => username;
  @override
  VobizAuthMode get authMode => mode;

  /// The access token sign-in in effect (set by [connectWithAccessToken]).
  @override
  VobizAccessToken? accessToken;

  /// Every token passed to [connectWithAccessToken] / [updateAccessToken].
  final List<String> tokens = <String>[];

  @override
  Future<void> connectWithAccessToken(String token) async {
    actions.add('connectWithAccessToken');
    tokens.add(token);
    final parsed = VobizAccessToken.parse(token);
    accessToken = parsed;
    username = parsed.sipUsername;
    mode = VobizAuthMode.accessToken;
    if (registerOnConnect) {
      connected = true;
      fakeConnections.add(ConnectionEvent(
        connectionState: ConnectionStateStatus.connected,
        registrationState: RegistrationState.registered,
        message: 'Registered',
      ));
    }
  }

  @override
  Future<void> updateAccessToken(String token) async {
    actions.add('updateAccessToken');
    tokens.add(token);
    accessToken = VobizAccessToken.parse(token);
  }

  @override
  String? get lastCallUuid => null;
  @override
  String? get callUuid => null;

  @override
  Future<ZeroConfigSession> connectWithAuthToken({required String authId, required String authToken}) async {
    actions.add('connectWithAuthToken');
    final gate = setupGate;
    if (gate != null) await gate.future;
    mode = VobizAuthMode.zeroConfig;
    _register('play1');
    return const ZeroConfigSession(sipUsername: 'play1', sipPassword: 'pw', applicationId: 'app1');
  }

  @override
  Future<void> connectWithCredentials(CredentialConfig config) async {
    actions.add('connectWithCredentials');
    mode = VobizAuthMode.sipDirect;
    _register(config.username);
  }

  void _register(String user) {
    username = user;
    if (!registerOnConnect) return;
    connected = true;
    scheduleMicrotask(() => fakeConnections.add(ConnectionEvent(
          connectionState: ConnectionStateStatus.connected,
          registrationState: RegistrationState.registered,
        )));
  }

  @override
  Future<void> disconnect() async {
    actions.add('disconnect');
    connected = false;
    username = null;
    accessToken = null;
    mode = VobizAuthMode.none;
  }

  @override
  Future<String> makeCall(
    String destination, {
    String? callerId,
    Map<String, String> headers = const <String, String>{},
    bool record = false,
    String? dialUser,
  }) async {
    actions.add('makeCall');
    state = CallStateStatus.connecting;
    direction = CallDirection.outbound;
    return 'out-1';
  }

  @override
  Future<void> acceptCall([String? callId]) async {
    actions.add('acceptCall');
    state = CallStateStatus.connecting;
  }
  @override
  Future<void> rejectCall([String? callId]) async => actions.add('rejectCall');
  @override
  Future<void> hangup([String? callId]) async => actions.add('hangup');
  @override
  Future<CallStats?> getCallStats() async => null;
  @override
  Future<void> dispose() async {}

  /// An INVITE arrives.
  void ring({String callId = 'sip-1', String from = '+918000000000', Map<String, String> headers = const {}}) {
    state = CallStateStatus.incoming;
    direction = CallDirection.inbound;
    this.headers = headers;
    fakeCalls.add(CallEvent(
      callId: callId,
      state: CallStateStatus.incoming,
      direction: CallDirection.inbound,
      remoteIdentity: from,
      headers: headers,
    ));
  }

  /// The current call reaches [next].
  void emit(CallStateStatus next, {String callId = 'sip-1', CallDirection? dir, String? reason}) {
    state = next == CallStateStatus.ended ? CallStateStatus.idle : next;
    fakeCalls.add(CallEvent(callId: callId, state: next, direction: dir ?? direction, reason: reason));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The system call screen, recorded instead of shown.
class FakeCallScreen extends CallScreenApi {
  final StreamController<ck.CallEvent?> controller = StreamController<ck.CallEvent?>.broadcast();
  final List<String> shown = <String>[];
  final List<String> ended = <String>[];
  final List<ck.CallKitParams> screens = <ck.CallKitParams>[];

  @override
  Stream<ck.CallEvent?> get events => controller.stream;

  @override
  Future<void> showIncoming({
    required String id,
    required String caller,
    String subtitle = 'Vobiz call',
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    shown.add(id);
    screens.add(ck.CallKitParams(id: id, nameCaller: caller, extra: extra));
  }

  @override
  Future<void> end(String id) async {
    ended.add(id);
    screens.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<ck.CallKitParams>> active() async => List<ck.CallKitParams>.of(screens);

  @override
  Future<bool?> canUseFullScreen() async => null;
}

/// The Android side (call service, missed-call notifications), recorded.
class FakeCallPlatform extends CallPlatform {
  FakeCallPlatform() : super.forTesting();

  final List<String> requests = <String>[];
  final StreamController<Map<String, String>> pushController = StreamController<Map<String, String>>.broadcast();
  final StreamController<void> hangUpController = StreamController<void>.broadcast();

  @override
  Stream<Map<String, String>> get pushes => pushController.stream;
  @override
  Stream<void> get hangUpRequests => hangUpController.stream;

  @override
  Future<List<Map<String, String>>> ready() async => const <Map<String, String>>[];

  @override
  Future<void> startCallService({required String caller, required bool outbound}) async =>
      requests.add('start:$caller');

  @override
  Future<void> stopCallService() async => requests.add('stop');

  @override
  Future<void> showMissedCall({required String id, required String caller, String? detail}) async =>
      requests.add('missed:$id');
}
