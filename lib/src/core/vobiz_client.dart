import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../audio/audio_route.dart';
import '../audio/proximity.dart';
import '../auth/access_token.dart';
import '../backend/webhook_server_api.dart';
import '../calls/call_session.dart';
import '../errors/vobiz_exception.dart';
import '../events/call_event.dart';
import '../events/connection_event.dart';
import '../events/error_event.dart';
import '../events/media_event.dart';
import '../media/audio_interruption.dart';
import '../media/call_media_event.dart';
import '../media/dtmf_transport.dart';
import '../models/auth/auth_mode.dart';
import '../models/auth/credential_config.dart';
import '../models/auth/token_config.dart';
import '../models/auth/zero_config_session.dart';
import '../models/call/call_direction.dart';
import '../models/call/call_stats.dart';
import '../models/call/recording.dart';
import '../models/call/transfer_leg.dart';
import '../network/connection_supervisor.dart';
import '../network/app_lifecycle_monitor.dart';
import '../network/connectivity_monitor.dart';
import '../network/network_event.dart';
import '../push/vobiz_push.dart';
import '../signaling/sip_service.dart';
import '../state/call_state.dart';
import '../state/connection_state.dart';
import '../state/registration_state.dart';
import '../utils/logger.dart';
import '../utils/stream_extensions.dart';
import '../webrtc/peer_service.dart';
import 'sdk_config.dart';
import 'sip_headers.dart';

/// Makes and receives Vobiz calls.
///
/// Sign in one of two ways, the same two the Vobiz WebRTC Playground offers:
///
/// - **Zero-Config Setup** — [connectWithAuthToken] with the account's Auth ID
///   and Auth Token. The webhook server provisions the SIP endpoint.
/// - **SIP Direct** — [connectWithCredentials] with an existing endpoint's
///   SIP username and password.
///
/// No credentials are compiled in: whoever uses the app supplies them.
class VobizClient {
  VobizClient({
    SdkConfig config = const SdkConfig(),
    Logger? logger,
    http.Client? httpClient,
    ConnectivityMonitor? connectivityMonitor,
    AppLifecycleMonitor? lifecycleMonitor,
  }) : this._(
          config: config,
          logger: logger ?? Logger(writer: config.debug ? debugPrint : null),
          httpClient: httpClient,
          connectivityMonitor: connectivityMonitor,
          lifecycleMonitor: lifecycleMonitor,
        );

  /// Test seam: a client driven by the given SIP and media services, with
  /// shorter timers so call-lifecycle tests run in milliseconds.
  @visibleForTesting
  VobizClient.withServices({
    required SIPService sip,
    required PeerService peer,
    SdkConfig config = const SdkConfig(autoReconnect: false),
    Logger? logger,
    http.Client? httpClient,
    Duration setupTimeout = _defaultSetupTimeout,
    Duration networkLossGrace = _defaultNetworkLossGrace,
    ConnectivityMonitor? connectivityMonitor,
    AppLifecycleMonitor lifecycleMonitor = const NoAppLifecycleMonitor(),
  }) : this._(
          config: config,
          logger: logger ?? Logger(),
          httpClient: httpClient,
          connectivityMonitor: connectivityMonitor ?? _AlwaysOnlineMonitor(),
          lifecycleMonitor: lifecycleMonitor,
          sip: sip,
          peer: peer,
          setupTimeout: setupTimeout,
          networkLossGrace: networkLossGrace,
        );

  VobizClient._({
    required SdkConfig config,
    required Logger logger,
    http.Client? httpClient,
    SIPService? sip,
    PeerService? peer,
    Duration setupTimeout = _defaultSetupTimeout,
    Duration networkLossGrace = _defaultNetworkLossGrace,
    ConnectivityMonitor? connectivityMonitor,
    AppLifecycleMonitor? lifecycleMonitor,
  })  : _config = config,
        _logger = logger,
        _lifecycle = lifecycleMonitor ?? PlatformAppLifecycleMonitor(),
        _sip = sip ??
            SIPService(
              wsUrl: config.wsUrl,
              sipServer: config.sipServer,
              keepAlive: config.keepAlive,
              logger: logger,
            ),
        _peer = peer ??
            PeerService(
              iceConfig: config.iceConfig,
              mediaConstraints: config.mediaConstraints,
              logger: logger,
            ),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _setupTimeout = setupTimeout,
        _networkLossGrace = networkLossGrace,
        backendUrl = config.backendUrl {
    _api = WebhookServerApi(
        client: _http, allowAccountCredentials: config.unsafeDemoZeroConfig);
    _supervisor = ConnectionSupervisor(
      policy: config.reconnectPolicy,
      monitor: connectivityMonitor ??
          (config.watchNetwork
              ? PlatformConnectivityMonitor()
              : _AlwaysOnlineMonitor()),
      reconnect: _reconnectOnce,
      onEvent: _onNetworkEvent,
      hasActiveCall: () => _callId != null,
      onHandover: _onNetworkHandover,
      logger: _logger,
    );
    _interruptions = AudioInterruptionHandler(
      isCallActive: () => _callState == CallStateStatus.active ||
          _callState == CallStateStatus.held,
      isHeld: () => _callState == CallStateStatus.held,
      hold: hold,
      resume: resume,
      logger: _logger,
    );
    _wireSip();
  }

  /// How long an outbound INVITE may go without any response at all (not
  /// even 100 Trying) before the call is given up. Once the far end has
  /// responded, ringing is bounded by the server's `<Dial timeout>` instead.
  static const Duration _defaultSetupTimeout = Duration(seconds: 30);

  /// How long a connected call may survive a dropped socket or lost media
  /// (ICE failed/disconnected) before it is ended as `network_lost`.
  static const Duration _defaultNetworkLossGrace = Duration(seconds: 12);

  final SdkConfig _config;
  final Logger _logger;
  final SIPService _sip;
  final PeerService _peer;
  final http.Client _http;
  final bool _ownsHttp;
  late final WebhookServerApi _api;
  final Duration _setupTimeout;
  final Duration _networkLossGrace;
  late final ConnectionSupervisor _supervisor;
  final AppLifecycleMonitor _lifecycle;
  StreamSubscription<bool>? _lifecycleSub;
  bool? _inForeground;
  DateTime? _lastForegroundRegister;
  bool _reregisteringOnForeground = false;

  /// Resumes closer together than this count as one
  /// ([SdkConfig.reregisterOnForeground]).
  static const Duration _foregroundDebounce = Duration(seconds: 2);
  late final AudioInterruptionHandler _interruptions;

  /// A hold, resume or ICE restart re-INVITE is in flight.
  bool _reInviteInProgress = false;

  /// Public base URL of the webhook server (see [SdkConfig.backendUrl]).
  ///
  /// Mutable so callers can update it at login time without recreating the
  /// client.
  String backendUrl;

  // Internal state
  String? _callId;
  String? _activeCallDestination;
  CallStateStatus _callState = CallStateStatus.idle;
  RegistrationState _registrationState = RegistrationState.unregistered;
  ConnectionStateStatus _connectionState = ConnectionStateStatus.disconnected;

  // Sign-in. The Auth ID and Auth Token exist only for Zero-Config Setup and
  // only in memory, for transfers; disconnect() drops them.
  VobizAuthMode _authMode = VobizAuthMode.none;
  String? _authId;
  String? _authToken;

  // Credentials stored for reconnection: a password, or an access token.
  String? _username;
  String? _password;
  VobizAccessToken? _accessToken;

  bool get _hasSignIn =>
      _username != null && (_password != null || _accessToken != null);

  /// Bumped by every sign-in and sign-out, so a sign-in still connecting
  /// when it is replaced stops quietly instead of reporting on the new one.
  int _signInEpoch = 0;

  /// The registrar could not take a REGISTER during a call (no answer, 408,
  /// 480, 5xx): reconnect once the call is over, as the socket closes then.
  bool _reconnectWhenCallEnds = false;

  // Inbound call state
  String? _pendingInboundCaller;
  String? _pendingInboundSdp;
  Timer? _callSetupTimer;

  // The call whose 200 OK has been applied, so a retransmitted 200 is not
  // applied (and reported as failing) a second time.
  String? _answeredCallId;

  // A connected call riding out a dropped socket or lost media.
  Timer? _networkLossTimer;
  bool _signalingLost = false;
  bool _mediaLost = false;

  // The current call's details
  CallDirection? _direction;
  String? _callUuid;
  String? _lastCallUuid;
  Map<String, String> _callHeaders = const <String, String>{};

  // Event streams
  final _connectionEvents = StreamController<ConnectionEvent>.broadcast();
  final _callEvents = StreamController<CallEvent>.broadcast();
  final _mediaEvents = StreamController<MediaEvent>.broadcast();
  final _errorEvents = StreamController<ErrorEvent>.broadcast();
  final _networkEvents = StreamController<NetworkEvent>.broadcast();
  final _pushCallUpdates = StreamController<VobizPushCallUpdate>.broadcast();

  /// The call a Vobiz push announced ([handleIncomingPush]), until its INVITE
  /// arrives and the call ends, or the push expires.
  _PushedCall? _pushed;

  /// This SDK's version, for `VobizPushDevice.sdkVersion` and logs.
  static const String sdkVersion = '0.2.0';

  /// What becomes of each call push handed to [handleIncomingPush]: claimed,
  /// ringing, answered or declined from the call screen, or expired.
  Stream<VobizPushCallUpdate> get pushCallUpdates => _pushCallUpdates.stream;

  /// The push whose call is awaited or ringing, if any.
  VobizIncomingPush? get pushedCall => _pushed?.push;

