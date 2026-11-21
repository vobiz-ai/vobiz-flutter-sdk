import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../playground_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The trace: every step of sign-in and every call event, as the Playground
/// logs them. Follows new lines while you are at the bottom, and stays put
/// when you scroll up to read.
class TracePanel extends StatefulWidget {
  const TracePanel({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<TracePanel> createState() => _TracePanelState();
}

class _TracePanelState extends State<TracePanel> {
  final ScrollController _scroll = ScrollController();
  bool _follow = true;
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom = _scroll.position.maxScrollExtent - _scroll.offset < 24;
      if (atBottom != _follow) setState(() => _follow = atBottom);
      if (atBottom) _seen = widget.controller.logs.length;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pg = context.pg;
    final logs = c.logs;
    if (logs.isEmpty) {
      // Cleared: the next lines start a new list, followed from the top.
      _follow = true;
      _seen = 0;
    }
    if (_follow) {
      _seen = logs.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final unseen = (logs.length - _seen).clamp(0, 9999);

    Color colorFor(LogType t) => switch (t) {
          LogType.error => pg.danger,
          LogType.success => pg.success,
          LogType.warning => pg.warning,
          LogType.event => pg.accent,
          LogType.info => pg.muted,
        };

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('TRACE',
                  style: TextStyle(fontSize: 11, letterSpacing: 1.8, fontWeight: FontWeight.w600, color: pg.faint)),
              const SizedBox(width: 8),
              if (logs.isNotEmpty) Chip2('${logs.length}', color: pg.accent),
              const Spacer(),
              IconButton(
                tooltip: 'Copy trace',
                onPressed: logs.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: c.logsText()));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('Trace copied')));
                      },
                icon: Icon(Icons.copy, size: 18, color: pg.faint),
              ),
              TextButton(onPressed: logs.isEmpty ? null : c.clearLogs, child: const Text('Clear')),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Stack(
              children: <Widget>[
                Container(
                  decoration: BoxDecoration(
                    color: pg.field,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: pg.border),
                  ),
                  child: logs.isEmpty
                      ? Center(
                          child: Text('No activity...',
                              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: pg.faint)))
                      : Scrollbar(
                          controller: _scroll,
                          thumbVisibility: true,
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(12),
                            itemCount: logs.length,
                            itemBuilder: (_, i) {
                              final l = logs[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(l.clock,
                                        style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: pg.faint)),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SelectableText(l.message,
                                          style: TextStyle(
                                              fontFamily: 'monospace', fontSize: 11.5, height: 1.35,
                                              color: colorFor(l.type))),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ),
                if (!_follow && unseen > 0)
                  Positioned(
                    bottom: 10,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: ActionChip(
                        avatar: const Icon(Icons.arrow_downward, size: 14),
                        label: Text('$unseen new'),
                        onPressed: _jumpToEnd,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
