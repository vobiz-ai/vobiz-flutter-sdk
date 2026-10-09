import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';

/// "Call headers": the custom headers sent or received on recent calls, kept
/// after each call ends so they can be inspected.
class CallHeadersPanel extends StatefulWidget {
  const CallHeadersPanel({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<CallHeadersPanel> createState() => _CallHeadersPanelState();
}

class _CallHeadersPanelState extends State<CallHeadersPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pg = context.pg;
    final records = c.callHeaders;
    String two(int v) => v.toString().padLeft(2, '0');

    return Container(
      decoration: BoxDecoration(
        color: pg.field,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: pg.border),
      ),
      child: Column(
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: <Widget>[
                  Icon(Icons.monitor_heart_outlined, size: 14, color: pg.accent.withValues(alpha: 0.8)),
                  const SizedBox(width: 8),
                  Text('CALL HEADERS',
                      style: TextStyle(
                          fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
                  if (records.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    Chip2('${records.length}', color: pg.accent),
                  ],
                  const Spacer(),
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: pg.faint),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: records.isEmpty
                  ? Text(
                      'Nothing yet. Headers arriving on an inbound call to this endpoint — from '
                      '<Dial><User sipHeaders="…"> or a caller\'s own X-VH- headers — are captured here.',
                      style: TextStyle(fontSize: 10.5, height: 1.4, color: pg.faint),
                    )
                  : Column(
                      children: <Widget>[
                        ...records.map((r) {
                          final inbound = r.direction == CallDirection.inbound;
                          return Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: pg.panel,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: pg.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(children: <Widget>[
                                  Chip2(inbound ? 'RECEIVED' : 'SENT',
                                      color: inbound ? pg.success : pg.info),
                                  const Spacer(),
                                  Text('${two(r.at.hour)}:${two(r.at.minute)}:${two(r.at.second)}',
                                      style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: pg.faint)),
                                ]),
                                const SizedBox(height: 6),
                                Text(
                                  '${inbound ? 'on the incoming INVITE' : 'sent on your INVITE'} · '
                                  '${r.events.join(', ')}',
                                  style: TextStyle(fontSize: 10, color: pg.faint),
                                ),
                                if (r.from.isNotEmpty)
                                  Text('from ${r.from}',
                                      style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: pg.muted)),
                                const SizedBox(height: 4),
                                HeaderTable(r.headers),
                              ],
                            ),
                          );
                        }),
                        Row(children: <Widget>[
                          TextButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: c.callHeadersJson()));
                              c.log('📋 Copied call headers to clipboard', LogType.success);
                            },
                            icon: const Icon(Icons.copy, size: 14),
                            label: const Text('Copy JSON'),
                          ),
                          TextButton.icon(
                            onPressed: c.clearCallHeaders,
                            icon: const Icon(Icons.clear_all, size: 14),
                            label: const Text('Clear'),
                          ),
                        ]),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}
