import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/vobiz_client.dart';
import '../events/call_event.dart';
import '../models/call/call_direction.dart';
import '../state/call_state.dart';
import 'vobiz_push.dart';

/// Vobiz push-to-wake on iOS, built into the SDK: PushKit VoIP pushes, the
/// CallKit call screen, and WebRTC's audio around CallKit.
///
/// The SDK's iOS code reports each Vobiz push to CallKit (iOS requires it
/// before the app runs any Dart), and this class does the rest for [client]:
/// it hands the push to [VobizClient.handleIncomingPush], turns CallKit's
/// Accept, Decline, End, mute and hold into SDK calls, puts calls that ring
/// over SIP on CallKit too, and keeps CallKit in step as calls connect and
/// end.
///
/// ```dart
/// final ios = VobizIosPush(client);
/// await ios.start();                       // before signing in
/// final token = await ios.waitForVoipToken();
/// // Register `token` with Vobiz push from your backend,
/// // as VobizPushDevice(platform: 'ios', pushToken: token, ...).
/// ios.pushes.listen((_) => signInIfNeeded());
/// ```
///
/// The app also needs the iOS setup in PLATFORM_SETUP.md: the Push
/// Notifications capability, the `voip` background mode, and an AppDelegate
/// that is a `VobizAppDelegate`, so a push can start the app's Flutter
/// engine. [start] is remembered: on the next launches the SDK registers for
/// PushKit before Flutter runs. [stop] turns it off.
///
/// On other platforms every method does nothing and [isSupported] is false.
class VobizIosPush {
  VobizIosPush(
    this.client, {
    this.includesCallsInRecents = true,
    this.iconTemplateImageName,
    this.ringtoneSound,
    this.showCallsOnCallKit = true,
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting bool? supported,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _supported = supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  static const String channelName = 'ai.vobiz.webrtc/ios_push';

  /// Whether this platform has the SDK's iOS push (iOS only).
  static bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  final VobizClient client;

  /// Whether CallKit lists this app's calls in the Phone app's Recents.
  final bool includesCallsInRecents;

  /// An image in the app's asset catalog that CallKit shows on its call
  /// screen (a template image: white on transparent, 40 by 40 points).
  final String? iconTemplateImageName;

  /// A sound file in the app bundle that CallKit rings with, in place of the
  /// default ringtone.
  final String? ringtoneSound;

  /// Whether a call that rings over SIP while the app runs (not through a
  /// push) shows on CallKit too, as a pushed call does. With false, the app
  /// shows it its own way, and it does not ring when the app is in the
  /// background.
  final bool showCallsOnCallKit;

  final MethodChannel _channel;
  final bool _supported;

  final StreamController<VobizIncomingPush> _pushes = StreamController<VobizIncomingPush>.broadcast();
  final StreamController<String> _tokens = StreamController<String>.broadcast();
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  /// Pushed calls by key (the push's SIP Call-ID).
  final Map<String, VobizIncomingPush> _pushed = <String, VobizIncomingPush>{};

  /// The CallKit key of each of the SDK's calls that is on CallKit.
  final Map<String, String> _keys = <String, String>{};

  /// SDK calls whose audio the app side started (no CallKit screen).
  final Set<String> _appAudio = <String>{};

  bool _started = false;
  String? _voipToken;

  /// This phone's PushKit VoIP token: what Vobiz pushes calls to. Null until
  /// PushKit has given one (soon after [start]).
  String? get voipToken => _voipToken;

  /// New VoIP tokens: register the phone again with each.
  Stream<String> get voipTokenChanges => _tokens.stream;

  /// Vobiz pushes, after they are on CallKit and handed to
  /// [VobizClient.handleIncomingPush]. Sign in on one when the app is not
  /// signed in: the sign-in claims the call.
  Stream<VobizIncomingPush> get pushes => _pushes.stream;

  /// Turns iOS push on (and keeps it on for the next launches), and starts
  /// driving CallKit for [client]. Call it once, before signing in, so the
  /// push that launched the app is claimed by that sign-in.
  Future<void> start() async {
    if (!_supported || _started) return;
    _started = true;
    _channel.setMethodCallHandler(_onNative);
    _subs.add(client.callEvents.listen(_onCall));
    _subs.add(client.pushCallUpdates.listen(_onPushUpdate));
    final reply = await _channel.invokeMapMethod<String, Object?>('start', <String, Object?>{
      'includesCallsInRecents': includesCallsInRecents,
      'iconTemplateImageName': iconTemplateImageName,
      'ringtoneSound': ringtoneSound,
    });
    final token = reply?['voipToken'];
    if (token is String && token.isNotEmpty) _setToken(token);
    for (final event in (reply?['events'] as List<Object?>?) ?? const <Object?>[]) {
      if (event is Map) await _onEvent(Map<String, Object?>.from(event));
    }
  }

  /// The VoIP token, waiting up to [timeout] for PushKit to give one.
  Future<String?> waitForVoipToken({Duration timeout = const Duration(seconds: 10)}) async {
    if (!_supported) return null;
    final known = _voipToken;
    if (known != null) return known;
    try {
      return await voipTokenChanges.first.timeout(timeout);
    } on TimeoutException {
      return _voipToken;
    } on StateError {
      return _voipToken;
    }
  }

  /// The app's bundle ID: the `appBundleId` to register the device with,
  /// matching the iOS push credential in the Vobiz Console.
  Future<String?> bundleId() async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<String>('bundleId');
    } on MissingPluginException {
      return null;
    }
  }

