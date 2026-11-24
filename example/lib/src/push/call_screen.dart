import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart' as ck;

/// The system incoming-call screen (flutter_callkit_incoming): full screen on
/// a locked phone, a heads-up notification with Accept and Decline otherwise.
/// On iOS it is CallKit.
///
/// The app names each call screen by a key: the pushed call's id, or
/// `sip-<call id>` for a call that rings over SIP. Android takes the key as
/// the screen's id. CallKit takes only UUIDs, so on iOS the id is a UUID made
/// from the key ([uuidFor]), the same one the app's iOS side
/// (`AppDelegate.screenId`) makes for a pushed call, and the key rides in
/// the screen's `extra` ([keyOf]).
///
/// Every method swallows platform errors, so the app still works where the
/// plugin is missing (widget tests) or a permission was refused.
class CallScreen {
  CallScreen._();

  /// How long the screen rings before it turns into a missed call.
  static const Duration ringFor = Duration(seconds: 45);

  static bool get supported => isAndroid || isIOS;

  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// iOS shows a pushed call's screen itself, before Dart hears of the push
  /// (PushKit requires it); Android leaves it to Dart.
  static bool get showsPushedCallsNatively => isIOS;

  /// The screen id for [key]: [key] itself on Android, [uuidFor] on iOS.
  static String idFor(String key) {
    if (!isIOS) return key;
    final id = uuidFor(key);
    _keyById[id] = key;
    return id;
  }

  /// The key of a call screen the plugin reports.
  static String keyOf(ck.CallKitParams params) {
    final key = params.extra?['key'];
    if (key is String && key.isNotEmpty) {
      _keyById[params.id.toLowerCase()] = key;
      return key;
    }
    return keyOfId(params.id);
  }

  /// The key of a screen known only by its id (a timeout reports no more).
  static String keyOfId(String id) => _keyById[id.toLowerCase()] ?? id;

  static final Map<String, String> _keyById = <String, String>{};

