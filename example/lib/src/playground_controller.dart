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

/// Whether Vobiz push knows this phone.
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
/// app (the sample server's `<Dial><User>`), the caller is the A-leg and the
/// app the B-leg, so "move me" is `bleg`.
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
    this.demoTools = kDemoTools,
    this.allowHttp = kAllowHttp,
  })  : client = client ?? createPlaygroundClient(demoTools: demoTools),
        _http = httpClient,
        _secure = secureStorage ?? const FlutterSecureStorage(),
        push = push ?? PushService.unavailable('Push is not set up in this build.'),
        callScreen = callScreen ?? const CallScreenApi(),
        platform = platform ?? CallPlatform(),
        authTab = demoTools ? AuthTab.zeroConfig : AuthTab.sipDirect;

  /// Whether this build has the demo and test-only tools ([kDemoTools]):
  /// Zero-Config sign-in, typing account credentials for Vobiz push sign-up,
  /// and "Call this phone through Vobiz". Without them nothing sends the
  /// account's Auth ID or Auth Token anywhere.
  final bool demoTools;

  /// Whether a plain http:// sample server or token server is accepted
  /// ([kAllowHttp]: not in release builds).
  final bool allowHttp;

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
  /// Zero-Config only with [demoTools].
  AuthTab authTab;
  String authId = '';
  String authToken = '';
  String sipUsername = '';
  String sipPassword = '';
  bool rememberMe = true;
  String webhookUrl = SdkConfig.defaultWebhookUrl;

  /// Access token sign-in: where to POST for a token (the Vobiz WebRTC demo's
  /// `/token`, or your own). Empty: the sample server's `/token`.
  String tokenServerUrl = '';

  /// The user id (`sub`) to ask the sample server's `/token` for. Empty: its
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

  // Connection watch: during a call the sample server gets an "alive" report
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

  // ── Conference (sample server) ──────────────────────────────────────────────
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
  String? _conferenceKey;

  /// The current call's conference, or null when it is not one.
  VobizConferenceState? get conference => _conference?.state.value;

  /// Who the conference sheet will dial: an E.164 number or a SIP username.
  String get conferenceDestination => conferenceTarget == TransferTarget.user
      ? VobizClient.endpointUsername(conferenceUser.trim())
      : '${findCountry(conferenceIso).dial}$conferenceNumber';

  /// Why the conference controls cannot be used, or null when they can. The
  /// sample server holds the Auth Token that moves calls into a room and
  /// dials people.
  String? get conferenceBlocker {
    if (bridgeConfig == null) {
      return 'Conference goes through the sample server: paste the line it prints under '
          'Identity → Sample server.';
    }
    return null;
  }

  // ── Sample server ───────────────────────────────────────────────────────────
  /// The line the sample server (example/push_bridge) prints:
  /// `https://<tunnel>#key=<key>`.
  String pushServer = '';

  /// Let the sample server watch this phone's connection during a call: the
  /// app reports "alive" every second, and when the reports stop the server
  /// plays a tone to the other side and can end the call. Off unless the
  /// user turns it on.
  bool connectionWatch = false;

  /// Android 13+ notification permission; null while unknown.
  bool? notificationsAllowed;

  /// Android 14+ permission to take over the lock screen; null while unknown.
  bool? fullScreenAllowed;

  bool _inForeground = true;

  /// The call screen showing the current call, and whether Accept was
  /// tapped there (it then becomes the ongoing-call notification).
  String? _callScreenId;
  bool _callScreenAccepted = false;

  /// Call screens this app closed itself. The plugin reports closing a screen
  /// that still rings as a Decline, which must not be taken for the user's.
  final Set<String> _closingScreens = <String>{};

  /// Pushed calls already taken after an Accept. The plugin can deliver
  /// one Accept twice (replayed when the app starts, and found again among
  /// its active calls); each call is taken once.
  final Set<String> _takenCalls = <String>{};

  /// Calls Vobiz holds that were turned away before their INVITE arrived
  /// (Decline, or Hang up after Accept), by the push's call id. The SDK
  /// rejects the INVITE and forgets the push as it arrives, so the app must
  /// know it by itself: it is not a new call to ring.
  final Set<String> _turnedAway = <String>{};

  PushBridgeConfig? get bridgeConfig => PushBridgeConfig.parse(pushServer, allowHttp: allowHttp);

  // ── Incoming calls (Vobiz push) ─────────────────────────────────────────────
  /// Sign this phone up with Vobiz's push service after signing in. A call
  /// to the signed-in SIP user then wakes the app when it is closed: Vobiz's
  /// registrar holds the call, pushes, and sends it to the REGISTER that
  /// claims it. Needs the app's Firebase key saved in the Vobiz Console.
  ///
  /// With a sample server line the sign-up goes through the server, which
  /// adds the account's credentials; without one it goes straight to Vobiz
  /// with [pushAuthId] and [pushAuthToken].
  bool vobizPush = false;
  PushState vobizPushState = PushState.off;
  String vobizPushDetail = '';

  /// The account's Auth ID and Auth Token, to sign this phone up with Vobiz
  /// push without a sample server, and for "Call this phone through Vobiz".
  /// TEST ONLY: the Auth Token is the account's API key. Empty, the
  /// Zero-Config fields are used. Kept in secure storage with "Remember me",
  /// like those.
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

  /// Calls Vobiz pushed, still ringing, by the push's call id (the SIP
  /// Call-ID of the held INVITE).
  final Map<String, PushCall> _ringingPushes = <String, PushCall>{};

  /// Pushes handled already: one push can arrive both through Firebase's
  /// onMessage (app open) and through the app's own receiver.
  final Set<String> _seenPushes = <String>{};

  /// The inbound call ringing or connected here, until its outcome is logged.
  _Inbound? _inbound;

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
  static const String _kConnectionWatch = 'vobiz_playground_connection_watch';
  static const String _kVobizPush = 'vobiz_playground_vobiz_push';
  static const String _kPushInstallId = 'vobiz_push_install_id';
  static const String _kPushAuthId = 'vobiz_push_auth_id';
  static const String _kPushAuthToken = 'vobiz_push_auth_token';
  static const String _kVobizCallFrom = 'vobiz_push_test_from';
  static const String _kVobizCallAnswerUrl = 'vobiz_push_test_answer_url';

  /// Left by the version of this app that paired with the sample server for
  /// its own pushes; removed at start-up.
  static const String _kOldReceiveCalls = 'vobiz_playground_receive_calls';
  static const String _kOldPushDevice = 'vobiz_push_device_token';

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
    _subs.add(push.tokenRefresh.listen((_) => _registerWithVobizPush(quiet: true)));
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

  // Async work can finish after the controller is disposed (a server reply
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
    if (tab == AuthTab.zeroConfig && !demoTools) return;
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
              ? 'Please enter a token server URL, or set up the sample server (its /token mints tokens)'
              : 'Please enter both SIP username and password');
    }
    final hook = webhookUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (zero && !hook.startsWith('https://')) {
      return _connectFailed('⚠️ Public Webhook URL is required! Vobiz Cloud cannot reach localhost. '
          'Use the hosted server or an https tunnel.');
    }
    if (token && tokenServerUrl.trim().isNotEmpty) {
      final url = Uri.tryParse(tokenServerUrl.trim());
      if (url == null || url.host.isEmpty || !(url.scheme == 'https' || (allowHttp && url.scheme == 'http'))) {
        missingFields = <String>{'tokenServer'};
        return _connectFailed('The token server must be an ${allowHttp ? 'http(s)' : 'https'} URL, such as '
            'https://<your server>/token');
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
  /// from the token server, or the sample server's /token when none is set.
  Future<void> _startTokenSession() async {
    await _stopTokenSession();
    final server = tokenServerUrl.trim();
    log('Fetching an access token from ${server.isEmpty ? 'the sample server' : server}...',
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
          'No token server: enter one, or set up the sample server');
    }
    final api = PushBridgeApi(config, client: _http);
    try {
      final user = tokenUser.trim();
      return await api.accessToken(sub: user.isEmpty ? null : user, reason: reason);
    } on PushBridgeException catch (e) {
      throw VobizAccessTokenException('The sample server did not give a token: ${e.message}',
          statusCode: e.statusCode, cause: e);
    } finally {
      api.close();
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

  /// The sign-out in progress, so a second Disconnect joins it.
  Future<void>? _disconnecting;

  /// Signs out on this device first (the registration, the access-token
  /// session, every saved secret: after a sign-out nothing on this device
  /// can sign in as this account again), then takes the phone off Vobiz
  /// push. A second call while one runs joins it.
  Future<void> disconnect() {
    final running = _disconnecting;
    if (running != null) return running;
    final attempt = _disconnect();
    _disconnecting = attempt;
    return attempt.whenComplete(() {
      if (identical(_disconnecting, attempt)) _disconnecting = null;
    });
  }

  Future<void> _disconnect() async {
    _session++;
    _connecting = null;
    _loginTimeout?.cancel();
    _reconnecting = false;
    connectError = null;
    log('Logging out...', LogType.info);
    // Made now, while the SIP user (and, without a sample server, the
    // account's credentials) are still known; sent once signed out here.
    final pushLogout = _vobizPushLogout();
    try {
      // Stop renewing the access token before the client lets go of it.
      await _stopTokenSession();
      await client.disconnect();
    } catch (e) {
      log('⚠️ Sign-out: $e', LogType.warning);
    }
    connectedAs = null;
    authToken = '';
    sipPassword = '';
    await _forgetCredentials();
    _stopCallService();
    _resetCallState(registered: false);
    _setStatus(PhoneStatus.offline, 'Disconnected');
    // Signing out means "stop ringing this phone"; closing the app does not.
    await pushLogout?.call();
  }

  /// Removes every secret this app saved: the sign-in credentials, the push
  /// account, and the sample server line (its key mints access tokens).
  Future<void> _forgetCredentials() async {
    pushAuthToken = '';
    pushServer = '';
    await _deleteSaved(<String>[..._signInKeys, _kPushServer]);
  }

  /// What "Remember me" keeps in secure storage.
  static const List<String> _signInKeys = <String>[
    _kAuthId, _kAuthToken, _kSipUser, _kSipPass, _kPushAuthId, _kPushAuthToken,
  ];

  Future<void> _deleteSaved(List<String> keys) async {
    try {
      for (final key in keys) {
        await _secure.delete(key: key);
      }
    } catch (e) {
      log('Could not remove the saved credentials: $e', LogType.warning);
    }
  }

  /// Ticks or unticks "Remember me". Unticked, what was saved earlier is
  /// removed at once, not at the next sign-in.
  Future<void> setRememberMe(bool on) async {
    rememberMe = on;
    notifyListeners();
    await _prefs?.setBool(_kRemember, on);
    if (!on) await _deleteSaved(_signInKeys);
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
    if (_turnAwayAcceptedHeldCall()) return;
    await client.hangup();
  }

  /// Hang up after Accept on a call Vobiz holds whose INVITE has not arrived
  /// yet: there is no call to hang up, and the SDK would answer the INVITE
  /// when it comes. Turn it away instead. Returns whether that was the case.
  bool _turnAwayAcceptedHeldCall() {
    final screen = _callScreenId;
    final pushed = screen == null ? null : _ringingPushes[screen];
    final sdk = pushed?.sdkPush;
    if (!_callScreenAccepted || pushed == null || sdk == null || client.callState != CallStateStatus.idle) {
      return false;
    }
    log('📵 Hung up before the call from ${pushed.displayCaller} arrived: turning it away', LogType.warning);
    _turnedAway.add(pushed.callId);
    _ringingPushes.remove(pushed.callId);
    client.reportCallScreenDeclined(sdk);
    _logCall(CallRecord(
      id: pushed.callId,
      inbound: true,
      party: pushed.displayCaller,
      at: DateTime.now(),
      outcome: CallOutcome.declined,
    ));
    _endCallScreen();
    _stopCallService();
    return true;
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
    _inbound?.declinedHere = true;
    await client.rejectCall();
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

  /// The SDK's conference client for the sample server, made on first use
  /// and again when the server's address or key changes.
  VobizConference? _conferenceClient() {
    final config = bridgeConfig;
    if (config == null) return null;
    final existing = _conference;
    if (existing != null && existing.serverUrl.toString() == config.baseUrl && _conferenceKey == config.key) {
      return existing;
    }
    existing?.state.removeListener(notifyListeners);
    existing?.dispose();
    final conference = VobizConference(
      client: client,
      serverUrl: Uri.parse(config.baseUrl),
      // Read on every request: the SIP user is whoever is signed in then.
      headers: () => PushBridgeApi.headers(config, sipUser: client.sipUsername),
      // A call the sample server rang is known there by its own id (PushRef,
      // the caller's leg); a call this app placed by its own CallUUID.
      callUuid: () => pushRefFromHeaders(client.callHeaders) ?? client.callUuid,
      httpClient: _http,
    );
    conference.state.addListener(notifyListeners);
    _conference = conference;
    _conferenceKey = config.key;
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

  // ── Incoming calls and the call screen ──────────────────────────────────────
  //
  // The sample server (example/push_bridge) answers the Vobiz number and rings
  // this app's SIP user with one <Dial>. Every call that rings here over SIP
  // also shows the system call screen. A closed app is woken by Vobiz push
  // (below): the push reaches this one Flutter engine (Android starts it
  // headless when the app was closed, see CallEngine.kt), which shows the
  // system call screen and signs in at once to claim the call Vobiz holds.

  /// The app moved to or from the foreground.
  void setForeground(bool foreground) => _inForeground = foreground;

  /// Whether the app is on screen.
  bool get inForeground => _inForeground;

  /// Saves the line the sample server printed. Returns a problem to show, or
  /// null.
  Future<String?> setPushServer(String value) async {
    final text = value.trim();
    if (text.isNotEmpty && PushBridgeConfig.parse(text, allowHttp: allowHttp) == null) {
      return PushBridgeConfig.parse(text, allowHttp: true) != null
          ? 'This build takes an https:// server line only: https://…#key=…'
          : 'Paste the whole line the server printed: https://…#key=…';
    }
    pushServer = text;
    try {
      if (text.isEmpty) {
        await _secure.delete(key: _kPushServer);
      } else {
        await _secure.write(key: _kPushServer, value: text);
      }
    } catch (e) {
      log('Could not save the sample server on this device: $e', LogType.warning);
    }
    final config = bridgeConfig;
    if (config != null && !config.isHttps) {
      log('⚠️ The sample server address is not https: its key and the tokens it mints travel '
          'unencrypted, and Vobiz cannot reach it.', LogType.warning);
    }
    notifyListeners();
    // Vobiz push sign-up goes through the server when there is one.
    if (vobizPush && client.isConnected) await _registerWithVobizPush(quiet: true);
    return null;
  }

  /// Turns the sample server's connection watch on or off. Turned off during
  /// a call, the server is told the call is no longer watched.
  Future<void> setConnectionWatch(bool on) async {
    connectionWatch = on;
    await _prefs?.setBool(_kConnectionWatch, on);
    if (!on) _stopAliveReports();
    notifyListeners();
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

  /// A call rings over SIP: show it on the system call screen too, which
  /// rings and vibrates (as the phone's settings allow), also with the app
  /// open.
  Future<void> _showCallScreenForSip(CallEvent e) async {
    final id = pushRefFromHeaders(e.headers) ?? 'sip-${e.callId}';
    _callScreenId = id;
    _callScreenAccepted = false;
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
        // Answer the SIP call only when it is the call this screen showed.
        final ringingHere = client.callState == CallStateStatus.incoming &&
            (callKitParams.id == _callScreenId ||
                pushRefFromHeaders(client.callHeaders) == callKitParams.id);
        if (!ringingHere) {
          log('📵 Accept on a call screen whose call is not ringing here: closed it', LogType.warning);
          await _closeCallScreen(callKitParams.id);
          unawaited(platform.leaveLockScreen());
          return;
        }
        _callScreenId = callKitParams.id;
        _callScreenAccepted = true;
        log('📲 Accepted on the call screen', LogType.event);
        onTabRequest?.call(1);
        await answer();
      case ck.CallEventActionCallDecline(:final callKitParams):
        final pushed = PushCall.fromExtra(callKitParams.extra);
        if (pushed != null && pushed.isVobiz && !_isRingingHere(callKitParams.id)) {
          await _declineVobizHeldCall(pushed);
          return;
        }
        if (_isRingingHere(callKitParams.id)) await reject();
      case ck.CallEventActionCallEnded(:final callKitParams):
        if (callKitParams.id == _callScreenId) {
          if (client.callState == CallStateStatus.incoming) {
            // Still ringing (the caller gave up): decline it; a call that was
            // never answered cannot be hung up.
            await client.rejectCall();
          } else if (client.callState != CallStateStatus.idle || _callScreenAccepted) {
            // "Hang up" on the ongoing-call notification, also for an
            // accepted call that has not arrived yet.
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
    final pushed = _ringingPushes.remove(id);
    final ring = _inbound;
    if (_isRingingHere(id)) {
      // Stop the SIP side too; this ring is now a missed call.
      _inbound = null;
      await client.rejectCall();
    }
    final callId = ring != null && (ring.id == id || _callScreenId == id) ? ring.id : id;
    log('📵 Missed call: nobody answered the call screen', LogType.warning);
    _logCall(CallRecord(
      id: callId,
      inbound: true,
      party: pushed?.displayCaller ?? ring?.party ?? '',
      at: DateTime.now(),
      outcome: CallOutcome.missed,
    ));
  }

  /// A push's raw data, from Android (any app state).
  void _onPushData(Map<String, String> data) {
    final call = PushCall.fromData(data);
    if (call != null) _onPush(call);
  }

  /// An incoming-call push, once however many routes it arrives by.
  void _onPush(PushCall call) {
    if (!_seenPushes.add(call.callId)) return;
    if (!call.isVobiz) {
      log('📲 Ignored a call push that is not a call Vobiz holds', LogType.info);
      return;
    }
    _onVobizHeldCall(call);
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

  // ── Calls Vobiz holds while its push wakes this phone ──────────────────────

  /// A push from Vobiz itself: its registrar holds the call (up to 30 s) until
  /// this phone claims it with a REGISTER carrying the push's hold reference.
  /// The SDK makes that claim: on the open connection when signed in, else on
  /// the sign-in this starts.
  void _onVobizHeldCall(PushCall call) {
    final sdk = call.sdkPush;
    if (sdk == null) return;
    // The SDK decides whether the push is still live, and claims the call.
    if (!client.handleIncomingPush(sdk)) {
      log('📲 Ignored a stale push for a call from ${call.displayCaller}', LogType.info);
      return;
    }
    _ringingPushes[call.callId] = call;
    final busyHere = client.callState != CallStateStatus.idle && client.callState != CallStateStatus.ended;
    if (busyHere) {
      // Vobiz does not hold calls for a phone that is registered, so this is a
      // race: the claim goes anyway, and the SDK turns it away busy at once.
      log('📞 ${call.displayCaller} is calling while you are on a call: they hear busy', LogType.warning);
      return;
    }
    unawaited(_showPushedCall(call));
    if (client.isConnected) {
      log('📲 Vobiz push: a call from ${call.displayCaller}. Signed in already: claiming it on this connection',
          LogType.info);
      return;
    }
    if (_sdkReconnecting) {
      log('📲 Vobiz push: a call from ${call.displayCaller}. Reconnecting already: the claim rides on it',
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
    onTabRequest?.call(1);
    log('📲 Accepted the call from ${call.displayCaller} on the call screen', LogType.event);
    // Accept is the user's tap: the moment Android allows the call's
    // microphone service to start.
    _startCallService(outbound: false, caller: call.displayCaller);
    client.reportCallScreenAccepted(sdk);
    if (client.isConnected || status == PhoneStatus.connecting || _sdkReconnecting) {
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
    _turnedAway.add(call.callId);
    log('📵 Declined the call from ${call.displayCaller}', LogType.warning);
    _logCall(CallRecord(
      id: call.callId,
      inbound: true,
      party: call.displayCaller,
      at: DateTime.now(),
      outcome: CallOutcome.declined,
    ));
    client.reportCallScreenDeclined(sdk);
    if (!client.isConnected && status != PhoneStatus.connecting && !_sdkReconnecting && _hasSavedSignIn) {
      log('Signing in to turn the call away...', LogType.info);
      await connect();
    }
  }

  /// The SDK is signed in but between connections: it reconnects with its
  /// own sign-in, and its REGISTER carries a pending claim. A new sign-in
  /// would tear that reconnect down.
  bool get _sdkReconnecting => client.connectionState == ConnectionStateStatus.reconnecting;

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
        _turnedAway.remove(id);
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
      await _vobizPushLogout(force: true)?.call();
      notifyListeners();
    }
  }

  /// Saves the account Auth ID and Auth Token used to register this phone
  /// with Vobiz push (test only), with "Remember me".
  Future<void> setPushAccount({required String authId, required String authToken}) async {
    if (!demoTools) return;
    pushAuthId = authId.trim();
    pushAuthToken = authToken.trim();
    try {
      if (rememberMe && pushAuthId.isNotEmpty && pushAuthToken.isNotEmpty) {
        await _secure.write(key: _kPushAuthId, value: pushAuthId);
        await _secure.write(key: _kPushAuthToken, value: pushAuthToken);
      } else {
        // Not remembered, or a field emptied: nothing old stays behind.
        await _secure.delete(key: _kPushAuthId);
        await _secure.delete(key: _kPushAuthToken);
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

  /// The account's headers for Vobiz's API (test only): the push account
  /// fields, else the Zero-Config ones. Null without [demoTools].
  Map<String, String>? _vobizPushHeaders() {
    if (!demoTools) return null;
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

  /// Where this phone signs up for Vobiz push and signs out of it. With a
  /// sample server line: through the server (`/push/devices/*`), which adds
  /// its account's credentials, so the account's Auth Token never reaches
  /// the phone; [user] names the SIP user the app is signed in as (null when
  /// it is not). Without one: straight to Vobiz with the account's Auth ID
  /// and Auth Token (test only). Null when neither is set.
  VobizPushDevices? _vobizPushDevices({String? user}) {
    final config = bridgeConfig;
    if (config != null) {
      final base = Uri.parse(config.baseUrl);
      return VobizPushDevices(
        baseUrl: base.replace(path: ''),
        pathPrefix: '${base.path}/push/devices',
        authHeaders: () => PushBridgeApi.headers(config, sipUser: user),
        httpClient: _http,
      );
    }
    final headers = _vobizPushHeaders();
    if (headers == null) return null;
    return VobizPushDevices(authHeaders: () => headers, httpClient: _http);
  }

  Future<void> _registerWithVobizPush({bool quiet = false}) async {
    final user = client.sipUsername;
    if (!vobizPush || user == null || !client.isConnected) return;
    final viaServer = bridgeConfig != null;
    if (!viaServer && _vobizPushHeaders() == null) {
      vobizPushState = PushState.failed;
      vobizPushDetail = demoTools
          ? 'Paste the sample server line under Sample server, so this phone signs up through it, or '
              'enter the account Auth ID and Auth Token below (test only).'
          : 'This phone signs up for Vobiz push through the sample server: paste the line it prints under '
              'Sample server.';
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
    // The application id Android runs this app as: Vobiz pushes with the
    // Firebase credential saved for it.
    final bundleId = await platform.packageName();
    if (token == null || bundleId == null || bundleId.isEmpty) {
      vobizPushState = PushState.failed;
      vobizPushDetail = token == null
          ? 'Firebase gave no push token (no network, or Google Play services missing).'
          : 'Could not read this app\'s package name from Android.';
      log('❌ Vobiz push: $vobizPushDetail', LogType.error);
      notifyListeners();
      return;
    }
    final devices = _vobizPushDevices(user: user);
    if (devices == null) {
      // The sample server line was cleared meanwhile.
      vobizPushState = PushState.off;
      notifyListeners();
      return;
    }
    try {
      final device = VobizPushDevice(
        deviceId: await _installId(),
        pushToken: token,
        sipUsername: user,
        appBundleId: bundleId,
        appVersion: 'example',
        sdkVersion: VobizClient.sdkVersion,
      );
      await devices.register(device);
      vobizPushState = PushState.ready;
      vobizPushDetail = 'This phone is signed up with Vobiz push for calls to $user'
          '${viaServer ? ' (through the sample server)' : ''}. With the app closed, a call to $user '
          'wakes it while its last registration lasts (the SDK asks for an hour).';
      if (!quiet) {
        log('📲 Vobiz push: this phone is signed up for calls to $user'
            '${viaServer ? ' through the sample server' : ''}', LogType.success);
      }
    } on VobizException catch (e) {
      vobizPushState = PushState.failed;
      vobizPushDetail = e.message;
      log('❌ Vobiz push: ${e.message}', LogType.error);
    } finally {
      devices.close();
    }
    notifyListeners();
  }

  /// Takes this phone off Vobiz push: made now (it reads the SIP user and,
  /// without a sample server, the account's credentials), sent when called.
  /// Null when there is nothing to remove. With [force] it is also made when
  /// this run of the app has not signed the phone up (the switch turned off
  /// after a restart, before signing in); a phone never signed up has no
  /// install id, so nothing is sent for it.
  Future<void> Function()? _vobizPushLogout({bool force = false}) {
    final id = _pushDeviceId ?? _prefs?.getString(_kPushInstallId);
    final wasOn = vobizPushState != PushState.off;
    vobizPushState = PushState.off;
    vobizPushDetail = '';
    if ((!wasOn && !force) || id == null) return null;
    final devices = _vobizPushDevices(user: client.sipUsername);
    if (devices == null) {
      log('⚠️ Vobiz push: no sample server${demoTools ? ' and no account Auth ID and Auth Token' : ''} to '
          'remove this phone with; it may still be pushed until Firebase replaces its token', LogType.warning);
      return null;
    }
    return () async {
      try {
        await devices.logout(id);
        log('📴 Vobiz push: this phone is no longer pushed for calls', LogType.info);
      } on VobizException catch (e) {
        log('⚠️ Vobiz push: ${e.message}', LogType.warning);
      } finally {
        devices.close();
      }
    };
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
  /// push sign-up. Vobiz keeps the registration until it expires (the SDK
  /// asks for an hour), and the call follows a moment later.
  Future<void> callThisPhoneThroughVobiz() async {
    if (!demoTools || vobizCallPlacing) return;
    final user = client.sipUsername;
    if (user == null || vobizPushState != PushState.ready || !client.isConnected) {
      log('Connect, and turn on "Receive calls through Vobiz push", first', LogType.error);
      return;
    }
    final headers = _vobizPushHeaders();
    if (headers == null) {
      log("The test call uses Vobiz's Call API: enter the account Auth ID and Auth Token (test only) under "
          'Incoming calls', LogType.error);
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
      if (!pushed.isVobiz || (expires != null && DateTime.now().isAfter(expires.add(const Duration(seconds: 30))))) {
        await _closeCallScreen(active.id);
        unawaited(platform.leaveLockScreen());
        continue;
      }
      await _acceptVobizHeldCall(pushed, active.id);
      return;
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
    _logCall(CallRecord(
      id: ring.id,
      inbound: true,
      party: ring.party,
      at: ring.at,
      outcome: outcome ?? CallOutcome.missed,
      duration: ring.answered ? callDuration : Duration.zero,
    ));
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
      final wasReconnecting = _reconnecting;
      _reconnecting = false;
      connectError = null;
      missingFields = <String>{};
      final wasConnecting = status != PhoneStatus.online &&
          status != PhoneStatus.inCall &&
          status != PhoneStatus.ringing;
      if (wasConnecting) {
        log(wasReconnecting
            ? 'Reconnected: registered again as ${client.sipUsername ?? connectedAs}'
            : 'Registered successfully as ${client.sipUsername ?? connectedAs}', LogType.success);
        _setStatus(PhoneStatus.online, 'Registered');
        if (!wasReconnecting) {
          // A reconnect leaves the user where they are.
          onTabRequest?.call(1);
          // Also a sign-in whose first attempt threw but that the SDK then
          // completed by itself, which skipped the save in _connect.
          unawaited(_saveCredentials());
        }
        _registerWithVobizPush();
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
    // The socket dropped while idle. The SDK reconnects by itself (the
    // Playground keeps autoReconnect on) and reports `reconnecting`; it ends
    // in `registered`, or in a `reconnect_failed` error when it gives up
    // (_onError). Without autoReconnect it reports `disconnected`, and nothing
    // follows unless the sign-in timeout ends it.
    final message = e.message ?? '';
    final reconnecting = e.connectionState == ConnectionStateStatus.reconnecting;
    final dropped = e.connectionState == ConnectionStateStatus.disconnected && message.startsWith('Socket error');
    if ((reconnecting || dropped) && status == PhoneStatus.online) {
      log('Connection lost — reconnecting ($message)', LogType.warning);
      _reconnecting = true;
      _setStatus(PhoneStatus.connecting, 'Reconnecting...');
      if (dropped) _startLoginTimeout();
    }
  }

  /// The SDK stopped reconnecting: the phone is offline until the user
  /// connects again (or the app comes back to the foreground, or the network
  /// changes, which make the SDK try again).
  void _onReconnectGaveUp(String message) {
    if (status != PhoneStatus.connecting && status != PhoneStatus.online) {
      log('⚠️ reconnect_failed: $message', LogType.warning);
      return;
    }
    _loginTimeout?.cancel();
    _reconnecting = false;
    connectError = 'Connection lost: $message. Connect again.';
    log(connectError!, LogType.error);
    _setStatus(PhoneStatus.error, 'Connection lost');
  }

  void _onCall(CallEvent e) {
    switch (e.state) {
      case CallStateStatus.incoming:
        // The sample server's caller ID can be the Vobiz number; it passes the
        // real caller in a header.
        remoteParty = callerFromHeaders(e.headers) ?? e.remoteIdentity ?? e.message ?? 'Unknown';
        _failedCallId = null;
        log('📲 Incoming call from: $remoteParty', LogType.event);
        activeHeaders = null;
        _recordHeaders('incoming call', e);
        final ref = pushRefFromHeaders(e.headers);
        final sipCallId = e.sipCallId;
        if (sipCallId != null && _turnedAway.remove(sipCallId)) {
          // Declined (or hung up) before it arrived: the SDK turns it away.
          // It is logged already, and must not ring again.
          log('📵 The call turned away on the call screen arrived: the SDK declines it', LogType.info);
          _inbound = _Inbound(id: sipCallId, party: remoteParty, pushId: sipCallId)..declinedHere = true;
          break;
        }
        // A call Vobiz held while its push woke this phone: the push's call
        // screen is already showing (and may have been accepted).
        final held = client.isPushedCall(e.callId) ? _ringingPushes[e.sipCallId ?? ''] : null;
        final id = ref ?? held?.callId ?? e.callId;
        _inbound = _Inbound(id: id, party: remoteParty, pushId: held?.callId);
        if (held != null) {
          _callScreenId ??= held.callId;
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
        // A call the sample server rang: report the server's own id for it
        // (PushRef, the caller's leg), which the server can act on. The
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
        // A call Vobiz pushed no longer rings: forget its push (read before
        // _finishInbound clears _inbound).
        final pushId = _inbound?.pushId;
        if (pushId != null) _ringingPushes.remove(pushId);
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
        _endCallScreen();
        _resetCallState();
        break;
      case CallStateStatus.idle:
      case CallStateStatus.outgoing:
      case CallStateStatus.held:
        break;
    }
  }

  void _onError(ErrorEvent e) {
    if (e.code == 'reconnect_failed') return _onReconnectGaveUp(e.message);
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
      // Registered from here. Still signed in: Disconnect stays reachable.
      _reconnecting = true;
      _setStatus(PhoneStatus.connecting, 'Reconnecting...');
    } else {
      notifyListeners();
    }
  }

  /// Reports "alive" to the sample server every second while a call is up. A
  /// phone that loses its network cannot tell anyone; the server notices the
  /// reports stop and has Vobiz beep to the other party, then ends the call
  /// if the SDK's 12 s reconnect window passes. Only with [connectionWatch]
  /// on, a sample server line set, and the app signed in.
  void _startAliveReports(String? callUuid) {
    _stopAliveReports(ended: false);
    final config = bridgeConfig;
    final user = client.sipUsername;
    if (!connectionWatch || config == null || user == null || user.isEmpty || callUuid == null) return;
    _aliveCallUuid = callUuid;
    _aliveApi = PushBridgeApi(config, client: _http, sipUser: user);
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
    } on PushBridgeException catch (e) {
      // Refused: the server does not watch this call for this user (it did not
      // ring it, or does not take the key). Asking again cannot help.
      final code = e.statusCode;
      if ((code == 401 || code == 403 || code == 404) && identical(_aliveApi, api)) {
        log('Connection watch: the sample server refused this call (HTTP $code: ${e.message}); '
            'no more reports for it', LogType.warning);
        _stopAliveReports(ended: false);
      }
      // Otherwise offline, or the server is unreachable: the missing reports are the signal.
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
      _ => demoTools ? AuthTab.zeroConfig : AuthTab.sipDirect,
    };
    webhookUrl = prefs.getString(_kWebhook) ?? SdkConfig.defaultWebhookUrl;
    tokenServerUrl = prefs.getString(_kTokenServer) ?? '';
    tokenUser = prefs.getString(_kTokenUser) ?? '';
    rememberMe = prefs.getBool(_kRemember) ?? true;
    connectionWatch = prefs.getBool(_kConnectionWatch) ?? false;
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

  /// The sample server line carries the server's key, so it lives in secure
  /// storage too.
  Future<void> _loadPushServer() async {
    try {
      pushServer = await _secure.read(key: _kPushServer) ?? '';
      await _secure.delete(key: _kOldPushDevice);
    } catch (e) {
      log('Could not read the saved sample server: $e', LogType.warning);
    }
    await _prefs?.remove(_kOldReceiveCalls);
  }

  Future<void> _loadSavedCredentials() async {
    if (!rememberMe) return;
    try {
      sipUsername = await _secure.read(key: _kSipUser) ?? '';
      sipPassword = await _secure.read(key: _kSipPass) ?? '';
      // The account's credentials are for the demo tools only.
      if (!demoTools) return;
      authId = await _secure.read(key: _kAuthId) ?? '';
      authToken = await _secure.read(key: _kAuthToken) ?? '';
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
    if (!rememberMe) return _deleteSaved(_signInKeys);
    try {
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
  _Inbound({required this.id, required this.party, this.pushId}) : at = DateTime.now();

  /// The sample server's call id (PushRef), the push's call id, or the SIP
  /// Call-ID.
  final String id;
  final String party;
  final DateTime at;

  /// The call id of the Vobiz push this call came with (the SIP Call-ID of
  /// the held INVITE), if it came with one.
  final String? pushId;
  bool answered = false;
  bool declinedHere = false;
}
