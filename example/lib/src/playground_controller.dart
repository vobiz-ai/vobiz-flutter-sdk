import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'countries.dart';
import 'push/call_screen.dart';
import 'push/push_bridge_api.dart';
import 'push/push_call.dart';
import 'push/push_service.dart';

/// The two ways to sign in, as on the web Playground.
enum AuthTab { zeroConfig, sipDirect }

enum PhoneStatus { offline, connecting, online, ringing, inCall, error }

/// Whether the push bridge knows this phone.
enum PushState { off, registering, ready, failed }

enum LogType { info, success, warning, error, event }

enum TransferTarget { number, user }

enum TransferStatus { idle, submitting, accepted, failed }

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
  PlaygroundController({VobizClient? client, FlutterSecureStorage? secureStorage, PushService? push})
      : client = client ?? VobizClient(),
        _secure = secureStorage ?? const FlutterSecureStorage(),
        push = push ?? PushService.unavailable('Push is not set up in this build.');

  final VobizClient client;
  final FlutterSecureStorage _secure;

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

  // ── Status ──────────────────────────────────────────────────────────────────
  PhoneStatus status = PhoneStatus.offline;
  String statusText = 'Disconnected';
  String? connectedAs;
  Timer? _loginTimeout;

  VobizAuthMode get authMode => client.authMode;
  bool _reconnecting = false;

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
  bool _recordRequested = false;
  String? _failedCallId;

  // ── Transfer ────────────────────────────────────────────────────────────────
  TransferTarget transferTarget = TransferTarget.number;
  TransferLeg transferLeg = TransferLeg.aLeg;
  String transferIso = 'IN';
  String transferNumber = '';
  String transferUser = '';
  TransferStatus transferStatus = TransferStatus.idle;
  String transferError = '';

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

  PushBridgeConfig? get bridgeConfig => PushBridgeConfig.parse(pushServer);

  // ── Trace ───────────────────────────────────────────────────────────────────
  final List<LogEntry> logs = <LogEntry>[];
  static const int _maxLogs = 500;

  // ── Theme ───────────────────────────────────────────────────────────────────
  ThemeMode themeMode = ThemeMode.system;

  // Storage keys. Header rows use the web Playground's key and shape.
  static const String _kHeaders = 'vobiz_playground_headers';
  static const String _kTheme = 'vobiz_playground_theme';
  static const String _kMode = 'vobiz_playground_mode';
  static const String _kWebhook = 'vobiz_playground_webhook';
  static const String _kRemember = 'vobiz_playground_remember';
  static const String _kCallerId = 'vobiz_playground_caller_id';
  static const String _kAuthId = 'vobiz_auth_id';
  static const String _kAuthToken = 'vobiz_auth_token';
  static const String _kSipUser = 'vobiz_sip_username';
  static const String _kSipPass = 'vobiz_sip_password';
  static const String _kPushServer = 'vobiz_push_server';
  static const String _kReceiveCalls = 'vobiz_playground_receive_calls';

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _loadPrefs();
    } catch (e) {
      log('Could not read saved settings: $e', LogType.warning);
    }
    await _loadSavedCredentials();
    await _loadPushServer();
    _subs.add(client.connectionEvents.listen(_onConnection));
    _subs.add(client.callEvents.listen(_onCall));
    _subs.add(client.errorEvents.listen(_onError));
    _subs.add(CallScreen.events.listen(_onCallScreenEvent, onError: (Object _) {}));
    _subs.add(push.foregroundCalls.listen(_onForegroundPush));
    _subs.add(push.tokenRefresh.listen((_) => _registerWithBridge(quiet: true)));
    notifyListeners();
    await refreshCallPermissions();
    await _resumeAcceptedCall();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _stopCallTimers();
    _loginTimeout?.cancel();
    _acceptedTimer?.cancel();
    client.dispose();
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

  Future<void> connect() async {
    if (status == PhoneStatus.connecting) return;
    final zero = authTab == AuthTab.zeroConfig;
    if (zero && (authId.trim().isEmpty || authToken.trim().isEmpty)) {
      log('Please enter Auth ID and Auth Token', LogType.error);
      return;
    }
    if (!zero && (sipUsername.trim().isEmpty || sipPassword.isEmpty)) {
      log('Please enter both SIP username and password', LogType.error);
      return;
    }
    final hook = webhookUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (zero && !hook.startsWith('https://')) {
      log('⚠️ Public Webhook URL is required! Vobiz Cloud cannot reach localhost. '
          'Use the hosted server or an https tunnel.', LogType.error);
      return;
    }

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
      } else {
        connectedAs = sipUsername.trim();
        log('Connecting as ${sipUsername.trim()}...', LogType.event);
        await client.connectWithCredentials(CredentialConfig(
          username: sipUsername.trim(),
          password: sipPassword,
        ));
      }
      await _saveCredentials();
    } on VobizException catch (e) {
      _loginTimeout?.cancel();
      connectedAs = null;
      log('API Setup Error: ${e.message}', LogType.error);
      _setStatus(PhoneStatus.offline, 'Error');
    } catch (e) {
      _loginTimeout?.cancel();
      log('Connection failed: $e', LogType.error);
      _setStatus(PhoneStatus.error, 'Error');
    }
  }

  Future<void> disconnect() async {
    _loginTimeout?.cancel();
    _reconnecting = false;
    log('Logging out...', LogType.info);
    // Signing out means "stop ringing this phone"; closing the app does not.
    await _unregisterFromBridge(client.sipUsername ?? connectedAs);
    await client.disconnect();
    connectedAs = null;
    _resetCallState(registered: false);
    _setStatus(PhoneStatus.offline, 'Disconnected');
  }

  void _startLoginTimeout() {
    _loginTimeout?.cancel();
    // Like the Playground: give up on a registrar that never answers.
    _loginTimeout = Timer(const Duration(seconds: 20), () {
      if (status == PhoneStatus.connecting) {
        _reconnecting = false;
        log('Login timed out (No response from registrar)', LogType.error);
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
    _setStatus(PhoneStatus.inCall, 'Calling...');

    try {
      await client.makeCall(
        destination,
        callerId: cli,
        headers: built.headers,
        record: recordCall,
      );
    } on ArgumentError catch (e) {
      _recordRequested = false;
      log('⚠️ ${e.message}', LogType.error);
      _setStatus(PhoneStatus.online, 'Registered');
    } catch (e) {
      _recordRequested = false;
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
    final caller = remoteParty;
    final pushed = _callScreenPush;
    await client.rejectCall();
    await _tellBridgeDeclined(caller, pushed);
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
    log('↗️ Transferring ${transferLeg == TransferLeg.aLeg ? 'you' : 'the other party'} '
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

  void _transferFailed(String message) {
    transferStatus = TransferStatus.failed;
    transferError = message;
    notifyListeners();
  }

  // ── Incoming calls: push bridge and call screen ─────────────────────────────
  //
  // The push bridge (example/push_bridge) answers the Vobiz number. It rings
  // this app's SIP endpoint and, when Firebase is set up, sends a push that
  // wakes the app and shows the system call screen. Accepting there opens
  // the app, which signs in with the saved credentials and answers the
  // call when the bridge rings it again.

  /// The app moved to or from the foreground.
  void setForeground(bool foreground) => _inForeground = foreground;

  /// Saves the line the bridge printed. Returns a problem to show, or null.
  Future<String?> setPushServer(String value) async {
    final text = value.trim();
    if (text.isNotEmpty && PushBridgeConfig.parse(text) == null) {
      return 'Paste the whole line the bridge printed: https://…#key=…';
    }
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
    fullScreenAllowed = await CallScreen.canUseFullScreen();
    notifyListeners();
  }

  /// Asks for what the call screen needs: notifications (Android 13+) and,
  /// when missing, full-screen notifications (Android 14+, opens Settings).
  Future<void> requestCallPermissions() async {
    notificationsAllowed = await push.requestNotificationPermission();
    fullScreenAllowed = await CallScreen.canUseFullScreen();
    if (fullScreenAllowed == false) await CallScreen.requestFullScreen();
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
    final api = PushBridgeApi(config);
    try {
      await api.sendTestCall(username: user, delaySeconds: 10);
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
    final api = PushBridgeApi(config);
    try {
      final token = await push.token();
      final registration = await api.register(
        username: user,
        token: token,
        app: 'vobiz_webrtc_example',
      );
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
    final api = PushBridgeApi(config);
    try {
      await api.unregister(username: user, token: await push.token());
      pushState = PushState.off;
      pushDetail = 'Signed out: calls no longer ring this phone.';
      log('📴 Push server: $user no longer rings this phone', LogType.info);
    } on PushBridgeException catch (e) {
      log('⚠️ Push server: ${e.message}', LogType.warning);
    } finally {
      api.close();
    }
  }

  /// A declined call should end for the caller now, not when ringing times out.
  Future<void> _tellBridgeDeclined(String caller, PushCall? pushed) async {
    try {
      if (pushed != null) {
        await PushBridgeApi.decline(pushed);
        return;
      }
      final config = bridgeConfig;
      final user = client.sipUsername;
      if (!receiveCalls || config == null || user == null) return;
      final api = PushBridgeApi(config);
      try {
        await api.declineByCaller(username: user, caller: caller);
      } finally {
        api.close();
      }
    } catch (_) {
      // Not a bridge call, or the bridge is gone: the SIP 486 still ends it.
    }
  }

  /// Whether an INVITE is the call the user already accepted on the call screen.
  bool _isAcceptedCall(CallEvent e) {
    final accepted = _acceptedCall;
    return accepted != null &&
        inviteMatchesPush(accepted, headers: e.headers, from: e.remoteIdentity);
  }

  /// A call rings over SIP while the app is in the background: show it on the
  /// call screen, joining a push for the same call if one is already showing.
  Future<void> _showCallScreenForSip(CallEvent e) async {
    final ref = pushRefFromHeaders(e.headers);
    for (final active in await CallScreen.active()) {
      final pushed = PushCall.fromExtra(active.extra);
      if (pushed == null || !inviteMatchesPush(pushed, headers: e.headers, from: e.remoteIdentity)) {
        continue;
      }
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
    _callScreenPush = null;
    await CallScreen.showIncoming(
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
    await CallScreen.end(id);
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
        _callScreenId = callKitParams.id;
        _callScreenAccepted = true;
        _callScreenPush = pushed;
        if (client.callState == CallStateStatus.incoming) {
          log('📲 Accepted on the call screen', LogType.event);
          onTabRequest?.call(1);
          if (pushed != null && !pushed.isTest) unawaited(_quietly(() => PushBridgeApi.accept(pushed)));
          await answer();
        } else if (pushed != null) {
          await _takeAcceptedCall(pushed, callKitParams.id);
        }
      case ck.CallEventActionCallDecline(:final callKitParams):
        final pushed = PushCall.fromExtra(callKitParams.extra);
        if (_acceptedCall?.callId == callKitParams.id) _clearAcceptedCall();
        if (client.callState == CallStateStatus.incoming && callKitParams.id == _callScreenId) {
          _callScreenPush = pushed;
          await reject();
        } else if (pushed != null) {
          log('📵 Declined ${pushed.isTest ? 'the test call' : 'the call from ${pushed.caller}'}',
              LogType.warning);
          if (!pushed.isTest) await _quietly(() => PushBridgeApi.decline(pushed));
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
        if (_acceptedCall?.callId == id) _clearAcceptedCall();
        log('📵 Missed call: nobody answered the call screen', LogType.warning);
      default:
        break;
    }
  }

  /// A push while the app is open. Signed in, the call also rings over SIP,
  /// so only the trace notes it; signed out, the call screen offers to
  /// accept, which signs in.
  void _onForegroundPush(PushCall call) {
    if (call.kind == PushKind.callEnded) {
      _closeCallScreen(call.callId);
      if (_acceptedCall?.callId == call.callId) {
        _clearAcceptedCall();
        log('📴 The caller hung up before the call connected', LogType.warning);
      }
      // The caller gave up while this call still rings here: the bridge knows
      // before the SIP CANCEL arrives (or if it is lost), so stop it now.
      if (call.reason != 'completed' &&
          client.callState == CallStateStatus.incoming &&
          pushRefFromHeaders(client.callHeaders) == call.callId) {
        log('📴 The caller hung up', LogType.warning);
        client.rejectCall();
      }
      return;
    }
    if (call.isExpired) return;
    if (client.isConnected && !call.isTest) {
      log('📲 Push received for a call from ${call.caller}; it rings here over SIP', LogType.info);
      return;
    }
    CallScreen.showIncoming(
      id: call.callId,
      caller: call.isTest ? 'Test call' : call.caller,
      subtitle: call.isTest ? 'The push reached this phone. Nothing will connect.' : 'Vobiz call',
      extra: call.toExtra(),
    );
  }

  /// Opened by Accept on the call screen while the app was closed: take it.
  Future<void> _resumeAcceptedCall() async {
    for (final active in await CallScreen.active()) {
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
    unawaited(_quietly(() => PushBridgeApi.accept(call)));
    if (client.callState == CallStateStatus.incoming) {
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
    });
    if (client.isConnected) {
      log('Waiting for the call to arrive...', LogType.info);
      return;
    }
    final saved = authTab == AuthTab.zeroConfig
        ? authId.isNotEmpty && authToken.isNotEmpty
        : sipUsername.isNotEmpty && sipPassword.isNotEmpty;
    if (!saved) {
      log('❌ Cannot take the call: no saved sign-in. Tick "Remember me" and connect once.',
          LogType.error);
      _clearAcceptedCall();
      _endCallScreen();
      return;
    }
    log('Signing in to take the call...', LogType.info);
    await connect();
  }

  void _clearAcceptedCall() {
    _acceptedTimer?.cancel();
    _acceptedTimer = null;
    _acceptedCall = null;
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
    themeMode = mode;
    _prefs?.setString(_kTheme, mode.name);
    notifyListeners();
  }

  // ── SDK events ──────────────────────────────────────────────────────────────

  void _onConnection(ConnectionEvent e) {
    if (e.registrationState == RegistrationState.registered) {
      _loginTimeout?.cancel();
      _reconnecting = false;
      final wasConnecting = status != PhoneStatus.online &&
          status != PhoneStatus.inCall &&
          status != PhoneStatus.ringing;
      if (wasConnecting) {
        log('Registered successfully as ${client.sipUsername ?? connectedAs}', LogType.success);
        _setStatus(PhoneStatus.online, 'Registered');
        onTabRequest?.call(1);
        _registerWithBridge();
        if (_acceptedCall != null) log('Waiting for the accepted call to arrive...', LogType.info);
      }
      return;
    }
    if (e.registrationState == RegistrationState.failed &&
        e.connectionState == ConnectionStateStatus.failed &&
        (e.message ?? '').startsWith('Registration failed')) {
      _loginTimeout?.cancel();
      _reconnecting = false;
      log('Login failed: ${e.message?.replaceFirst('Registration failed: ', '') ?? 'Unknown reason'}',
          LogType.error);
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
        if (!_inForeground) _showCallScreenForSip(e);
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
        showIncoming = false;
        log('✅ Call answered! (${e.callUuid ?? ''})', LogType.success);
        _recordHeaders('answer', e);
        _setStatus(PhoneStatus.inCall, 'In Call');
        _startCallTimers();
        // Accepted on the call screen: it becomes the ongoing-call
        // notification, whose service keeps the call alive in the background.
        if (_callScreenId != null && _callScreenAccepted) CallScreen.connected(_callScreenId!);
        break;
      case CallStateStatus.failed:
        _failedCallId = e.callId;
        final code = e.sipCode != null ? ' · SIP ${e.sipCode}' : '';
        log('❌ Call failed: ${e.reason ?? e.message ?? 'Unknown'}$code', LogType.error);
        _recordHeaders('failure', e);
        _recordRequested = false;
        break;
      case CallStateStatus.ended:
        if (_failedCallId != e.callId) {
          log('📴 Call ended: ${e.reason ?? e.message ?? 'Terminated'}', LogType.warning);
          _recordHeaders('hangup', e);
        }
        _failedCallId = null;
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
      notifyListeners();
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final stats = await client.getCallStats();
      if (latency.isNotEmpty) latency.removeAt(0);
      latency.add(stats?.rttMs);
      notifyListeners();
    });
  }

  void _stopCallTimers() {
    _callTimer?.cancel();
    _callTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  void _resetCallState({bool registered = true}) {
    _stopCallTimers();
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
    } else {
      notifyListeners();
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
    themeMode = ThemeMode.values.where((m) => m.name == theme).firstOrNull ?? ThemeMode.system;
    authTab = prefs.getString(_kMode) == 'sip' ? AuthTab.sipDirect : AuthTab.zeroConfig;
    webhookUrl = prefs.getString(_kWebhook) ?? SdkConfig.defaultWebhookUrl;
    rememberMe = prefs.getBool(_kRemember) ?? true;
    receiveCalls = prefs.getBool(_kReceiveCalls) ?? false;
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
    } catch (e) {
      log('Could not read saved credentials: $e', LogType.warning);
    }
  }

  /// "Remember me" keeps the credentials in the platform's secure storage
  /// (Keychain / Keystore). Unticked, anything saved earlier is removed.
  Future<void> _saveCredentials() async {
    final prefs = _prefs;
    await prefs?.setString(_kMode, authTab == AuthTab.sipDirect ? 'sip' : 'api');
    await prefs?.setBool(_kRemember, rememberMe);
    await prefs?.setString(_kWebhook, webhookUrl.trim());
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
      } else {
        await _secure.write(key: _kSipUser, value: sipUsername.trim());
        await _secure.write(key: _kSipPass, value: sipPassword);
      }
    } catch (e) {
      log('Could not save credentials on this device: $e', LogType.warning);
    }
  }
}
