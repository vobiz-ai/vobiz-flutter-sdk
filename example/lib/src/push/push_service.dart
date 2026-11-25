import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart' show VobizIosPush;

import 'call_screen.dart';

/// Where Vobiz's push service reaches this phone: the device token it sends
/// to, and the notification permission. The pushes themselves reach the app
/// through its own native side (CallPlatform.pushes), in every app state.
///
/// * Android: Firebase Cloud Messaging. Without
///   `android/app/google-services.json` the app still rings for calls while
///   it is open; [available] is false and [problem] says why.
/// * iOS: PushKit VoIP pushes, through APNs, handled by the SDK
///   (VobizIosPush): the token, the call screen and the claim. No Firebase,
///   so [token] and [tokenRefresh] are Android's only.
class PushService {
  PushService._({required this.available, this.problem, this.voip = false});

  /// A service for tests and builds without push.
  PushService.unavailable(String this.problem)
      : available = false,
        voip = false;

  /// Push is set up, so Vobiz push can wake this app.
  final bool available;

  /// Why push is off, in words for the screen.
  final String? problem;

  /// iOS: PushKit VoIP pushes rather than Firebase.
  final bool voip;

  /// The platform Vobiz's push service sends to: `ios` (APNs) or `android`
  /// (Firebase).
  String get platform => voip ? 'ios' : 'android';

  /// What carries the pushes, for the screen.
  String get name => voip ? 'VoIP push (PushKit)' : 'Firebase push';

  /// Starts Firebase (Android), before `runApp`. Never throws.
  static Future<PushService> start() async {
    // iOS: the SDK registers for PushKit (VobizIosPush.start).
    if (VobizIosPush.isSupported) return PushService._(available: true, voip: true);
    if (!CallScreen.supported) {
      return PushService._(available: false, problem: 'Push needs Android or iOS.');
    }
    try {
      await Firebase.initializeApp();
    } catch (_) {
      return PushService._(
        available: false,
        problem: 'Firebase is not set up in this build. Add android/app/google-services.json '
            'and rebuild to ring this phone when the app is closed.',
      );
    }
    // No Dart background handler: it would start a second Flutter engine
    // for every push. The app's own receiver (CallPushReceiver.kt) hands
    // each push to the one engine that also runs the SIP connection and the
    // UI, starting it when the app is closed. See CallPlatform.
    return PushService._(available: true);
  }

  /// This device's Firebase token, or null without Firebase or a network
  /// (and on iOS: VobizIosPush has the VoIP token).
  Future<String?> token() async {
    if (!available || voip) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  /// Firebase replaces tokens now and then; Vobiz push must get the new one.
  /// (iOS: VobizIosPush.voipTokenChanges.)
  Stream<String> get tokenRefresh =>
      available && !voip ? FirebaseMessaging.instance.onTokenRefresh : const Stream<String>.empty();

  /// Android 13+: asks for the notification permission and says whether it
  /// was given. Null when it cannot tell (no Firebase). iOS: true, as CallKit
  /// rings without it.
  Future<bool?> requestNotificationPermission() async {
    if (voip) return true;
    if (!available) {
      await CallScreen.requestNotifications();
      return null;
    }
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      return _allowed(settings.authorizationStatus);
    } catch (_) {
      return null;
    }
  }

  /// Whether notifications are allowed, without asking.
  Future<bool?> notificationsAllowed() async {
    if (voip) return true;
    if (!available) return null;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return _allowed(settings.authorizationStatus);
    } catch (_) {
      return null;
    }
  }

  static bool _allowed(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized || status == AuthorizationStatus.provisional;
}
