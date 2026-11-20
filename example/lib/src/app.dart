import 'package:flutter/material.dart';

import 'playground_controller.dart';
import 'push/push_service.dart';
import 'screens/home_shell.dart';
import 'theme.dart';

/// The Vobiz Playground for Flutter.
class PlaygroundApp extends StatefulWidget {
  const PlaygroundApp({super.key, this.controller, this.push});

  /// Injected by tests; the app makes its own otherwise.
  final PlaygroundController? controller;

  /// Firebase push, started in main() before the app runs.
  final PushService? push;

  @override
  State<PlaygroundApp> createState() => _PlaygroundAppState();
}

class _PlaygroundAppState extends State<PlaygroundApp> {
  late final PlaygroundController _controller =
      widget.controller ?? PlaygroundController(push: widget.push);

  /// Back in the app (from Settings, where "Allow" sends the user for
  /// full-screen calls, or from the background): read the call permissions
  /// again, so the Incoming calls checks are current.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _controller.refreshCallPermissions);
    _controller.init();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Only the theme rebuilds the app; each screen listens for what it shows.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _controller.theme,
      builder: (context, mode, home) => MaterialApp(
        title: 'Vobiz Playground',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: home,
      ),
      child: HomeShell(controller: _controller),
    );
  }
}
