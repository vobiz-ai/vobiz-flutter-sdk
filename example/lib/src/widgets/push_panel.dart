import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';

/// "Incoming calls" (Vobiz push, which rings this phone also when the app is
/// closed) and "Sample server" (the line example/push_bridge prints).
class PushPanel extends StatefulWidget {
  const PushPanel({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<PushPanel> createState() => _PushPanelState();
}

class _PushPanelState extends State<PushPanel> {
  late final TextEditingController _server = TextEditingController(text: widget.controller.pushServer);
  late final TextEditingController _pushAuthId = TextEditingController(text: widget.controller.pushAuthId);
  late final TextEditingController _pushAuthToken = TextEditingController(text: widget.controller.pushAuthToken);
  late final TextEditingController _callFrom = TextEditingController(text: widget.controller.vobizCallFrom);
  late final TextEditingController _callAnswerUrl = TextEditingController(text: widget.controller.vobizCallAnswerUrl);
  bool _showServer = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _pushAuthId.dispose();
    _pushAuthToken.dispose();
    _callFrom.dispose();
    _callAnswerUrl.dispose();
    super.dispose();
  }

  Future<void> _savePushAccount() async {
    await widget.controller.setVobizCallTest(from: _callFrom.text, answerUrl: _callAnswerUrl.text);
    await widget.controller.setPushAccount(authId: _pushAuthId.text, authToken: _pushAuthToken.text);
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
          ..._incomingCalls(c, pg),
          const SizedBox(height: 14),
          Divider(color: pg.border, height: 1),
          const SizedBox(height: 12),
          ..._sampleServer(c, pg),
        ],
      ),
    );
  }

  /// Ringing this phone, also when closed, through Vobiz push: Vobiz holds
  /// the call, pushes, and sends it to the REGISTER that claims it.
  List<Widget> _incomingCalls(PlaygroundController c, PlaygroundColors pg) {
    final (chipText, chipColor) = switch (c.vobizPushState) {
      PushState.off => ('OFF', pg.faint),
      PushState.registering => ('REGISTERING', pg.muted),
      PushState.ready => ('REGISTERED', pg.success),
      PushState.failed => ('ERROR', pg.danger),
    };
    return <Widget>[
      Row(children: <Widget>[
        Icon(Icons.ring_volume_outlined, size: 15, color: pg.accent.withValues(alpha: 0.85)),
        const SizedBox(width: 8),
        Expanded(
          child: Text('INCOMING CALLS',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
        ),
        Chip2(chipText, color: chipColor),
      ]),
      const SizedBox(height: 8),
      Text(
        'Ring this phone for calls to the SIP user you sign in as, also when the app is closed: Vobiz '
        'holds the call, pushes this phone, and the app claims the call as it signs in. Needs this '
        "app's Firebase key under Push Notifications in the Vobiz Console. With a sample server line "
        'below, this phone signs up through the server.',
        style: TextStyle(fontSize: 11, height: 1.45, color: pg.muted),
      ),
      Row(children: <Widget>[
        Expanded(child: Text('Receive calls through Vobiz push', style: TextStyle(fontSize: 13, color: pg.text))),
        Switch(key: const Key('vobizPush'), value: c.vobizPush, onChanged: c.setVobizPush),
      ]),
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
      if (c.vobizPush) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          'TEST ONLY: without a sample server line, signing this phone up takes the account\'s Auth ID '
          'and Auth Token (its API key), sent straight to Vobiz. The test call below always takes them. '
          'Left empty, the Zero-Config ones are used.',
          style: TextStyle(fontSize: 10.5, height: 1.35, color: pg.warning),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('pushAuthId'),
          controller: _pushAuthId,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(labelText: 'Account Auth ID', hintText: 'MA_…'),
          onSubmitted: (_) => _savePushAccount(),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('pushAuthToken'),
          controller: _pushAuthToken,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(labelText: 'Account Auth Token (test only)'),
          onSubmitted: (_) => _savePushAccount(),
        ),
        const SizedBox(height: 10),
        Text(
          'TEST CALL: to try it without a second phone, Vobiz\'s Call API calls this phone. It needs a '
          'caller ID (a number on the account) and an answer URL (any https address that returns Vobiz XML, '
          'fetched when the call is answered).',
          style: TextStyle(fontSize: 10.5, height: 1.35, color: pg.warning),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('testCallFrom'),
          controller: _callFrom,
          keyboardType: TextInputType.phone,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(labelText: 'Caller ID (a number on the account)', hintText: '14155551234'),
          onSubmitted: (_) => _savePushAccount(),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('testCallAnswerUrl'),
          controller: _callAnswerUrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(labelText: 'Answer URL (returns Vobiz XML)', hintText: 'https://…'),
          onSubmitted: (_) => _savePushAccount(),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(key: const Key('savePushAccount'), onPressed: _savePushAccount, child: const Text('Save')),
        ),
      ],
      if (c.vobizPushDetail.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(c.vobizPushDetail,
              style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: c.vobizPushState == PushState.failed ? pg.danger : pg.muted)),
        ),
      OutlinedButton.icon(
        key: const Key('vobizTestCall'),
        onPressed: c.vobizPushState == PushState.ready && c.client.isConnected && !c.vobizCallPlacing
            ? c.callThisPhoneThroughVobiz
            : null,
        icon: const Icon(Icons.phone_callback_outlined, size: 16),
        label: const Text('Call this phone through Vobiz'),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Drops the connection without signing off, as when Android closes the app, then places a real '
          'call: Vobiz should push this phone, and the app sign back in to take it.',
          style: TextStyle(fontSize: 10.5, height: 1.35, color: pg.faint),
        ),
      ),
    ];
  }

  /// The sample server (example/push_bridge): access tokens, Conference, the
  /// connection watch and Vobiz push sign-up. It does not wake a closed app.
  List<Widget> _sampleServer(PlaygroundController c, PlaygroundColors pg) {
    return <Widget>[
      Row(children: <Widget>[
        Icon(Icons.dns_outlined, size: 15, color: pg.accent.withValues(alpha: 0.85)),
        const SizedBox(width: 8),
        Text('SAMPLE SERVER',
            style: TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
      ]),
      const SizedBox(height: 8),
      Text(
        'For access tokens, Conference, the connection watch, and signing this phone up for Vobiz push '
        'without the account\'s Auth Token on the phone. Run example/push_bridge behind an https tunnel '
        'and paste the line it prints. It does not wake a closed app: Vobiz push does.',
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
          child: Text('Let the sample server watch my calls', style: TextStyle(fontSize: 13, color: pg.text)),
        ),
        Switch(
          key: const Key('connectionWatch'),
          value: c.connectionWatch,
          onChanged: c.pushServer.isEmpty ? null : c.setConnectionWatch,
        ),
      ]),
      Text(
        'During a call the app reports to the server every second. When the reports stop (this phone '
        'lost its network), the server plays a tone to the other side and ends the call a few seconds '
        'later. Starts with the next call.',
        style: TextStyle(fontSize: 10.5, height: 1.35, color: pg.faint),
      ),
    ];
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
