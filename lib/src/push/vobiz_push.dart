import '../utils/sip_text.dart';

/// What became of a call push handed to `VobizClient.handleIncomingPush`.
enum VobizPushCallStatus {
  /// The REGISTER that claims the held call is on its way, or waits for the
  /// sign-in (when the app is not signed in yet).
  claiming,

  /// The registrar took that REGISTER: the held INVITE should follow.
  claimed,

  /// The held call's INVITE arrived ([VobizPushCallUpdate.callId] is its
  /// `CallEvent.callId`).
  ringing,

  /// It was answered, because Accept was reported on the call screen.
  answering,

  /// It was declined, because Decline was reported on the call screen.
  declining,

  /// No INVITE came by the push's expiry: stop showing the call.
  expired,
}

/// One step of a pushed call, from `VobizClient.pushCallUpdates`.
class VobizPushCallUpdate {
  const VobizPushCallUpdate({required this.push, required this.status, this.callId});

  /// The push the call came with.
  final VobizIncomingPush push;
  final VobizPushCallStatus status;

  /// The call's `CallEvent.callId`, once its INVITE has arrived.
  final String? callId;

  @override
  String toString() => 'VobizPushCallUpdate(${status.name}, ${push.callId}${callId == null ? '' : ', $callId'})';
}

/// Where Vobiz's registrar is holding a call while a push wakes the app: the
/// reference the app hands back on its REGISTER so the registrar sends the
/// held INVITE to the new registration.
///
/// It comes in a Vobiz push as `index`, `label` and `registrar`, and goes back
/// as the `X-Index`, `X-Label` and `X-vobiz-Registrar-Info` headers.
class VobizPushHold {
  const VobizPushHold({
    required this.index,
    required this.label,
    required this.registrar,
  });

  /// Reads the hold reference from a push's data map. Null unless `index`,
  /// `label` and `registrar` are all there, and none holds a control
  /// character: each goes into a REGISTER header line as it is.
  static VobizPushHold? tryParse(Map<String, Object?> data) {
    final index = '${data['index'] ?? ''}'.trim();
    final label = '${data['label'] ?? ''}'.trim();
    final registrar = '${data['registrar'] ?? ''}'.trim();
    if (<String>[index, label, registrar].any((v) => v.isEmpty || hasControlCharacter(v))) return null;
    return VobizPushHold(index: index, label: label, registrar: registrar);
  }

  /// The registrar's transaction index for the held INVITE.
  final String index;

  /// The registrar's transaction label for the held INVITE.
  final String label;

  /// The address of the registrar that holds the call. A REGISTER that lands
  /// on another registrar is forwarded to this one.
  final String registrar;

  /// The headers the REGISTER that claims the call carries.
  Map<String, String> get registerHeaders => <String, String>{
        'X-Index': index,
        'X-Label': label,
        'X-vobiz-Registrar-Info': registrar,
      };

  @override
  String toString() => 'VobizPushHold(index $index, label $label, registrar $registrar)';
}

/// Vobiz's incoming-call push, read from a push message's data map (for
/// example `RemoteMessage.data` from `firebase_messaging`).
///
/// The SDK does not depend on any push service or call-screen plugin; the app
/// receives the push and hands its data here. Vobiz's registrar sends it,
/// through Vobiz's push service, and holds the call for up to 30 s while the
/// push wakes the app:
///
/// ```json
/// {"type": "incoming_call", "call_id": "<SIP Call-ID>", "call_uuid": "...",
///  "caller": "...", "caller_number": "+91...", "callee": "<SIP user>",
///  "index": "...", "label": "...", "registrar": "...",
///  "expires_at": "1762900030"}
/// ```
///
/// `expires_at` is in Unix seconds. Hand the push to
/// `VobizClient.handleIncomingPush`: the next REGISTER claims the held call
/// ([hold]), and the INVITE that follows carries [callId] as its Call-ID,
/// which [matchesIncomingCall] checks. See doc/PUSH_DESIGN.md.
class VobizIncomingPush {
  const VobizIncomingPush({
    required this.callId,
    required this.hold,
    this.caller = '',
    this.callee = '',
    this.expiresAt,
    this.callUuid = '',
    this.callerNumber = '',
  });

  /// Reads a push's data map. Null unless it is Vobiz's push for a call its
  /// registrar holds: `type` is `incoming_call`, `call_id` is not empty, and
  /// `index`, `label` and `registrar` are all there ([hold]).
  ///
  /// `expires_at` is read as Unix seconds, or as milliseconds when it is too
  /// large to be seconds ([epochToDateTime]).
  static VobizIncomingPush? tryParse(Map<String, Object?> data) {
    if ('${data['type'] ?? ''}' != 'incoming_call') return null;
    final callId = '${data['call_id'] ?? ''}';
    if (callId.isEmpty) return null;
    final hold = VobizPushHold.tryParse(data);
    if (hold == null) return null;
    final expires = int.tryParse('${data['expires_at'] ?? ''}');
    return VobizIncomingPush(
      callId: callId,
      hold: hold,
      caller: '${data['caller'] ?? ''}',
      callee: '${data['callee'] ?? ''}',
      expiresAt: expires == null ? null : epochToDateTime(expires),
      callUuid: '${data['call_uuid'] ?? ''}',
      callerNumber: '${data['caller_number'] ?? ''}',
    );
  }

  /// A Unix time in seconds or milliseconds, told apart by size: no time in
  /// milliseconds since 1973 is below 10^11, and no time in seconds is above
  /// it before the year 5138.
  static DateTime epochToDateTime(int value) => value < 100000000000
      ? DateTime.fromMillisecondsSinceEpoch(value * 1000)
      : DateTime.fromMillisecondsSinceEpoch(value);

  /// The SIP Call-ID of the INVITE Vobiz's registrar is holding.
  final String callId;

  /// Vobiz's CallUUID for the call, for logs and call records.
  final String callUuid;

  /// The caller's number, where [caller] may be a name.
  final String callerNumber;

  /// Where Vobiz's registrar holds the call: the next REGISTER hands it back
  /// to claim the call.
  final VobizPushHold hold;

  /// Who is calling, as Vobiz saw it.
  final String caller;

  /// The SIP user that was called.
  final String callee;

  /// When Vobiz stops holding the call for this device.
  final DateTime? expiresAt;

  /// Whether the push has expired at [now] (default: the current time).
  bool isExpired([DateTime? now]) {
    final at = expiresAt;
    return at != null && !(now ?? DateTime.now()).isBefore(at);
  }

  /// Whether an incoming SIP call is the one this push announced: the
  /// INVITE's SIP Call-ID ([sipCallId], from `CallEvent.sipCallId`) must be
  /// [callId]. Only an exact match counts: matching by phone number could
  /// auto-answer a different call from the same caller.
  bool matchesIncomingCall({required String? sipCallId}) => sipCallId != null && sipCallId == callId;
}
