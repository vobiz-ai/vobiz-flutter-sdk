import 'package:flutter/material.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import '../playground_controller.dart';
import '../theme.dart';
import '../widgets/call_headers_panel.dart';
import '../widgets/common.dart';
import '../widgets/keypad.dart';
import '../widgets/latency_chart.dart';
import '../widgets/phone_number_field.dart';
import '../widgets/sip_header_editor.dart';
import '../widgets/transfer_sheet.dart';

/// The dialer terminal: caller ID, destination, SIP headers and the keypad
/// between calls; the incoming-call screen; and the in-call controls.
class DialerPanel extends StatefulWidget {
  const DialerPanel({super.key, required this.controller});

  final PlaygroundController controller;

  @override
  State<DialerPanel> createState() => _DialerPanelState();
}

class _DialerPanelState extends State<DialerPanel> {
  bool _showDtmf = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pg = context.pg;
    final offline = !c.isSignedIn;
    final inCall = c.status == PhoneStatus.inCall || c.status == PhoneStatus.ringing;

    Widget body;
    if (c.showIncoming) {
      body = _incoming(c, pg);
    } else if (inCall) {
      body = _activeCall(c, pg);
    } else {
      _showDtmf = false;
      body = _idle(c, pg, offline);
    }

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('DIALER TERMINAL',
                  style: TextStyle(fontSize: 11, letterSpacing: 1.8, fontWeight: FontWeight.w600, color: pg.faint)),
              const Spacer(),
              StatusPill(status: c.status, text: c.statusText),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: offline ? 0.45 : 1,
              child: IgnorePointer(ignoring: offline, child: body),
            ),
          ),
          if (offline)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Connect on the Identity tab to start dialling.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: pg.muted)),
            ),
        ],
      ),
    );
  }

  Widget _idle(PlaygroundController c, PlaygroundColors pg, bool offline) {
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              const SectionLabel('Caller ID Override',
                  trailing: InfoTip(
                    title: 'PSTN Requirement',
                    message: 'Required for calls to Mobile/Landline. Use a number purchased from '
                        'Vobiz or your trial number (e.g. +919999999999). It is sent as the '
                        'X-VH-Caller-ID header.',
                  )),
              PhoneNumberField(
                key: const Key('callerId'),
                iso: c.callerIdIso,
                number: c.callerIdNumber,
                onIsoChanged: (v) => c.update(() => c.callerIdIso = v),
                onNumberChanged: (v) => c.update(() => c.callerIdNumber = v),
                label: 'Caller ID',
                placeholder: '9876543210',
              ),
              const SizedBox(height: 14),
              const SectionLabel('Destination Target'),
              PhoneNumberField(
                key: const Key('destination'),
                iso: c.destIso,
                number: c.destNumber,
                onIsoChanged: (v) => c.update(() => c.destIso = v),
                onNumberChanged: (v) => c.update(() => c.destNumber = v),
                label: 'Destination number',
                placeholder: '1234567890',
                large: true,
                accent: true,
                onSubmitted: c.call,
              ),
              const SizedBox(height: 14),
              SipHeaderEditor(controller: c),
              const SizedBox(height: 10),
              CallHeadersPanel(controller: c),
              const SizedBox(height: 14),
              Keypad(onKey: c.pressKey, compact: true),
              const SizedBox(height: 8),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                key: const Key('call'),
                style: FilledButton.styleFrom(backgroundColor: callGreen, foregroundColor: Colors.white),
                onPressed: offline ? null : c.call,
                icon: const Icon(Icons.call),
                label: const Text('Call'),
              ),
            ),
            if (c.destNumber.isNotEmpty) ...<Widget>[
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: 'Delete digit',
                onPressed: () => c.update(() =>
                    c.destNumber = c.destNumber.substring(0, c.destNumber.length - 1)),
                icon: const Icon(Icons.backspace_outlined),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _incoming(PlaygroundController c, PlaygroundColors pg) {
    final headers = c.activeHeaders?.headers ?? const <String, String>{};
    return ListView(
      children: <Widget>[
        const SizedBox(height: 24),
        Icon(Icons.phone_callback, size: 52, color: pg.info),
        const SizedBox(height: 16),
        Text('Incoming Call',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: pg.text)),
        const SizedBox(height: 6),
        Text(c.remoteParty,
            textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: pg.muted)),
        const SizedBox(height: 20),
        if (headers.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: pg.field,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: pg.accent.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('# SIP HEADERS ON THIS CALL',
                    style: TextStyle(fontSize: 9, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: pg.accent)),
                const SizedBox(height: 6),
                HeaderTable(headers),
              ],
            ),
          )
        else
          Text('No custom SIP headers on this call',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: pg.faint)),
        const SizedBox(height: 28),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                key: const Key('answer'),
                style: FilledButton.styleFrom(backgroundColor: callGreen),
                onPressed: c.answer,
                icon: const Icon(Icons.call),
                label: const Text('Answer'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const Key('reject'),
                style: FilledButton.styleFrom(
                    backgroundColor: pg.danger.withValues(alpha: 0.12), foregroundColor: pg.danger),
                onPressed: c.reject,
                icon: const Icon(Icons.call_end),
                label: const Text('Reject'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _activeCall(PlaygroundController c, PlaygroundColors pg) {
    final live = c.status == PhoneStatus.inCall && c.client.callState == CallStateStatus.active;
    final ringing = !live;
    final tone = live ? pg.success : pg.warning;
    final headers = c.activeHeaders;
    String two(int v) => v.toString().padLeft(2, '0');

    return Column(
      children: <Widget>[
        Expanded(
          child: ListView(
            children: <Widget>[
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(color: tone.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Icon(Icons.call, size: 36, color: tone),
                ),
              ),
              const SizedBox(height: 14),
              Text(ringing ? c.statusText.toUpperCase() : 'ACTIVE CALL',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, letterSpacing: 1.6, color: pg.faint)),
              const SizedBox(height: 4),
              Text(c.remoteParty,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 24, color: pg.text)),
              if (live) ...<Widget>[
                const SizedBox(height: 12),
                // The clock and the chart tick every second; only they rebuild.
                ListenableBuilder(
                  listenable: c.callTicker,
                  builder: (context, _) {
                    final d = c.callDuration;
                    return Column(children: <Widget>[
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: pg.field,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: pg.accent.withValues(alpha: 0.2)),
                          ),
                          child: Text('${two(d.inMinutes)}:${two(d.inSeconds % 60)}',
                              key: const Key('callClock'),
                              style: TextStyle(fontFamily: 'monospace', fontSize: 18, color: pg.accent)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(child: LatencyChart(samples: List<double?>.of(c.latency))),
                    ]);
                  },
                ),
              ],
              if (headers != null && headers.headers.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: pg.field,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: pg.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(children: <Widget>[
                        Text('# SIP HEADERS ON THIS CALL',
                            style: TextStyle(
                                fontSize: 9, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: pg.faint)),
                        const SizedBox(width: 6),
                        Chip2(headers.direction == CallDirection.inbound ? 'RECEIVED' : 'SENT',
                            color: headers.direction == CallDirection.inbound ? pg.success : pg.info),
                      ]),
                      const SizedBox(height: 6),
                      HeaderTable(headers.headers),
                    ],
                  ),
                ),
              ],
              if (_showDtmf && live) ...<Widget>[
                const SizedBox(height: 16),
                Keypad(onKey: c.pressKey, compact: true),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            _control(
              icon: c.isMuted ? Icons.mic_off : Icons.mic,
              label: c.isMuted ? 'Unmute' : 'Mute',
              active: c.isMuted,
              onTap: live ? c.toggleMute : null,
              pg: pg,
            ),
            _control(
              icon: Icons.dialpad,
              label: 'Keypad',
              active: _showDtmf,
              onTap: live ? () => setState(() => _showDtmf = !_showDtmf) : null,
              pg: pg,
            ),
            _control(
              icon: c.speakerOn ? Icons.volume_up : Icons.volume_down,
              label: 'Speaker',
              active: c.speakerOn,
              onTap: c.toggleSpeaker,
              pg: pg,
            ),
            _control(
              icon: Icons.phone_forwarded,
              label: 'Transfer',
              active: false,
              onTap: live ? () => showTransferSheet(context, c) : null,
              pg: pg,
            ),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('hangup'),
          style: FilledButton.styleFrom(backgroundColor: hangupRed),
          onPressed: c.hangup,
          icon: const Icon(Icons.call_end),
          label: const Text('Hang up'),
        ),
      ],
    );
  }

  Widget _control({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback? onTap,
    required PlaygroundColors pg,
  }) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Material(
            color: active ? pg.accent : pg.field,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Icon(icon, color: active ? Colors.white : pg.text, size: 22),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(fontSize: 11, color: pg.muted)),
        ],
      ),
    );
  }
}
