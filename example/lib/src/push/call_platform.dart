import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The example's own Android code (`android/app/src/main/kotlin/...`):
///
/// * `CallService`, the foreground service (types `phoneCall|microphone`)
///   that keeps the microphone and the process alive during every call,
///   inbound or outbound, however it was answered;
/// * `CallPushReceiver` + `CallEngine`, which hand each call push from
///   Vobiz's push service to the one Flutter engine that hosts both the SIP
///   connection and the UI, starting it (headless) when the app was closed;
/// * the missed-call notification.
///
/// And its iOS code (`ios/Runner/AppDelegate.swift`), on the same channel:
///
/// * PushKit, which hands each call push to Dart (`push`, [ready]) after
///   reporting it to CallKit;
/// * `startCallService` and `stopCallService`, which start and stop the
///   call's audio when CallKit does not carry it (outgoing calls, calls
///   answered in the app);
/// * the bundle id ([packageName]).
///
/// Every method is a no-op where that code is missing (tests, web) or the
/// platform has no such thing (iOS: [leaveLockScreen], [showMissedCall]).
class CallPlatform {
  CallPlatform() : _channel = const MethodChannel(channelName) {
    if (_supported) _channel.setMethodCallHandler(_onNativeCall);
  }

  /// For tests: talks to nothing.
  @visibleForTesting
  CallPlatform.forTesting() : _channel = const MethodChannel('$channelName/test');

  static const String channelName = 'ai.vobiz.example/call';

  final MethodChannel _channel;
  final StreamController<Map<String, String>> _pushes = StreamController<Map<String, String>>.broadcast();
  final StreamController<void> _hangUps = StreamController<void>.broadcast();

  static bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Call push data messages, as Android (or iOS PushKit) received them. They arrive here
  /// whether the app is open, in the background, or was started by the push
  /// itself.
  Stream<Map<String, String>> get pushes => _pushes.stream;

  /// "Hang up" tapped on the ongoing-call notification.
  Stream<void> get hangUpRequests => _hangUps.stream;

  /// Tells Android the Dart side listens now. Returns the pushes that
  /// arrived before it did (the push that started the app, typically).
  Future<List<Map<String, String>>> ready() async {
    final raw = await _invoke<List<Object?>>('ready');
    return <Map<String, String>>[
      for (final item in raw ?? const <Object?>[])
        if (item is Map) item.map((k, v) => MapEntry('$k', '$v')),
    ];
  }

  /// The app's package name (its Android application id) or iOS bundle id,
  /// or null where there is no native side. Vobiz pushes with the Firebase
  /// or APNs credential saved for it in the Vobiz Console.
  Future<String?> packageName() => _invoke<String>('packageName');

  /// Starts the foreground service for a call that is now ringing out,
  /// connecting or connected. Call it while the app is visible or right
  /// after the user's tap: Android 14 refuses a microphone service started
  /// from the background.
  Future<void> startCallService({required String caller, required bool outbound}) =>
      _invoke<void>('startCallService', <String, Object>{'caller': caller, 'outbound': outbound});

  /// Stops the foreground service: the call is over. An app that Accept
  /// opened over the lock screen goes back behind it.
  Future<void> stopCallService() => _invoke<void>('stopCallService');

  /// An accepted call screen led to no call: an app that Accept opened over
  /// the lock screen goes back behind it, unless a call is running.
  Future<void> leaveLockScreen() => _invoke<void>('leaveLockScreen');

  /// iOS: asks for permission to post notifications (missed calls), and says
  /// whether it was given. CallKit itself rings without it. Null elsewhere.
  Future<bool?> requestNotifications() => _invoke<bool>('requestNotifications');

  /// Posts a "Missed call" notification. One per [id]; a second post for
  /// the same call replaces the first.
  Future<void> showMissedCall({required String id, required String caller}) =>
      _invoke<void>('showMissedCall', <String, Object?>{'id': id, 'caller': caller});

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'push':
        final args = call.arguments;
        if (args is Map) _pushes.add(args.map((k, v) => MapEntry('$k', '$v')));
      case 'hangUp':
        _hangUps.add(null);
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('Call platform: $method failed: ${e.code} ${e.message}');
      return null;
    }
  }
}
