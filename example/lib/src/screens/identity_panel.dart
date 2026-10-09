import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import '../playground_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/push_panel.dart';
import '../widgets/vobiz_logo.dart';

/// Sign in: Zero-Config Setup (Auth ID + Auth Token) or SIP Direct (an
/// endpoint's username and password). Nothing is pre-filled from code.
class IdentityPanel extends StatefulWidget {
  const IdentityPanel({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<IdentityPanel> createState() => _IdentityPanelState();
}

class _IdentityPanelState extends State<IdentityPanel> {
  late final TextEditingController _authId = TextEditingController(text: widget.controller.authId);
  late final TextEditingController _authToken = TextEditingController(text: widget.controller.authToken);
  late final TextEditingController _sipUser = TextEditingController(text: widget.controller.sipUsername);
  late final TextEditingController _sipPass = TextEditingController(text: widget.controller.sipPassword);
  bool _showToken = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _authId.dispose();
    _authToken.dispose();
    _sipUser.dispose();
    _sipPass.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(IdentityPanel old) {
    super.didUpdateWidget(old);
    _sync(_authId, widget.controller.authId);
    _sync(_authToken, widget.controller.authToken);
    _sync(_sipUser, widget.controller.sipUsername);
    _sync(_sipPass, widget.controller.sipPassword);
  }

  void _sync(TextEditingController field, String value) {
    if (field.text != value) field.text = value;
  }

  Future<void> _editWebhook() async {
    final c = widget.controller;
    final field = TextEditingController(text: c.webhookUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.pg.panel,
        title: const Text('Webhook server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Zero-Config points your application\'s answer URL at <this>/api/answer, so '
              'Vobiz must reach it over HTTPS. Keep the hosted server unless you run your '
              'own Playground server (or an https tunnel to one).',
              style: TextStyle(fontSize: 12, height: 1.4, color: context.pg.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'https://abc.ngrok-free.app'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(SdkConfig.defaultWebhookUrl),
            child: const Text('Use hosted'),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
            onPressed: () => Navigator.of(context).pop(field.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (result != null && result.isNotEmpty) c.update(() => c.webhookUrl = result);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pg = context.pg;
    final connecting = c.status == PhoneStatus.connecting;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const VobizBrand(),
              const Spacer(),
              ThemeToggle(mode: c.themeMode, onChanged: c.setThemeMode),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                if (!c.isSignedIn) ..._signInForm(c, pg, connecting) else _connected(c, pg),
                const SizedBox(height: 18),
                PushPanel(controller: c),
                const SizedBox(height: 28),
                _faq(pg),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _signInForm(PlaygroundController c, PlaygroundColors pg, bool connecting) {
    final zero = c.authTab == AuthTab.zeroConfig;
    return <Widget>[
      Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: pg.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: pg.border),
        ),
        child: Row(
          children: <Widget>[
            _tab('Zero-Config Setup', Icons.code, zero, () => c.setAuthTab(AuthTab.zeroConfig), pg),
            _tab('SIP Direct', Icons.call_outlined, !zero, () => c.setAuthTab(AuthTab.sipDirect), pg),
          ],
        ),
      ),
      const SizedBox(height: 18),
      if (zero) ...<Widget>[
        const SectionLabel('Auth ID',
            trailing: InfoTip(
                title: 'Auth ID', message: 'Found in your Vobiz Console Dashboard.')),
        TextField(
          key: const Key('authId'),
          controller: _authId,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'e.g. MA_XXXXXXX'),
          onChanged: (v) => c.authId = v,
        ),
        const SizedBox(height: 14),
        const SectionLabel('Auth Token',
            trailing: InfoTip(
                title: 'Auth Token',
                message: 'On your Vobiz Console Dashboard, next to the Auth ID. It is not your '
                    'login password. It is sent once to the webhook server to set up your '
                    'endpoint, and kept only in memory for transfers.')),
        TextField(
          key: const Key('authToken'),
          controller: _authToken,
          obscureText: !_showToken,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: '••••••••',
            suffixIcon: IconButton(
              tooltip: _showToken ? 'Hide' : 'Show',
              icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility, size: 18),
              onPressed: () => setState(() => _showToken = !_showToken),
            ),
          ),
          onChanged: (v) => c.authToken = v,
        ),
        const SizedBox(height: 14),
        InkWell(
          onTap: _editWebhook,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: pg.field,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: pg.border),
            ),
            child: Row(
              children: <Widget>[
                Container(width: 8, height: 8, decoration: BoxDecoration(color: pg.accent, shape: BoxShape.circle)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        c.webhookUrl == SdkConfig.defaultWebhookUrl
                            ? 'PRODUCTION WEBHOOK CALLBACK'
                            : 'CUSTOM WEBHOOK CALLBACK',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: pg.faint),
                      ),
                      const SizedBox(height: 2),
                      Text(c.webhookUrl,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: pg.text)),
                    ],
                  ),
                ),
                Icon(Icons.edit_outlined, size: 16, color: pg.faint),
              ],
            ),
          ),
        ),
      ] else ...<Widget>[
        TextField(
          key: const Key('sipUsername'),
          controller: _sipUser,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'Username'),
          onChanged: (v) => c.sipUsername = v,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('sipPassword'),
          controller: _sipPass,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: 'Password',
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Hide' : 'Show',
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility, size: 18),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
          onChanged: (v) => c.sipPassword = v,
          onSubmitted: (_) => c.connect(),
        ),
        const SizedBox(height: 8),
        Text(
          'An endpoint from Vobiz Console → Voice → Endpoints. Nothing is provisioned, and no '
          'account credentials reach this device. Transfer needs Zero-Config.',
          style: TextStyle(fontSize: 11, height: 1.4, color: pg.faint),
        ),
      ],
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Checkbox(
            key: const Key('rememberMe'),
            value: c.rememberMe,
            onChanged: (v) => c.update(() => c.rememberMe = v ?? false),
          ),
          GestureDetector(
            onTap: () => c.update(() => c.rememberMe = !c.rememberMe),
            child: Text('Remember me', style: TextStyle(fontSize: 12, color: pg.muted)),
          ),
        ],
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        key: const Key('connect'),
        onPressed: connecting ? null : c.connect,
        icon: connecting
            ? const SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
            : const Icon(Icons.login),
        label: const Text('Connect'),
      ),
      if (c.status == PhoneStatus.error)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('${c.statusText} — the Trace tab has the details.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: pg.danger)),
        ),
    ];
  }

  Widget _tab(String label, IconData icon, bool selected, VoidCallback onTap, PlaygroundColors pg) {
    return Expanded(
      child: Material(
        color: selected ? pg.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 15, color: selected ? Colors.white : pg.muted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : pg.muted)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _connected(PlaygroundController c, PlaygroundColors pg) {
    final user = c.connectedAs ?? c.client.sipUsername ?? '';
    final zero = c.authMode == VobizAuthMode.zeroConfig;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: pg.accentSoft,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: pg.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(children: <Widget>[
            Text('CONNECTION ACTIVE',
                style: TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.muted)),
            const Spacer(),
            Chip2(zero ? 'ZERO-CONFIG' : 'SIP DIRECT', color: pg.accent),
          ]),
          const SizedBox(height: 12),
          Row(children: <Widget>[
            Expanded(
              child: SelectableText(user,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 15, color: pg.accent)),
            ),
            IconButton(
              tooltip: 'Copy SIP username',
              icon: Icon(Icons.copy, size: 16, color: pg.faint),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: user));
                c.log('📋 Copied User to clipboard', LogType.success);
              },
            ),
          ]),
          if (zero)
            Text('Webhook: ${c.client.backendUrl}',
                style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: pg.faint)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: pg.field, borderRadius: BorderRadius.circular(12)),
            child: Text(
              'Ready to dial! Ensure your Caller ID matches a Vobiz number (purchased or trial) to '
              'bridge to PSTN.',
              style: TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, height: 1.4, color: pg.muted),
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            key: const Key('disconnect'),
            onPressed: c.disconnect,
            icon: const Icon(Icons.logout, size: 16),
            label: const Text('Disconnect'),
          ),
        ],
      ),
    );
  }

  Widget _faq(PlaygroundColors pg) {
    Widget qa(String q, String a) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(q, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pg.text)),
              const SizedBox(height: 3),
              Text(a, style: TextStyle(fontSize: 11, height: 1.45, color: pg.muted)),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(children: <Widget>[
          Icon(Icons.info_outline, size: 13, color: pg.accent),
          const SizedBox(width: 6),
          Text('FREQUENTLY ASKED',
              style: TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
        ]),
        const SizedBox(height: 12),
        qa('Where do I find my credentials?',
            'Auth ID and Auth Token are both on your Vobiz Console Dashboard. The Auth Token is not your login password.'),
        qa('Why do I need a Caller ID?',
            'Carriers require an E.164 CLI to bridge calls to mobile or landlines. Use a number purchased from Vobiz or your assigned trial number.'),
        qa('What does Zero-Config Setup create?',
            'An application named "Vobiz WebRTC Playground" and an endpoint aliased "Vobiz WebRTC Playground Endpoint" on your account — '
            'the same ones the web Playground uses, so signing in here gives that endpoint a new password.'),
        qa('How do calls to my Vobiz number reach this phone?',
            'The push bridge in example/push_bridge answers the number. It rings this app over SIP and sends a '
            'Firebase push that wakes it when it is in the background or closed. Accept on the call screen opens '
            'the app, which signs in and answers.'),
      ],
    );
  }
}
