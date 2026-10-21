import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart' as ck;

/// The system incoming-call screen (flutter_callkit_incoming): full screen on
/// a locked phone, a heads-up notification with Accept and Decline otherwise.
///
/// Every method swallows platform errors, so the app still works where the
/// plugin is missing (widget tests) or a permission was refused.
class CallScreen {
  CallScreen._();

  /// How long the screen rings before it turns into a missed call.
  static const Duration ringFor = Duration(seconds: 45);

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
          id: id,
          nameCaller: caller.isEmpty ? 'Unknown caller' : caller,
          appName: 'Vobiz Playground',
          handle: subtitle,
          type: 0,
          duration: ringFor.inMilliseconds,
          extra: extra,
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
          ios: const ck.IOSParams(handleType: 'generic', supportsVideo: false),
        )));
  }

  /// Stops ringing (or ends the ongoing-call notification) for [id].
  static Future<void> end(String id) async {
    if (!supported) return;
    await _guard(() => ck.FlutterCallkitIncoming.endCall(id));
  }

  /// The call the screen knows about: on Android, only the latest one.
  static Future<List<ck.CallKitParams>> active() async {
    if (!supported) return const <ck.CallKitParams>[];
    return await _guard(ck.FlutterCallkitIncoming.activeCalls) ?? const <ck.CallKitParams>[];
  }

  /// Android 13+: asks for the notification permission, without which
  /// nothing rings. The plugin does not report the answer; [PushService]
  /// reads it back through Firebase when Firebase is set up.
  static Future<void> requestNotifications() async {
    if (!supported) return;
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
    if (!supported) return null;
    return _guard(ck.FlutterCallkitIncoming.canUseFullScreenIntent);
  }

  /// Opens the system setting for full-screen notifications.
  static Future<void> requestFullScreen() async {
    if (!supported) return;
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

  Future<List<ck.CallKitParams>> active() => CallScreen.active();

  Future<bool?> canUseFullScreen() => CallScreen.canUseFullScreen();

  Future<void> requestFullScreen() => CallScreen.requestFullScreen();
}
