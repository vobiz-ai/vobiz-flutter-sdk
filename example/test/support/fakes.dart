import 'dart:async';

import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/push/call_platform.dart';
import 'package:vobiz_webrtc_example/src/push/call_screen.dart';
import 'package:vobiz_webrtc_example/src/push/push_service.dart';

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

  /// When set, the next Zero-Config or SIP Direct sign-in throws it (and
  /// clears it), as the SDK does when its first socket attempt fails.
  Object? failConnect;

  void _throwIfFailing() {
    final fail = failConnect;
    if (fail == null) return;
    failConnect = null;
    throw fail;
  }

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

  /// The SDK's token session reads it to time its refresh; the fake has no
  /// registrar to say.
  @override
  Duration? get accessTokenTimeLeft => null;

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
    _throwIfFailing();
    final gate = setupGate;
    if (gate != null) await gate.future;
    mode = VobizAuthMode.zeroConfig;
    _register('play1');
    return const ZeroConfigSession(sipUsername: 'play1', sipPassword: 'pw', applicationId: 'app1');
  }

  @override
  Future<void> connectWithCredentials(CredentialConfig config) async {
    actions.add('connectWithCredentials');
    _throwIfFailing();
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
  Future<void> disconnect({bool unregister = true}) async {
    actions.add(unregister ? 'disconnect' : 'disconnect:keep-registration');
    connected = false;
    username = null;
    accessToken = null;
    mode = VobizAuthMode.none;
  }

  /// When set, [makeCall] throws it before anything is sent, as the SDK
  /// does for a destination or caller ID it refuses.
  Object? failMakeCall;

  @override
  Future<String> makeCall(
    String destination, {
    String? callerId,
    Map<String, String> headers = const <String, String>{},
    bool record = false,
    String? dialUser,
  }) async {
    actions.add('makeCall');
    final fail = failMakeCall;
    if (fail != null) throw fail;
    state = CallStateStatus.connecting;
    direction = CallDirection.outbound;
    return 'out-1';
  }

  /// The caller ID of each [transferCall].
  final List<String?> transferCallerIds = <String?>[];

  @override
  Future<String> transferCall({
    String? number,
    String? sipUser,
    TransferLeg leg = TransferLeg.aLeg,
    String? callerId,
    Map<String, String> sipHeaders = const <String, String>{},
  }) async {
    actions.add('transferCall');
    transferCallerIds.add(callerId);
    return 'Transfer accepted';
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

  // ── Vobiz push ─────────────────────────────────────────────────────────
  final StreamController<VobizPushCallUpdate> fakePushUpdates = StreamController<VobizPushCallUpdate>.broadcast();

  /// The push handed to [handleIncomingPush], as the SDK would keep it.
  VobizIncomingPush? handledPush;

  /// The `CallEvent.callId` of the call the push announced, once it rang.
  String? pushedCallId;

  @override
  Stream<VobizPushCallUpdate> get pushCallUpdates => fakePushUpdates.stream;
  @override
  VobizIncomingPush? get pushedCall => handledPush;
  @override
  bool isPushedCall(String callId) => pushedCallId == callId;

  @override
  bool handleIncomingPush(VobizIncomingPush push) {
    if (push.isExpired()) return false;
    actions.add('handleIncomingPush:${push.callId}');
    handledPush = push;
    return true;
  }

  @override
  void reportCallScreenAccepted(VobizIncomingPush push) => actions.add('reportAccepted:${push.callId}');
  @override
  void reportCallScreenDeclined(VobizIncomingPush push) => actions.add('reportDeclined:${push.callId}');

  /// An INVITE arrives.
  void ring({
    String callId = 'sip-1',
    String from = '+918000000000',
    Map<String, String> headers = const {},
    String? sipCallId,
  }) {
    state = CallStateStatus.incoming;
    direction = CallDirection.inbound;
    this.headers = headers;
    final held = handledPush;
    if (held != null && sipCallId != null && sipCallId == held.callId) pushedCallId = callId;
    fakeCalls.add(CallEvent(
      callId: callId,
      state: CallStateStatus.incoming,
      direction: CallDirection.inbound,
      remoteIdentity: from,
      headers: headers,
      sipCallId: sipCallId,
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

  /// What [canUseFullScreen] answers.
  bool? fullScreen;

  @override
  Future<bool?> canUseFullScreen() async => fullScreen;
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

  /// Pushes Android received before Dart was listening (the push that
  /// started a closed app): [ready] hands them over once.
  final List<Map<String, String>> queued = <Map<String, String>>[];

  @override
  Future<List<Map<String, String>>> ready() async {
    final pushes = List<Map<String, String>>.of(queued);
    queued.clear();
    return pushes;
  }

  /// What [packageName] returns: the application id in build.gradle.kts.
  String? appId = 'ai.vobiz.vobiz_webrtc_example';

  @override
  Future<String?> packageName() async => appId;

  @override
  Future<void> startCallService({required String caller, required bool outbound}) async =>
      requests.add('start:$caller');

  @override
  Future<void> stopCallService() async => requests.add('stop');

  @override
  Future<void> leaveLockScreen() async => requests.add('leaveLockScreen');

  @override
  Future<void> showMissedCall({required String id, required String caller}) async =>
      requests.add('missed:$id');
}

/// Firebase, as a test sees it: set up, with one token, and token refreshes
/// the test sends through [refreshes].
class FakePush extends PushService {
  FakePush() : super.unavailable('fake');

  /// What [token] returns.
  String? pushToken = 'fcm-token-1';
  final StreamController<String> refreshes = StreamController<String>.broadcast();

  @override
  bool get available => true;

  @override
  Future<String?> token() async => pushToken;

  @override
  Stream<String> get tokenRefresh => refreshes.stream;

  @override
  Future<bool?> requestNotificationPermission() async => true;

  @override
  Future<bool?> notificationsAllowed() async => true;
}
