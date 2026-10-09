import 'package:flutter/material.dart';

import 'playground_controller.dart';
import 'screens/home_shell.dart';
import 'theme.dart';

/// The Vobiz Playground for Flutter.
class PlaygroundApp extends StatefulWidget {
  const PlaygroundApp({super.key, this.controller});

  /// Injected by tests; the app makes its own otherwise.
  final PlaygroundController? controller;

  @override
  State<PlaygroundApp> createState() => _PlaygroundAppState();
}

class _PlaygroundAppState extends State<PlaygroundApp> {
  late final PlaygroundController _controller = widget.controller ?? PlaygroundController();

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
        title: 'Vobiz Playground',
        debugShowCheckedModeBanner: false,
        themeMode: _controller.themeMode,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: HomeShell(controller: _controller),
      ),
    );
  }
}
