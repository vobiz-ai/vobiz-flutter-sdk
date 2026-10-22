import 'dart:async';

import 'package:flutter/widgets.dart';

/// Tells the client when the app comes to the foreground or leaves it.
///
/// The client re-registers each time the app returns to the foreground (see
/// [SdkConfig.reregisterOnForeground]): a phone's IP address often changes
/// while it is locked or the app is in the background, and the registrar
/// would otherwise keep sending calls to the old one.
///
/// The default, [PlatformAppLifecycleMonitor], follows Flutter's
/// [AppLifecycleState]. Supply your own to [VobizClient] to drive it from
/// another source, or in tests.
abstract class AppLifecycleMonitor {
  /// `true` when the app comes to the foreground, `false` when it leaves.
  ///
  /// Listened to from sign-in until sign-out.
  Stream<bool> get foregroundChanges;
}

/// [AppLifecycleMonitor] backed by [WidgetsBinding]: `resumed` is the
/// foreground; `hidden`, `paused` and `detached` are the background.
///
/// `inactive` is neither. It is the brief state on the way to the background,
/// and also what an app sees while the notification shade, Control Center or
/// a system dialog covers it, which is not leaving the foreground.
///
/// Reports nothing when no binding is initialized (plain unit tests).
class PlatformAppLifecycleMonitor implements AppLifecycleMonitor {
  @override
  Stream<bool> get foregroundChanges {
    late final StreamController<bool> controller;
    _Observer? observer;
    controller = StreamController<bool>(
      onListen: () {
        final WidgetsBinding binding;
        try {
          binding = WidgetsBinding.instance;
        } catch (_) {
          return;
        }
        observer = _Observer(controller.add);
        binding.addObserver(observer!);
      },
      onCancel: () {
        final o = observer;
        observer = null;
        if (o != null) WidgetsBinding.instance.removeObserver(o);
      },
    );
    return controller.stream;
  }
}

class _Observer with WidgetsBindingObserver {
  _Observer(this._onForeground);

  final void Function(bool foreground) _onForeground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _onForeground(true);
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _onForeground(false);
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }
}

/// An [AppLifecycleMonitor] that never reports anything.
class NoAppLifecycleMonitor implements AppLifecycleMonitor {
  const NoAppLifecycleMonitor();

  @override
  Stream<bool> get foregroundChanges => const Stream<bool>.empty();
}
