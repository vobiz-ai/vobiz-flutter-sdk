import 'package:flutter/material.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import '../playground_controller.dart';
import '../theme.dart';
import 'common.dart';
import 'phone_number_field.dart';

/// Opens the conference panel for the connected call: add people, see who
/// is in, mute, hold or remove them, or end it for everyone.
Future<void> showConferenceSheet(BuildContext context, PlaygroundController controller) {
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
        builder: (context, _) => _ConferenceSheet(controller: controller),
      ),
    ),
  );
}

class _ConferenceSheet extends StatelessWidget {
  const _ConferenceSheet({required this.controller});

  final PlaygroundController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final pg = context.pg;
    // The call is over (and its conference with it): close the sheet.
    if (c.status != PhoneStatus.inCall) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
      });
    }
    final state = c.conference;
    final blocker = c.conferenceBlocker;
    final live = c.client.callState == CallStateStatus.active && (state?.active ?? true);
    final filled = c.conferenceTarget == TransferTarget.user
        ? c.conferenceUser.trim().isNotEmpty
        : c.conferenceNumber.isNotEmpty;

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
            Icon(Icons.groups, color: pg.accent, size: 20),
            const SizedBox(width: 8),
            Text('Conference', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pg.text)),
            const Spacer(),
            if (state != null) Chip2(state.active ? '${state.present.length} ON THE CALL' : 'ENDED',
                color: state.active ? pg.success : pg.faint),
          ]),
          const SizedBox(height: 4),
          Text(
            state == null
                ? 'The first person you add makes this call a conference: you and the other side move '
                    'into a Vobiz conference room, then they are dialled into it. The push server does it '
                    'with your Auth Token, which never comes to this phone.'
                : 'Everyone below is in the same Vobiz conference room. Hold takes a person out onto '
                    'music; Resume brings them back.',
            style: TextStyle(fontSize: 11, height: 1.4, color: pg.faint),
          ),
          if (blocker != null) ...<Widget>[
            const SizedBox(height: 12),
            _notice(pg, blocker, pg.warning),
          ],
          if (state != null) ...<Widget>[
            const SizedBox(height: 16),
            const SectionLabel('On the call'),
            for (final person in state.participants) _ParticipantRow(controller: c, person: person, live: live),
            if (!state.active)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('The conference ended${state.endedReason == null ? '' : ': ${state.endedReason}'}.',
                    style: TextStyle(fontSize: 12, color: pg.muted)),
              ),
          ],
          if (live) ...<Widget>[
            const SizedBox(height: 16),
            const SectionLabel('Add a person'),
            SegmentedButton<TransferTarget>(
              segments: const <ButtonSegment<TransferTarget>>[
                ButtonSegment(value: TransferTarget.number, icon: Icon(Icons.dialpad), label: Text('Number')),
                ButtonSegment(value: TransferTarget.user, icon: Icon(Icons.person_outline), label: Text('SIP user')),
              ],
              selected: <TransferTarget>{c.conferenceTarget},
              onSelectionChanged: (s) => c.update(() => c.conferenceTarget = s.first),
            ),
            const SizedBox(height: 12),
            if (c.conferenceTarget == TransferTarget.number)
              PhoneNumberField(
                key: Key('conferenceNumber-${c.conferenceAdds}'),
                iso: c.conferenceIso,
                number: c.conferenceNumber,
                onIsoChanged: (v) => c.update(() => c.conferenceIso = v),
                onNumberChanged: (v) => c.update(() => c.conferenceNumber = v),
                label: 'Phone number to add',
                placeholder: '9876543210',
              )
            else
              TextField(
                key: Key('conferenceUser-${c.conferenceAdds}'),
                autocorrect: false,
                onChanged: (v) => c.update(() => c.conferenceUser = v),
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: 'play123 or sip:play123@registrar.vobiz.ai',
                  prefixIcon: Icon(Icons.alternate_email, size: 18),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              c.callerId.isEmpty
                  ? 'They see the push server\'s Vobiz number (VOBIZ_NUMBER).'
                  : 'They see ${c.callerId} (the Caller ID on the Dialer).',
              style: TextStyle(fontSize: 11, color: pg.faint),
            ),
            if (c.conferenceError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(c.conferenceError, style: TextStyle(color: pg.danger, fontSize: 12)),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('conferenceAdd'),
              onPressed: c.conferenceBusy || !filled || blocker != null ? null : c.conferenceAdd,
              icon: c.conferenceBusy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.person_add_alt_1),
              label: Text(c.conferenceBusy ? 'Adding…' : 'Add ${c.conferenceDestination}'),
            ),
          ],
          if (state != null && state.active) ...<Widget>[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('conferenceEnd'),
              style: OutlinedButton.styleFrom(foregroundColor: pg.danger),
              onPressed: c.conferenceEnd,
              icon: const Icon(Icons.call_end),
              label: const Text('End for everyone'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _notice(PlaygroundColors pg, String text, Color color) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(fontSize: 12, color: color)),
      );
}

/// One person: who, where they are, and what can be done to them.
class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({required this.controller, required this.person, required this.live});

  final PlaygroundController controller;
  final VobizConferenceParticipant person;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    final (text, color) = switch (person.status) {
      VobizParticipantStatus.connecting => ('CONNECTING', pg.info),
      VobizParticipantStatus.dialing => ('RINGING', pg.info),
      VobizParticipantStatus.joined => ('IN THE ROOM', pg.success),
      VobizParticipantStatus.onHold => ('ON HOLD', pg.warning),
      VobizParticipantStatus.left => (person.reason == 'removed' ? 'REMOVED' : 'LEFT', pg.faint),
      VobizParticipantStatus.failed => ((person.reason ?? 'not answered').toUpperCase(), pg.danger),
    };
    final joined = person.status == VobizParticipantStatus.joined;
    final manage = live && !person.isYou && person.isPresent;
    void act(VobizParticipantAction action) => controller.conferenceAct(person, action);

    return Padding(
      key: Key('participant-${person.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: <Widget>[
        Icon(person.isYou ? Icons.smartphone : person.label.startsWith('+') ? Icons.phone : Icons.alternate_email,
            size: 18, color: person.isPresent ? pg.text : pg.faint),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(person.isYou ? 'You (${person.label})' : person.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: person.isPresent ? pg.text : pg.faint)),
            const SizedBox(height: 3),
            Row(children: <Widget>[
              Chip2(text, color: color),
              if (person.muted && person.isPresent) ...<Widget>[
                const SizedBox(width: 6),
                Chip2('MUTED', color: pg.warning),
              ],
            ]),
          ]),
        ),
        if (manage && joined)
          IconButton(
            tooltip: person.muted ? 'Unmute' : 'Mute',
            icon: Icon(person.muted ? Icons.mic_off : Icons.mic, size: 20),
            onPressed: () => act(person.muted ? VobizParticipantAction.unmute : VobizParticipantAction.mute),
          ),
        if (manage && (joined || person.status == VobizParticipantStatus.onHold))
          IconButton(
            tooltip: joined ? 'Hold' : 'Resume',
            icon: Icon(joined ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 20),
            onPressed: () => act(joined ? VobizParticipantAction.hold : VobizParticipantAction.resume),
          ),
        if (manage)
          IconButton(
            tooltip: 'Remove',
            icon: Icon(Icons.person_remove_outlined, size: 20, color: pg.danger),
            onPressed: () => act(VobizParticipantAction.remove),
          ),
      ]),
    );
  }
}
