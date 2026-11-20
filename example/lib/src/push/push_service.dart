import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'call_screen.dart';

/// Firebase Cloud Messaging for the running app: the device token Vobiz's
/// push service sends to, and the notification permission. The pushes
/// themselves reach the app through its own receiver (CallPlatform.pushes),
/// in every app state.
///
/// Push is optional. Without `android/app/google-services.json` the app
/// still rings for calls while it is open; [available] is false and
/// [problem] says why.
class PushService {
  PushService._({required this.available, this.problem});

  /// A service for tests and builds without push.
  PushService.unavailable(String this.problem) : available = false;

  /// Firebase is set up, so Vobiz push can wake this app.
  final bool available;

  /// Why push is off, in words for the screen.
  final String? problem;

  /// Starts Firebase, before `runApp`. Never throws.
  static Future<PushService> start() async {
    if (!CallScreen.supported) {
      return PushService._(
          available: false, problem: 'Push in this example is Android-only for now.');
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

  /// This device's Firebase token, or null without Firebase or a network.
  Future<String?> token() async {
    if (!available) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  /// Firebase replaces tokens now and then; Vobiz push must get the new one.
  Stream<String> get tokenRefresh =>
      available ? FirebaseMessaging.instance.onTokenRefresh : const Stream<String>.empty();

  /// Android 13+: asks for the notification permission and says whether it
  /// was given. Null when it cannot tell (no Firebase).
  Future<bool?> requestNotificationPermission() async {
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
