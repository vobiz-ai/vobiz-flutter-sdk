import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_history.dart';
import 'countries.dart';
import 'demo_client.dart';
import 'push/call_platform.dart';
import 'push/call_screen.dart';
import 'push/push_bridge_api.dart';
import 'push/push_call.dart';
import 'push/push_service.dart';

/// The ways to sign in: the web Playground's two, and an access token (JWT)
/// from a token server, as the Vobiz WebRTC demo does.
enum AuthTab { zeroConfig, sipDirect, accessToken }

enum PhoneStatus { offline, connecting, online, ringing, inCall, error }

/// Whether the push bridge knows this phone.
enum PushState { off, registering, ready, failed }

enum LogType { info, success, warning, error, event }

enum TransferTarget { number, user }

enum TransferStatus { idle, submitting, accepted, failed }

/// Who a transfer moves, as the user sees it.
enum TransferParty { me, other, both }

/// The Redirect API's `legs` for [party] on a call in [direction].
///
/// Vobiz names legs by the call, not by this app: the A-leg is the side
/// that started the call and the B-leg the side `<Dial>` reached. On a
/// call this app placed, the app is the A-leg. On a call that rang this
/// app (the bridge's `<Dial><User>`), the caller is the A-leg and the app
/// the B-leg, so "move me" is `bleg`.
TransferLeg transferLegFor(TransferParty party, CallDirection? direction) {
  final inbound = direction == CallDirection.inbound;
  return switch (party) {
    TransferParty.both => TransferLeg.both,
    TransferParty.me => inbound ? TransferLeg.bLeg : TransferLeg.aLeg,
    TransferParty.other => inbound ? TransferLeg.aLeg : TransferLeg.bLeg,
  };
}

class LogEntry {
  LogEntry(this.message, this.type) : time = DateTime.now();

  final DateTime time;
  final String message;
  final LogType type;

  String get clock {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// One row of the SIP header editor.
class HeaderRow {
  HeaderRow(this.id, {this.name = VobizSipHeaders.prefix, this.value = ''});

  final int id;
  String name;
  String value;

  /// Untouched: empty, or still just the pre-filled `X-VH-` prefix.
  bool get isPristine {
    if (value.trim().isNotEmpty) return false;
    final k = name.trim();
    return k.isEmpty || k.toUpperCase() == VobizSipHeaders.prefix.toUpperCase();
  }
}

/// Headers seen on one call, kept for inspection after it ends.
class CallHeaderRecord {
  CallHeaderRecord({
    required this.id,
    required this.at,
    required this.direction,
    required this.from,
    required this.events,
    required this.headers,
  });

  final String id;
  final DateTime at;
  final CallDirection direction;
  String from;
  final List<String> events;
  final Map<String, String> headers;

  Map<String, Object> toJson() => <String, Object>{
        'id': id,
        'at': at.toIso8601String(),
        'direction': direction.name,
        'from': from,
        'events': events,
        'headers': headers,
      };
}

/// Everything the Playground screens show, and every action they take.
///
/// It mirrors the web Playground's VobizPhone component: the same two sign-in
/// modes, the same checks before dialling, and the same trace messages, so the
/// two can be compared side by side.
class PlaygroundController extends ChangeNotifier {
  PlaygroundController({
    VobizClient? client,
    FlutterSecureStorage? secureStorage,
    PushService? push,
    CallScreenApi? callScreen,
    CallPlatform? platform,
    http.Client? httpClient,
  })  : client = client ?? createPlaygroundClient(),
        _http = httpClient,
        _secure = secureStorage ?? const FlutterSecureStorage(),
        push = push ?? PushService.unavailable('Push is not set up in this build.'),
        callScreen = callScreen ?? const CallScreenApi(),
        platform = platform ?? CallPlatform();

  final VobizClient client;
  final FlutterSecureStorage _secure;

  /// For fetching access tokens; the default client when null (tests pass one).
  final http.Client? _http;

  /// The system incoming-call screen.
  final CallScreenApi callScreen;

  /// The example's Android side: the call's foreground service, pushes,
  /// missed-call notifications.
  final CallPlatform platform;

  /// Firebase push, which wakes the app for calls when it is closed.
  final PushService push;
  SharedPreferences? _prefs;
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  /// Asks the shell to show a tab: 1 when registered or a call rings.
  void Function(int tab)? onTabRequest;

  // ── Sign-in form ────────────────────────────────────────────────────────────
  AuthTab authTab = AuthTab.zeroConfig;
  String authId = '';
  String authToken = '';
  String sipUsername = '';
  String sipPassword = '';
  bool rememberMe = true;
  String webhookUrl = SdkConfig.defaultWebhookUrl;

  /// Access token sign-in: where to POST for a token (the Vobiz WebRTC demo's
  /// `/token`, or your own). Empty: the push server's `/token`.
  String tokenServerUrl = '';

  /// The user id (`sub`) to ask the push server's `/token` for. Empty: its
  /// JWT_SUB. Your own token server decides `sub` itself.
  String tokenUser = '';
  VobizAccessTokenSession? _tokenSession;
  StreamSubscription<VobizException>? _tokenFailures;
  VobizBackendAccessTokenProvider? _tokenProvider;

  // ── Status ──────────────────────────────────────────────────────────────────
  PhoneStatus status = PhoneStatus.offline;
  String statusText = 'Disconnected';
  String? connectedAs;
  Timer? _loginTimeout;

  VobizAuthMode get authMode => client.authMode;
  bool _reconnecting = false;

  /// Why the last Connect did nothing or failed, shown under the button (it
  /// is in the Trace too).
  String? connectError;

  /// The sign-in fields Connect found empty: 'authId', 'authToken',
  /// 'sipUsername', 'sipPassword'.
  Set<String> missingFields = <String>{};

  /// Bumped by every sign-out, so a sign-in that was still waiting for the
  /// server cannot bring the session back afterwards.
  int _session = 0;

  /// The sign-in in progress, so a second Connect joins it.
  Future<void>? _connecting;

  /// Registered, in a call, or briefly reconnecting after the network dropped.
  bool get isSignedIn =>
      status == PhoneStatus.online ||
      status == PhoneStatus.ringing ||
      status == PhoneStatus.inCall ||
      _reconnecting;

  // ── Dialer ──────────────────────────────────────────────────────────────────
  String callerIdIso = 'IN';
  String callerIdNumber = '';
  String destIso = 'IN';
  String destNumber = '';

  String get callerId =>
      callerIdNumber.isEmpty ? '' : '${findCountry(callerIdIso).dial}$callerIdNumber';
  String get destination => '${findCountry(destIso).dial}$destNumber';

  // ── SIP headers ─────────────────────────────────────────────────────────────
  final List<HeaderRow> headerRows = <HeaderRow>[];
  int _rowId = 0;
  bool recordCall = false;
  bool sendHeadersOnTransfer = true;
  bool headerSubmitAttempted = false;
  final List<CallHeaderRecord> callHeaders = <CallHeaderRecord>[];
  CallHeaderRecord? activeHeaders;

  int get activeHeaderCount => headerRows.where((r) => !r.isPristine).length;

  // ── Call ────────────────────────────────────────────────────────────────────
  String remoteParty = '';
  bool showIncoming = false;
  bool isMuted = false;
  bool speakerOn = false;
  Duration callDuration = Duration.zero;
  final List<double?> latency = List<double?>.filled(20, null, growable: true);
  Timer? _callTimer;
  Timer? _statsTimer;

  // Connection watch: during a call the push bridge gets an "alive" report
  // every second, so it can beep to the other party when this phone's
  // network drops (see _startAliveReports).
  Timer? _aliveTimer;
  PushBridgeApi? _aliveApi;
  String? _aliveCallUuid;
  bool _aliveInFlight = false;

  /// Ticks once a second during a call, for the call clock and the latency
  /// chart. Only the widgets showing those listen; the timers no longer
  /// notify the whole controller (which rebuilt every screen).
  final ChangeNotifier callTicker = ChangeNotifier();
  bool _recordRequested = false;
  String? _failedCallId;

  // ── Transfer ────────────────────────────────────────────────────────────────
  TransferTarget transferTarget = TransferTarget.number;
  TransferParty transferParty = TransferParty.me;

  /// The `legs` value the current call's transfer will send.
  TransferLeg get transferLeg => transferLegFor(transferParty, client.callDirection);
  String transferIso = 'IN';
  String transferNumber = '';
  String transferUser = '';
  TransferStatus transferStatus = TransferStatus.idle;
  String transferError = '';

  // ── Conference (push bridge) ────────────────────────────────────────────────
  TransferTarget conferenceTarget = TransferTarget.number;
  String conferenceIso = 'IN';
  String conferenceNumber = '';
  String conferenceUser = '';
  bool conferenceBusy = false;
  String conferenceError = '';

  /// People added so far: the sheet keys its input fields with it, so they
  /// are empty again after each add.
  int conferenceAdds = 0;
  VobizConference? _conference;
  String? _conferenceToken;

  /// The current call's conference, or null when it is not one.
  VobizConferenceState? get conference => _conference?.state.value;

  /// Who the conference sheet will dial: an E.164 number or a SIP username.
  String get conferenceDestination => conferenceTarget == TransferTarget.user
      ? VobizClient.endpointUsername(conferenceUser.trim())
      : '${findCountry(conferenceIso).dial}$conferenceNumber';

  /// Why the conference controls cannot be used, or null when they can. The
  /// push bridge holds the Auth Token that moves calls into a room and dials
  /// people, so it needs the bridge and this phone paired with it.
  String? get conferenceBlocker {
    if (bridgeConfig == null) {
      return 'Conference goes through the push server: paste the line it prints under '
          'Identity → Incoming calls.';
    }
    if (_bridgeDeviceToken == null) {
      return 'Pair this phone with the push server first: turn on "Receive calls through the '
          'push server" under Identity → Incoming calls.';
    }
    return null;
  }

  // ── Incoming calls (push bridge) ────────────────────────────────────────────
  /// The line the push bridge prints: `https://<tunnel>#key=<key>`.
  String pushServer = '';

  /// Register with the push bridge after signing in, so calls to the Vobiz
  /// number ring this phone (also when closed, with Firebase set up).
  bool receiveCalls = false;
  PushState pushState = PushState.off;
  String pushDetail = '';

  /// Android 13+ notification permission; null while unknown.
  bool? notificationsAllowed;

  /// Android 14+ permission to take over the lock screen; null while unknown.
  bool? fullScreenAllowed;

  bool _inForeground = true;

  /// A call accepted on the call screen whose INVITE has not arrived yet.
  PushCall? _acceptedCall;
  Timer? _acceptedTimer;

  /// The call screen showing the current call, and whether Accept was
  /// tapped there (it then becomes the ongoing-call notification).
  String? _callScreenId;
  bool _callScreenAccepted = false;
  PushCall? _callScreenPush;

  /// Call screens this app closed itself. The plugin reports closing a screen
  /// that still rings as a Decline, which must not be taken for the user's.
  final Set<String> _closingScreens = <String>{};

  /// Pushed calls already taken after an Accept. The plugin can deliver
  /// one Accept twice (replayed when the app starts, and found again among
  /// its active calls); each call is taken once.
  final Set<String> _takenCalls = <String>{};

  PushBridgeConfig? get bridgeConfig => PushBridgeConfig.parse(pushServer);

  // ── Incoming calls (Vobiz push, no push bridge) ─────────────────────────────
  /// Register this phone with Vobiz's own push service after signing in. A
  /// call to the signed-in SIP user then wakes the app when it is closed:
  /// Vobiz's registrar holds the call, pushes, and sends it to the REGISTER
  /// that claims it. Needs Vobiz's server side for it (registrar and
  /// push-service), and the app's Firebase key saved in the Vobiz Console.
  bool vobizPush = false;
  PushState vobizPushState = PushState.off;
  String vobizPushDetail = '';

  /// The account's Auth ID and Auth Token, to register this phone with
  /// Vobiz push. TEST ONLY: the Auth Token is the account's API key, and
  /// Vobiz has no device sign-in for apps yet. Empty, the Zero-Config fields
  /// are used. Kept in secure storage with "Remember me", like those.
  String pushAuthId = '';
  String pushAuthToken = '';

  /// TEST ONLY: what "Call this phone through Vobiz" needs besides the account:
  /// a caller ID (a number on the account, digits) and an answer URL (any
  /// address that returns Vobiz XML; Vobiz fetches it when the call is
  /// answered). Not secret, so kept with the other settings.
  String vobizCallFrom = '';
  String vobizCallAnswerUrl = '';

  /// A test call is on its way: its button waits.
  bool vobizCallPlacing = false;

  /// This install's id with Vobiz push, made once and kept.
  String? _pushDeviceId;

  /// The app's package name: Vobiz pushes with the Firebase key saved for it.
  static const String appBundleId = 'ai.vobiz.vobiz_webrtc_example';

  /// This phone's own token with the push bridge, from pairing.
  String? _bridgeDeviceToken;

  /// Pushed calls still ringing, by the bridge's call id (its PushRef).
  final Map<String, PushCall> _ringingPushes = <String, PushCall>{};

  /// Pushes handled already: one push can arrive both through Firebase's
  /// onMessage (app open) and through the app's own receiver.
  final Set<String> _seenPushes = <String>{};

  /// The inbound call ringing or connected here, until its outcome is logged.
  _Inbound? _inbound;

  /// A bridge call whose SIP attempt ended unanswered: the bridge may ring
  /// again, so it becomes a missed call only if nothing follows.
  final Map<String, Timer> _pendingMissed = <String, Timer>{};

  /// How long a bridge call may go quiet between ringing attempts before it
  /// counts as missed (when no push says how it ended).
  static const Duration missedGrace = Duration(seconds: 10);

  /// A call that arrived while this line was busy: shown as call waiting,
  /// never as the full-screen ringing screen.
  PushCall? callWaiting;

  /// Whether the call's foreground service is running.
  bool _callServiceOn = false;

  /// Whether a call placed from this phone is in progress, and whether it
  /// was answered.
  bool _outboundActive = false;
  bool _outboundAnswered = false;

  // ── Call log ────────────────────────────────────────────────────────────────
  /// Recent calls on this phone, with how each ended.
  final CallHistory history = CallHistory();

  // ── Trace ───────────────────────────────────────────────────────────────────
  final List<LogEntry> logs = <LogEntry>[];
  static const int _maxLogs = 500;

  // ── Theme ───────────────────────────────────────────────────────────────────
  /// The theme on its own listenable: the app's root rebuilds only when it
  /// changes, not on every log line or call-timer tick.
  final ValueNotifier<ThemeMode> theme = ValueNotifier<ThemeMode>(ThemeMode.system);

  ThemeMode get themeMode => theme.value;

  // Storage keys. Header rows use the web Playground's key and shape.
  static const String _kHeaders = 'vobiz_playground_headers';
  static const String _kTheme = 'vobiz_playground_theme';
  static const String _kMode = 'vobiz_playground_mode';
  static const String _kWebhook = 'vobiz_playground_webhook';
  static const String _kTokenServer = 'vobiz_playground_token_server';
  static const String _kTokenUser = 'vobiz_playground_token_user';
  static const String _kRemember = 'vobiz_playground_remember';
  static const String _kCallerId = 'vobiz_playground_caller_id';
  static const String _kAuthId = 'vobiz_auth_id';
  static const String _kAuthToken = 'vobiz_auth_token';
  static const String _kSipUser = 'vobiz_sip_username';
  static const String _kSipPass = 'vobiz_sip_password';
  static const String _kPushServer = 'vobiz_push_server';
  static const String _kReceiveCalls = 'vobiz_playground_receive_calls';
  static const String _kPushDevice = 'vobiz_push_device_token';
  static const String _kVobizPush = 'vobiz_playground_vobiz_push';
  static const String _kPushInstallId = 'vobiz_push_install_id';
  static const String _kPushAuthId = 'vobiz_push_auth_id';
  static const String _kPushAuthToken = 'vobiz_push_auth_token';
  static const String _kVobizCallFrom = 'vobiz_push_test_from';
  static const String _kVobizCallAnswerUrl = 'vobiz_push_test_answer_url';

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _loadPrefs();
      history.load(_prefs!);
    } catch (e) {
      log('Could not read saved settings: $e', LogType.warning);
    }
    await _loadSavedCredentials();
    await _loadPushServer();
    _subs.add(client.connectionEvents.listen(_onConnection));
    _subs.add(client.callEvents.listen(_onCall));
    _subs.add(client.errorEvents.listen(_onError));
    _subs.add(callScreen.events.listen(_onCallScreenEvent, onError: (Object _) {}));
    _subs.add(push.foregroundCalls.listen(_onPush));
    _subs.add(platform.pushes.listen(_onPushData));
    _subs.add(platform.hangUpRequests.listen((_) => hangup()));
    _subs.add(push.tokenRefresh.listen((_) {
      _registerWithBridge(quiet: true);
      _registerWithVobizPush(quiet: true);
    }));
    _subs.add(client.pushCallUpdates.listen(_onPushCallUpdate));
    notifyListeners();
    // The push that started the app (closed app), if any: handled before
    // anything else so its call screen rings and sign-in starts at once.
    for (final data in await platform.ready()) {
      _onPushData(data);
    }
    await refreshCallPermissions();
    await _resumeAcceptedCall();
  }

