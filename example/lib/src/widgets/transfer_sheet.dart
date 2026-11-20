import 'package:flutter/material.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';
import 'phone_number_field.dart';

/// Opens the transfer panel for the connected call.
Future<void> showTransferSheet(BuildContext context, PlaygroundController controller) =>
    showPlaygroundSheet(context, controller, (_) => _TransferSheet(controller: controller));

class _TransferSheet extends StatelessWidget {
  const _TransferSheet({required this.controller});

  final PlaygroundController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final pg = context.pg;
    // The call is over: close the sheet, as the Conference sheet does.
    if (c.status != PhoneStatus.inCall) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
      });
    }
    final busy = c.transferStatus == TransferStatus.submitting;
    final zeroConfig = c.authMode == VobizAuthMode.zeroConfig;
    final filled = c.transferTarget == TransferTarget.user
        ? c.transferUser.trim().isNotEmpty
        : c.transferNumber.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SheetHandle(),
          const SizedBox(height: 14),
          Row(children: <Widget>[
            Icon(Icons.phone_forwarded, color: pg.accent, size: 20),
            const SizedBox(width: 8),
            Text('Transfer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pg.text)),
          ]),
          const SizedBox(height: 4),
          Text(
            'Goes through the Vobiz Redirect API, never SIP REFER: a number is a blind '
            '<Dial><Number>; a SIP user is <Dial><User> carrying context in sipHeaders.',
            style: TextStyle(fontSize: 11, height: 1.4, color: pg.faint),
          ),
          if (!zeroConfig) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: pg.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                c.demoTools
                    ? 'Transfer needs API credentials. Disconnect and sign in with Zero-Config Setup '
                        '(Auth ID and Auth Token) to use it.'
                    : 'Transfer needs the account\'s API credentials, which only the demo build takes '
                        '(Zero-Config Setup).',
                style: TextStyle(fontSize: 12, color: pg.warning),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const SectionLabel('Transfer to'),
          SegmentedButton<TransferTarget>(
            segments: const <ButtonSegment<TransferTarget>>[
              ButtonSegment(value: TransferTarget.number, icon: Icon(Icons.dialpad), label: Text('Number')),
              ButtonSegment(value: TransferTarget.user, icon: Icon(Icons.person_outline), label: Text('SIP user')),
            ],
            selected: <TransferTarget>{c.transferTarget},
            onSelectionChanged: (s) => c.update(() => c.transferTarget = s.first),
          ),
          const SizedBox(height: 12),
          if (c.transferTarget == TransferTarget.number)
            PhoneNumberField(
              iso: c.transferIso,
              number: c.transferNumber,
              onIsoChanged: (v) => c.update(() => c.transferIso = v),
              onNumberChanged: (v) => c.update(() => c.transferNumber = v),
              label: 'Transfer destination phone number',
              placeholder: '9876543210',
            )
          else
            TextFormField(
              key: const Key('transferUser'),
              initialValue: c.transferUser,
              autocorrect: false,
              onChanged: (v) => c.update(() => c.transferUser = v),
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'play123 or sip:play123@registrar.vobiz.ai',
                prefixIcon: Icon(Icons.alternate_email, size: 18),
              ),
            ),
          const SizedBox(height: 16),
          const SectionLabel('What moves'),
          SegmentedButton<TransferParty>(
            segments: const <ButtonSegment<TransferParty>>[
              ButtonSegment(value: TransferParty.me, label: Text('Move me')),
              ButtonSegment(value: TransferParty.other, label: Text('Move them')),
              ButtonSegment(value: TransferParty.both, label: Text('Both')),
            ],
            selected: <TransferParty>{c.transferParty},
            onSelectionChanged: (s) => c.update(() => c.transferParty = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _legHelp(c),
            key: const Key('transferLegHelp'),
            style: TextStyle(fontSize: 11, color: pg.faint),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: c.sendHeadersOnTransfer,
            onChanged: c.setSendHeadersOnTransfer,
            title: Text('Carry my SIP headers', style: TextStyle(fontSize: 14, color: pg.text)),
            subtitle: Text(
              'Sends the header editor\'s X-VH- rows as sipHeaders on the new <Dial>. '
              'XML only allows A-Za-z0-9 in names, so names with hyphens are left out.',
              style: TextStyle(fontSize: 11, color: pg.faint),
            ),
          ),
          if (c.transferStatus == TransferStatus.failed && c.transferError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(c.transferError, style: TextStyle(color: pg.danger, fontSize: 12)),
            ),
          if (c.transferStatus == TransferStatus.accepted)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Transfer accepted.', style: TextStyle(color: pg.success, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: busy || !filled || !zeroConfig ? null : c.transfer,
            icon: busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.call_made),
            label: Text(busy ? 'Transferring…' : 'Transfer to ${c.transferDestination}'),
          ),
        ],
      ),
    );
  }
}

/// What the selected option does on this call, with the `legs` it sends.
String _legHelp(PlaygroundController c) {
  final inbound = c.client.callDirection == CallDirection.inbound;
  final legs = c.transferLeg.apiValue;
  final side = inbound
      ? 'This call rang this app, so the caller is the A-leg and you are the B-leg.'
      : 'You placed this call, so you are the A-leg.';
  final what = switch (c.transferParty) {
    TransferParty.me => 'Your leg moves onto the target; the other party is dropped.',
    TransferParty.other => 'The other party moves onto the target; you are dropped.',
    TransferParty.both => 'Both legs leave this call and each runs the transfer on its own '
        '(each dials the target). Mostly useful for a conference.',
  };
  return '$what legs=$legs. $side';
}