  /// Turns iOS push off, also for the next launches: PushKit stops, so Vobiz
  /// can no longer wake the app. Remove the device from Vobiz push too.
  Future<void> stop() async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('stop');
    _voipToken = null;
  }

  /// Mutes or unmutes the current call, and shows it on CallKit.
  Future<void> setMuted(bool muted) async {
    final id = client.currentCallId;
    if (id == null) return;
    if (muted) {
      await client.mute(id);
    } else {
      await client.unmute(id);
    }
    final key = _keys[id];
    if (key != null) await _invoke('setMuted', <String, Object?>{'key': key, 'muted': muted});
  }

  /// Stops listening. CallKit and PushKit stay on for the next launches
  /// (see [stop]).
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    if (_supported) _channel.setMethodCallHandler(null);
    await _pushes.close();
    await _tokens.close();
  }

  // ── From the iOS side ──────────────────────────────────────────────────────

  Future<Object?> _onNative(MethodCall call) async {
    if (call.method == 'event' && call.arguments is Map) {
      await _onEvent(Map<String, Object?>.from(call.arguments as Map));
    }
    return null;
  }

  Future<void> _onEvent(Map<String, Object?> event) async {
    switch (event['type']) {
      case 'token':
        final token = '${event['token'] ?? ''}';
        if (token.isEmpty) {
          _voipToken = null;
        } else {
          _setToken(token);
        }
      case 'push':
        final data = event['data'];
        if (data is Map) _onPush(Map<String, Object?>.from(data));
      case 'action':
        await _onAction('${event['action']}', '${event['key'] ?? ''}', event);
    }
  }

  void _setToken(String token) {
    if (token == _voipToken) return;
    _voipToken = token;
    if (!_tokens.isClosed) _tokens.add(token);
  }

  void _onPush(Map<String, Object?> data) {
    final push = VobizIncomingPush.tryParse(data);
    if (push == null) return;
    _pushed[push.callId] = push;
    if (!client.handleIncomingPush(push)) {
      // Stale: it rang on CallKit, but there is no call to claim any more.
      _pushed.remove(push.callId);
      unawaited(_invoke('end', <String, Object?>{'key': push.callId, 'reason': 'failed'}));
      return;
    }
    if (!_pushes.isClosed) _pushes.add(push);
  }

  /// The SDK call on CallKit as [key], if it exists now.
  String? _callIdFor(String key) {
    for (final entry in _keys.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  Future<void> _onAction(String action, String key, Map<String, Object?> event) async {
    final push = _pushed[key];
    final callId = _callIdFor(key);
    final current = callId != null && callId == client.currentCallId;
    final state = client.callState;
    try {
      switch (action) {
        case 'accept':
          if (current && state != CallStateStatus.incoming) return; // answered already
          if (push != null) {
            client.reportCallScreenAccepted(push);
          } else if (current) {
            await client.acceptCall(callId);
          }
        case 'decline':
          if (push != null && !current) {
            client.reportCallScreenDeclined(push);
          } else if (current && state == CallStateStatus.incoming) {
            if (push != null) {
              client.reportCallScreenDeclined(push);
            } else {
              await client.rejectCall(callId);
            }
          } else if (current) {
            await client.hangup(callId);
          }
          _pushed.remove(key);
        case 'end':
          if (current && state == CallStateStatus.incoming) {
            await client.rejectCall(callId);
          } else if (current) {
            await client.hangup(callId);
          } else if (push != null) {
            // Accepted, but its call has not arrived: turn it away.
            client.reportCallScreenDeclined(push);
          }
          _pushed.remove(key);
        case 'mute':
          if (!current) return;
          final muted = event['muted'] == true;
          if (muted == client.isMuted) return;
          if (muted) {
            await client.mute(callId);
          } else {
            await client.unmute(callId);
          }
        case 'hold':
          if (!current) return;
          final held = event['held'] == true;
          if (held && state == CallStateStatus.active) await client.hold(callId);
          if (!held && state == CallStateStatus.held) await client.resume(callId);
        case 'reset':
          // CallKit dropped every call (it restarted): so does the SDK.
          if (state != CallStateStatus.idle && state != CallStateStatus.ended) await client.hangup();
          _keys.clear();
          _pushed.clear();
      }
    } catch (e) {
      debugPrint('VobizIosPush: CallKit $action for $key: $e');
    }
  }

  // ── From the SDK ───────────────────────────────────────────────────────────

  void _onCall(CallEvent e) {
    final inbound = e.direction == CallDirection.inbound;
    switch (e.state) {
      case CallStateStatus.incoming:
        final pushed = _pushFor(e);
        if (pushed != null) {
          // On CallKit since the push came.
          _keys[e.callId] = pushed.callId;
        } else if (showCallsOnCallKit && !_keys.containsKey(e.callId)) {
          final key = 'sip-${e.sipCallId ?? e.callId}';
          _keys[e.callId] = key;
          unawaited(_invoke('reportIncoming', <String, Object?>{
            'key': key,
            'caller': e.remoteIdentity,
            'handle': e.remoteIdentity,
          }));
        }
      case CallStateStatus.ringing:
      case CallStateStatus.connecting:
        // An outgoing call (or one answered without CallKit): its audio
        // starts now, for ringback and early media.
        if (!inbound || !_keys.containsKey(e.callId)) _startAppAudio(e.callId);
      case CallStateStatus.active:
        final key = _keys[e.callId];
        if (key != null) {
          // Answered in the app: CallKit takes it over (and its audio).
          unawaited(_invoke('answered', <String, Object?>{'key': key}));
        } else {
          _startAppAudio(e.callId);
        }
      case CallStateStatus.ended:
      case CallStateStatus.failed:
        final key = _keys.remove(e.callId);
        if (key != null) {
          _pushed.remove(key);
          final reason = e.state == CallStateStatus.failed ? 'failed' : (inbound && e.sipCode == 487 ? 'unanswered' : 'remoteEnded');
          unawaited(_invoke('end', <String, Object?>{'key': key, 'reason': reason}));
        }
        if (_appAudio.remove(e.callId)) unawaited(_invoke('audioStop'));
      default:
        break;
    }
  }

  void _startAppAudio(String callId) {
    if (_appAudio.add(callId)) unawaited(_invoke('audioStart'));
  }

  VobizIncomingPush? _pushFor(CallEvent e) {
    for (final push in _pushed.values) {
      if (push.matchesIncomingCall(sipCallId: e.sipCallId)) return push;
    }
    final current = client.pushedCall;
    if (current != null && client.isPushedCall(e.callId)) return current;
    return null;
  }

  void _onPushUpdate(VobizPushCallUpdate update) {
    if (update.status != VobizPushCallStatus.expired) return;
    final key = update.push.callId;
    if (_pushed.remove(key) == null) return;
    // No call came in time: it was missed.
    unawaited(_invoke('end', <String, Object?>{'key': key, 'reason': 'unanswered'}));
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No iOS side (a test, or the app was not rebuilt after adding the SDK).
    } on PlatformException catch (e) {
      debugPrint('VobizIosPush: $method failed: ${e.code} ${e.message}');
    }
  }
}

/// The Android side of the plugin: Dart only, as the SDK needs no Android
/// code of its own.
class VobizWebrtcAndroid {
  /// Called by Flutter's plugin registration.
  static void registerWith() {}
}
