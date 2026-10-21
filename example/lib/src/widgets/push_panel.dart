import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';

/// "Incoming calls": connects the app to the push bridge, so calls to the
/// Vobiz number ring this phone in the foreground, in the background and
/// after the app is swiped away.
class PushPanel extends StatefulWidget {
  const PushPanel({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<PushPanel> createState() => _PushPanelState();
}

class _PushPanelState extends State<PushPanel> {
  late final TextEditingController _server = TextEditingController(text: widget.controller.pushServer);
  bool _showServer = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  Future<void> _save([String? value]) async {
    final error = await widget.controller.setPushServer(value ?? _server.text);
    if (mounted) setState(() => _error = error);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _server.text = text;
    await _save(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pg = context.pg;
    final (chipText, chipColor) = switch (c.pushState) {
      PushState.off => ('OFF', pg.faint),
      PushState.registering => ('CONNECTING', pg.muted),
      PushState.ready => c.push.available ? ('PUSH ON', pg.success) : ('RINGS WHEN OPEN', pg.warning),
      PushState.failed => ('ERROR', pg.danger),
    };
    final canTest = c.pushState == PushState.ready && c.push.available;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pg.field,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: pg.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(children: <Widget>[
            Icon(Icons.ring_volume_outlined, size: 15, color: pg.accent.withValues(alpha: 0.85)),
            const SizedBox(width: 8),
            Text('INCOMING CALLS',
                style: TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
            const Spacer(),
            Chip2(chipText, color: chipColor),
          ]),
          const SizedBox(height: 8),
          Text(
            'Ring this phone for calls to your Vobiz number: while it is open, in the background, '
            'and after it is swiped away. Run example/push_bridge behind an https tunnel and '
            'paste the line it prints.',
            style: TextStyle(fontSize: 11, height: 1.45, color: pg.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pushServer'),
            controller: _server,
            obscureText: !_showServer,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              hintText: 'https://….trycloudflare.com#key=…',
              errorText: _error,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: _showServer ? 'Hide' : 'Show',
                    icon: Icon(_showServer ? Icons.visibility_off : Icons.visibility, size: 18),
                    onPressed: () => setState(() => _showServer = !_showServer),
                  ),
                  IconButton(
                    tooltip: 'Paste',
                    icon: const Icon(Icons.content_paste, size: 18),
                    onPressed: _paste,
                  ),
                ],
              ),
            ),
            onSubmitted: _save,
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              if (_server.text.trim() != c.pushServer) _save();
            },
          ),
          const SizedBox(height: 6),
          Row(children: <Widget>[
            Expanded(
              child: Text('Receive calls through the push server',
                  style: TextStyle(fontSize: 13, color: pg.text)),
            ),
            Switch(
              key: const Key('receiveCalls'),
              value: c.receiveCalls,
              onChanged: c.pushServer.isEmpty ? null : c.setReceiveCalls,
            ),
          ]),
          if (c.pushDetail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(c.pushDetail,
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: c.pushState == PushState.failed ? pg.danger : pg.muted)),
            ),
          _check(pg, 'Firebase push', c.push.available,
              c.push.available ? 'Wakes the app when it is closed' : (c.push.problem ?? '')),
          _check(pg, 'Notifications', c.notificationsAllowed,
              'The call screen is a notification',
              action: c.notificationsAllowed == true ? null : c.requestCallPermissions),
          _check(pg, 'Full-screen call screen', c.fullScreenAllowed,
              'Rings over the lock screen',
              action: c.fullScreenAllowed == false ? c.requestCallPermissions : null),
          _check(pg, 'Remember me', c.rememberMe,
              'Lets the app sign itself in to answer when it was closed'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('testCall'),
            onPressed: canTest ? c.sendTestCall : null,
            icon: const Icon(Icons.notifications_active_outlined, size: 16),
            label: const Text('Send a test call in 10 s'),
          ),
        ],
      ),
    );
  }

  /// One requirement: a tick, a cross, or a dash while unknown.
  Widget _check(PlaygroundColors pg, String label, bool? ok, String detail, {VoidCallback? action}) {
    final (icon, color) = switch (ok) {
      true => (Icons.check_circle, pg.success),
      false => (Icons.cancel, pg.danger),
      null => (Icons.remove_circle_outline, pg.faint),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: pg.text)),
                if (detail.isNotEmpty)
                  Text(detail, style: TextStyle(fontSize: 10.5, height: 1.35, color: pg.faint)),
              ],
            ),
          ),
          if (action != null)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: action,
              child: const Text('Allow'),
            ),
        ],
      ),
    );
  }
}
