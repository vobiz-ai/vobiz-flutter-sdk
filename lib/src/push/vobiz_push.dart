/// What an incoming-call push says happened.
enum VobizPushKind {
  /// A call is ringing: show the call screen and sign in.
  incomingCall,

  /// The call ended before it was answered: stop ringing.
  callEnded,
}

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
  /// `label` and `registrar` are all there.
  static VobizPushHold? tryParse(Map<String, Object?> data) {
    final index = '${data['index'] ?? ''}'.trim();
    final label = '${data['label'] ?? ''}'.trim();
    final registrar = '${data['registrar'] ?? ''}'.trim();
    if (index.isEmpty || label.isEmpty || registrar.isEmpty) return null;
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

/// A call push, read from a push message's data map (for example
/// `RemoteMessage.data` from `firebase_messaging`).
///
/// The SDK does not depend on any push service or call-screen plugin; the app
/// receives the push and hands its data here. Two senders are understood:
///
/// * **Vobiz** (the registrar, through Vobiz's push service). It holds the
///   call for up to 30 s while the push wakes the app:
///
///   ```json
///   {"type": "incoming_call", "call_id": "<SIP Call-ID>", "call_uuid": "...",
///    "caller": "...", "caller_number": "+91...", "callee": "<SIP user>",
///    "index": "...", "label": "...", "registrar": "...",
///    "expires_at": "1762900030"}
///   ```
///
///   `expires_at` is in Unix seconds. Hand the push to
///   `VobizClient.handleIncomingPush`: the next REGISTER claims the held call
///   ([hold]), and the INVITE that follows carries [callId] as its Call-ID.
/// * **The reference push bridge** (`example/push_bridge`), which puts its
///   own reference on the INVITE as a `PushRef` SIP header:
///
///   ```json
///   {"type": "incoming_call", "call_id": "...", "caller": "+91...",
///    "callee": "+91...", "expires_at": "1729600000000"}
///   ```
///
///   `expires_at` is in Unix milliseconds.
///
/// [matchesIncomingCall] ties the SIP INVITE that follows to the screen the
/// app already showed. See doc/PUSH_DESIGN.md.
class VobizIncomingPush {
  const VobizIncomingPush({
    required this.kind,
    required this.callId,
    this.callKey = '',
    this.caller = '',
    this.callee = '',
    this.server = '',
    this.expiresAt,
    this.reason = '',
    this.isTest = false,
    this.lineBusy = false,
    this.callUuid = '',
    this.callerNumber = '',
    this.hold,
  });

  /// Reads a push's data map. Null when it is not a Vobiz call push.
  ///
  /// [receivedAt] (default: now) anchors the sender's relative `ttl_ms`, so
  /// the expiry does not depend on the phone's clock agreeing with the
  /// sender's. An absolute `expires_at` is used only when there is no
  /// `ttl_ms`; it is read as Unix seconds when it is too small to be
  /// milliseconds (Vobiz sends seconds, the push bridge milliseconds).
  static VobizIncomingPush? tryParse(Map<String, Object?> data,
      {DateTime? receivedAt}) {
    final kind = switch ('${data['type'] ?? ''}') {
      'incoming_call' => VobizPushKind.incomingCall,
      'call_ended' => VobizPushKind.callEnded,
      _ => null,
    };
    final callId = '${data['call_id'] ?? ''}';
    if (kind == null || callId.isEmpty) return null;
    final ttlMs = int.tryParse('${data['ttl_ms'] ?? ''}');
    final expires = int.tryParse('${data['expires_at'] ?? ''}');
    final DateTime? expiresAt = ttlMs != null
        ? (receivedAt ?? DateTime.now()).add(Duration(milliseconds: ttlMs))
        : expires == null
            ? null
            : epochToDateTime(expires);
    return VobizIncomingPush(
      kind: kind,
      callId: callId,
      callKey: '${data['call_key'] ?? ''}',
      caller: '${data['caller'] ?? ''}',
      callee: '${data['callee'] ?? ''}',
      server: '${data['server'] ?? ''}',
      expiresAt: expiresAt,
      reason: '${data['reason'] ?? ''}',
      isTest: '${data['test'] ?? ''}' == '1',
      lineBusy: '${data['line_busy'] ?? ''}' == '1',
      callUuid: '${data['call_uuid'] ?? ''}',
      callerNumber: '${data['caller_number'] ?? ''}',
      hold: VobizPushHold.tryParse(data),
    );
  }

  /// A Unix time in seconds or milliseconds, told apart by size: no time in
  /// milliseconds since 1973 is below 10^11, and no time in seconds is above
  /// it before the year 5138.
  static DateTime epochToDateTime(int value) => value < 100000000000
      ? DateTime.fromMillisecondsSinceEpoch(value * 1000)
      : DateTime.fromMillisecondsSinceEpoch(value);

  final VobizPushKind kind;

  /// The sender's reference for this call: the SIP Call-ID of the INVITE
  /// Vobiz is holding, or the push bridge's own reference, which it also puts
  /// on the INVITE as a `PushRef` SIP header.
  final String callId;

  /// Vobiz's CallUUID for the call (Vobiz pushes), for logs and call records.
  final String callUuid;

  /// The caller's number (Vobiz pushes), where [caller] may be a name.
  final String callerNumber;

  /// Where Vobiz's registrar holds the call (Vobiz pushes only): the next
  /// REGISTER hands it back to claim the call. Null for the push bridge's
  /// pushes.
  final VobizPushHold? hold;

  /// Whether Vobiz's registrar is holding this call for a REGISTER that
  /// claims it ([hold]), rather than a push bridge ringing again.
  bool get isHeldByVobiz => hold != null;

  /// A per-call secret the sender issued, for declining through it.
  final String callKey;

  /// Who is calling, as the sender saw it.
  final String caller;

  /// The number that was called.
  final String callee;

  /// The sender's public base URL.
  final String server;

  /// When the sender stops ringing this device.
  final DateTime? expiresAt;

  /// Why the call ended ([VobizPushKind.callEnded] only).
  final String reason;

  /// A test push, not a real call.
  final bool isTest;

  /// The user is already on a call: show call waiting, not a full-screen
  /// incoming-call screen.
  final bool lineBusy;

  /// Whether the push has expired at [now] (default: the current time).
  bool isExpired([DateTime? now]) {
    final at = expiresAt;
    return at != null && !(now ?? DateTime.now()).isBefore(at);
  }

  /// Whether an incoming SIP call is the one this push announced.
  ///
  /// For a call Vobiz holds ([isHeldByVobiz]), the INVITE's SIP Call-ID
  /// ([sipCallId], from `CallEvent.sipCallId`) must be [callId]. For the push
  /// bridge, [headers] (the INVITE's custom headers, `VobizClient.callHeaders`)
  /// must carry it as `PushRef`. Only an exact match counts: matching by phone
  /// number could auto-answer a different call from the same caller.
  bool matchesIncomingCall({required Map<String, String> headers, String? sipCallId}) =>
      isHeldByVobiz ? sipCallId != null && sipCallId == callId : pushRefFromHeaders(headers) == callId;

  /// The push reference on an INVITE's headers: any header whose name
  /// contains `PushRef` (Vobiz documents two spellings for `<User
  /// sipHeaders>` keys).
  static String? pushRefFromHeaders(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase().contains('pushref') && entry.value.isNotEmpty) {
        try {
          return Uri.decodeComponent(entry.value);
        } on ArgumentError {
          return entry.value;
        }
      }
    }
    return null;
  }

  /// The real caller passed as an `X-VH-Caller` header, when present.
  static String? callerFromHeaders(Map<String, String> headers) {
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (name.endsWith('-caller') || name.endsWith('-callerx-vh')) {
        final digits = entry.value.replaceAll(RegExp(r'\D'), '');
        if (digits.isNotEmpty) return '+$digits';
      }
    }
    return null;
  }

  /// Two numbers are the same when their last ten digits match (at least six
  /// digits each), so `+91 98765 43210` matches `09876543210`.
  static bool samePhoneNumber(String a, String b) {
    final x = a.replaceAll(RegExp(r'\D'), '');
    final y = b.replaceAll(RegExp(r'\D'), '');
    if (x.length < 6 || y.length < 6) return false;
    String tail(String s) => s.length > 10 ? s.substring(s.length - 10) : s;
    return tail(x) == tail(y);
  }
}
