import 'package:flutter/material.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';

/// The "SIP Headers" panel: custom `X-VH-` headers sent on the INVITE, the
/// Dial-User shortcut and the "Record this call" switch.
class SipHeaderEditor extends StatefulWidget {
  const SipHeaderEditor({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<SipHeaderEditor> createState() => _SipHeaderEditorState();
}

class _SipHeaderEditorState extends State<SipHeaderEditor> {
  late bool _open = widget.controller.headerRows.isNotEmpty;
  final Map<int, (TextEditingController, TextEditingController)> _fields =
      <int, (TextEditingController, TextEditingController)>{};

  @override
  void dispose() {
    for (final f in _fields.values) {
      f.$1.dispose();
      f.$2.dispose();
    }
    super.dispose();
  }

  (TextEditingController, TextEditingController) _fieldsFor(HeaderRow row) {
    return _fields.putIfAbsent(
      row.id,
      () => (TextEditingController(text: row.name), TextEditingController(text: row.value)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pg = context.pg;
    // Forget fields for rows that were removed.
    _fields.removeWhere((id, f) {
      final gone = !c.headerRows.any((r) => r.id == id);
      if (gone) {
        f.$1.dispose();
        f.$2.dispose();
      }
      return gone;
    });

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
                  Icon(Icons.tag, size: 14, color: pg.accent.withValues(alpha: 0.8)),
                  const SizedBox(width: 8),
                  Text('SIP HEADERS',
                      style: TextStyle(
                          fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
                  if (c.activeHeaderCount > 0) ...<Widget>[
                    const SizedBox(width: 8),
                    Chip2('${c.activeHeaderCount}', color: pg.accent),
                  ],
                  if (c.recordCall) ...<Widget>[
                    const SizedBox(width: 6),
                    Chip2('REC', color: pg.danger),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Names must be X-VH- plus 1-19 letters, digits or hyphens. Values allow '
                    'A-Z a-z 0-9 _ - + ( ) % . up to 120 chars, no spaces. Vobiz delivers them '
                    'to your answer webhook as top-level parameters.',
                    style: TextStyle(fontSize: 10.5, height: 1.4, color: pg.faint),
                  ),
                  const SizedBox(height: 10),
                  ...c.headerRows.map((row) => _row(row, c, pg)),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: () => c.addHeaderRow(),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add header'),
                      ),
                      Tooltip(
                        message: 'Ring a SIP endpoint instead of the dialled number — '
                            'the value is the endpoint username',
                        child: OutlinedButton.icon(
                          onPressed: () => c.addHeaderRow(name: VobizSipHeaders.dialUser),
                          icon: const Icon(Icons.phone_forwarded, size: 16),
                          label: const Text('Dial-User'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => c.setRecordCall(!c.recordCall),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Checkbox(value: c.recordCall, onChanged: (v) => c.setRecordCall(v ?? false)),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(children: <Widget>[
                                  Icon(Icons.fiber_manual_record, size: 12, color: pg.danger),
                                  const SizedBox(width: 6),
                                  Text('Record this call', style: TextStyle(fontSize: 13, color: pg.text)),
                                ]),
                                const SizedBox(height: 2),
                                Text(
                                  'Sends ${VobizSipHeaders.record}: true, which makes the answer webhook '
                                  'emit a session <Record>. The file link appears in the trace once the '
                                  'call ends.',
                                  style: TextStyle(fontSize: 10.5, height: 1.4, color: pg.faint),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(HeaderRow row, PlaygroundController c, PlaygroundColors pg) {
    final fields = _fieldsFor(row);
    final pristine = row.isPristine;
    final keyError = pristine ? null : VobizSipHeaders.validateName(row.name.trim());
    // A blank value is flagged only after a call was attempted, so a fresh row
    // does not look broken.
    final valueError = !pristine && keyError == null &&
            (row.value.trim().isNotEmpty || c.headerSubmitAttempted)
        ? VobizSipHeaders.validateValue(row.name.trim(), row.value.trim())
        : null;
    InputDecoration deco(String hint, String? error) => InputDecoration(
          hintText: hint,
          errorText: null,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          enabledBorder: error == null
              ? null
              : OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: pg.danger.withValues(alpha: 0.6)),
                ),
        );
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 11.5);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // Names run to 24 characters, values are usually short: give the
              // name the larger share so X-VH-DialUser is not cut off on a phone.
              Expanded(
                flex: 3,
                child: TextField(
                  controller: fields.$1,
                  style: mono,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: deco('X-VH-Order-Id', keyError),
                  onChanged: (v) => c.updateHeaderRow(row.id, name: v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: fields.$2,
                  style: mono,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: deco(row.name.toUpperCase() == VobizSipHeaders.dialUser.toUpperCase()
                      ? 'play123'
                      : 'A1234', valueError),
                  onChanged: (v) => c.updateHeaderRow(row.id, value: v),
                ),
              ),
              IconButton(
                tooltip: 'Remove header',
                onPressed: () => c.removeHeaderRow(row.id),
                icon: Icon(Icons.delete_outline, size: 18, color: pg.faint),
              ),
            ],
          ),
          if (keyError != null || valueError != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: Text(keyError ?? valueError!, style: TextStyle(fontSize: 10.5, color: pg.danger)),
            ),
        ],
      ),
    );
  }
}
