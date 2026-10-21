import 'package:flutter/material.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'dialer_panel.dart';
import 'identity_panel.dart';
import 'trace_panel.dart';

/// Identity, Dialer and Trace: side by side on a wide screen, as tabs on a
/// phone — the same layout the web Playground uses.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.onTabRequest = (tab) {
      if (mounted && _tab != tab) setState(() => _tab = tab);
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pg = context.pg;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final panels = <Widget>[
          IdentityPanel(controller: c),
          DialerPanel(controller: c),
          TracePanel(controller: c),
        ];
        return LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth >= 1000) {
            return Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(flex: 5, child: panels[0]),
                      const SizedBox(width: 16),
                      Expanded(flex: 6, child: panels[1]),
                      const SizedBox(width: 16),
                      Expanded(flex: 5, child: panels[2]),
                    ],
                  ),
                ),
              ),
            );
          }
          final ringing = c.status == PhoneStatus.ringing || c.showIncoming;
          return Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: IndexedStack(index: _tab, children: panels),
              ),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: <Widget>[
                const NavigationDestination(
                    icon: Icon(Icons.badge_outlined), selectedIcon: Icon(Icons.badge), label: 'Identity'),
                NavigationDestination(
                  icon: Badge(isLabelVisible: ringing, backgroundColor: pg.warning, child: const Icon(Icons.dialpad)),
                  label: 'Dialer',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: c.logs.isNotEmpty && _tab != 2,
                    label: Text('${c.logs.length > 99 ? '99+' : c.logs.length}'),
                    child: const Icon(Icons.receipt_long_outlined),
                  ),
                  label: 'Trace',
                ),
              ],
            ),
          );
        });
      },
    );
  }
}