  /// Whether [callId] (a `CallEvent.callId`) is the call a push announced.
  bool isPushedCall(String callId) => _pushed?.callId == callId;

  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  Stream<CallEvent> get callEvents => _callEvents.stream;
  Stream<MediaEvent> get mediaEvents => _mediaEvents.stream;
  Stream<ErrorEvent> get errorEvents => _errorEvents.stream;

  /// Network changes (offline, online, Wi-Fi to mobile) and reconnect
  /// progress (`reconnecting`, `reconnected`, `reconnectFailed`). Each event
  /// carries a [SignalingQuality] for a connection indicator.
  Stream<NetworkEvent> get networkEvents => _networkEvents.stream;

  /// The device's network as last reported, once signed in.
  NetworkStatus? get network => _supervisor.network;

  /// How usable the signalling connection is right now.
  SignalingQuality get signalingQuality => _supervisor.quality;
  /// Typed media updates for the current call: [MuteChangedEvent],
  /// [HoldChangedEvent], [EarlyMediaEvent], [AudioRouteChangedEvent] and
  /// [CallQualityEvent] (every 2 s once media flows; show a "poor network"
  /// warning when `levelChanged` and the level is poor).
  Stream<CallMediaEvent> get callMediaEvents => _peer.callMediaEvents;

  /// Call audio outputs: list them, pick earpiece, speaker, Bluetooth or a
  /// wired headset, and watch for changes. Set
  /// [AudioRouteController.bluetoothPermissionRequester] so Bluetooth
  /// headsets work on Android 12+.
  AudioRouteController get audioRoutes => _peer.audioRoutes;

  /// Turns the screen off at the ear while a call is on the earpiece. The SDK
  /// has no platform code, so the app supplies the switch; see
  /// [ProximityController]. Does nothing by default.
  ProximityController get proximity => _peer.proximity;
  set proximity(ProximityController value) => _peer.proximity = value;

  RegistrationState get registrationState => _registrationState;
  ConnectionStateStatus get connectionState => _connectionState;

  bool get isConnected =>
      _connectionState == ConnectionStateStatus.connected &&
      _registrationState == RegistrationState.registered;

  /// How this client signed in.
  VobizAuthMode get authMode => _authMode;

  /// The SIP username this client registers as, once signed in. For an
  /// access token it is `<sub>_<iss>`.
  String? get sipUsername => _username;

  /// The access token this client signed in with: identity, expiry and
  /// grants. Null unless [authMode] is [VobizAuthMode.accessToken].
  VobizAccessToken? get accessToken => _accessToken;

  /// How long the registrar said the access token had left, at the last
  /// successful REGISTER (from its clock, not the device's). Null before one,
  /// or without an access token.
  Duration? get accessTokenTimeLeft {
    final seconds = _accessToken == null ? null : _sip.accessTokenExpiresIn;
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// The current call's state ([CallStateStatus.idle] between calls).
  CallStateStatus get callState => _callState;

  String? get currentCallId => _callId;

  /// Whether the current call was placed by this client or rang it.
  CallDirection? get callDirection => _direction;

  /// Vobiz's CallUUID for the current call, once the platform reports it.
  String? get callUuid => _callUuid;

  /// The CallUUID of the most recent call that has ended. Use it to find that
  /// call's recording with [waitForRecording].
  String? get lastCallUuid => _lastCallUuid;

  /// Custom `X-VH-` headers on the current call: sent on an outbound call,
  /// received on an inbound one.
  Map<String, String> get callHeaders => Map<String, String>.unmodifiable(_callHeaders);

  CallSession? get currentCall {
    final id = _callId;
    if (id == null) return null;
    return CallSession(
      callId: id,
      remoteIdentity: _pendingInboundCaller ?? _activeCallDestination ?? '',
      isIncoming: _direction == CallDirection.inbound,
      state: _callState,
      callUuid: _callUuid,
      headers: _callHeaders,
    );
  }

  // ---------------------------------------------------------------------------
  // Sign in / out
  // ---------------------------------------------------------------------------

  /// Zero-Config Setup: sign in with the account's Auth ID and Auth Token.
  ///
  /// **Demo only.** Throws [VobizDemoModeRequiredException] unless
  /// [SdkConfig.unsafeDemoZeroConfig] is true. Production apps use
  /// `connectWithCredentialsProvider` with per-user credentials from their
  /// own backend; see CREDENTIALS.md.
  ///
  /// Like the web Playground, this sends them to the webhook server's
  /// `/api/setup`, which finds or creates the "Vobiz WebRTC Playground"
  /// application and endpoint on that account, points the application at
  /// `<backendUrl>/api/answer`, gives the endpoint a fresh password and
  /// returns its credentials. The client then registers as that endpoint;
  /// watch [connectionEvents] for the result.
  ///
  /// The Auth ID and Auth Token stay in memory, for [transferCall], until
  /// [disconnect]. The SDK never stores them.
  ///
  /// Throws [VobizException] (`setup_failed`) when the server rejects the
  /// credentials or cannot be reached.
  Future<ZeroConfigSession> connectWithAuthToken({
    required String authId,
    required String authToken,
  }) async {
    final id = authId.trim();
    final token = authToken.trim();
    if (id.isEmpty || token.isEmpty) {
      throw ArgumentError('Both the Auth ID and the Auth Token are required');
    }
    // Demo only: refuse before touching the current connection.
    if (!_config.unsafeDemoZeroConfig) {
      throw const VobizDemoModeRequiredException('Zero-Config Setup');
    }

    _closeExistingConnection();
    final epoch = _signInEpoch;
    _connectionState = ConnectionStateStatus.connecting;
    _connectionEvents.addIfOpen(ConnectionEvent(
      connectionState: _connectionState,
      registrationState: _registrationState,
      message: 'Provisioning the application and endpoint',
    ));

    final ZeroConfigSession session;
    try {
      session = await _api.setup(
        webhookUrl: backendUrl,
        voiceApiUrl: _config.voiceApiUrl,
        authId: id,
        authToken: token,
      );
    } on VobizException catch (e) {
      final explained = _explainSetupFailure(e);
      // Signed out, or in again, meanwhile: that sign-in owns the state.
      if (epoch != _signInEpoch) throw explained;
      _connectionState = ConnectionStateStatus.failed;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Setup failed: ${explained.message}',
      ));
      _emitError('setup_failed', explained.message, e);
      throw explained;
    }
    // Signed out, or in again, while the server was provisioning: do not
    // sign in as this endpoint over that.
    if (epoch != _signInEpoch) return session;