  /// A name-based UUID (version 5, URL namespace) for [key], in lower case.
  static String uuidFor(String key) {
    const namespace = <int>[
      0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, //
      0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
    ];
    final h = List<int>.of(sha1.convert(<int>[...namespace, ...utf8.encode(key)]).bytes.take(16));
    h[6] = (h[6] & 0x0f) | 0x50;
    h[8] = (h[8] & 0x3f) | 0x80;
    final hex = h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Accept, Decline, timeout and hang-up taps, while the app is running.
  ///
  /// Checks the plugin answers first: listening to its event channel where
  /// it is missing (widget tests) reports an error instead of throwing one.
  static Stream<ck.CallEvent?> get events async* {
    if (!supported) return;
    try {
      await ck.FlutterCallkitIncoming.activeCalls();
    } on MissingPluginException {
      return;
    } on PlatformException {
      // The plugin is there; the call list just could not be read.
    }
    yield* ck.FlutterCallkitIncoming.onEvent;
  }

  static Future<void> showIncoming({
    required String id,
    required String caller,
    String subtitle = 'Vobiz call',
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    if (!supported) return;
    await _guard(() => ck.FlutterCallkitIncoming.showCallkitIncoming(ck.CallKitParams(
          id: idFor(id),
          nameCaller: caller.isEmpty ? 'Unknown caller' : caller,
          appName: 'Vobiz Playground',
          handle: subtitle,
          type: 0,
          duration: ringFor.inMilliseconds,
          extra: <String, dynamic>{...extra, 'key': id},
          // The app posts missed calls itself (CallPlatform.showMissedCall),
          // from how the call really ended. The plugin's own appears only on
          // its 45 s timeout: also for a call answered elsewhere, never when
          // the caller hangs up.
          missedCallNotification: const ck.NotificationParams(
            showNotification: false,
            isShowCallback: false,
            subtitle: 'Missed call',
          ),
          callingNotification: const ck.NotificationParams(
            showNotification: true,
            isShowCallback: true,
            subtitle: 'On a call',
            callbackText: 'Hang up',
          ),
          android: const ck.AndroidParams(
            isCustomNotification: true,
            isShowLogo: false,
            isShowCallID: false,
            isShowFullLockedScreen: true,
            ringtonePath: 'system_ringtone_default',
            backgroundColor: '#0A0C10',
            actionColor: '#16A34A',
            textColor: '#FFFFFF',
            incomingCallNotificationChannelName: 'Incoming calls',
            missedCallNotificationChannelName: 'Missed calls',
            textAccept: 'Accept',
            textDecline: 'Decline',
          ),
          // WebRTC's audio waits for CallKit to activate the session (the
          // iOS side's CallAudio); the plugin must not activate it first.
          ios: const ck.IOSParams(handleType: 'generic', supportsVideo: false, configureAudioSession: false),
        )));
  }

  /// Stops ringing (or ends the ongoing-call notification, or the CallKit
  /// call) for the screen with key [id].
  static Future<void> end(String id) async {
    if (!supported) return;
    await _guard(() => ck.FlutterCallkitIncoming.endCall(idFor(id)));
  }

  /// iOS: the call answered on CallKit is connected, so CallKit counts its
  /// time. It stays on CallKit until it ends ([end]).
  static Future<void> connected(String id) async {
    if (!isIOS) return;
    await _guard(() => ck.FlutterCallkitIncoming.setCallConnected(idFor(id)));
  }

  /// iOS: shows the CallKit call [id] as muted or not, after a mute in the
  /// app. CallKit reports its own mute button as a CallEvent.
  static Future<void> setMuted(String id, bool muted) async {
    if (!isIOS) return;
    await _guard(() => ck.FlutterCallkitIncoming.muteCall(idFor(id), isMuted: muted));
  }

  /// iOS: this phone's PushKit VoIP token, which Vobiz pushes calls to.
  /// Null until PushKit has given one (soon after launch), and on Android.
  static Future<String?> voipToken() async {
    if (!isIOS) return null;
    final token = await _guard(ck.FlutterCallkitIncoming.getDevicePushTokenVoIP);
    return token == null || token.isEmpty ? null : token;
  }

  /// The call the screen knows about: on Android, only the latest one. Read
  /// each one's key with [keyOf].
  static Future<List<ck.CallKitParams>> active() async {
    if (!supported) return const <ck.CallKitParams>[];
    return await _guard(ck.FlutterCallkitIncoming.activeCalls) ?? const <ck.CallKitParams>[];
  }

  /// Android 13+: asks for the notification permission, without which
  /// nothing rings. The plugin does not report the answer; [PushService]
  /// reads it back through Firebase when Firebase is set up.
  static Future<void> requestNotifications() async {
    if (!isAndroid) return;
    await _guard(() => ck.FlutterCallkitIncoming.requestNotificationPermission(<String, String>{
          'title': 'Allow notifications',
          'rationaleMessagePermission':
              'Incoming calls ring as a notification. Allow notifications to receive calls.',
          'postNotificationMessageRequired':
              'Incoming calls need notifications. Allow them in Settings → Notifications.',
        }));
  }

  /// Android 14+: whether the call can take over a locked screen.
  static Future<bool?> canUseFullScreen() async {
    if (!isAndroid) return null;
    return _guard(ck.FlutterCallkitIncoming.canUseFullScreenIntent);
  }

  /// Opens the system setting for full-screen notifications.
  static Future<void> requestFullScreen() async {
    if (!isAndroid) return;
    await _guard(ck.FlutterCallkitIncoming.requestFullIntentPermission);
  }

  static Future<T?> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('Call screen: ${e.code} ${e.message}');
      return null;
    }
  }
}

/// [CallScreen] as an object, so the app can be tested without the plugin.
class CallScreenApi {
  const CallScreenApi();

  Stream<ck.CallEvent?> get events => CallScreen.events;

  Future<void> showIncoming({
    required String id,
    required String caller,
    String subtitle = 'Vobiz call',
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) =>
      CallScreen.showIncoming(id: id, caller: caller, subtitle: subtitle, extra: extra);

  Future<void> end(String id) => CallScreen.end(id);

  Future<void> connected(String id) => CallScreen.connected(id);

  Future<void> setMuted(String id, bool muted) => CallScreen.setMuted(id, muted);

  String keyOf(ck.CallKitParams params) => CallScreen.keyOf(params);

  String keyOfId(String id) => CallScreen.keyOfId(id);

  Future<List<ck.CallKitParams>> active() => CallScreen.active();

  Future<bool?> canUseFullScreen() => CallScreen.canUseFullScreen();

  Future<void> requestFullScreen() => CallScreen.requestFullScreen();
}
