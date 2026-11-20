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
/// Every method is a no-op where that code is missing (tests, iOS, web).
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

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Call push data messages, as Android received them. They arrive here
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

  /// The app's package name (its Android application id), or null where
  /// there is no Android side. Vobiz pushes with the Firebase credential
  /// saved for it in the Vobiz Console.
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
