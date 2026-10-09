import 'package:flutter/material.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';
import 'phone_number_field.dart';

/// Opens the transfer panel for the connected call.
Future<void> showTransferSheet(BuildContext context, PlaygroundController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.pg.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _TransferSheet(controller: controller),
      ),
    ),
  );
}

class _TransferSheet extends StatelessWidget {
  const _TransferSheet({required this.controller});

  final PlaygroundController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final pg = context.pg;
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
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: pg.border, borderRadius: BorderRadius.circular(2)),
            ),
          ),
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
                'Transfer needs API credentials. Disconnect and sign in with Zero-Config Setup '
                '(Auth ID and Auth Token) to use it.',
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
            TextField(
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
          SegmentedButton<TransferLeg>(
            segments: const <ButtonSegment<TransferLeg>>[
              ButtonSegment(value: TransferLeg.aLeg, label: Text('Move me')),
              ButtonSegment(value: TransferLeg.bLeg, label: Text('Move the other party')),
            ],
            selected: <TransferLeg>{c.transferLeg},
            onSelectionChanged: (s) => c.update(() => c.transferLeg = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            c.transferLeg == TransferLeg.aLeg
                ? 'aleg: your leg moves onto the target; the other party is dropped.'
                : 'bleg: the other party moves onto the target; you are dropped.',
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
