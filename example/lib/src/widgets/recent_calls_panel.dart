import 'package:flutter/material.dart';

import '../call_history.dart';
import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';

/// "Recent calls": the local call log, with missed calls marked.
class RecentCallsPanel extends StatefulWidget {
  const RecentCallsPanel({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<RecentCallsPanel> createState() => _RecentCallsPanelState();
}

class _RecentCallsPanelState extends State<RecentCallsPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return ListenableBuilder(
      listenable: widget.controller.history,
      builder: (context, _) {
        final records = widget.controller.history.records;
        final missed = records.where((r) => r.outcome.notifies).length;
        return Container(
          decoration: BoxDecoration(
            color: pg.field,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: pg.border),
          ),
          child: Column(
            children: <Widget>[
              InkWell(
                key: const Key('recentCalls'),
                borderRadius: BorderRadius.circular(18),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.history, size: 14, color: pg.accent.withValues(alpha: 0.8)),
                      const SizedBox(width: 8),
                      Text('RECENT CALLS',
                          style: TextStyle(
                              fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
                      if (missed > 0) ...<Widget>[
                        const SizedBox(width: 8),
                        Chip2('$missed missed', color: pg.danger),
                      ],
                      const Spacer(),
                      Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: pg.faint),
                    ],
                  ),
                ),
              ),
              if (_open && records.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: Text('No calls yet', style: TextStyle(fontSize: 11, color: pg.faint)),
                ),
              if (_open)
                for (final r in records.take(20)) _row(r, pg),
              if (_open && records.isNotEmpty)
                TextButton(onPressed: widget.controller.history.clear, child: const Text('Clear')),
            ],
          ),
        );
      },
    );
  }

  Widget _row(CallRecord r, PlaygroundColors pg) {
    final (IconData icon, Color color) = switch (r.outcome) {
      CallOutcome.answered => (Icons.call_received, pg.success),
      CallOutcome.missed || CallOutcome.busy => (Icons.call_missed, pg.danger),
      CallOutcome.declined => (Icons.call_end, pg.warning),
      CallOutcome.answeredElsewhere => (Icons.devices_other, pg.muted),
      CallOutcome.outgoing => (Icons.call_made, pg.info),
      CallOutcome.failed => (Icons.call_missed_outgoing, pg.danger),
    };
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${two(r.at.day)}/${two(r.at.month)} ${two(r.at.hour)}:${two(r.at.minute)}';
    final length = r.duration > Duration.zero
        ? ' · ${two(r.duration.inMinutes)}:${two(r.duration.inSeconds % 60)}'
        : '';
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18, color: color),
      title: Text(r.party.isEmpty ? 'Unknown caller' : r.party,
          style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: pg.text)),
      subtitle: Text('${r.outcome.label} · $when$length', style: TextStyle(fontSize: 11, color: pg.faint)),
    );
  }
}
