/// What an incoming-call push says happened.
enum VobizPushKind {
  /// A call is ringing: show the call screen and sign in.
  incomingCall,

  /// The call ended before it was answered: stop ringing.
  callEnded,
}

/// A call push, read from a push message's data map (for example
/// `RemoteMessage.data` from `firebase_messaging`).
///
/// The SDK does not depend on any push service or call-screen plugin; the app
/// receives the push, hands its data here, and uses [matchesIncomingCall] to
/// tie the SIP INVITE that follows to the screen it already showed. The
/// payload format is the one the reference push bridge
/// (`example/push_bridge`) sends:
///
/// ```json
/// {"type": "incoming_call", "call_id": "...", "caller": "+91...",
///  "callee": "+91...", "expires_at": "1729600000000"}
/// ```
///
/// See doc/PUSH_DESIGN.md for what the SDK will add on top of this.
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
  });

  /// Reads a push's data map. Null when it is not a Vobiz call push.
  static VobizIncomingPush? tryParse(Map<String, Object?> data) {
    final kind = switch ('${data['type'] ?? ''}') {
      'incoming_call' => VobizPushKind.incomingCall,
      'call_ended' => VobizPushKind.callEnded,
      _ => null,
    };
    final callId = '${data['call_id'] ?? ''}';
    if (kind == null || callId.isEmpty) return null;
    final expires = int.tryParse('${data['expires_at'] ?? ''}');
    return VobizIncomingPush(
      kind: kind,
      callId: callId,
      callKey: '${data['call_key'] ?? ''}',
      caller: '${data['caller'] ?? ''}',
      callee: '${data['callee'] ?? ''}',
      server: '${data['server'] ?? ''}',
      expiresAt: expires == null ? null : DateTime.fromMillisecondsSinceEpoch(expires),
      reason: '${data['reason'] ?? ''}',
      isTest: '${data['test'] ?? ''}' == '1',
    );
  }

  final VobizPushKind kind;

  /// The push sender's reference for this call. The sender also puts it on
  /// the INVITE as a `PushRef` SIP header.
  final String callId;

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

  /// Whether the push has expired at [now] (default: the current time).
  bool isExpired([DateTime? now]) {
    final at = expiresAt;
    return at != null && !(now ?? DateTime.now()).isBefore(at);
  }

  /// Whether an incoming SIP call is the one this push announced.
  ///
  /// [headers] are the INVITE's custom headers (`VobizClient.callHeaders`)
  /// and [from] the caller identity. A `PushRef` header decides when present;
  /// otherwise the caller (or an `X-VH-Caller` header) is compared with the
  /// push's caller and callee by their last ten digits.
  bool matchesIncomingCall({required Map<String, String> headers, String? from}) {
    final ref = pushRefFromHeaders(headers);
    if (ref != null) return ref == callId;
    final who = callerFromHeaders(headers) ?? from ?? '';
    return samePhoneNumber(who, caller) || samePhoneNumber(who, callee);
  }

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