    _authMode = VobizAuthMode.zeroConfig;
    _authId = id;
    _authToken = token;
    await _connectWithCredentials(session.sipUsername, session.sipPassword);
    return session;
  }

  /// SIP Direct with a [CredentialConfig], or a [TokenConfig] whose token is
  /// the endpoint password.
  @Deprecated('Use connectWithCredentials for an endpoint, or connectWithAccessToken '
      'for a JWT.')
  Future<void> connect(Object credentials) async {
    if (credentials is CredentialConfig) {
      _beginSipDirect();
      await _connectWithCredentials(credentials.username, credentials.password);
      return;
    }
    if (credentials is TokenConfig) {
      _beginSipDirect();
      await _connectWithCredentials(
          credentials.displayName ?? 'token-user', credentials.token);
      return;
    }
    throw ArgumentError(
        'Unsupported credentials type: ${credentials.runtimeType}');
  }

  /// SIP Direct: sign in as an existing endpoint with its SIP username and
  /// password (Vobiz Console → Voice → Endpoints).
  Future<void> connectWithCredentials(CredentialConfig config) {
    _beginSipDirect();
    return _connectWithCredentials(config.username, config.password);
  }

  /// Signs in with an access token (JWT) that your backend minted with
  /// `POST /api/v1/Account/{auth_id}/JWT/Token/`. The same as the web SDK's
  /// `loginWithAccessToken`.
  ///
  /// The client registers as `<sub>_<iss>` ([sipUsername]) with the token in
  /// an `X-Vobiz-Jwt` header instead of a password, and sends it on every
  /// outbound INVITE, where its `app` claim picks the application whose
  /// Answer URL handles the call. No endpoint has to exist in the Console,
  /// and neither the Auth Token nor a SIP password reaches the device. To
  /// ring this user, dial `<User>sip:<sub>_<iss>@registrar.vobiz.ai</User>`.
  ///
  /// The token is not renewed: once it expires the next REGISTER is refused
  /// (`ACCESS_TOKEN_EXPIRED`). Pass a fresh one to [updateAccessToken] before
  /// then, or sign in with `connectWithAccessTokenProvider`, which does it
  /// for you.
  ///
  /// Throws [VobizAccessTokenException] (`INVALID_ACCESS_TOKEN`) before
  /// connecting when [accessToken] is not a Vobiz token. Like
  /// [connectWithCredentials] it completes once the REGISTER is sent; watch
  /// [connectionEvents] for the answer. A refusal arrives as an [ErrorEvent]
  /// with code [VobizErrorCode.registrationFailed] whose `cause` is a
  /// [VobizAccessTokenException] carrying the registrar's reason.
  Future<void> connectWithAccessToken(String accessToken) async {
    final token = VobizAccessToken.parse(accessToken);
    _closeExistingConnection();
    _authMode = VobizAuthMode.accessToken;
    _authId = null;
    _authToken = null;
    _logger.info('Signing in with an access token as ${token.sipUsername}, '
        'valid until ${token.expiresAt.toIso8601String()}');
    await _connectWithAccessToken(token);
  }

  /// Presents a fresh access token for the same user, without dropping the
  /// connection or a call: the client registers again with it right away.
  ///
  /// Call it before the current token expires (the provider session does).
  /// It also recovers a client whose token was refused: it registers again,
  /// on the open socket when a call is keeping it up.
  ///
  /// Throws [StateError] unless signed in with an access token, and
  /// [ArgumentError] when [accessToken] is for another user (another `sub`
  /// or `iss`): sign in again with [connectWithAccessToken] to switch users.
  Future<void> updateAccessToken(String accessToken) async {
    final current = _accessToken;
    if (_authMode != VobizAuthMode.accessToken || current == null) {
      throw StateError('Not signed in with an access token: call connectWithAccessToken first');
    }
    final next = VobizAccessToken.parse(accessToken);
    if (next.accountId != current.accountId || next.subject != current.subject) {
      throw ArgumentError.value(next.sipUsername, 'accessToken',
          'is for another user than ${current.sipUsername}; sign in with connectWithAccessToken to switch');
    }
    _accessToken = next;
    _sip.updateAccessToken(next.token);
    _logger.info('New access token for $_username, valid until ${next.expiresAt.toIso8601String()}');
    // Registered: present it now on the same socket. A call is not touched.
    if (isConnected && _sip.refreshRegistration()) return;
    // Reconnecting after a drop: the next attempt carries the new token.
    if (_connectionState == ConnectionStateStatus.reconnecting && _supervisor.isRunning) return;
    // The last token was refused: register again with this one, on the
    // socket a call is keeping open if there is one.
    if (_sip.registerAgain()) {
      _registrationState = RegistrationState.registering;
      _connectionState = ConnectionStateStatus.connecting;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Registering with a new access token',
      ));
      if (_config.autoReconnect && !_supervisor.isRunning) await _supervisor.start();
      return;
    }
    await _connectAndRegister(reconnecting: false);
  }

  // ---------------------------------------------------------------------------
  // Incoming calls to a closed app: Vobiz push
  // ---------------------------------------------------------------------------

  /// Hands Vobiz's incoming-call push to the client: a call Vobiz's
  /// registrar holds (up to 30 s) while the push wakes the app.
  ///
  /// The client claims the call: a REGISTER carries the push's hold
  /// reference ([VobizIncomingPush.hold]), and the registrar then sends the
  /// held INVITE to this registration. Signed in and registered, that
  /// REGISTER goes at once. Otherwise sign in now ([connectWithCredentials],
  /// [connectWithAccessToken], and so on), and the sign-in's REGISTER carries
  /// it.
  ///
  /// The INVITE arrives as a normal incoming call whose `CallEvent.sipCallId`
  /// is the push's `call_id`; [isPushedCall] tells it apart. Report the call
  /// screen's buttons with [reportCallScreenAccepted] and
  /// [reportCallScreenDeclined]: a call accepted, or declined, before its
  /// INVITE arrives is answered, or declined, as soon as it does.
  /// [pushCallUpdates] reports each step, and `expired` when no INVITE came
  /// by the push's expiry: take the call screen down then.
  ///
  /// Returns false and does nothing for a push that has expired. A repeat of
  /// the push being handled returns true and does nothing more.
  bool handleIncomingPush(VobizIncomingPush push) {
    final hold = push.hold;
    if (push.isExpired()) return false;
    final current = _pushed;
    if (current != null && current.push.callId == push.callId) return true;
    _forgetPushedCall();
    final pushed = _PushedCall(push);
    _pushed = pushed;
    final expiresAt = push.expiresAt;
    if (expiresAt != null) {
      pushed.expiry = Timer(expiresAt.difference(DateTime.now()), () => _expirePushedCall(pushed));
    }
    _emitPushUpdate(pushed, VobizPushCallStatus.claiming);
    final sentNow = _sip.claimHeldCall(hold.registerHeaders);
    _logger.info(sentNow
        ? 'Claiming the call ${push.callId} that Vobiz holds: REGISTER sent with its hold reference'
        : 'Claiming the call ${push.callId} that Vobiz holds: the next REGISTER carries its hold reference');
    // Signed in but between connections: reconnect now rather than at the
    // next backoff step, so the claim is made while the call is still held.
    if (!sentNow && _connectionState == ConnectionStateStatus.reconnecting) {
      _supervisor.reconnectNow();
    }
    return true;
  }

  /// The user tapped Accept on the call screen for [push]. Answers its call
  /// now if it is ringing, or as soon as its INVITE arrives. A push not
  /// handed to [handleIncomingPush] yet (Accept after a cold start) is
  /// handled first.
  void reportCallScreenAccepted(VobizIncomingPush push) {
    final pushed = _pushedFor(push);
    if (pushed == null) return;
    pushed.accepted = true;
    pushed.declined = false;
    final id = pushed.callId;
    if (id != null && _callId == id && _callState == CallStateStatus.incoming) {
      _emitPushUpdate(pushed, VobizPushCallStatus.answering);
      unawaited(acceptCall(id));
    }
  }

  /// The user tapped Decline on the call screen for [push]. Declines its call
  /// now if it is ringing, or as soon as its INVITE arrives: the claim still
  /// goes, so the caller hears busy at once instead of ringing out the
  /// registrar's hold. Vobiz has no way yet to decline a held call without
  /// claiming it.
  void reportCallScreenDeclined(VobizIncomingPush push) {
    final pushed = _pushedFor(push);
    if (pushed == null) return;
    pushed.declined = true;
    pushed.accepted = false;
    final id = pushed.callId;
    if (id != null && _callId == id && _callState == CallStateStatus.incoming) {
      _emitPushUpdate(pushed, VobizPushCallStatus.declining);
      unawaited(rejectCall(id));
    }
  }

  /// The pushed call [push] is about, handling the push first when the app
  /// went straight to its call screen.
  _PushedCall? _pushedFor(VobizIncomingPush push) {
    final current = _pushed;
    if (current != null && current.push.callId == push.callId) return current;
    if (!handleIncomingPush(push)) return null;
    return _pushed;
  }

  /// An INVITE arrived: is it the call the push announced? Only an exact
  /// Call-ID match counts, so another call from the same caller is never
  /// answered for them.
  void _matchPushedCall(String callId, String callerId) {
    final pushed = _pushed;
    if (pushed == null || pushed.callId != null) return;
    final sipCallId = _sip.activeSipCallId;
    if (!pushed.push.matchesIncomingCall(sipCallId: sipCallId)) {
      final number = pushed.push.callerNumber.isNotEmpty ? pushed.push.callerNumber : pushed.push.caller;
      if (_samePhoneNumber(callerId, number)) {
        _logger.warn('A call from $callerId arrived while the pushed call ${pushed.push.callId} was '
            'awaited, with another Call-ID ($sipCallId): not taken for the pushed call');
      }
      return;
    }
    pushed.callId = callId;
    pushed.expiry?.cancel();
    _logger.info('The pushed call ${pushed.push.callId} arrived');
    _emitPushUpdate(pushed, VobizPushCallStatus.ringing);
    if (pushed.declined) {
      _emitPushUpdate(pushed, VobizPushCallStatus.declining);
      unawaited(rejectCall(callId));
    } else if (pushed.accepted) {
      _emitPushUpdate(pushed, VobizPushCallStatus.answering);
      unawaited(acceptCall(callId));
    }
  }

  /// Two numbers are the same when their last ten digits match (at least six
  /// digits each), so `+91 98765 43210` matches `09876543210`.
  static bool _samePhoneNumber(String a, String b) {
    final x = a.replaceAll(RegExp(r'\D'), '');
    final y = b.replaceAll(RegExp(r'\D'), '');
    if (x.length < 6 || y.length < 6) return false;
    String tail(String s) => s.length > 10 ? s.substring(s.length - 10) : s;
    return tail(x) == tail(y);
  }

  /// A pushed call that no REGISTER has claimed yet rides on the next one.
  void _claimPushedCallOnRegister() {
    final pushed = _pushed;
    if (pushed == null || pushed.claimed || pushed.callId != null) return;
    if (pushed.push.isExpired()) return;
    _sip.claimHeldCall(pushed.push.hold.registerHeaders);
  }

  void _expirePushedCall(_PushedCall pushed) {
    if (!identical(_pushed, pushed) || pushed.callId != null) return;
    _logger.warn('The pushed call ${pushed.push.callId} did not arrive before the push expired');
    _pushed = null;
    _sip.cancelHeldCallClaim();
    _emitPushUpdate(pushed, VobizPushCallStatus.expired);
  }

  void _forgetPushedCall() {
    final pushed = _pushed;
    if (pushed == null) return;
    pushed.expiry?.cancel();
    _pushed = null;
    if (pushed.callId == null) _sip.cancelHeldCallClaim();
  }

  void _emitPushUpdate(_PushedCall pushed, VobizPushCallStatus status) => _pushCallUpdates
      .addIfOpen(VobizPushCallUpdate(push: pushed.push, status: status, callId: pushed.callId));

  /// Reconnects and re-registers now, resetting the retry backoff.
  ///
  /// Call it when a push arrives, or from a "retry" button after a
  /// `reconnect_failed` error. Returning to the foreground needs no call:
  /// see [SdkConfig.reregisterOnForeground]. Does nothing when
  /// signed out; while offline it waits for the network.
  void reconnect() => _supervisor.reconnectNow();

  /// Signs out. A call in progress is ended first, while the socket is still
  /// open: a ringing call is declined (480) and any other gets a BYE, so the
  /// far end is not left talking to a closed socket.
  ///
  /// [unregister] false closes the connection without a REGISTER
  /// `Expires: 0`, as when Android kills the app: Vobiz keeps this phone's
  /// registration until its keep-alive finds the socket gone (a few
  /// seconds), and a call in that time takes Vobiz's push-to-wake path: the
  /// registrar holds it and pushes the devices registered for this SIP user
  /// ([VobizPushDevices]). For testing that path; a sign-out leaves it true.
  Future<void> disconnect({bool unregister = true}) async {
    _signInEpoch++;
    _supervisor.stop();
    _reconnectWhenCallEnds = false;
    _stopWatchingLifecycle();
    _clearCallSetupTimer();
    _forgetPushedCall();
    final callId = _callId;
    if (callId != null) {
      await _terminate(callId,
          message: 'Signed out', reason: 'disconnected', declineCode: 480);
    }
    // Unregisters (REGISTER Expires: 0, at most ~2 s) before the socket
    // closes, unless asked not to.
    await _sip.disconnect(unregister: unregister);
    await _peer.disposeAllCalls();
    _callId = null;
    _callState = CallStateStatus.idle;
    _direction = null;
    _callUuid = null;
    _callHeaders = const <String, String>{};
    _registrationState = RegistrationState.unregistered;
    _connectionState = ConnectionStateStatus.disconnected;
    _authMode = VobizAuthMode.none;
    _authId = null;
    _authToken = null;
    _username = null;
    _password = null;
    _accessToken = null;
    _connectionEvents.addIfOpen(ConnectionEvent(
      connectionState: _connectionState,
      registrationState: _registrationState,
      message: 'Disconnected',
    ));
  }

  Future<void> dispose() async {
    await disconnect();
    await _pushCallUpdates.close();
    await _connectionEvents.close();
    await _callEvents.close();
    await _mediaEvents.close();
    await _errorEvents.close();
    await _networkEvents.close();
    await _peer.dispose();
    if (_ownsHttp) _http.close();
  }

  // ---------------------------------------------------------------------------
  // Outbound call
  // ---------------------------------------------------------------------------

  /// Calls [destination], a phone number in E.164 format such as
  /// `+919876543210`.
  ///
  /// - [callerId]: the number to present, sent as `X-VH-Caller-ID`. Carriers
  ///   need a number the account owns (purchased or trial) to reach a phone.
  /// - [headers]: custom `X-VH-` headers. Vobiz passes each one to the answer
  ///   webhook as a parameter.
  /// - [record]: record the whole call (`X-VH-Record: true`). The recording
  ///   appears in [fetchRecordings] once the call ends.
  /// - [dialUser]: ring this SIP endpoint (its username) instead of
  ///   [destination] (`X-VH-DialUser`). A destination number is still needed:
  ///   it is what gets the call to the webhook.
  ///
  /// Throws [ArgumentError] naming every invalid header before anything is
  /// dialled, where the web SDK would silently drop it.
  Future<String> makeCall(
    String destination, {
    String? callerId,
    Map<String, String> headers = const <String, String>{},
    bool record = false,
    String? dialUser,
  }) async {
    if (_supervisor.isOffline) {
      throw StateError('No network connection');
    }
    if (!isConnected) throw StateError('Not registered — call connect() first');
    if (_callState != CallStateStatus.idle) {
      throw StateError('Already in a call');
    }
    // As the web SDK does: a token that does not grant outgoing calls is
    // refused here, before the registrar refuses the INVITE.
    final token = _accessToken;
    if (token != null && !token.canCallOut) {
      throw const VobizAccessTokenException(
          'This access token does not allow outgoing calls '
          '(per.voice.outgoing_allow is not true)',
          tokenError: VobizAccessTokenException.invalidGrants);
    }
    final target = destination.trim();
    if (target.isEmpty) throw ArgumentError('A destination is required');
    final outgoing = buildCallHeaders(
      headers: headers,
      callerId: callerId,
      record: record,
      dialUser: dialUser,
    );

    final callId = DateTime.now().microsecondsSinceEpoch.toString();
    _callId = callId;
    _activeCallDestination = target;
    _direction = CallDirection.outbound;
    _callUuid = null;
    _callHeaders = Map<String, String>.unmodifiable(outgoing);
    _callState = CallStateStatus.connecting;
    _emitCallEvent(callId, CallStateStatus.connecting, 'Preparing outbound call');
    // Busy for inbound INVITEs while the microphone and ICE are prepared: one
    // arriving now would ring unseen and tangle with this call's dialog.
    _sip.reserveForOutgoingCall();

    try {
      await _peer.initialize(callId);
      final offer = await _peer.createOffer();
      await _waitForIceGathering(callId);
      // Hung up while the call was being prepared: send nothing.
      if (_callId != callId) {
        _logger.info('Call $callId ended before it was placed');
        await _peer.disposeCall(callId);
        return callId;
      }
      final local = await _peer.peerConnection?.getLocalDescription();
      final sdp = local?.sdp ?? offer.sdp ?? '';
      _sip.call(target, sdp, extraHeaders: outgoing);
      _callState = CallStateStatus.ringing;
      _emitCallEvent(callId, CallStateStatus.ringing, 'Invite sent');
      _startCallSetupTimer(callId);
      return callId;
    } catch (e, st) {
      // Hung up while the microphone or ICE was being set up: not a failure.
      if (_callId != callId) {
        await _peer.disposeCall(callId);
        return callId;
      }
      _logger.error('makeCall failed: $e\n$st');
      // Ends the reservation, and the INVITE if it already went out.
      if (_callId == callId) _sip.hangup();
      await _cleanupCall(callId);
      _emitError('make_call_failed', 'Could not start the call', e);
      rethrow;
    }
  }

  /// The headers [makeCall] sends for these options, checked the way the
  /// platform checks them. Throws [ArgumentError] listing every problem, so
  /// an app can validate a form before dialling.
  static Map<String, String> buildCallHeaders({
    Map<String, String> headers = const <String, String>{},
    String? callerId,
    bool record = false,
    String? dialUser,
  }) {
    final all = <String, String>{...headers};
    final cli = callerId?.trim() ?? '';
    if (cli.isNotEmpty) {
      if (!_callerIdPattern.hasMatch(cli)) {
        throw ArgumentError(
            'Caller ID must be a phone number in E.164 format, such as +919876543210');
      }
      all[VobizSipHeaders.callerId] = cli;
    }
    if (record) all[VobizSipHeaders.record] = 'true';
    final user = endpointUsername(dialUser);
    if (user.isNotEmpty) all[VobizSipHeaders.dialUser] = user;

    final check = VobizSipHeaders.check(all);
    if (!check.isValid) throw ArgumentError(check.errors.join('; '));
    return check.valid;
  }

  /// `sip:play123@registrar.vobiz.ai`, `play123@registrar.vobiz.ai` and
  /// `play123` all become `play123`: a header value cannot carry `:` or `@`.
  static String endpointUsername(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return '';
    return raw.replaceFirst(RegExp('^sip:', caseSensitive: false), '').split('@').first;
  }

  static final RegExp _callerIdPattern = RegExp(r'^\+?\d{7,15}$');

  // ---------------------------------------------------------------------------
  // Inbound call
  // ---------------------------------------------------------------------------

  Future<void> acceptCall([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null || _callState != CallStateStatus.incoming) return;
    await _answerInvite(id);
  }

  /// Declines a ringing call. Once the call has been answered there is
  /// nothing to decline, so this hangs it up (with a BYE) instead.
  Future<void> rejectCall([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    if (_callState != CallStateStatus.incoming) return hangup(id);
    await _terminate(id, message: 'Rejected', reason: 'Rejected');
  }

  Future<void> hangup([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    await _terminate(id, message: 'Hung up', reason: 'Hung up');
  }

  // ---------------------------------------------------------------------------
  // Audio control
  // ---------------------------------------------------------------------------

  /// Mutes the microphone on the current call. Asked while the call is still
  /// connecting, it applies as soon as the microphone opens; it survives
  /// hold and resume. A new call starts unmuted. Each change is a
  /// [MuteChangedEvent].
  Future<void> mute([String? callId]) => _peer.setMuted(true);

  Future<void> unmute([String? callId]) => _peer.setMuted(false);

  /// Whether the current call's microphone is muted. False between calls.
  bool get isMuted => _peer.isMuted;

  /// Routes call audio to the loudspeaker (true) or back to the earpiece or
  /// a connected headset (false). Each call starts off the loudspeaker.
  Future<void> setSpeakerphone(bool enabled) => _peer.enableSpeaker(enabled);

  /// Whether call audio is on the loudspeaker.
  bool get isSpeakerOn => _peer.audioRoutes.isSpeakerOn;

  /// Sends DTMF on the connected call: keypad presses for an IVR.
  ///
  /// Accepts `0-9`, `*`, `#` and `A-D`. With [DtmfTransport.auto] (the
  /// default) the tones go as RFC 4733 telephone-events in the audio when
  /// the media server negotiated `telephone-event`, otherwise each one as a
  /// SIP INFO (`application/dtmf-relay`, the way the Vobiz web SDK sends
  /// them) with JsSIP's default gap between digits.
  Future<void> sendDtmf(
    String digits, {
    DtmfTransport transport = DtmfTransport.auto,
  }) async {
    final tones = digits.trim().toUpperCase();
    if (tones.isEmpty) return;
    if (!RegExp(r'^[0-9*#A-D]+$').hasMatch(tones)) {
      throw ArgumentError('DTMF digits must be 0-9, *, # or A-D');
    }
    if (_callState != CallStateStatus.active || !_sip.hasActiveDialog) {
      throw StateError('DTMF needs a connected call');
    }
    if (transport != DtmfTransport.sipInfo) {
      if (await _peer.insertDtmf(tones)) return;
      if (transport == DtmfTransport.rfc4733) {
        throw StateError('This call did not negotiate RFC 4733 telephone-event');
      }
    }
    for (var i = 0; i < tones.length; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!_sip.sendDtmf(tones[i])) break;
    }
  }

  /// Round-trip time, jitter and packet loss for the connected call, or null
  /// when there is no call. Poll it (the Playground does every second) to
  /// draw a latency trace.
  Future<CallStats?> getCallStats() => _peer.getStats();

  // ---------------------------------------------------------------------------
  // Transfer and recordings (webhook server)
  // ---------------------------------------------------------------------------

  /// Transfers the connected call the way the web Playground does: the
  /// webhook server moves a leg with the Vobiz Redirect API onto a phone
  /// [number] (blind) or a SIP endpoint [sipUser], carrying [sipHeaders] on
  /// the new `<Dial>`.
  ///
  /// [leg] picks what moves: [TransferLeg.aLeg] moves you onto the target and
  /// drops the other party; [TransferLeg.bLeg] moves the other party and
  /// drops you.
  ///
  /// Needs Zero-Config Setup, because the redirect is made with the
  /// account's Auth ID and Auth Token. Returns the server's confirmation.
  Future<String> transferCall({
    String? number,
    String? sipUser,
    TransferLeg leg = TransferLeg.aLeg,
    String? callerId,
    Map<String, String> sipHeaders = const <String, String>{},
  }) async {
    if (_callState != CallStateStatus.active) {
      throw StateError('Transfer is only available once the call is answered');
    }
    final authId = _authId;
    final authToken = _authToken;
    if (_authMode != VobizAuthMode.zeroConfig || authId == null || authToken == null) {
      throw StateError(
          'Transfer needs Zero-Config Setup (Auth ID and Auth Token), not SIP Direct');
    }
    final uuid = _callUuid ?? _sip.callUuid;
    if (uuid == null) {
      throw StateError('Vobiz has not reported a CallUUID for this call yet');
    }
    final user = endpointUsername(sipUser);
    final phone = number?.trim() ?? '';
    if (user.isEmpty == phone.isEmpty) {
      throw ArgumentError('Give either a phone number or a SIP user to transfer to');
    }
    if (user.isNotEmpty && !RegExp(r'^[a-zA-Z0-9_.\-+]{1,120}$').hasMatch(user)) {
      throw ArgumentError('Transfer target must be a SIP endpoint username, such as play123');
    }
    if (phone.isNotEmpty && !RegExp(r'^\+\d{7,15}$').hasMatch(phone)) {
      throw ArgumentError('Transfer number must be in E.164 format, such as +919876543210');
    }
    final check = VobizSipHeaders.check(sipHeaders);
    if (!check.isValid) throw ArgumentError(check.errors.join('; '));
    final xml = VobizSipHeaders.toXml(check.valid);
    if (xml.skipped.isNotEmpty) {
      _logger.warn('Not carried on the transfer (XML allows only A-Za-z0-9 in '
          'names): ${xml.skipped.join(', ')}');
    }

    try {
      final reply = await _api.transfer(
        webhookUrl: backendUrl,
        voiceApiUrl: _config.voiceApiUrl,
        authId: authId,
        authToken: authToken,
        callUuid: uuid,
        leg: leg,
        number: phone.isEmpty ? null : phone,
        sipUser: user.isEmpty ? null : user,
        callerId: callerId?.trim(),
        sipHeaders: xml.value,
      );
      return '${reply['message'] ?? 'Transfer accepted'}';
    } on VobizException catch (e) {
      _emitError('transfer_failed', e.message, e);
      rethrow;
    }
  }

  /// Recordings the webhook server has received, most recent first.
  ///
  /// On the hosted Playground server this list is shared by everyone who
  /// uses it, so match by CallUUID (see [waitForRecording]) rather than
  /// taking the newest entry.
  Future<List<VobizRecording>> fetchRecordings() async {
    try {
      return await _api.recordings(webhookUrl: backendUrl);
    } on VobizException catch (e) {
      _emitError('recordings_failed', e.message, e);
      rethrow;
    }
  }

  /// Waits for the recording of the call with [callUuid] (usually
  /// [lastCallUuid]) to be reported, polling like the web Playground: every
  /// [interval], up to [attempts] times. Returns null if it never arrives.
  Future<VobizRecording?> waitForRecording(
    String callUuid, {
    Duration interval = const Duration(milliseconds: 2500),
    int attempts = 12,
  }) async {
    for (var i = 0; i < attempts; i++) {
      await Future<void>.delayed(interval);
      try {
        final recordings = await _api.recordings(webhookUrl: backendUrl);
        for (final recording in recordings) {
          if (recording.callUuid == callUuid && recording.url.isNotEmpty) {
            return recording;
          }
        }
      } on VobizException catch (e) {
        _logger.warn('Recording poll failed: ${e.message}');
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Hold
  // ---------------------------------------------------------------------------

  /// Puts the connected call on hold with a re-INVITE offering
  /// `a=sendonly`, so the media server plays hold music to the other party
  /// instead of dead air. The microphone is silenced while held; the user's
  /// mute choice is kept for [resume].
  ///
  /// Throws [StateError] without a connected call, and [VobizException]
  /// (`hold_failed`) when the far end refuses; the call then carries on as
  /// it was.
  Future<void> hold([String? callId]) async {
    final id = _requireCurrentCall(callId);
    if (_callState != CallStateStatus.active) {
      throw StateError('Hold needs a connected call');
    }
    await _renegotiateHold(id, true);
    if (_callId != id) return;
    _callState = CallStateStatus.held;
    _emitCallEvent(id, CallStateStatus.held, 'On hold');
  }

  /// Takes the call off hold (re-INVITE with `a=sendrecv`). The microphone
  /// comes back muted if the user had muted it.
  Future<void> resume([String? callId]) async {
    final id = _requireCurrentCall(callId);
    if (_callState != CallStateStatus.held) {
      throw StateError('The call is not on hold');
    }
    await _renegotiateHold(id, false);
    _interruptions.reset();
    if (_callId != id) return;
    _callState = CallStateStatus.active;
    _emitCallEvent(id, CallStateStatus.active, 'Resumed');
  }

  /// Tell the SDK another app's call (a SIM, WhatsApp or other VoIP call)
  /// took the microphone: Android audio-focus loss, an iOS
  /// `AVAudioSession` interruption, or a Telecom/CallKit hold. The SDK
  /// cannot detect these itself. It holds the connected call so the other
  /// party hears hold music instead of dead air.
  ///
  /// ```dart
  /// final session = await AudioSession.instance; // package:audio_session
  /// session.interruptionEventStream.listen((e) => e.begin
  ///     ? client.audioInterruptionBegan()
  ///     : client.audioInterruptionEnded());
  /// ```
  Future<void> audioInterruptionBegan() => _interruptions.began();

  /// The interruption is over. Resumes the call if
  /// [audioInterruptionBegan] held it and [shouldResume] is true; a call
  /// the user held stays held.
  Future<void> audioInterruptionEnded({bool shouldResume = true}) =>
      _interruptions.ended(shouldResume: shouldResume);

  String _requireCurrentCall(String? callId) {
    final id = _callId;
    if (id == null || (callId != null && callId != id)) {
      throw StateError('No such call');
    }
    return id;
  }

  Future<void> _renegotiateHold(String id, bool hold) async {
    if (_reInviteInProgress) {
      throw StateError('A hold, resume or ICE restart is already in progress');
    }
    _reInviteInProgress = true;
    try {
      final offer = await _peer.beginHold(hold);
      try {
        final answer = await _sip.reInvite(offer);
        if (_callId != id) return;
        await _peer.completeHold(answer);
      } catch (e) {
        if (_callId != id) return; // the call ended meanwhile
        await _peer.abortHold();
        final code = hold ? 'hold_failed' : 'resume_failed';
        final message = 'Could not ${hold ? 'hold' : 'resume'} the call: $e';
        _emitError(code, message, e);
        throw VobizException(code, message,
            statusCode: e is SipRequestFailed ? e.statusCode : null);
      }
    } finally {
      _reInviteInProgress = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Private — SIP wiring
  // ---------------------------------------------------------------------------

  void _wireSip() {
    _sip.onRegistered = () {
      _registrationState = RegistrationState.registered;
      _connectionState = ConnectionStateStatus.connected;
      _reconnectWhenCallEnds = false;
      _supervisor.connected();
      final onForeground = _reregisteringOnForeground;
      _reregisteringOnForeground = false;
      if (onForeground) _logger.info('reregistered on foreground');
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: onForeground ? 'Reregistered on foreground' : 'Registered',
      ));
      if (_signalingLost) {
        _signalingLost = false;
        _checkNetworkRecovered();
        // The socket died with the network, and the call's media went with
        // it, even when ICE has not noticed yet: Android deletes the ports
        // WebRTC gathered on a lost network. Move the audio to this one.
        unawaited(_restartIce('registered again after the connection dropped'));
      } else if (_mediaLost) {
        unawaited(_restartIce('registered while the call has no audio'));
      }
    };

    _sip.onRegistrationFailed = (reason) {
      _reregisteringOnForeground = false;
      if (_sip.registrationFailureTemporary && _config.autoReconnect && _supervisor.isRunning) {
        _onTemporaryRegistrationFailure(reason);
        return;
      }
      // Wrong credentials are not a network problem: retrying cannot help.
      _supervisor.stop();
      _registrationState = RegistrationState.failed;
      _connectionState = ConnectionStateStatus.failed;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Registration failed: $reason',
      ));
      // A refused access token carries the registrar's reason (10001-10010).
      _emitError(
          'registration_failed',
          reason,
          _accessToken == null
              ? null
              : VobizAccessTokenException(reason, tokenError: _sip.accessTokenError));
    };

    _sip.onSocketError = _onSocketLost;
    // A REGISTER refresh went unanswered: the socket died silently (common
    // after the phone was locked). Reconnect now, not after a backoff delay.
    _sip.onTransportDead = (reason) => _onSocketLost(reason, immediately: true);

    _sip.onTrying = () {
      // The far end has the INVITE: from here ringing is bounded by the
      // server's Dial timeout or the user, not by the setup timer.
      if (_direction == CallDirection.outbound) _clearCallSetupTimer();
    };
    _wireSipCalls();
  }

  /// The registrar could not take the REGISTER now (no answer, 408, 480,
  /// 5xx): not a refusal of the credentials, so keep trying with the
  /// reconnect backoff. The SIP layer has closed the socket, or closes it
  /// when the call on it ends; the reconnect waits for that.
  void _onTemporaryRegistrationFailure(String reason) {
    _logger.warn('Registration failed for now, trying again: $reason');
    // Already reported as given up: a network change or reconnect() starts
    // again.
    if (_supervisor.hasGivenUp) return;
    _registrationState = RegistrationState.unregistered;
    _connectionState = ConnectionStateStatus.reconnecting;
    _connectionEvents.addIfOpen(ConnectionEvent(
      connectionState: _connectionState,
      registrationState: _registrationState,
      message: 'Registration failed: $reason. Trying again',
    ));
    if (_callId != null) {
      _reconnectWhenCallEnds = true;
      return;
    }
    _scheduleReconnect('Registration failed: $reason');
  }

  /// The signalling socket is gone. A connected call rides it out (its
  /// dialog is kept across the reconnect); anything else ends.
  void _onSocketLost(String reason, {bool immediately = false}) {
    _registrationState = RegistrationState.unregistered;
    _connectionState = _config.autoReconnect
        ? ConnectionStateStatus.reconnecting
        : ConnectionStateStatus.disconnected;
    _connectionEvents.addIfOpen(ConnectionEvent(
      connectionState: _connectionState,
      registrationState: _registrationState,
      message: 'Socket error: $reason',
    ));
    _emitError('socket_error', reason, null);
    _onSignalingLost();
    if (!_config.autoReconnect) return;
    if (immediately) {
      if (_hasSignIn) {
        _supervisor.reconnectNow(reason: reason);
      }
    } else {
      _scheduleReconnect(reason);
    }
  }

  void _wireSipCalls() {
    _sip.onRemoteRinging = () {
      final id = _callId;
      if (id == null) return;
      _clearCallSetupTimer();
      _callUuid = _sip.callUuid ?? _callUuid;
      _callState = CallStateStatus.ringing;
      _emitCallEvent(id, CallStateStatus.ringing, 'Remote ringing');
    };

    _sip.onCallProgress = (sdp) {
      final id = _callId;
      if (id == null) return;
      _clearCallSetupTimer();
      _callUuid = _sip.callUuid ?? _callUuid;
      _callState = CallStateStatus.ringing;
      _emitCallEvent(id, CallStateStatus.ringing, 'Call progress');
      // 183 with SDP: play the ringback or carrier announcement it carries.
      if (sdp != null && sdp.trim().isNotEmpty) {
        unawaited(_peer.applyProvisionalAnswer(sdp));
      }
    };

    // The far end changed the session mid-call (its own hold, new media):
    // answer from the PeerConnection so its audio follows.
    _sip.onSessionOffer = (offer) async {
      if (_callId == null) return null;
      return _peer.answerSessionOffer(offer);
    };

    _sip.onCallAnswered = (sdp) async {
      final id = _callId;
      if (id == null) return;
      // A retransmitted 200 OK (the SIP layer ACKs it again) was already
      // applied; applying it twice would fail and report a false error.
      if (_answeredCallId == id) return;
      _answeredCallId = id;
      _clearCallSetupTimer();
      _callUuid = _sip.callUuid ?? _callUuid;
      try {
        // A 200 without SDP confirms the 183's early-media SDP.
        await _peer.applyRemoteAnswer(sdp);
        if (_callId != id) return;
        _callState = CallStateStatus.active;
        _emitCallEvent(id, CallStateStatus.active, 'Call connected');
        if (_mediaLost) _startNetworkLossTimer(id);
      } catch (e) {
        // The call is answered (and billed) but has no audio. The SIP layer
        // has already ACKed the 200, so end it with a BYE rather than leave
        // dead air until the platform's no-media timeout.
        if (_callId != id) return;
        _logger.error('Failed to apply remote answer: $e');
        await _terminate(id,
            message: 'Could not connect audio', reason: 'answer_failed');
        _emitError('answer_failed', 'Could not connect audio', e);
      }
    };

    _sip.onHeldCallClaimed = () {
      final pushed = _pushed;
      if (pushed == null || pushed.claimed || pushed.callId != null) return;
      pushed.claimed = true;
      _emitPushUpdate(pushed, VobizPushCallStatus.claimed);
    };

    _sip.onIncomingCall = (callerId, sdp, headers) {
      if (_callState != CallStateStatus.idle) return;
      final callId = 'in_${DateTime.now().millisecondsSinceEpoch}';
      _callId = callId;
      _pendingInboundCaller = callerId;
      _pendingInboundSdp = sdp;
      _direction = CallDirection.inbound;
      _callUuid = _sip.callUuid;
      _callHeaders = Map<String, String>.unmodifiable(headers);
      _callState = CallStateStatus.incoming;
      _emitCallEvent(callId, CallStateStatus.incoming, callerId);
      _matchPushedCall(callId, callerId);
    };

    _sip.onCallEnded = (reason) {
      final id = _callId;
      if (id != null) _cleanupCall(id, reason: reason);
    };

    _sip.onCallFailed = (reason, sipCode) {
      final id = _callId;
      _callUuid = _sip.callUuid ?? _callUuid;
      if (id != null) {
        _emitCallEvent(id, CallStateStatus.failed, reason,
            sipCode: sipCode, reason: reason);
        _cleanupCall(id, reason: reason);
      }
      // A 401/407 here means the digest was refused (the SIP layer answers
      // one challenge, two for a stale nonce): wrong credentials, not a
      // failed call.
      final authFailed = sipCode == 401 || sipCode == 407;
      _emitError(
          authFailed ? VobizErrorCode.authFailed : VobizErrorCode.callFailed,
          reason,
          null);
    };

    _peer.onIceConnectionState = (callId, state) {
      if (callId != _callId) return;
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _mediaLost = true;
          if (_callState == CallStateStatus.active ||
              _callState == CallStateStatus.held) {
            _startNetworkLossTimer(callId);
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _mediaLost = false;
          _checkNetworkRecovered();
          break;
        default:
          break;
      }
    };

    _peer.mediaEvents.listen((MediaEvent event) {
      _mediaEvents.addIfOpen(event);
    });
  }

  void _beginSipDirect() {
    _closeExistingConnection();
    _authMode = VobizAuthMode.sipDirect;
    _authId = null;
    _authToken = null;
  }

  /// A new sign-in replaces the old connection rather than opening a second
  /// socket next to it. Until it signs in, nothing describes the old one.
  void _closeExistingConnection() {
    _signInEpoch++;
    _supervisor.stop();
    _reconnectWhenCallEnds = false;
    _registrationState = RegistrationState.unregistered;
    _authMode = VobizAuthMode.none;
    _authId = null;
    _authToken = null;
    _username = null;
    _password = null;
    _accessToken = null;
    final callId = _callId;
    if (callId != null) {
      unawaited(_terminate(callId,
          message: 'Signed out', reason: 'disconnected', declineCode: 480));
    }
    if (_sip.connectionState.value != SipConnectionState.disconnected) {
      unawaited(_sip.disconnect());
    }
  }

  Future<void> _connectWithCredentials(String username, String password,
      {bool reconnecting = false}) {
    _username = username;
    _password = password;
    _accessToken = null;
    return _connectAndRegister(reconnecting: reconnecting);
  }

  Future<void> _connectWithAccessToken(VobizAccessToken token) {
    _username = token.sipUsername;
    _password = null;
    _accessToken = token;
    return _connectAndRegister(reconnecting: false);
  }

  /// Opens the socket and sends the first REGISTER with whatever this client
  /// signs in with: a password, or an access token.
  ///
  /// A sign-in or sign-out that comes while it connects replaces it: it then
  /// stops without reporting anything. A reconnect attempt that fails is
  /// rethrown to the supervisor, which counts it and reports when it gives
  /// up, so the state stays `reconnecting` meanwhile.
  Future<void> _connectAndRegister({required bool reconnecting}) async {
    final username = _username;
    if (username == null) return;
    final epoch = _signInEpoch;
    _registrationState = RegistrationState.registering;
    _connectionState = reconnecting
        ? ConnectionStateStatus.reconnecting
        : ConnectionStateStatus.connecting;
    _connectionEvents.addIfOpen(ConnectionEvent(
      connectionState: _connectionState,
      registrationState: _registrationState,
      message: reconnecting ? 'Reconnecting' : 'Connecting',
    ));

    _watchLifecycle();
    try {
      if (_config.autoReconnect && !_supervisor.isRunning) {
        await _supervisor.start();
        if (epoch != _signInEpoch) return;
      }
      await _sip.connect();
      if (epoch != _signInEpoch) return;
      // A pushed call not claimed yet rides on this sign-in's REGISTER.
      _claimPushedCallOnRegister();
      final token = _accessToken;
      if (token != null) {
        _sip.registerWithAccessToken(username, token.token);
      } else {
        _sip.register(username, _password ?? '');
      }
    } on SipConnectSuperseded {
      // A sign-out, or a newer connection, replaced this one.
      return;
    } catch (e) {
      if (epoch != _signInEpoch) return;
      if (reconnecting) {
        _registrationState = RegistrationState.unregistered;
        _logger.warn('Reconnect attempt failed: $e');
        rethrow;
      }
      _registrationState = RegistrationState.failed;
      _connectionState = ConnectionStateStatus.failed;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Connection failed: $e',
      ));
      _emitError('connect_failed', 'Could not connect', e);
      // SIPService does not call onSocketError when connect fails, so a
      // first sign-in schedules its reconnect here.
      if (_config.autoReconnect) _scheduleReconnect('Could not connect: $e');
      rethrow;
    }
  }

  /// The Playground server answers a bad Auth ID / Auth Token with a generic
  /// "Could not resolve Application ID", which says nothing useful.
  VobizException _explainSetupFailure(VobizException e) {
    final status = e.statusCode;
    final rejected = status == 401 ||
        status == 403 ||
        e.message.contains('Could not resolve Application ID');
    if (!rejected) return e;
    return VobizException(
      e.code,
      'Vobiz did not accept that Auth ID and Auth Token. Both are on the Vobiz '
      'Console dashboard; the Auth Token is not your login password.',
      statusCode: status,
    );
  }

  // ---------------------------------------------------------------------------
  // Private — reconnection
  // ---------------------------------------------------------------------------

  /// Hands a drop to the supervisor, which applies [SdkConfig.reconnectPolicy]
  /// backoff, gives up after its last attempt, and waits while offline.
  void _scheduleReconnect([String reason = 'Connection lost']) {
    if (!_hasSignIn) return;
    _supervisor.connectionLost(reason);
  }

  /// One reconnect attempt for the supervisor: a fresh socket and REGISTER,
  /// with the password or the current access token.
  Future<void> _reconnectOnce() async {
    if (!_hasSignIn) return;
    // Keep a connected call's dialog: once registered again it can still
    // be hung up, and the far end's BYE still matches it.
    // Not a sign-out: no unregistration, the REGISTER below replaces it.
    unawaited(_sip.disconnect(keepCall: _callId != null, unregister: false));
    await _connectAndRegister(reconnecting: true);
  }

  void _onNetworkEvent(NetworkEvent event) {
    _networkEvents.addIfOpen(event);
    if (_username == null) return;
    switch (event.type) {
      case NetworkEventType.offline:
      case NetworkEventType.reconnecting:
        // Not connected until REGISTER succeeds again: makeCall fails fast
        // instead of writing an INVITE to a dead socket.
        _connectionState = ConnectionStateStatus.reconnecting;
        if (event.type == NetworkEventType.offline) {
          _registrationState = RegistrationState.unregistered;
        }
        _connectionEvents.addIfOpen(ConnectionEvent(
          connectionState: _connectionState,
          registrationState: _registrationState,
          message: event.reason ?? 'Reconnecting',
        ));
        break;
      case NetworkEventType.reconnectFailed:
        _connectionState = ConnectionStateStatus.failed;
        _registrationState = RegistrationState.failed;
        _connectionEvents.addIfOpen(ConnectionEvent(
          connectionState: _connectionState,
          registrationState: _registrationState,
          message: event.reason ?? 'Reconnect failed',
        ));
        _emitError('reconnect_failed', event.reason ?? 'Reconnect failed', null);
        break;
      case NetworkEventType.online:
      case NetworkEventType.networkChanged:
      case NetworkEventType.reconnected:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Private — app lifecycle
  // ---------------------------------------------------------------------------

  void _watchLifecycle() {
    if (!_config.reregisterOnForeground || _lifecycleSub != null) return;
    _lifecycleSub = _lifecycle.foregroundChanges.listen(_onForegroundChanged);
  }

  void _stopWatchingLifecycle() {
    unawaited(_lifecycleSub?.cancel());
    _lifecycleSub = null;
    _inForeground = null;
    _lastForegroundRegister = null;
    _reregisteringOnForeground = false;
  }

  /// Back in the foreground: tell the registrar where this device is now.
  /// A live registration is refreshed on its own socket (a call on it is
  /// untouched); anything else is reconnected with the backoff reset.
  void _onForegroundChanged(bool foreground) {
    final wasForeground = _inForeground;
    _inForeground = foreground;
    if (!foreground || wasForeground == true) return;
    if (!_hasSignIn) return;
    final now = DateTime.now();
    final last = _lastForegroundRegister;
    if (last != null && now.difference(last) < _foregroundDebounce) return;
    _lastForegroundRegister = now;
    // The first REGISTER of a sign-in is still on its way.
    if (_connectionState == ConnectionStateStatus.connecting) return;
    if (isConnected && _sip.refreshRegistration()) {
      _logger.info('App in foreground: refreshing the registration');
      _reregisteringOnForeground = true;
      return;
    }
    _logger.info('App in foreground: reconnecting');
    _supervisor.reconnectNow(reason: 'App returned to the foreground');
  }

  /// The network changed during a call. The signalling socket is left alone
  /// (replacing it would drop the dialog). When the socket died with the
  /// old network, the reconnect's REGISTER triggers the ICE restart
  /// ([_restartIce]); a socket that survived keeps its media path too.
  void _onNetworkHandover(NetworkStatus from, NetworkStatus to) {
    _logger.warn('Network changed during a call: $from -> $to');
  }

  Future<void> _answerInvite(String callId) async {
    _callState = CallStateStatus.connecting;
    _emitCallEvent(callId, CallStateStatus.connecting, 'Answering');

    // The step that fails decides the final response the caller gets, so
    // the platform stops ringing them and the SIP layer is free for the
    // next call (an unanswered INVITE turns every later one away busy).
    var declineCode = 480;
    var declinePhrase = 'Temporarily Unavailable';
    var why = 'Could not open the microphone';
    try {
      await _peer.initialize(callId);
      declineCode = 488;
      declinePhrase = 'Not Acceptable Here';
      why = 'The call has no audio this device can use';
      final remoteSdp = _pendingInboundSdp;
      if (remoteSdp == null || remoteSdp.isEmpty) {
        // Answering an offerless INVITE would mean putting the offer in the
        // 200 OK, which this SDK does not do.
        throw StateError('The INVITE carried no SDP offer');
      }
      await _peer.setRemoteDescription(
          RTCSessionDescription(remoteSdp, 'offer'));
      declineCode = 500;
      declinePhrase = 'Server Internal Error';
      why = 'Could not set up the call audio';
      final answer = await _peer.createAnswer();
      await _waitForIceGathering(callId);
      final local = await _peer.peerConnection?.getLocalDescription();
      // Answering takes a moment (microphone, ICE). If the caller cancelled
      // or the user hung up meanwhile, the call is gone: marking it active
      // now would leave a call on screen that nothing can end. Checked after
      // the last await, so nothing can slip in before the 200 OK is sent.
      if (_callId != callId) {
        _logger.info('Call $callId ended while it was being answered');
        await _peer.disposeCall(callId);
        return;
      }
      final sdp = local?.sdp ?? answer.sdp ?? '';
      _sip.answer(sdp);
      if (!_sip.hasActiveDialog) {
        // No 200 OK went out: the INVITE is no longer there to answer.
        await _cleanupCall(callId,
            message: 'Caller cancelled', reason: 'Caller cancelled');
        return;
      }
      _callState = CallStateStatus.active;
      _emitCallEvent(callId, CallStateStatus.active, 'Call connected');
      if (_mediaLost) _startNetworkLossTimer(callId);
    } catch (e, st) {
      if (_callId != callId) {
        // Cancelled while answering; that path has already cleaned up.
        await _peer.disposeCall(callId);
        return;
      }
      _logger.error('Answer failed: $e\n$st');
      await _terminate(callId,
          message: why,
          reason: 'answer_failed',
          declineCode: declineCode,
          declinePhrase: declinePhrase);
      _emitError('answer_failed', why, e);
    }
  }

  // ---------------------------------------------------------------------------
  // Private — call setup timer
  // ---------------------------------------------------------------------------

  /// Guards only the case where the INVITE gets no response at all. The
  /// first provisional response (100, 180, 183) clears it.
  void _startCallSetupTimer(String callId) {
    _clearCallSetupTimer();
    _callSetupTimer = Timer(_setupTimeout, () async {
      _callSetupTimer = null;
      if (_callId != callId) return;
      if (_callState == CallStateStatus.connecting ||
          _callState == CallStateStatus.ringing) {
        _logger.warn('Call setup timeout for $callId');
        await _terminate(callId,
            message: 'Call setup timed out', reason: 'setup_timeout');
        _emitError('call_timeout', 'Call setup timed out', null);
      }
    });
  }

  void _clearCallSetupTimer() {
    _callSetupTimer?.cancel();
    _callSetupTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Private — network loss during a call
  // ---------------------------------------------------------------------------

  /// The socket dropped. A connected call's media may well still be flowing,
  /// so it gets [_networkLossGrace] to reconnect and re-register. A call
  /// still being set up cannot be completed over a new connection (its
  /// INVITE transaction belonged to the old one), so it ends now.
  void _onSignalingLost() {
    final id = _callId;
    if (id == null) return;
    if (_callState == CallStateStatus.active ||
        _callState == CallStateStatus.held) {
      _signalingLost = true;
      _startNetworkLossTimer(id);
      return;
    }
    unawaited(_terminate(id,
        message: 'Network connection lost', reason: 'network_lost'));
  }

  void _startNetworkLossTimer(String callId) {
    if (_networkLossTimer != null) return;
    _logger.warn('Call $callId lost its network connection; waiting '
        '${_networkLossGrace.inSeconds}s for it to come back');
    _emitCallEvent(callId, _callState, 'Reconnecting', reason: 'reconnecting');
    _networkLossTimer = Timer(_networkLossGrace, () async {
      _networkLossTimer = null;
      if (_callId != callId) return;
      _logger.warn('Call $callId did not recover; ending it');
      await _terminate(callId,
          message: 'Network connection lost', reason: 'network_lost');
      _emitError('network_lost', 'The call was lost with the network', null);
    });
  }

  /// Signalling is registered again and media is flowing: the call survived.
  void _checkNetworkRecovered() {
    final id = _callId;
    if (id == null || _networkLossTimer == null) return;
    if (_signalingLost || _mediaLost) return;
    _clearNetworkLossTimer();
    _emitCallEvent(id, _callState, 'Reconnected', reason: 'reconnected');
  }

  void _clearNetworkLossTimer() {
    _networkLossTimer?.cancel();
    _networkLossTimer = null;
  }

  /// Moves the call's audio to the network the phone has now: an ICE
  /// restart (new ICE credentials, candidates gathered on this network)
  /// offered in a re-INVITE on the current connection. The registrar passes
  /// the re-INVITE on with this connection in its Contact, so the far end's
  /// later requests (its BYE) reach the phone here too. The audio is back
  /// when ICE connects again ([PeerService.onIceConnectionState]); a restart
  /// that fails leaves the network-loss timer to end the call.
  Future<void> _restartIce(String why) async {
    final id = _callId;
    if (id == null ||
        (_callState != CallStateStatus.active &&
            _callState != CallStateStatus.held)) {
      return;
    }
    if (_reInviteInProgress) {
      _logger.warn('ICE restart for $id skipped: a re-INVITE is in flight');
      return;
    }
    _reInviteInProgress = true;
    if (_networkLossTimer != null) {
      // Signalling is back. Gathering, the re-INVITE and the ICE checks take
      // a few seconds: the audio gets a full grace period from now.
      _clearNetworkLossTimer();
      _startNetworkLossTimer(id);
    }
    _logger.info('Restarting ICE for call $id: $why');
    try {
      final offer = await _peer.beginIceRestart(cancelled: () => _callId != id);
      if (_callId != id) return;
      try {
        final answer = await _sip.reInvite(offer);
        if (_callId != id) return;
        await _peer.completeIceRestart(answer);
        _logger.info('ICE restart for call $id answered; waiting for ICE');
      } catch (e) {
        if (_callId != id) return; // the call ended meanwhile
        if (e is SipRequestFailed && e.statusCode == 481) {
          // Vobiz no longer has this call: it ended while the phone was
          // offline (the far end hung up, or the call was transferred
          // away). End it now rather than waiting out the grace period, and
          // send no BYE: it would only be refused too (RFC 3261 12.2.1.2).
          _logger.warn('ICE restart for call $id refused with 481: the call '
              'no longer exists; ending it');
          final cleanup = _cleanupCall(id,
              message: 'The call ended while the connection was down',
              reason: 'ended_while_offline');
          _sip.abandonCall();
          await cleanup;
          return;
        }
        _logger.warn('ICE restart for call $id refused: $e');
        await _peer.abortIceRestart();
      }
    } catch (e) {
      _logger.warn('ICE restart for call $id failed: $e');
    } finally {
      if (_callId == id) _reInviteInProgress = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Private — WebRTC helpers
  // ---------------------------------------------------------------------------

  /// Waits until the offer or answer can carry a candidate the media server
  /// can reach: gathering complete, or a server-reflexive or relay candidate
  /// (from STUN or TURN) already gathered. Android seldom reports gathering
  /// complete, and waiting out a long timeout kept the caller hearing ringing
  /// for 8 s after the user had answered.
  ///
  /// With a TURN server configured it waits for the relay candidate rather
  /// than returning at the first srflx one; see
  /// [PeerService.waitForIceGathering].
  Future<void> _waitForIceGathering(String callId) => _peer.waitForIceGathering(
        callId,
        cancelled: () => _callId != callId,
      );

  // ---------------------------------------------------------------------------
  // Private — cleanup
  // ---------------------------------------------------------------------------

  /// Ends [callId] from this side: the call is torn down locally with
  /// [message] and [reason], then the SIP layer is told. A call that is
  /// still ringing here is declined with [declineCode]; any other gets a BYE
  /// (or whatever the SIP layer sends to end an unanswered outbound call).
  ///
  /// Local teardown comes first so that the SIP layer's own onCallEnded
  /// ('Hung up'), fired synchronously, cannot overwrite [reason].
  Future<void> _terminate(
    String callId, {
    required String message,
    String? reason,
    int declineCode = 486,
    String? declinePhrase,
  }) async {
    if (_callId != callId) return;
    final ringingHere =
        _direction == CallDirection.inbound && !_sip.hasActiveDialog;
    final cleanup = _cleanupCall(callId, message: message, reason: reason);
    try {
      if (ringingHere) {
        _sip.reject(declineCode,
            declinePhrase ?? _declinePhrases[declineCode] ?? 'Busy Here');
      } else {
        _sip.hangup();
      }
    } catch (e) {
      // The socket may already be gone; the call is ended locally either way.
      _logger.warn('Could not signal the end of call $callId: $e');
    }
    await cleanup;
  }

  static const Map<int, String> _declinePhrases = <int, String>{
    480: 'Temporarily Unavailable',
    486: 'Busy Here',
    488: 'Not Acceptable Here',
    500: 'Server Internal Error',
  };

  /// Ends [callId] once. A local hangup reaches here twice — from hangup()
  /// and from the SIP layer's onCallEnded — so the second arrival is ignored
  /// instead of reporting the call as ended twice. The second arrival waits
  /// for the first to release the media, so `await hangup()` returns with the
  /// microphone, PeerConnection and audio route released.
  Future<void> _cleanupCall(String callId, {String? message, String? reason}) {
    if (_callId != callId) return _releasing[callId] ?? Future<void>.value();
    // A block body: remove() returns this very future, and whenComplete
    // would wait on it.
    final done = _endCall(callId, message, reason).whenComplete(() {
      _releasing.remove(callId);
    });
    _releasing[callId] = done;
    return done;
  }

  final Map<String, Future<void>> _releasing = <String, Future<void>>{};

  Future<void> _endCall(String callId, String? message, String? reason) async {
    if (_pushed?.callId == callId) _forgetPushedCall();
    _callId = null;
    _clearCallSetupTimer();
    _clearNetworkLossTimer();
    _signalingLost = false;
    _mediaLost = false;
    _callUuid = _sip.callUuid ?? _callUuid;
    _callState = CallStateStatus.ended;
    _emitCallEvent(
        callId, CallStateStatus.ended, message ?? reason ?? 'Call ended',
        reason: reason);
    if (_callUuid != null) _lastCallUuid = _callUuid;
    _pendingInboundCaller = null;
    _pendingInboundSdp = null;
    _activeCallDestination = null;
    _direction = null;
    _callUuid = null;
    _callHeaders = const <String, String>{};
    _callState = CallStateStatus.idle;
    _interruptions.reset();
    _reInviteInProgress = false;
    if (_reconnectWhenCallEnds) {
      // The SIP layer closes the socket now that the call is over.
      _reconnectWhenCallEnds = false;
      _scheduleReconnect('Registration failed during the call');
    }
    await _peer.disposeCall(callId);
  }

  // ---------------------------------------------------------------------------
  // Private — events
  // ---------------------------------------------------------------------------

  void _emitCallEvent(String callId, CallStateStatus state, String message,
      {int? sipCode, String? reason}) {
    _callEvents.addIfOpen(CallEvent(
      callId: callId,
      state: state,
      message: message,
      direction: _direction,
      remoteIdentity: _pendingInboundCaller ?? _activeCallDestination,
      callUuid: _callUuid,
      headers: _callHeaders,
      sipCode: sipCode,
      reason: reason,
      sipCallId: _sip.activeSipCallId,
    ));
  }

  void _emitError(String code, String message, Object? cause) {
    _errorEvents.addIfOpen(ErrorEvent(
      code: code,
      message: message,
      cause: cause,
    ));
  }
}

/// A monitor for [SdkConfig.watchNetwork] = false: always online, never
/// changes, so only the keep-alive notices a lost network.
class _AlwaysOnlineMonitor implements ConnectivityMonitor {
  @override
  Future<NetworkStatus> current() async =>
      NetworkStatus(const <NetworkType>[NetworkType.other]);

  @override
  Stream<NetworkStatus> get changes => const Stream<NetworkStatus>.empty();
}

/// A call a Vobiz push announced, from [VobizClient.handleIncomingPush] until
/// its call ends or the push expires.
class _PushedCall {
  _PushedCall(this.push);

  final VobizIncomingPush push;

  /// The call's `CallEvent.callId`, once its INVITE has arrived.
  String? callId;

  /// The registrar took the REGISTER that claimed it.
  bool claimed = false;

  /// Accept, or Decline, was tapped on the call screen.
  bool accepted = false;
  bool declined = false;

  Timer? expiry;
}