  bool _disposed = false;

  // Async work can finish after the controller is disposed (a push-server reply
  // that fails late, say) and log: that must not notify listeners that are gone.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _stopCallTimers();
    _stopAliveReports(ended: false);
    unawaited(_stopTokenSession());
    _loginTimeout?.cancel();
    _acceptedTimer?.cancel();
    for (final t in _pendingMissed.values) {
      t.cancel();
    }
    _conference?.state.removeListener(notifyListeners);
    _conference?.dispose();
    client.dispose();
    history.dispose();
    theme.dispose();
    callTicker.dispose();
    super.dispose();
  }

  // ── Sign in / out ───────────────────────────────────────────────────────────

  void setAuthTab(AuthTab tab) {
    authTab = tab;
    notifyListeners();
  }

  void update(void Function() change) {
    change();
    notifyListeners();
  }

  /// Signs in. A second call while one is in progress joins it rather than
  /// opening another connection.
  Future<void> connect() {
    final running = _connecting;
    if (running != null) return running;
    if (status == PhoneStatus.connecting) return Future<void>.value();
    final attempt = _connect();
    _connecting = attempt;
    return attempt.whenComplete(() {
      if (identical(_connecting, attempt)) _connecting = null;
    });
  }

  Future<void> _connect() async {
    final zero = authTab == AuthTab.zeroConfig;
    final token = authTab == AuthTab.accessToken;
    final sip = authTab == AuthTab.sipDirect;
    connectError = null;
    missingFields = <String>{
      if (zero && authId.trim().isEmpty) 'authId',
      if (zero && authToken.trim().isEmpty) 'authToken',
      if (sip && sipUsername.trim().isEmpty) 'sipUsername',
      if (sip && sipPassword.isEmpty) 'sipPassword',
      if (token && tokenServerUrl.trim().isEmpty && bridgeConfig == null) 'tokenServer',
    };
    if (missingFields.isNotEmpty) {
      return _connectFailed(zero
          ? 'Please enter Auth ID and Auth Token'
          : token
              ? 'Please enter a token server URL, or set up the push server (its /token mints tokens)'
              : 'Please enter both SIP username and password');
    }
    final hook = webhookUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (zero && !hook.startsWith('https://')) {
      return _connectFailed('⚠️ Public Webhook URL is required! Vobiz Cloud cannot reach localhost. '
          'Use the hosted server or an https tunnel.');
    }
    if (token && tokenServerUrl.trim().isNotEmpty) {
      final url = Uri.tryParse(tokenServerUrl.trim());
      if (url == null || url.host.isEmpty || (url.scheme != 'https' && url.scheme != 'http')) {
        missingFields = <String>{'tokenServer'};
        return _connectFailed('The token server must be an http(s) URL, such as https://<your server>/token');
      }
    }

    final session_ = _session;
    _setStatus(PhoneStatus.connecting, 'Connecting...');
    _startLoginTimeout();
    try {
      if (zero) {
        client.backendUrl = hook;
        log('Generating Application & Endpoint via API...', LogType.info);
        final session = await client.connectWithAuthToken(
          authId: authId,
          authToken: authToken,
        );
        if (session_ != _session) {
          await _abandonSignIn();
          return;
        }
        log('Provisioned App ID: ${session.applicationId}'
            '${session.reusedExisting ? ' (reused existing infrastructure)' : ''}',
            LogType.success);
        connectedAs = session.sipUsername;
        // As on the web Playground, the provisioned endpoint fills the SIP
        // Direct fields, so it can be used that way next time.
        sipUsername = session.sipUsername;
        sipPassword = session.sipPassword;
        log('Connecting as dynamically generated user: ${session.sipUsername}...',
            LogType.event);
      } else if (token) {
        await _startTokenSession();
        if (session_ != _session) {
          await _abandonSignIn();
          return;
        }
        final t = client.accessToken;
        connectedAs = client.sipUsername;
        if (t != null) {
          log('Access token for ${t.sipUsername}: valid until ${_clock(t.expiresAt.toLocal())}, '
              'incoming ${t.canReceiveCalls ? 'allowed' : 'not allowed'}, '
              'outgoing ${t.canCallOut ? 'allowed' : 'not allowed'}'
              '${t.appId != null ? ', outbound calls through application ${t.appId}' : ''}',
              LogType.event);
        }
      } else {
        connectedAs = sipUsername.trim();
        log('Connecting as ${sipUsername.trim()}...', LogType.event);
        await client.connectWithCredentials(CredentialConfig(
          username: sipUsername.trim(),
          password: sipPassword,
        ));
        if (session_ != _session) {
          await _abandonSignIn();
          return;
        }
      }
      await _saveCredentials();
    } on VobizException catch (e) {
      if (session_ != _session) return;
      _loginTimeout?.cancel();
      connectedAs = null;
      await _stopTokenSession();
      connectError = token ? 'Access token error: ${e.message}' : 'API Setup Error: ${e.message}';
      log(connectError!, LogType.error);
      _setStatus(PhoneStatus.offline, 'Error');
    } catch (e) {
      if (session_ != _session) return;
      _loginTimeout?.cancel();
      connectError = 'Connection failed: $e';
      log(connectError!, LogType.error);
      _setStatus(PhoneStatus.error, 'Error');
    }
  }

  void _connectFailed(String message) {
    connectError = message;
    log(message, LogType.error);
  }

  /// Signs in with access tokens that the SDK renews before they expire,
  /// from the token server, or the push server's /token when none is set.
  Future<void> _startTokenSession() async {
    await _stopTokenSession();
    final server = tokenServerUrl.trim();
    log('Fetching an access token from ${server.isEmpty ? 'the push server' : server}...',
        LogType.info);
    final session = await client.connectWithAccessTokenProvider(_fetchAccessToken);
    _tokenSession = session;
    _tokenFailures = session.failures.listen((e) {
      connectError = 'Access token error: ${e.message}';
      log(connectError!, LogType.error);
      notifyListeners();
    });
  }

  Future<String> _fetchAccessToken(VobizAccessTokenRequest request) async {
    final reason = VobizBackendAccessTokenProvider.reasonValue(request);
    if (request != VobizAccessTokenRequest.signIn) {
      log('Asking for a new access token ($reason)', LogType.info);
    }
    final server = tokenServerUrl.trim();
    if (server.isNotEmpty) {
      final provider = _tokenProvider ??=
          VobizBackendAccessTokenProvider(url: Uri.parse(server), httpClient: _http);
      return provider(request);
    }
    final config = bridgeConfig;
    if (config == null) {
      throw const VobizAccessTokenException(
          'No token server: enter one, or set up the push server');
    }
    final api = PushBridgeApi(config, client: _http, deviceToken: _bridgeDeviceToken);
    try {
      final user = tokenUser.trim();
      return await api.accessToken(sub: user.isEmpty ? null : user, reason: reason);
    } on PushBridgeException catch (e) {
      throw VobizAccessTokenException('The push server did not give a token: ${e.message}',
          statusCode: e.statusCode, cause: e);
    } finally {
      // A client passed in is the caller's to close.
      if (_http == null) api.close();
    }
  }

  Future<void> _stopTokenSession() async {
    await _tokenFailures?.cancel();
    _tokenFailures = null;
    await _tokenSession?.dispose();
    _tokenSession = null;
    _tokenProvider?.close();
    _tokenProvider = null;
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Signed out while the server was still answering: drop what it gave.
  Future<void> _abandonSignIn() async {
    log('Sign-in finished after sign-out; dropping that session', LogType.warning);
    connectedAs = null;
    await client.disconnect();
  }

  /// Signs out, and forgets the saved Auth Token and SIP password: after a
  /// sign-out nothing on this device can sign in as this account again.
  Future<void> disconnect() async {
    _session++;
    _connecting = null;
    _loginTimeout?.cancel();
    _reconnecting = false;
    connectError = null;
    log('Logging out...', LogType.info);
    // Signing out means "stop ringing this phone"; closing the app does not.
    await _unregisterFromBridge(client.sipUsername ?? connectedAs);
    await _logoutFromVobizPush();
    // Stop renewing the access token before the client lets go of it.
    await _stopTokenSession();
    await client.disconnect();
    connectedAs = null;
    authToken = '';
    sipPassword = '';
    await _forgetCredentials();
    await _saveBridgeDeviceToken(null);
    _stopCallService();
    _resetCallState(registered: false);
    _setStatus(PhoneStatus.offline, 'Disconnected');
  }

  Future<void> _forgetCredentials() async {
    try {
      for (final key in <String>[_kAuthId, _kAuthToken, _kSipUser, _kSipPass, _kPushAuthId, _kPushAuthToken]) {
        await _secure.delete(key: key);
      }
      pushAuthToken = '';
    } catch (e) {
      log('Could not remove the saved credentials: $e', LogType.warning);
    }
  }

  void _startLoginTimeout() {
    _loginTimeout?.cancel();
    // Like the Playground: give up on a registrar that never answers.
    _loginTimeout = Timer(const Duration(seconds: 20), () {
      if (status == PhoneStatus.connecting) {
        _reconnecting = false;
        connectError = 'Login timed out (No response from registrar)';
        log(connectError!, LogType.error);
        _setStatus(PhoneStatus.error, 'Timeout');
      }
    });
  }

  // ── Dialling ────────────────────────────────────────────────────────────────

  /// The editor's rows as headers, with a reason for each row the platform
  /// would reject. Blank rows are ignored.
  ({Map<String, String> headers, List<String> errors}) buildRowHeaders() {
    final headers = <String, String>{};
    final errors = <String>[];
    final seen = <String>{};
    for (final row in headerRows) {
      if (row.isPristine) continue;
      final key = row.name.trim();
      final value = row.value.trim();
      final keyError = VobizSipHeaders.validateName(key);
      if (keyError != null) {
        errors.add('${key.isEmpty ? '(unnamed)' : key}: $keyError');
        continue;
      }
      final valueError = VobizSipHeaders.validateValue(key, value);
      if (valueError != null) {
        errors.add('$key: $valueError');
        continue;
      }
      if (!seen.add(key.toUpperCase())) {
        errors.add('$key: duplicate header, keeping the first one');
        continue;
      }
      headers[key] = value;
    }
    return (headers: headers, errors: errors);
  }

  Future<void> call() async {
    if (destNumber.trim().isEmpty) return log('Please enter a destination', LogType.error);
    if (!client.isConnected) return log('Login first', LogType.error);
    final cli = callerId;
    if (cli.isEmpty || !RegExp(r'^\+?\d{7,15}$').hasMatch(cli)) {
      return log('⚠️ Caller ID is required for PSTN calls. Enter a verified number '
          '(e.g. +919876543210)', LogType.error);
    }

    // The SDK would refuse these anyway; say which and why before dialling.
    final built = buildRowHeaders();
    headerSubmitAttempted = built.errors.isNotEmpty;
    if (built.errors.isNotEmpty) {
      for (final e in built.errors) {
        log('⚠️ SIP header rejected — $e', LogType.error);
      }
      return log('Fix the highlighted SIP headers before dialling', LogType.error);
    }

    remoteParty = destination;
    log('📞 Calling $destination...', LogType.event);
    final onInvite = <String, String>{
      ...built.headers,
      if (recordCall) VobizSipHeaders.record: 'true',
    };
    if (onInvite.isNotEmpty) {
      log('📤 SIP headers on INVITE: ${_fmtHeaders(onInvite)}', LogType.info);
    }
    _recordRequested = recordCall;
    activeHeaders = null;
    _outboundActive = true;
    _outboundAnswered = false;
    _setStatus(PhoneStatus.inCall, 'Calling...');
    // Started now, while the app is on screen: Android 14 refuses a
    // microphone service started later from the background.
    _startCallService(outbound: true);

    try {
      await client.makeCall(
        destination,
        callerId: cli,
        headers: built.headers,
        record: recordCall,
      );
    } on ArgumentError catch (e) {
      _recordRequested = false;
      _outboundActive = false;
      _stopCallService();
      log('⚠️ ${e.message}', LogType.error);
      _setStatus(PhoneStatus.online, 'Registered');
    } catch (e) {
      _recordRequested = false;
      _outboundActive = false;
      _stopCallService();
      log('❌ Could not start the call: $e', LogType.error);
      _resetCallState();
    }
  }

  Future<void> hangup() async {
    log('Hanging up...', LogType.info);
    await client.hangup();
  }

  Future<void> answer() async {
    showIncoming = false;
    log('Answering incoming call...', LogType.info);
    notifyListeners();
    _startCallService(outbound: false);
    // Answered in the app: a call screen still ringing for it has to stop.
    final screen = _callScreenId;
    if (screen != null && !_callScreenAccepted) {
      _callScreenId = null;
      await _closeCallScreen(screen);
    }
    await client.acceptCall();
  }

  Future<void> reject() async {
    showIncoming = false;
    log('Rejecting incoming call...', LogType.warning);
    notifyListeners();
    // Read before rejecting: the call-ended event clears them.
    final ring = _inbound;
    final pushed = _callScreenPush ?? (ring == null ? null : _ringingPushes[ring.id]);
    ring?.declinedHere = true;
    await client.rejectCall();
    await _tellBridgeDeclined(pushed);
  }

  Future<void> toggleMute() async {
    if (isMuted) {
      await client.unmute();
      isMuted = false;
      log('🔊 Unmuted', LogType.info);
    } else {
      await client.mute();
      isMuted = true;
      log('🔇 Muted', LogType.warning);
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await client.setSpeakerphone(speakerOn);
    log(speakerOn ? '🔈 Speaker on' : '📱 Earpiece', LogType.info);
    notifyListeners();
  }

  /// A keypad press: DTMF during a connected call, otherwise a digit for the
  /// destination, exactly as the Playground's keypad behaves.
  Future<void> pressKey(String key) async {
    if (status == PhoneStatus.inCall && client.callState == CallStateStatus.active) {
      try {
        await client.sendDtmf(key);
        log('🔢 DTMF: $key', LogType.info);
      } catch (e) {
        log('DTMF not sent: $e', LogType.error);
      }
      return;
    }
    if (status == PhoneStatus.inCall || status == PhoneStatus.ringing) return;
    if (RegExp(r'^\d$').hasMatch(key)) {
      destNumber = '$destNumber$key';
      notifyListeners();
    }
  }

  // ── Transfer ────────────────────────────────────────────────────────────────

  String get transferDestination => transferTarget == TransferTarget.user
      ? 'sip:${VobizClient.endpointUsername(transferUser)}@registrar.vobiz.ai'
      : '${findCountry(transferIso).dial}$transferNumber';

  Future<void> transfer() async {
    if (status != PhoneStatus.inCall || client.callState != CallStateStatus.active) {
      return log('Transfer is only available after the call is answered', LogType.error);
    }
    if (client.authMode != VobizAuthMode.zeroConfig) {
      _transferFailed('Transfer needs API credentials');
      return log('⚠️ Transfer needs API credentials — connect using Zero-Config Setup.',
          LogType.error);
    }
    final user = VobizClient.endpointUsername(transferUser);
    if (transferTarget == TransferTarget.user) {
      if (!RegExp(r'^[a-zA-Z0-9_.\-+]{1,120}$').hasMatch(user)) {
        _transferFailed('Enter a valid SIP user');
        return log('Transfer target must be a SIP endpoint username, e.g. play123',
            LogType.error);
      }
    } else if (!RegExp(r'^\+\d{7,15}$').hasMatch(transferDestination)) {
      _transferFailed('Enter a valid phone number');
      return log('Transfer target must be a valid E.164 phone number', LogType.error);
    }

    final built = sendHeadersOnTransfer
        ? buildRowHeaders()
        : (headers: <String, String>{}, errors: <String>[]);
    if (built.errors.isNotEmpty) {
      for (final e in built.errors) {
        log('⚠️ SIP header rejected — $e', LogType.error);
      }
      headerSubmitAttempted = true;
      return _transferFailed('Fix the SIP headers before transferring');
    }
    final xml = VobizSipHeaders.toXml(built.headers);
    if (xml.skipped.isNotEmpty) {
      log('⚠️ Not carried on the transfer (XML allows only A-Za-z0-9 in names): '
          '${xml.skipped.join(', ')}', LogType.warning);
    }

    transferStatus = TransferStatus.submitting;
    transferError = '';
    final who = switch (transferParty) {
      TransferParty.me => 'you',
      TransferParty.other => 'the other party',
      TransferParty.both => 'both parties',
    };
    log('↗️ Transferring $who (legs=${transferLeg.apiValue}) '
        'to $transferDestination '
        '${transferTarget == TransferTarget.user ? '(with headers)' : '(blind)'}...',
        LogType.event);
    if (xml.value.isNotEmpty) log('📤 sipHeaders on <Dial>: ${xml.value}', LogType.info);
    notifyListeners();

    try {
      final message = await client.transferCall(
        number: transferTarget == TransferTarget.number ? transferDestination : null,
        sipUser: transferTarget == TransferTarget.user ? user : null,
        leg: transferLeg,
        callerId: callerId,
        sipHeaders: built.headers,
      );
      transferStatus = TransferStatus.accepted;
      log('✅ Transfer accepted: $message', LogType.success);
    } on VobizException catch (e) {
      _transferFailed(e.message);
      log('❌ Transfer failed: ${e.message}', LogType.error);
    } catch (e) {
      final message = e is ArgumentError ? '${e.message}' : '$e';
      _transferFailed(message);
      log('❌ Transfer failed: $message', LogType.error);
    }
    notifyListeners();
  }

  /// The SDK's conference client for the paired push bridge, made on first
  /// use and again when the bridge or this phone's token changes.
  VobizConference? _conferenceClient() {
    final config = bridgeConfig;
    final token = _bridgeDeviceToken;
    if (config == null || token == null) return null;
    final existing = _conference;
    if (existing != null && existing.serverUrl.toString() == config.baseUrl && _conferenceToken == token) {
      return existing;
    }
    existing?.state.removeListener(notifyListeners);
    existing?.dispose();
    final conference = VobizConference(
      client: client,
      serverUrl: Uri.parse(config.baseUrl),
      headers: () => <String, String>{'Authorization': 'Bearer $token'},
      // A call the push bridge rang is known there by its own id (PushRef,
      // the caller's leg); a call this app placed by its own CallUUID.
      callUuid: () => pushRefFromHeaders(client.callHeaders) ?? client.callUuid,
    );
    conference.state.addListener(notifyListeners);
    _conference = conference;
    _conferenceToken = token;
    return conference;
  }

  /// Dials [conferenceDestination] into a conference of the current call.
  /// The first person added turns the call into the conference.
  Future<void> conferenceAdd() async {
    final conference = _conferenceClient();
    if (conference == null) {
      conferenceError = conferenceBlocker ?? '';
      notifyListeners();
      return;
    }
    final target = conferenceDestination;
    final user = conferenceTarget == TransferTarget.user;
    if (user ? !RegExp(r'^[a-zA-Z0-9_.\-+]{1,120}$').hasMatch(target) : !RegExp(r'^\+\d{7,15}$').hasMatch(target)) {
      conferenceError = user ? 'Enter a SIP endpoint username, e.g. play123' : 'Enter a valid phone number';
      notifyListeners();
      return;
    }
    conferenceBusy = true;
    conferenceError = '';
    final first = conference.state.value == null;
    log(first ? '👥 Making this call a conference and dialling $target…' : '👥 Dialling $target into the conference…',
        LogType.event);
    notifyListeners();
    try {
      final state = await conference.add(
        number: user ? null : target,
        sipUser: user ? target : null,
        callerId: callerId.isEmpty ? null : callerId,
      );
      log('✅ Conference ${state.room}: dialling $target', LogType.success);
      conferenceNumber = '';
      conferenceUser = '';
      conferenceAdds++;
    } catch (e) {
      conferenceError = _conferenceMessage(e);
      log('❌ Conference: $conferenceError', LogType.error);
    } finally {
      conferenceBusy = false;
      notifyListeners();
    }
  }

  /// Mutes, unmutes, holds, resumes or removes one person in the conference.
  Future<void> conferenceAct(VobizConferenceParticipant person, VobizParticipantAction action) async {
    final conference = _conference;
    if (conference == null) return;
    conferenceError = '';
    notifyListeners();
    try {
      await conference.act(person.id, action);
      log('👥 ${person.label}: ${action.name}', LogType.event);
    } catch (e) {
      conferenceError = _conferenceMessage(e);
      log('❌ Conference ${action.name} ${person.label}: $conferenceError', LogType.error);
      notifyListeners();
    }
  }

  /// Ends the conference for everyone, this call included.
  Future<void> conferenceEnd() async {
    final conference = _conference;
    if (conference == null) return;
    try {
      await conference.end();
      log('👥 Conference ended for everyone', LogType.event);
    } catch (e) {
      conferenceError = _conferenceMessage(e);
      log('❌ Conference end: $conferenceError', LogType.error);
      notifyListeners();
    }
  }

  static String _conferenceMessage(Object e) => switch (e) {
        VobizException(:final message) => message,
        ArgumentError(:final message) => '$message',
        StateError(:final message) => message,
        _ => '$e',
      };

  void _transferFailed(String message) {
    transferStatus = TransferStatus.failed;
    transferError = message;
    notifyListeners();
  }

  // ── Incoming calls: push bridge and call screen ─────────────────────────────
  //
  // The push bridge (example/push_bridge) answers the Vobiz number. It rings
  // this app's SIP endpoint and, when Firebase is set up, sends a push. The
  // push reaches this one Flutter engine (Android starts it headless when
  // the app was closed, see CallEngine.kt), which shows the system call
  // screen and signs in at once, so the call is registered and ringing over
  // SIP by the time the user taps Accept.

  /// The app moved to or from the foreground.
  void setForeground(bool foreground) => _inForeground = foreground;

  /// Whether the app is on screen.
  bool get inForeground => _inForeground;

  /// Saves the line the bridge printed. Returns a problem to show, or null.
  Future<String?> setPushServer(String value) async {
    final text = value.trim();
    if (text.isNotEmpty && PushBridgeConfig.parse(text) == null) {
      return 'Paste the whole line the bridge printed: https://…#key=…';
    }
    if (text != pushServer) await _saveBridgeDeviceToken(null);
    pushServer = text;
    try {
      if (text.isEmpty) {
        await _secure.delete(key: _kPushServer);
      } else {
        await _secure.write(key: _kPushServer, value: text);
      }
    } catch (e) {
      log('Could not save the push server on this device: $e', LogType.warning);
    }
    if (text.isEmpty && receiveCalls) await setReceiveCalls(false);
    notifyListeners();
    if (receiveCalls) await _registerWithBridge();
    return null;
  }

  /// Turns "ring this phone for my Vobiz number" on or off.
  Future<void> setReceiveCalls(bool on) async {
    if (on && bridgeConfig == null) {
      log('Paste the push server line first (the bridge prints it when it starts)', LogType.error);
      return;
    }
    receiveCalls = on;
    await _prefs?.setBool(_kReceiveCalls, on);
    notifyListeners();
    if (on) {
      await requestCallPermissions();
      if (!rememberMe) {
        log('⚠️ Tick "Remember me" and sign in again: with the app closed, a call can only '
            'be answered if the app can sign itself in.', LogType.warning);
      }
      if (client.isConnected) {
        await _registerWithBridge();
      } else {
        pushDetail = 'Connect to register this phone with the push server.';
        notifyListeners();
      }
    } else {
      await _unregisterFromBridge(client.sipUsername);
      pushState = PushState.off;
      pushDetail = '';
      notifyListeners();
    }
  }

  /// Reads the notification and full-screen permissions without asking.
  Future<void> refreshCallPermissions() async {
    notificationsAllowed = await push.notificationsAllowed();
    fullScreenAllowed = await callScreen.canUseFullScreen();
    notifyListeners();
  }

  /// Asks for what the call screen needs: notifications (Android 13+) and,
  /// when missing, full-screen notifications (Android 14+, opens Settings).
  Future<void> requestCallPermissions() async {
    notificationsAllowed = await push.requestNotificationPermission();
    fullScreenAllowed = await callScreen.canUseFullScreen();
    if (fullScreenAllowed == false) await callScreen.requestFullScreen();
    notifyListeners();
  }

  /// Asks the bridge for a pretend call in ten seconds: time to press Home or
  /// swipe the app away, then watch the call screen appear.
  Future<void> sendTestCall() async {
    final config = bridgeConfig;
    final user = client.sipUsername;
    if (config == null || user == null || pushState != PushState.ready) {
      log('Turn on "Receive calls" and connect first', LogType.error);
      return;
    }
    if (!push.available) {
      log('Test calls need Firebase: ${push.problem}', LogType.error);
      return;
    }
    final api = PushBridgeApi(config, deviceToken: _bridgeDeviceToken);
    try {
      await api.sendTestCall(delaySeconds: 10);
      log('🧪 Test call in 10 s. Press Home, or swipe the app away from Recents, and wait '
          'for the call screen.', LogType.event);
    } on PushBridgeException catch (e) {
      log('❌ Test call: ${e.message}', LogType.error);
    } finally {
      api.close();
    }
  }

  Future<void> _registerWithBridge({bool quiet = false}) async {
    final config = bridgeConfig;
    final user = client.sipUsername;
    if (!receiveCalls || config == null || user == null || !client.isConnected) return;
    pushState = PushState.registering;
    notifyListeners();
    final api = PushBridgeApi(config, deviceToken: _bridgeDeviceToken);
    try {
      final token = await push.token();
      final registration = await api.register(
        username: user,
        token: token,
        app: 'vobiz_webrtc_example',
      );
      if (registration.deviceToken != null) await _saveBridgeDeviceToken(registration.deviceToken);
      pushState = PushState.ready;
      pushDetail = registration.push
          ? 'Calls to your Vobiz number ring this phone, also in the background and after '
              'the app is swiped away.'
          : 'Calls ring this app while it is open. ${push.problem ?? 'Firebase gave no token.'}';
      if (!quiet) {
        log(registration.push
            ? '📲 Push server: $user rings this phone, even with the app closed'
            : '📲 Push server: $user rings this app while it is open (no push token)',
            LogType.success);
      }
      if (!config.isHttps) {
        log('⚠️ The push server address is not https; Vobiz cannot reach it.', LogType.warning);
      }
      if (registration.warning != null) log('⚠️ ${registration.warning}', LogType.warning);
    } on PushBridgeException catch (e) {
      pushState = PushState.failed;
      pushDetail = e.message;
      log('❌ Push server: ${e.message}', LogType.error);
    } finally {
      api.close();
    }
    notifyListeners();
  }

  Future<void> _unregisterFromBridge(String? user) async {
    final config = bridgeConfig;
    if (!receiveCalls || config == null || user == null || user.isEmpty) return;
    final api = PushBridgeApi(config, deviceToken: _bridgeDeviceToken);
    try {
      if (_bridgeDeviceToken != null) await api.unregister();
      pushState = PushState.off;
      pushDetail = 'Signed out: calls no longer ring this phone.';
      log('📴 Push server: $user no longer rings this phone', LogType.info);
    } on PushBridgeException catch (e) {
      log('⚠️ Push server: ${e.message}', LogType.warning);
    } finally {
      api.close();
    }
    await _saveBridgeDeviceToken(null);
  }

  Future<void> _saveBridgeDeviceToken(String? token) async {
    _bridgeDeviceToken = token;
    try {
      if (token == null) {
        await _secure.delete(key: _kPushDevice);
      } else {
        await _secure.write(key: _kPushDevice, value: token);
      }
    } catch (e) {
      log('Could not save the push device token: $e', LogType.warning);
    }
  }

  /// A declined call should end for the caller now, not when ringing times
  /// out. Only a call the bridge pushed can be declined there: the push
  /// carries the call's key.
  Future<void> _tellBridgeDeclined(PushCall? pushed) async {
    if (pushed == null || pushed.isTest || pushed.isVobiz) return;
    await _quietly(() => PushBridgeApi.decline(pushed));
  }

  /// Whether an INVITE is the call the user already accepted on the call screen.
  bool _isAcceptedCall(CallEvent e) {
    final accepted = _acceptedCall;
    return accepted != null && inviteMatchesPush(accepted, headers: e.headers);
  }

  /// A call rings over SIP: show it on the system call screen too, which
  /// rings and vibrates (as the phone's settings allow), also with the app
  /// open. A push for the same call that is already showing is joined.
  Future<void> _showCallScreenForSip(CallEvent e) async {
    final ref = pushRefFromHeaders(e.headers);
    for (final active in await callScreen.active()) {
      final pushed = PushCall.fromExtra(active.extra);
      if (pushed == null || !inviteMatchesPush(pushed, headers: e.headers)) continue;
      _callScreenId = active.id;
      _callScreenPush = pushed;
      if (active.isAccepted) {
        _callScreenAccepted = true;
        await answer();
      }
      return;
    }
    final id = ref ?? 'sip-${e.callId}';
    _callScreenId = id;
    _callScreenAccepted = false;
    _callScreenPush = ref == null ? null : _ringingPushes[ref];
    await callScreen.showIncoming(
      id: id,
      caller: remoteParty,
      extra: <String, dynamic>{'source': 'sip', 'call': e.callId},
    );
  }

  void _endCallScreen() {
    final id = _callScreenId;
    _callScreenId = null;
    _callScreenAccepted = false;
    _callScreenPush = null;
    if (id != null) _closeCallScreen(id);
  }

  Future<void> _closeCallScreen(String id) async {
    _closingScreens.add(id);
    await callScreen.end(id);
  }

  /// Whether [id] is the call screen of the call ringing here over SIP.
  bool _isRingingHere(String id) {
    final ring = _inbound;
    return client.callState == CallStateStatus.incoming &&
        ring != null &&
        !ring.answered &&
        (ring.id == id || _callScreenId == id);
  }

  Future<void> _onCallScreenEvent(ck.CallEvent? event) async {
    // The echo of a screen this app closed itself: not the user's choice.
    final closedHere = switch (event) {
      ck.CallEventActionCallDecline(:final callKitParams) => _closingScreens.remove(callKitParams.id),
      ck.CallEventActionCallEnded(:final callKitParams) => _closingScreens.remove(callKitParams.id),
      _ => false,
    };
    if (closedHere) return;
    switch (event) {
      case ck.CallEventActionCallAccept(:final callKitParams):
        final pushed = PushCall.fromExtra(callKitParams.extra);
        if (pushed != null && pushed.isVobiz) {
          await _acceptVobizHeldCall(pushed, callKitParams.id);
          return;
        }
        final ringingHere = client.callState == CallStateStatus.incoming &&
            (callKitParams.id == _callScreenId ||
                pushRefFromHeaders(client.callHeaders) == callKitParams.id);
        _callScreenId = callKitParams.id;
        _callScreenAccepted = true;
        _callScreenPush = pushed;
        // Answer the SIP call only when it is the call this screen showed.
        if (ringingHere) {
          log('📲 Accepted on the call screen', LogType.event);
          onTabRequest?.call(1);
          if (pushed != null && !pushed.isTest) unawaited(_quietly(() => PushBridgeApi.accept(pushed)));
          await answer();
        } else if (pushed != null) {
          await _takeAcceptedCall(pushed, callKitParams.id);
        }
      case ck.CallEventActionCallDecline(:final callKitParams):
        final pushed = PushCall.fromExtra(callKitParams.extra);
        if (pushed != null && pushed.isVobiz && !_isRingingHere(callKitParams.id)) {
          await _declineVobizHeldCall(pushed);
          return;
        }
        if (_acceptedCall?.callId == callKitParams.id) _clearAcceptedCall();
        if (_isRingingHere(callKitParams.id)) {
          _callScreenPush = pushed ?? _callScreenPush;
          await reject();
        } else if (pushed != null) {
          _ringingPushes.remove(pushed.callId);
          log('📵 Declined ${pushed.isTest ? 'the test call' : 'the call from ${pushed.caller}'}',
              LogType.warning);
          if (!pushed.isTest) {
            _logCall(CallRecord(
              id: pushed.callId,
              inbound: true,
              party: pushed.caller,
              at: DateTime.now(),
              outcome: CallOutcome.declined,
            ));
            await _tellBridgeDeclined(pushed);
          }
        }
      case ck.CallEventActionCallEnded(:final callKitParams):
        if (_acceptedCall?.callId == callKitParams.id) {
          _clearAcceptedCall();
          log('📴 The caller hung up before the call connected', LogType.warning);
        } else if (callKitParams.id == _callScreenId) {
          if (client.callState == CallStateStatus.incoming) {
            // Still ringing (the caller gave up): decline it; a call that was
            // never answered cannot be hung up.
            await client.rejectCall();
          } else if (client.callState != CallStateStatus.idle) {
            // "Hang up" on the ongoing-call notification.
            await hangup();
          }
        }
      case ck.CallEventActionCallTimeout(:final id):
        await _onCallScreenTimeout(id);
      default:
        break;
    }
  }

  /// The call screen rang out (45 s) without an answer.
  Future<void> _onCallScreenTimeout(String id) async {
    if (_acceptedCall?.callId == id) _clearAcceptedCall();
    final pushed = _ringingPushes.remove(id);
    if (pushed?.isTest ?? false) return;
    final ring = _inbound;
    if (_isRingingHere(id)) {
      // Stop the SIP side too; this ring is now a missed call.
      _inbound = null;
      await client.rejectCall();
    }
    final callId = ring != null && (ring.id == id || _callScreenId == id) ? ring.id : id;
    _pendingMissed.remove(callId)?.cancel();
    log('📵 Missed call: nobody answered the call screen', LogType.warning);
    _logCall(CallRecord(
      id: callId,
      inbound: true,
      party: pushed?.caller ?? ring?.party ?? '',
      at: DateTime.now(),
      outcome: CallOutcome.missed,
    ));
  }

  /// A push's raw data, from Android (any app state).
  void _onPushData(Map<String, String> data) {
    final call = PushCall.fromData(data);
    if (call != null) _onPush(call);
  }

  /// A push from the bridge: a call to ring, or one to stop ringing.
  void _onPush(PushCall call) {
    if (!_seenPushes.add('${call.kind.name}:${call.callId}')) return;
    if (call.kind == PushKind.cancel) {
      _onCancelPush(call);
    } else {
      _onIncomingPush(call);
    }
  }

  /// A call to ring. Shows the call screen and, when the app is signed out
  /// (it was closed), signs in right away, so the INVITE is already ringing
  /// here when the user taps Accept.
  void _onIncomingPush(PushCall call) {
    if (call.isExpired) {
      log('📲 Ignored a stale push for a call from ${call.caller}', LogType.info);
      return;
    }
    if (call.isTest) {
      callScreen.showIncoming(
        id: call.callId,
        caller: 'Test call',
        subtitle: 'The push reached this phone. Nothing will connect.',
        extra: call.toExtra(),
      );
      return;
    }
    if (call.isVobiz) {
      _onVobizHeldCall(call);
      return;
    }
    final ring = _inbound;
    if (ring != null && ring.id == call.callId) {
      // Already ringing over SIP, with its call screen.
      _ringingPushes[call.callId] = call;
      _callScreenPush ??= call;
      return;
    }
    final busyHere = client.callState != CallStateStatus.idle && client.callState != CallStateStatus.ended;
    if (call.lineBusy || busyHere) {
      // Call waiting: no full-screen ringing screen. It could not connect
      // while this call runs, and ending it would stop the running call's
      // service. The bridge's call_ended push says how it ended.
      _ringingPushes[call.callId] = call;
      callWaiting = call;
      log('📞 Call waiting: ${call.caller} is calling while you are on a call', LogType.warning);
      notifyListeners();
      return;
    }
    _ringingPushes[call.callId] = call;
    unawaited(_showPushedCall(call));
    if (client.isConnected) {
      log('📲 Push received for a call from ${call.caller}; already signed in, so the push server '
          'rings this phone now', LogType.info);
      // Already registered: say so now, or the bridge holds the caller for
      // its whole push wait before it dials.
      unawaited(_quietly(() => PushBridgeApi.registered(call)));
      return;
    }
    if (!_hasSavedSignIn) {
      log('📲 Call from ${call.caller}. Sign in to take it (no saved sign-in).', LogType.warning);
      return;
    }
    log('📲 Call from ${call.caller}: signing in now so it is ready when you answer', LogType.event);
    unawaited(connect());
  }

  Future<void> _showPushedCall(PushCall call) async {
    for (final active in await callScreen.active()) {
      if (active.id == call.callId) return;
    }
    await callScreen.showIncoming(
      id: call.callId,
      caller: call.displayCaller,
      subtitle: call.callee.isEmpty ? 'Vobiz call' : 'Calling ${call.callee}',
      extra: call.toExtra(),
    );
  }

  /// Stop ringing [call]: answered elsewhere, declined, or the caller hung
  /// up. Logs the outcome; only a call nobody answered is a missed call.
  void _onCancelPush(PushCall call) {
    final id = call.callId;
    final pushed = _ringingPushes.remove(id);
    _pendingMissed.remove(id)?.cancel();
    final ring = _inbound;
    final ours = ring != null && ring.id == id;
    // This phone has the call (its INVITE carried PushRef == call_id).
    if (ours && ring.answered) return;
    if (pushRefFromHeaders(client.callHeaders) == id && client.callState == CallStateStatus.active) return;
    final waiting = callWaiting?.callId == id;
    if (waiting) {
      callWaiting = null;
      notifyListeners();
    }
    if (_acceptedCall?.callId == id) _clearAcceptedCall();

    final screen = ours && _callScreenId != null ? _callScreenId! : id;
    if (waiting) {
      // Call waiting had no call screen.
    } else if (screen == _callScreenId) {
      _callScreenId = null;
      _callScreenAccepted = false;
      _callScreenPush = null;
    }
    if (!waiting) unawaited(_closeCallScreen(screen));
    if (ours && client.callState == CallStateStatus.incoming) {
      _inbound = null;
      client.rejectCall();
    }

    final outcome = call.answeredElsewhere
        ? CallOutcome.answeredElsewhere
        : call.reason == CancelReason.declined
            ? CallOutcome.declined
            : (waiting || call.reason == CancelReason.busy || (pushed?.lineBusy ?? false))
                ? CallOutcome.busy
                : CallOutcome.missed;
    log(switch (outcome) {
      CallOutcome.answeredElsewhere =>
        '📴 Answered on another device${call.answeredBy.isEmpty ? '' : ' (${call.answeredBy})'}',
      CallOutcome.declined => '📴 Declined on another device',
      _ => '📴 The caller hung up',
    }, LogType.warning);
    _logCall(CallRecord(
      id: id,
      inbound: true,
      party: pushed?.caller ?? (ours ? ring.party : ''),
      at: DateTime.now(),
      outcome: outcome,
    ));
  }

  // ── Calls Vobiz holds while its push wakes this phone ──────────────────────

  /// A push from Vobiz itself: its registrar holds the call (up to 30 s) until
  /// this phone claims it with a REGISTER carrying the push's hold reference.
  /// The SDK makes that claim: on the open connection when signed in, else on
  /// the sign-in this starts.
  void _onVobizHeldCall(PushCall call) {
    final sdk = call.sdkPush;
    if (sdk == null) return;
    _ringingPushes[call.callId] = call;
    final busyHere = client.callState != CallStateStatus.idle && client.callState != CallStateStatus.ended;
    if (busyHere) {
      // Vobiz does not hold calls for a phone that is registered, so this is a
      // race: claim it anyway, and the SDK turns it away busy at once.
      log('📞 ${call.displayCaller} is calling while you are on a call: they hear busy', LogType.warning);
      client.handleIncomingPush(sdk);
      return;
    }
    unawaited(_showPushedCall(call));
    client.handleIncomingPush(sdk);
    if (client.isConnected) {
      log('📲 Vobiz push: a call from ${call.displayCaller}. Signed in already: claiming it on this connection',
          LogType.info);
      return;
    }
    if (!_hasSavedSignIn) {
      log('📲 Call from ${call.displayCaller}. Sign in to take it (no saved sign-in).', LogType.warning);
      return;
    }
    log('📲 Vobiz push: a call from ${call.displayCaller}. Signing in to claim the call Vobiz is holding',
        LogType.event);
    unawaited(connect());
  }

  /// Accept on the call screen of a call Vobiz holds. The SDK answers it as
  /// soon as its INVITE arrives (at once if it already rings).
  Future<void> _acceptVobizHeldCall(PushCall call, String screenId) async {
    final sdk = call.sdkPush;
    if (sdk == null || !_takenCalls.add(call.callId)) return;
    _ringingPushes[call.callId] = call;
    _callScreenId = screenId;
    _callScreenAccepted = true;
    _callScreenPush = call;
    onTabRequest?.call(1);
    log('📲 Accepted the call from ${call.displayCaller} on the call screen', LogType.event);
    // Accept is the user's tap: the moment Android allows the call's
    // microphone service to start.
    _startCallService(outbound: false, caller: call.displayCaller);
    client.reportCallScreenAccepted(sdk);
    if (client.isConnected || status == PhoneStatus.connecting) {
      if (client.callState != CallStateStatus.incoming) log('Waiting for the call Vobiz is holding...', LogType.info);
      return;
    }
    if (!_hasSavedSignIn) {
      log('❌ Cannot take the call: no saved sign-in. Tick "Remember me" and connect once.', LogType.error);
      _endCallScreen();
      _stopCallService();
      return;
    }
    log('Signing in to take the call...', LogType.info);
    await connect();
  }

  /// Decline on the call screen of a call Vobiz holds that has not rung here
  /// yet. Vobiz has no way to decline a held call without claiming it, so the
  /// claim still goes and the SDK turns the call away when it arrives: the
  /// caller hears busy at once instead of ringing out the 30 s hold.
  Future<void> _declineVobizHeldCall(PushCall call) async {
    final sdk = call.sdkPush;
    if (sdk == null) return;
    _ringingPushes.remove(call.callId);
    log('📵 Declined the call from ${call.displayCaller}', LogType.warning);
    _logCall(CallRecord(
      id: call.callId,
      inbound: true,
      party: call.displayCaller,
      at: DateTime.now(),
      outcome: CallOutcome.declined,
    ));
    client.reportCallScreenDeclined(sdk);
    if (!client.isConnected && status != PhoneStatus.connecting && _hasSavedSignIn) {
      log('Signing in to turn the call away...', LogType.info);
      await connect();
    }
  }

  /// What became of a call Vobiz held: claimed, arrived, or never came.
  void _onPushCallUpdate(VobizPushCallUpdate update) {
    switch (update.status) {
      case VobizPushCallStatus.claiming:
        break;
      case VobizPushCallStatus.claimed:
        log('📲 Vobiz took the claim (REGISTER with X-Index/X-Label): the held call should arrive now',
            LogType.info);
      case VobizPushCallStatus.ringing:
        log('📲 The call Vobiz held arrived (Call-ID ${update.push.callId})', LogType.event);
      case VobizPushCallStatus.answering:
        break;
      case VobizPushCallStatus.declining:
        log('📵 Turning away the call declined on the call screen: the caller hears busy', LogType.warning);
      case VobizPushCallStatus.expired:
        final id = update.push.callId;
        final call = _ringingPushes.remove(id);
        final accepted = _callScreenAccepted && _callScreenId == id;
        log('📵 The call Vobiz held did not arrive before the push expired'
            '${accepted ? ' (it was accepted on the call screen)' : ''}', LogType.warning);
        if (_callScreenId == id) {
          _endCallScreen();
        } else {
          unawaited(_closeCallScreen(id));
        }
        if (accepted) _stopCallService();
        _logCall(CallRecord(
          id: id,
          inbound: true,
          party: call?.displayCaller ?? update.push.callerNumber,
          at: DateTime.now(),
          outcome: CallOutcome.missed,
        ));
    }
  }

  /// Turns "ring this phone through Vobiz push" on or off.
  Future<void> setVobizPush(bool on) async {
    vobizPush = on;
    await _prefs?.setBool(_kVobizPush, on);
    notifyListeners();
    if (on) {
      await requestCallPermissions();
      if (!rememberMe) {
        log('⚠️ Tick "Remember me" and sign in again: with the app closed, a call can only '
            'be answered if the app can sign itself in.', LogType.warning);
      }
      if (client.isConnected) {
        await _registerWithVobizPush();
      } else {
        vobizPushDetail = 'Connect to register this phone with Vobiz push.';
        notifyListeners();
      }
    } else {
      await _logoutFromVobizPush();
      notifyListeners();
    }
  }

  /// Saves the account Auth ID and Auth Token used to register this phone
  /// with Vobiz push (test only), with "Remember me".
  Future<void> setPushAccount({required String authId, required String authToken}) async {
    pushAuthId = authId.trim();
    pushAuthToken = authToken.trim();
    try {
      if (rememberMe && pushAuthId.isNotEmpty && pushAuthToken.isNotEmpty) {
        await _secure.write(key: _kPushAuthId, value: pushAuthId);
        await _secure.write(key: _kPushAuthToken, value: pushAuthToken);
      }
    } catch (e) {
      log('Could not save the push account on this device: $e', LogType.warning);
    }
    notifyListeners();
    if (vobizPush && client.isConnected) await _registerWithVobizPush();
  }

  /// Saves the caller ID and answer URL of the test call (not secret).
  Future<void> setVobizCallTest({required String from, required String answerUrl}) async {
    vobizCallFrom = from.replaceAll(RegExp(r'[^0-9]'), '');
    vobizCallAnswerUrl = answerUrl.trim();
    await _prefs?.setString(_kVobizCallFrom, vobizCallFrom);
    await _prefs?.setString(_kVobizCallAnswerUrl, vobizCallAnswerUrl);
    notifyListeners();
  }

  /// The account's headers for Vobiz push (test only): the push account
  /// fields, else the Zero-Config ones.
  Map<String, String>? _vobizPushHeaders() {
    final id = pushAuthId.trim().isNotEmpty ? pushAuthId.trim() : authId.trim();
    final token = pushAuthToken.trim().isNotEmpty ? pushAuthToken.trim() : authToken.trim();
    if (id.isEmpty || token.isEmpty) return null;
    return VobizPushDevices.accountHeaders(id, token);
  }

  /// This install's id with Vobiz push: made once, then kept.
  Future<String> _installId() async {
    final known = _pushDeviceId ?? _prefs?.getString(_kPushInstallId);
    if (known != null && known.isNotEmpty) return _pushDeviceId = known;
    final random = Random.secure();
    final id = 'vobiz-example-${List<String>.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _pushDeviceId = id;
    await _prefs?.setString(_kPushInstallId, id);
    return id;
  }

  Future<void> _registerWithVobizPush({bool quiet = false}) async {
    final user = client.sipUsername;
    if (!vobizPush || user == null || !client.isConnected) return;
    final headers = _vobizPushHeaders();
    if (headers == null) {
      vobizPushState = PushState.failed;
      vobizPushDetail = 'Enter the account Auth ID and Auth Token below (test only) to register this '
          'phone with Vobiz push.';
      log('❌ Vobiz push: $vobizPushDetail', LogType.error);
      notifyListeners();
      return;
    }
    if (!push.available) {
      vobizPushState = PushState.failed;
      vobizPushDetail = push.problem ?? 'Firebase is not set up in this build.';
      notifyListeners();
      return;
    }
    vobizPushState = PushState.registering;
    notifyListeners();
    final token = await push.token();
    if (token == null) {
      vobizPushState = PushState.failed;
      vobizPushDetail = 'Firebase gave no push token (no network, or Google Play services missing).';
      log('❌ Vobiz push: $vobizPushDetail', LogType.error);
      notifyListeners();
      return;
    }
    final devices = VobizPushDevices(authHeaders: () => headers, httpClient: _http);
    try {
      final device = VobizPushDevice(
        deviceId: await _installId(),
        pushToken: token,
        sipUsername: user,
        appBundleId: appBundleId,
        appVersion: 'example',
        sdkVersion: VobizClient.sdkVersion,
      );
      await devices.register(device);
      vobizPushState = PushState.ready;
      vobizPushDetail = 'This phone is registered with Vobiz push for calls to $user. With the app '
          'closed, a call to $user wakes it once Vobiz holds such calls for push.';
      if (!quiet) log('📲 Vobiz push: this phone is registered for calls to $user', LogType.success);
    } on VobizException catch (e) {
      vobizPushState = PushState.failed;
      vobizPushDetail = e.message;
      log('❌ Vobiz push: ${e.message}', LogType.error);
    } finally {
      devices.close();
    }
    notifyListeners();
  }

  Future<void> _logoutFromVobizPush() async {
    final id = _pushDeviceId ?? _prefs?.getString(_kPushInstallId);
    final wasOn = vobizPushState != PushState.off;
    vobizPushState = PushState.off;
    vobizPushDetail = '';
    if (!wasOn || id == null) return;
    final headers = _vobizPushHeaders();
    if (headers == null) {
      log('⚠️ Vobiz push: no account Auth ID and Auth Token to remove this phone with; it may still be '
          'pushed until Firebase replaces its token', LogType.warning);
      return;
    }
    final devices = VobizPushDevices(authHeaders: () => headers, httpClient: _http);
    try {
      await devices.logout(id);
      log('📴 Vobiz push: this phone is no longer pushed for calls', LogType.info);
    } on VobizException catch (e) {
      log('⚠️ Vobiz push: ${e.message}', LogType.warning);
    } finally {
      devices.close();
    }
  }

  /// A real call to this phone's SIP user through Vobiz's Call API, to try the
  /// whole path: Vobiz holds the call, pushes this phone, and the app claims it.
  ///
  /// Pushes are sent by Vobiz's registrar alone (the push service refuses
  /// everyone else), so there is no pretend push: this is the real thing. The
  /// registrar pushes when it still has this phone's registration but its
  /// connection is gone, as after Android kills the app. So the connection is
  /// dropped first WITHOUT signing off (a sign-off deletes the registration,
  /// and the call would then be refused), keeping the saved sign-in and the
  /// push registration, and the call follows a moment later, well inside the
  /// few seconds before Vobiz's keep-alive notices.
  Future<void> callThisPhoneThroughVobiz() async {
    if (vobizCallPlacing) return;
    final user = client.sipUsername;
    final headers = _vobizPushHeaders();
    if (user == null || headers == null || vobizPushState != PushState.ready || !client.isConnected) {
      log('Connect, and turn on "Receive calls through Vobiz push", first', LogType.error);
      return;
    }
    final from = vobizCallFrom.replaceAll(RegExp(r'[^0-9]'), '');
    if (from.length < 8) {
      log('Enter the caller ID: a number on this Vobiz account, such as 14155551234', LogType.error);
      return;
    }
    final answer = Uri.tryParse(vobizCallAnswerUrl.trim());
    if (answer == null || answer.scheme != 'https' || answer.host.isEmpty) {
      log('Enter an https:// answer URL that returns Vobiz XML (Vobiz fetches it when the call is answered)',
          LogType.error);
      return;
    }
    vobizCallPlacing = true;
    notifyListeners();
    final web = _http ?? http.Client();
    try {
      // Gone the way a killed app goes: no sign-off, so Vobiz keeps the
      // registration; the saved sign-in and the push registration stay.
      _loginTimeout?.cancel();
      _reconnecting = false;
      await _stopTokenSession();
      await client.disconnect(unregister: false);
      _resetCallState(registered: false);
      _setStatus(PhoneStatus.offline, 'Offline: waiting for a call through Vobiz push');
      log('🧪 Connection dropped without signing off, as when Android kills the app. Calling this phone '
          'through Vobiz…', LogType.event);
      // A moment for the closed socket to reach the registrar.
      await Future<void>.delayed(const Duration(seconds: 1));
      final response = await web
          .post(Uri.parse('https://api.vobiz.ai/api/v1/Account/${Uri.encodeComponent(headers['X-Auth-ID']!)}/Call/'),
              headers: <String, String>{...headers, 'Content-Type': 'application/json'},
              body: jsonEncode(<String, Object>{
                'from': from,
                'to': 'sip:${VobizClient.endpointUsername(user)}@registrar.vobiz.ai',
                'answer_url': answer.toString(),
                'answer_method': 'POST',
                'time_limit': 120,
              }))
          .timeout(const Duration(seconds: 15));
      final reply = response.body.replaceAll(RegExp(r'\s+'), ' ');
      if (response.statusCode >= 200 && response.statusCode < 300) {
        log('🧪 Vobiz is calling this phone ($reply). Vobiz should push it now, and the app sign back in '
            'to take the call.', LogType.event);
      } else {
        log('❌ Test call: HTTP ${response.statusCode} $reply', LogType.error);
      }
    } catch (e) {
      log('❌ Test call: $e', LogType.error);
    } finally {
      if (_http == null) web.close();
      vobizCallPlacing = false;
      notifyListeners();
    }
  }

  /// Declines the waiting call: the caller hears busy.
  Future<void> declineWaitingCall() async {
    final call = callWaiting;
    if (call == null) return;
    callWaiting = null;
    _ringingPushes.remove(call.callId);
    log('📵 Declined the waiting call from ${call.caller}', LogType.warning);
    _logCall(CallRecord(
      id: call.callId,
      inbound: true,
      party: call.caller,
      at: DateTime.now(),
      outcome: CallOutcome.declined,
    ));
    notifyListeners();
    await _tellBridgeDeclined(call);
  }

  bool get _hasSavedSignIn => switch (authTab) {
        AuthTab.zeroConfig => authId.isNotEmpty && authToken.isNotEmpty,
        AuthTab.sipDirect => sipUsername.isNotEmpty && sipPassword.isNotEmpty,
        // Nothing secret is kept: a token is fetched again at sign-in.
        AuthTab.accessToken => rememberMe && (tokenServerUrl.isNotEmpty || bridgeConfig != null),
      };

  /// Opened by Accept on the call screen while the app was closed: take it.
  Future<void> _resumeAcceptedCall() async {
    for (final active in await callScreen.active()) {
      final pushed = PushCall.fromExtra(active.extra);
      if (pushed == null || !active.isAccepted) continue;
      final expires = pushed.expiresAt;
      if (expires != null && DateTime.now().isAfter(expires.add(const Duration(seconds: 30)))) {
        await _closeCallScreen(active.id);
        continue;
      }
      _callScreenId = active.id;
      _callScreenAccepted = true;
      _callScreenPush = pushed;
      await _takeAcceptedCall(pushed, active.id);
      return;
    }
  }

  /// The user accepted a pushed call. Sign in if needed, then answer when
  /// the bridge rings this endpoint again.
  Future<void> _takeAcceptedCall(PushCall call, String screenId) async {
    if (call.isVobiz) return _acceptVobizHeldCall(call, screenId);
    if (!_takenCalls.add(call.callId)) return;
    onTabRequest?.call(1);
    if (call.isTest) {
      log('✅ Test call accepted. The push woke this phone and the call screen worked; a real '
          'call would now sign in and connect.', LogType.success);
      _callScreenId = null;
      _callScreenAccepted = false;
      await _closeCallScreen(screenId);
      return;
    }
    log('📲 Accepted the call from ${call.caller} on the call screen', LogType.event);
    unawaited(_acceptOnBridge(call));
    // Accept is the user's tap with the app coming on screen: the moment
    // Android allows the call's microphone service to start.
    _startCallService(outbound: false, caller: call.caller);
    if (client.callState == CallStateStatus.incoming &&
        pushRefFromHeaders(client.callHeaders) == call.callId) {
      await answer();
      return;
    }
    _acceptedCall = call;
    _acceptedTimer?.cancel();
    _acceptedTimer = Timer(const Duration(seconds: 60), () {
      if (_acceptedCall == null) return;
      _clearAcceptedCall();
      log('❌ The accepted call never arrived. Is the push bridge still running?', LogType.error);
      _endCallScreen();
      _stopCallService();
    });
    if (client.isConnected) {
      log('Waiting for the call to arrive...', LogType.info);
      return;
    }
    if (!_hasSavedSignIn) {
      log('❌ Cannot take the call: no saved sign-in. Tick "Remember me" and connect once.',
          LogType.error);
      _clearAcceptedCall();
      _endCallScreen();
      _stopCallService();
      return;
    }
    if (status != PhoneStatus.connecting) log('Signing in to take the call...', LogType.info);
    await connect();
  }

  /// Tells the bridge about the Accept. If the call is already over (the
  /// caller hung up, another device answered), stop waiting for it.
  Future<void> _acceptOnBridge(PushCall call) async {
    PerCallReply reply = const PerCallReply();
    await _quietly(() async => reply = await PushBridgeApi.accept(call));
    if (!reply.finished || _acceptedCall?.callId != call.callId) return;
    _clearAcceptedCall();
    log('📴 That call is already over${reply.reason.isEmpty ? '' : ' (${reply.reason})'}', LogType.warning);
    _endCallScreen();
    _stopCallService();
  }

  void _clearAcceptedCall() {
    _acceptedTimer?.cancel();
    _acceptedTimer = null;
    _acceptedCall = null;
  }

  /// Signed in after a push woke the app: tell the bridge, so it dials now
  /// rather than at the end of its push wait.
  void _reportRegisteredForPushes() {
    for (final call in _ringingPushes.values.toList()) {
      if (call.isTest || call.lineBusy) continue;
      log('📲 Registered while ${call.caller} rings: asking the push server to ring this phone now',
          LogType.info);
      unawaited(_quietly(() => PushBridgeApi.registered(call)));
    }
  }

  // ── Call service and call log ───────────────────────────────────────────────

  /// Keeps the microphone and the app alive for the call, also in the
  /// background (Android foreground service, types phoneCall|microphone).
  void _startCallService({required bool outbound, String? caller}) {
    if (_callServiceOn) return;
    _callServiceOn = true;
    unawaited(platform.startCallService(caller: caller ?? remoteParty, outbound: outbound));
  }

  void _stopCallService() {
    if (!_callServiceOn) return;
    _callServiceOn = false;
    unawaited(platform.stopCallService());
  }

  /// Logs how a call ended, once per call, with a "Missed call"
  /// notification when nobody answered it.
  void _logCall(CallRecord record) {
    if (!history.add(record)) return;
    if (record.outcome.notifies) {
      unawaited(platform.showMissedCall(
        id: record.id,
        caller: record.party.isEmpty ? 'Unknown caller' : record.party,
        detail: record.outcome == CallOutcome.busy ? 'While you were on another call' : null,
      ));
    }
  }

  /// The inbound call's SIP side ended: log how.
  void _finishInbound(String? reason) {
    final ring = _inbound;
    _inbound = null;
    if (ring == null) return;
    CallOutcome? outcome;
    if (ring.answered) {
      outcome = CallOutcome.answered;
    } else if (ring.declinedHere) {
      outcome = CallOutcome.declined;
    } else if (reasonMeansAnsweredElsewhere(reason)) {
      outcome = CallOutcome.answeredElsewhere;
    }
    if (outcome == null && ring.fromBridge) {
      // One ringing attempt ended. The bridge may ring again, and its push
      // says how the call ended; without either, it is missed.
      _pendingMissed.remove(ring.id)?.cancel();
      _pendingMissed[ring.id] = Timer(missedGrace, () {
        _pendingMissed.remove(ring.id);
        if (_inbound?.id == ring.id) return;
        _logCall(CallRecord(
          id: ring.id,
          inbound: true,
          party: ring.party,
          at: ring.at,
          outcome: CallOutcome.missed,
        ));
      });
      return;
    }
    _logCall(CallRecord(
      id: ring.id,
      inbound: true,
      party: ring.party,
      at: ring.at,
      outcome: outcome ?? CallOutcome.missed,
      duration: ring.answered ? callDuration : Duration.zero,
    ));
  }

  Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      log('⚠️ Could not reach the push server: $e', LogType.warning);
    }
  }

  // ── SIP header editor ───────────────────────────────────────────────────────

  void addHeaderRow({String name = VobizSipHeaders.prefix, String value = ''}) {
    headerRows.add(HeaderRow(_rowId++, name: name, value: value));
    _saveHeaderPrefs();
    notifyListeners();
  }

  void updateHeaderRow(int id, {String? name, String? value}) {
    final row = headerRows.where((r) => r.id == id).firstOrNull;
    if (row == null) return;
    if (name != null) row.name = name;
    if (value != null) row.value = value;
    _saveHeaderPrefs();
    notifyListeners();
  }

  void removeHeaderRow(int id) {
    headerRows.removeWhere((r) => r.id == id);
    _saveHeaderPrefs();
    notifyListeners();
  }

  void setRecordCall(bool value) {
    recordCall = value;
    _saveHeaderPrefs();
    notifyListeners();
  }

  void setSendHeadersOnTransfer(bool value) {
    sendHeadersOnTransfer = value;
    _saveHeaderPrefs();
    notifyListeners();
  }

  void clearCallHeaders() {
    callHeaders.clear();
    notifyListeners();
  }

  String callHeadersJson() => const JsonEncoder.withIndent('  ')
      .convert(callHeaders.map((r) => r.toJson()).toList());

  // ── Trace ───────────────────────────────────────────────────────────────────

  void log(String message, LogType type) {
    logs.add(LogEntry(message, type));
    if (logs.length > _maxLogs) logs.removeRange(0, logs.length - _maxLogs);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  String logsText() => logs.map((l) => '[${l.clock}] ${l.message}').join('\n');

  // ── Theme ───────────────────────────────────────────────────────────────────

  void setThemeMode(ThemeMode mode) {
    theme.value = mode;
    _prefs?.setString(_kTheme, mode.name);
    notifyListeners();
  }

  // ── SDK events ──────────────────────────────────────────────────────────────

  void _onConnection(ConnectionEvent e) {
    if (e.registrationState == RegistrationState.registered) {
      // Signed out meanwhile: a late registration must not sign back in.
      if (status == PhoneStatus.offline && statusText == 'Disconnected') return;
      _loginTimeout?.cancel();
      _reconnecting = false;
      connectError = null;
      missingFields = <String>{};
      final wasConnecting = status != PhoneStatus.online &&
          status != PhoneStatus.inCall &&
          status != PhoneStatus.ringing;
      if (wasConnecting) {
        log('Registered successfully as ${client.sipUsername ?? connectedAs}', LogType.success);
        _setStatus(PhoneStatus.online, 'Registered');
        onTabRequest?.call(1);
        _registerWithBridge();
        _registerWithVobizPush();
        _reportRegisteredForPushes();
        if (_acceptedCall != null) log('Waiting for the accepted call to arrive...', LogType.info);
      }
      return;
    }
    if (e.registrationState == RegistrationState.failed &&
        e.connectionState == ConnectionStateStatus.failed &&
        (e.message ?? '').startsWith('Registration failed')) {
      _loginTimeout?.cancel();
      _reconnecting = false;
      connectError =
          'Login failed: ${e.message?.replaceFirst('Registration failed: ', '') ?? 'Unknown reason'}';
      log(connectError!, LogType.error);
      _setStatus(PhoneStatus.error, 'Auth Failed');
      return;
    }
    final message = e.message ?? '';
    if (e.connectionState == ConnectionStateStatus.disconnected &&
        message.startsWith('Socket error') &&
        status == PhoneStatus.online) {
      log('Connection lost — reconnecting ($message)', LogType.warning);
      _reconnecting = true;
      _setStatus(PhoneStatus.connecting, 'Reconnecting...');
      _startLoginTimeout();
    }
  }

  void _onCall(CallEvent e) {
    switch (e.state) {
      case CallStateStatus.incoming:
        // The push bridge's caller ID can be the Vobiz number; it passes the
        // real caller in a header.
        remoteParty = callerFromHeaders(e.headers) ?? e.remoteIdentity ?? e.message ?? 'Unknown';
        _failedCallId = null;
        log('📲 Incoming call from: $remoteParty', LogType.event);
        activeHeaders = null;
        _recordHeaders('incoming call', e);
        final ref = pushRefFromHeaders(e.headers);
        // A call Vobiz held while its push woke this phone: the push's call
        // screen is already showing (and may have been accepted).
        final held = client.isPushedCall(e.callId) ? _ringingPushes[e.sipCallId ?? ''] : null;
        final id = ref ?? held?.callId ?? e.callId;
        _pendingMissed.remove(id)?.cancel();
        _inbound = _Inbound(id: id, party: remoteParty, fromBridge: ref != null);
        if (held != null) {
          _callScreenId ??= held.callId;
          _callScreenPush = held;
          onTabRequest?.call(1);
          if (_callScreenAccepted && _callScreenId == held.callId) {
            // The SDK answers it: it was accepted on the call screen.
            log('📲 The call Vobiz held for this phone arrived: answering (accepted on the call screen)',
                LogType.event);
            _setStatus(PhoneStatus.ringing, 'Answering...');
            break;
          }
          showIncoming = true;
          _setStatus(PhoneStatus.ringing, 'Incoming Call');
          break;
        }
        if (_isAcceptedCall(e)) {
          log('📲 This is the call you accepted on the call screen — answering', LogType.event);
          _acceptedTimer?.cancel();
          _acceptedCall = null;
          _setStatus(PhoneStatus.ringing, 'Answering...');
          onTabRequest?.call(1);
          answer();
          break;
        }
        showIncoming = true;
        _setStatus(PhoneStatus.ringing, 'Incoming Call');
        onTabRequest?.call(1);
        // Also with the app open: the system call screen is what rings and
        // vibrates. In the foreground it shows as a heads-up notification.
        _showCallScreenForSip(e);
        break;
      case CallStateStatus.connecting:
        _failedCallId = null;
        if (e.direction == CallDirection.inbound) {
          _setStatus(PhoneStatus.ringing, 'Answering...');
        } else {
          _setStatus(PhoneStatus.inCall, 'Calling...');
        }
        break;
      case CallStateStatus.ringing:
        if (e.message == 'Invite sent') break;
        log('📞 Ringing... (${e.callUuid ?? ''})', LogType.event);
        _setStatus(PhoneStatus.ringing, 'Ringing...');
        break;
      case CallStateStatus.active:
        // The SDK reports a dropped connection, and its recovery, as events
        // of the connected call. They are not new answers.
        if (e.reason == 'reconnecting') {
          log('📶 Connection lost: reconnecting (the call ends if it is not back in 12 s)',
              LogType.warning);
          _setStatus(PhoneStatus.inCall, 'Reconnecting...');
          break;
        }
        if (e.reason == 'reconnected') {
          log('📶 Reconnected: the audio is back', LogType.success);
          _setStatus(PhoneStatus.inCall, 'In Call');
          break;
        }
        showIncoming = false;
        log('✅ Call answered! (${e.callUuid ?? ''})', LogType.success);
        _recordHeaders('answer', e);
        _setStatus(PhoneStatus.inCall, 'In Call');
        _startCallTimers();
        if (e.direction == CallDirection.inbound || client.callDirection == CallDirection.inbound) {
          _inbound?.answered = true;
        } else {
          _outboundAnswered = true;
        }
        // The app's own service carries the call from here, for calls
        // answered anywhere. A call screen accepted in the plugin is closed:
        // the plugin's service then stops, and no longer anything else.
        _startCallService(outbound: e.direction != CallDirection.inbound);
        if (_callScreenId != null && _callScreenAccepted) _endCallScreen();
        // A call through the push bridge: report the bridge's own id for it
        // (PushRef, the caller's leg), which the bridge can act on. The
        // X-Calluuid on the INVITE to this phone is not a call Vobiz's
        // live-call API knows.
        _startAliveReports(pushRefFromHeaders(e.headers) ??
            pushRefFromHeaders(client.callHeaders) ??
            e.callUuid ??
            client.lastCallUuid);
        break;
      case CallStateStatus.failed:
        _failedCallId = e.callId;
        final code = e.sipCode != null ? ' · SIP ${e.sipCode}' : '';
        log('❌ Call failed: ${e.reason ?? e.message ?? 'Unknown'}$code', LogType.error);
        _recordHeaders('failure', e);
        _recordRequested = false;
        break;
      case CallStateStatus.ended:
        _stopAliveReports();
        if (_failedCallId != e.callId) {
          log('📴 Call ended: ${e.reason ?? e.message ?? 'Terminated'}', LogType.warning);
          _recordHeaders('hangup', e);
        }
        _failedCallId = null;
        _stopCallService();
        final keepScreen = _keepRingingForPush();
        if (!_outboundActive) {
          _finishInbound(e.reason ?? e.message);
        } else {
          _outboundActive = false;
          _logCall(CallRecord(
            id: e.callUuid ?? e.callId,
            inbound: false,
            party: remoteParty,
            at: DateTime.now().subtract(callDuration),
            outcome: _outboundAnswered ? CallOutcome.outgoing : CallOutcome.failed,
            duration: callDuration,
          ));
          _outboundAnswered = false;
        }
        if (_recordRequested) {
          _recordRequested = false;
          final uuid = e.callUuid ?? client.lastCallUuid;
          if (uuid != null) {
            log('🎙️ Recording requested — waiting for the callback...', LogType.info);
            _pollRecording(uuid);
          } else {
            log('🎙️ Vobiz reported no CallUUID for this call, so its recording '
                'cannot be matched.', LogType.warning);
          }
        }
        if (keepScreen) {
          // The bridge rings again (its push screen keeps ringing meanwhile).
          _callScreenId = null;
          _callScreenPush = null;
        } else {
          _endCallScreen();
        }
        _resetCallState();
        break;
      case CallStateStatus.idle:
      case CallStateStatus.outgoing:
      case CallStateStatus.held:
        break;
    }
  }

  void _onError(ErrorEvent e) {
    // Call failures and setup failures are already reported, with more detail.
    const shown = <String>{
      'call_failed', 'setup_failed', 'registration_failed', 'transfer_failed',
    };
    if (shown.contains(e.code)) return;
    log('⚠️ ${e.code}: ${e.message}', LogType.warning);
  }

  /// Keeps one record per call, merging the headers each event reports.
  void _recordHeaders(String label, CallEvent e) {
    if (e.headers.isEmpty) return;
    final direction = e.direction ?? CallDirection.outbound;
    final verb = direction == CallDirection.inbound ? '📥 Received' : '📤 Sent';
    log('$verb on $label: ${_fmtHeaders(e.headers)}', LogType.event);

    final key = e.callUuid ?? e.callId;
    final existing = callHeaders.where((r) => r.id == key).firstOrNull;
    if (existing != null) {
      existing.headers.addAll(e.headers);
      if (!existing.events.contains(label)) existing.events.add(label);
      if (existing.from.isEmpty && direction == CallDirection.inbound) {
        existing.from = e.remoteIdentity ?? '';
      }
      activeHeaders = existing;
    } else {
      final record = CallHeaderRecord(
        id: key,
        at: DateTime.now(),
        direction: direction,
        from: direction == CallDirection.inbound ? (e.remoteIdentity ?? '') : '',
        events: <String>[label],
        headers: Map<String, String>.of(e.headers),
      );
      callHeaders.insert(0, record);
      if (callHeaders.length > 25) callHeaders.removeLast();
      activeHeaders = record;
    }
  }

  Future<void> _pollRecording(String callUuid) async {
    final recording = await client.waitForRecording(callUuid);
    if (recording != null) {
      log('🎙️ Recording ready'
          '${recording.durationSecs != null ? ' (${recording.durationSecs}s)' : ''}: '
          '${recording.url}', LogType.success);
    } else {
      log('🎙️ No recording callback yet — check the server console for the payload.',
          LogType.warning);
    }
  }

  // ── Call state ──────────────────────────────────────────────────────────────

  void _startCallTimers() {
    _stopCallTimers();
    callDuration = Duration.zero;
    latency
      ..clear()
      ..addAll(List<double?>.filled(20, null));
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      callDuration += const Duration(seconds: 1);
      _tick();
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final stats = await client.getCallStats();
      if (latency.isNotEmpty) latency.removeAt(0);
      latency.add(stats?.rttMs);
      _tick();
    });
  }

  /// A bridge call whose SIP attempt ended unanswered while its push screen
  /// still rings: the bridge rings this phone again, so keep the screen.
  bool _keepRingingForPush() {
    final ring = _inbound;
    return ring != null &&
        !ring.answered &&
        !ring.declinedHere &&
        !_callScreenAccepted &&
        _ringingPushes.containsKey(ring.id) &&
        _callScreenId == ring.id;
  }

  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  void _tick() => callTicker.notifyListeners();

  void _stopCallTimers() {
    _callTimer?.cancel();
    _callTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  void _resetCallState({bool registered = true}) {
    _stopCallTimers();
    _stopAliveReports(ended: false);
    callDuration = Duration.zero;
    activeHeaders = null;
    showIncoming = false;
    isMuted = false;
    speakerOn = false;
    transferStatus = TransferStatus.idle;
    transferError = '';
    transferNumber = '';
    transferUser = '';
    if (registered && client.isConnected) {
      _setStatus(PhoneStatus.online, 'Registered');
    } else if (registered &&
        (status == PhoneStatus.inCall || status == PhoneStatus.ringing) &&
        client.connectionState == ConnectionStateStatus.reconnecting) {
      // The call ended while the network is down (the SDK gave up, the far
      // end's BYE arrived as it dropped, or an outgoing call was still
      // ringing). Leave the call screen and show the reconnect: registering
      // again (_onConnection) leaves a call screen alone, but shows
      // Registered from here.
      _setStatus(PhoneStatus.connecting, 'Reconnecting...');
    } else {
      notifyListeners();
    }
  }

  /// Reports "alive" to the push bridge every second while a call is up. A
  /// phone that loses its network cannot tell anyone; the bridge notices the
  /// reports stop and has Vobiz beep to the other party, then ends the call
  /// if the SDK's 12 s reconnect window passes. Needs the push server.
  void _startAliveReports(String? callUuid) {
    _stopAliveReports(ended: false);
    final config = bridgeConfig;
    final token = _bridgeDeviceToken;
    if (!receiveCalls || config == null || token == null || callUuid == null) return;
    _aliveCallUuid = callUuid;
    _aliveApi = PushBridgeApi(config, deviceToken: token);
    _aliveTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendAlive());
    _sendAlive();
  }

  Future<void> _sendAlive() async {
    final api = _aliveApi;
    final uuid = _aliveCallUuid;
    if (api == null || uuid == null || _aliveInFlight) return;
    _aliveInFlight = true;
    try {
      await api.callAlive(uuid);
    } catch (_) {
      // Offline, or the bridge is unreachable: the missing reports are the signal.
    } finally {
      _aliveInFlight = false;
    }
  }

  void _stopAliveReports({bool ended = true}) {
    _aliveTimer?.cancel();
    _aliveTimer = null;
    final api = _aliveApi;
    final uuid = _aliveCallUuid;
    _aliveApi = null;
    _aliveCallUuid = null;
    if (api == null) return;
    if (ended && uuid != null) {
      unawaited(api.callEnded(uuid).catchError((Object _) {}).whenComplete(api.close));
    } else {
      api.close();
    }
  }

  void _setStatus(PhoneStatus next, String text) {
    status = next;
    statusText = text;
    notifyListeners();
  }

  static String _fmtHeaders(Map<String, String> headers) =>
      headers.entries.map((e) => '${e.key}: ${e.value}').join('  |  ');

  // ── Persistence ─────────────────────────────────────────────────────────────

  void _loadPrefs() {
    final prefs = _prefs;
    if (prefs == null) return;
    final theme = prefs.getString(_kTheme);
    this.theme.value = ThemeMode.values.where((m) => m.name == theme).firstOrNull ?? ThemeMode.system;
    authTab = switch (prefs.getString(_kMode)) {
      'sip' => AuthTab.sipDirect,
      'token' => AuthTab.accessToken,
      _ => AuthTab.zeroConfig,
    };
    webhookUrl = prefs.getString(_kWebhook) ?? SdkConfig.defaultWebhookUrl;
    tokenServerUrl = prefs.getString(_kTokenServer) ?? '';
    tokenUser = prefs.getString(_kTokenUser) ?? '';
    rememberMe = prefs.getBool(_kRemember) ?? true;
    receiveCalls = prefs.getBool(_kReceiveCalls) ?? false;
    vobizPush = prefs.getBool(_kVobizPush) ?? false;
    vobizCallFrom = prefs.getString(_kVobizCallFrom) ?? '';
    vobizCallAnswerUrl = prefs.getString(_kVobizCallAnswerUrl) ?? '';
    final cli = prefs.getString(_kCallerId);
    if (cli != null && cli.startsWith('+')) {
      final split = splitE164(cli);
      if (split != null) {
        callerIdIso = split.country.iso;
        callerIdNumber = split.national;
      }
    }
    final saved = prefs.getString(_kHeaders);
    if (saved != null) {
      try {
        final json = jsonDecode(saved) as Map<String, dynamic>;
        for (final row in (json['rows'] as List? ?? const <Object>[]).whereType<Map>()) {
          headerRows.add(HeaderRow(_rowId++,
              name: '${row['key'] ?? ''}', value: '${row['value'] ?? ''}'));
        }
        recordCall = json['record'] == true;
        if (json['transferHeaders'] is bool) {
          sendHeadersOnTransfer = json['transferHeaders'] as bool;
        }
      } catch (_) {}
    }
  }

  void _saveHeaderPrefs() {
    _prefs?.setString(
      _kHeaders,
      jsonEncode(<String, Object>{
        'rows': headerRows.map((r) => <String, String>{'key': r.name, 'value': r.value}).toList(),
        'record': recordCall,
        'transferHeaders': sendHeadersOnTransfer,
      }),
    );
  }

  /// The push bridge line carries the bridge's key, so it lives in secure
  /// storage too.
  Future<void> _loadPushServer() async {
    try {
      pushServer = await _secure.read(key: _kPushServer) ?? '';
      _bridgeDeviceToken = await _secure.read(key: _kPushDevice);
    } catch (e) {
      log('Could not read the saved push server: $e', LogType.warning);
    }
    if (bridgeConfig == null) receiveCalls = false;
  }

  Future<void> _loadSavedCredentials() async {
    if (!rememberMe) return;
    try {
      authId = await _secure.read(key: _kAuthId) ?? '';
      authToken = await _secure.read(key: _kAuthToken) ?? '';
      sipUsername = await _secure.read(key: _kSipUser) ?? '';
      sipPassword = await _secure.read(key: _kSipPass) ?? '';
      pushAuthId = await _secure.read(key: _kPushAuthId) ?? '';
      pushAuthToken = await _secure.read(key: _kPushAuthToken) ?? '';
    } catch (e) {
      log('Could not read saved credentials: $e', LogType.warning);
    }
  }

  /// "Remember me" keeps the credentials in the platform's secure storage
  /// (Keychain / Keystore). Unticked, anything saved earlier is removed.
  Future<void> _saveCredentials() async {
    final prefs = _prefs;
    await prefs?.setString(_kMode, switch (authTab) {
      AuthTab.sipDirect => 'sip',
      AuthTab.accessToken => 'token',
      AuthTab.zeroConfig => 'api',
    });
    await prefs?.setBool(_kRemember, rememberMe);
    await prefs?.setString(_kWebhook, webhookUrl.trim());
    await prefs?.setString(_kTokenServer, tokenServerUrl.trim());
    await prefs?.setString(_kTokenUser, tokenUser.trim());
    if (callerId.isNotEmpty) await prefs?.setString(_kCallerId, callerId);
    try {
      if (!rememberMe) {
        for (final key in <String>[_kAuthId, _kAuthToken, _kSipUser, _kSipPass]) {
          await _secure.delete(key: key);
        }
        return;
      }
      if (authTab == AuthTab.zeroConfig) {
        await _secure.write(key: _kAuthId, value: authId.trim());
        await _secure.write(key: _kAuthToken, value: authToken.trim());
      } else if (authTab == AuthTab.sipDirect) {
        await _secure.write(key: _kSipUser, value: sipUsername.trim());
        await _secure.write(key: _kSipPass, value: sipPassword);
      }
      // An access token is never stored: the next sign-in fetches a fresh one.
    } catch (e) {
      log('Could not save credentials on this device: $e', LogType.warning);
    }
  }
}

/// The inbound call ringing or connected here.
class _Inbound {
  _Inbound({required this.id, required this.party, required this.fromBridge}) : at = DateTime.now();

  /// The bridge's call id (PushRef), or the SIP Call-ID without one.
  final String id;
  final String party;
  final DateTime at;

  /// Rung by the push bridge, which may ring again after an attempt ends.
  final bool fromBridge;
  bool answered = false;
  bool declinedHere = false;
}
