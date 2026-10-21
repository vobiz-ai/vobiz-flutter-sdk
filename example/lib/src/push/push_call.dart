import 'package:flutter/foundation.dart';

/// What a push message from the push bridge asks the app to do.
enum PushKind {
  /// Someone is calling: show the incoming-call screen.
  incomingCall,

  /// Stop ringing: the call was answered elsewhere, declined, or the caller
  /// hung up. [PushCall.reason] says which. Sent as `cancel` (or, by older
  /// bridges, `call_ended`).
  cancel,
}

/// Why a [PushKind.cancel] push stopped the ringing.
abstract final class CancelReason {
  /// Another phone, browser or device took the call.
  static const String answeredElsewhere = 'answered_elsewhere';

  /// The call was answered and has now ended (older bridges send this when
  /// any device answered).
  static const String completed = 'completed';

  /// Someone declined it (this user, on another device).
  static const String declined = 'declined';

  /// The caller gave up before anyone answered.
  static const String callerHungUp = 'caller_hung_up';

  /// Nobody answered before the bridge gave up.
  static const String missed = 'missed';

  /// The user was on another call and did not take this one.
  static const String busy = 'busy';
}

/// One push message from the push bridge (`example/push_bridge`), as it
/// arrives in a Firebase data message and as the call screen stores it.
@immutable
class PushCall {
  const PushCall({
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
    this.answeredBy = '',
  });

  /// Reads a Firebase data message. Null when it is not from the push bridge.
  ///
  /// The call screen expires `ttl_ms` after [receivedAt] (default: now), so
  /// a phone whose clock is off still stops ringing on time. Only without
  /// `ttl_ms` (older bridges) is the bridge's absolute `expires_at` used.
  static PushCall? fromData(Map<String, dynamic> data, {DateTime? receivedAt}) {
    final kind = switch ('${data['type'] ?? ''}') {
      'incoming_call' => PushKind.incomingCall,
      'cancel' || 'call_ended' => PushKind.cancel,
      _ => null,
    };
    final callId = '${data['call_id'] ?? ''}';
    if (kind == null || callId.isEmpty) return null;
    final ttl = int.tryParse('${data['ttl_ms'] ?? ''}');
    final at = int.tryParse('${data['expires_at'] ?? ''}');
    final expires = ttl != null
        ? (receivedAt ?? DateTime.now()).add(Duration(milliseconds: ttl)).millisecondsSinceEpoch
        : at;
    return PushCall(
      kind: kind,
      callId: callId,
      callKey: '${data['call_key'] ?? ''}',
      caller: '${data['caller'] ?? ''}',
      callee: '${data['callee'] ?? ''}',
      server: '${data['server'] ?? ''}',
      expiresAt: expires == null ? null : DateTime.fromMillisecondsSinceEpoch(expires),
      reason: '${data['reason'] ?? ''}',
      isTest: '${data['test'] ?? ''}' == '1',
      lineBusy: '${data['line_busy'] ?? ''}' == '1',
      answeredBy: '${data['answered_by'] ?? ''}',
    );
  }

  /// Reads the `extra` the call screen hands back on Accept or Decline.
  static PushCall? fromExtra(Map<dynamic, dynamic>? extra) {
    if (extra == null || extra['source'] != 'push') return null;
    return fromData(extra.map((key, value) => MapEntry('$key', value)));
  }

  final PushKind kind;

  /// Vobiz's CallUUID for the inbound call.
  final String callId;

  /// Lets this device accept or decline this one call on the bridge.
  final String callKey;

  /// Who is calling, in E.164 where Vobiz gave a number.
  final String caller;

  /// The Vobiz number that was called.
  final String callee;

  /// The bridge's public address, to report Accept and Decline to.
  final String server;

  /// After this the caller has stopped waiting; the push is stale.
  final DateTime? expiresAt;

  /// Why ringing stopped, for [PushKind.cancel]: one of [CancelReason].
  final String reason;

  /// Some other device took the call: not a missed call.
  bool get answeredElsewhere =>
      reason == CancelReason.answeredElsewhere || reason == CancelReason.completed;

  /// A test call from the app's "Send a test call" button: nothing to connect.
  final bool isTest;

  /// The bridge knows this endpoint is already on a call: call waiting, not
  /// the full-screen ringing screen.
  final bool lineBusy;

  /// For [CancelReason.answeredElsewhere]: the endpoint that answered, when
  /// Vobiz named it.
  final String answeredBy;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// The fields the call screen keeps, so Accept and Decline can reach the
  /// bridge even when the app was closed. The expiry is stored as an
  /// absolute time on this phone's clock, worked out when the push arrived.
  Map<String, dynamic> toExtra() => <String, dynamic>{
        'source': 'push',
        'type': 'incoming_call',
        'call_id': callId,
        'call_key': callKey,
        'caller': caller,
        'callee': callee,
        'server': server,
        if (expiresAt != null) 'expires_at': '${expiresAt!.millisecondsSinceEpoch}',
        if (isTest) 'test': '1',
      };

  @override
  String toString() => 'PushCall(${kind.name}, $callId, from $caller)';
}

/// Whether two phone numbers are the same line. Compares the last ten
/// digits, so +919876543210, 919876543210 and 09876543210 all match.
bool samePhoneNumber(String a, String b) {
  final x = a.replaceAll(RegExp(r'\D'), '');
  final y = b.replaceAll(RegExp(r'\D'), '');
  if (x.length < 6 || y.length < 6) return false;
  String tail(String s) => s.length > 10 ? s.substring(s.length - 10) : s;
  return tail(x) == tail(y);
}

/// The bridge's call reference from an incoming INVITE's `X-VH-` headers.
///
/// Vobiz documents two spellings for `<User sipHeaders>` keys, so this takes
/// any header whose name contains "PushRef".
String? pushRefFromHeaders(Map<String, String> headers) {
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

/// Whether an incoming SIP call is the call [push] announced: only when the
/// INVITE carries the bridge's call reference for exactly that call.
///
/// Numbers are never enough. With the bridge's default caller ID every call
/// shows the Vobiz number, so matching by number would answer any call that
/// arrived after an Accept without a tap.
bool inviteMatchesPush(PushCall push, {required Map<String, String> headers}) =>
    pushRefFromHeaders(headers) == push.callId;

/// The real caller the bridge passed on the INVITE (`X-VH-Caller`), when its
/// caller ID shows the Vobiz number instead.
String? callerFromHeaders(Map<String, String> headers) {
  for (final entry in headers.entries) {
    final name = entry.key.toLowerCase();
    if (name.endsWith('-caller') || name.endsWith('-callerx-vh')) {
      final digits = entry.value.replaceAll(RegExp(r'\D'), '');
      if (digits.isNotEmpty) return '+$digits';
    }
  }
  return null;
}
