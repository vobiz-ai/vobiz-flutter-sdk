import 'package:flutter/foundation.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart' show VobizIncomingPush;

/// An incoming-call push from Vobiz's push service, as it arrives in a
/// Firebase data message and as the call screen stores it.
@immutable
class PushCall {
  const PushCall({
    required this.callId,
    this.caller = '',
    this.callee = '',
    this.expiresAt,
    this.callUuid = '',
    this.callerNumber = '',
    this.holdIndex = '',
    this.holdLabel = '',
    this.registrar = '',
  });

  /// Reads a Firebase data message. Null unless it is an incoming-call push
  /// with a call id; [isVobiz] tells whether Vobiz holds the call for it.
  /// `expires_at` is Unix seconds from Vobiz (milliseconds once the call
  /// screen has stored it), told apart by size.
  static PushCall? fromData(Map<String, dynamic> data) {
    if ('${data['type'] ?? ''}' != 'incoming_call') return null;
    final callId = '${data['call_id'] ?? ''}';
    if (callId.isEmpty) return null;
    final at = int.tryParse('${data['expires_at'] ?? ''}');
    return PushCall(
      callId: callId,
      caller: '${data['caller'] ?? ''}',
      callee: '${data['callee'] ?? ''}',
      expiresAt: at == null ? null : VobizIncomingPush.epochToDateTime(at),
      callUuid: '${data['call_uuid'] ?? ''}',
      callerNumber: '${data['caller_number'] ?? ''}',
      holdIndex: '${data['index'] ?? ''}',
      holdLabel: '${data['label'] ?? ''}',
      registrar: '${data['registrar'] ?? ''}',
    );
  }

  /// Reads the `extra` the call screen hands back on Accept or Decline.
  static PushCall? fromExtra(Map<dynamic, dynamic>? extra) {
    if (extra == null || extra['source'] != 'push') return null;
    return fromData(extra.map((key, value) => MapEntry('$key', value)));
  }

  /// The SIP Call-ID of the INVITE Vobiz is holding.
  final String callId;

  /// Vobiz's CallUUID.
  final String callUuid;

  /// The caller's number, where [caller] may be a name.
  final String callerNumber;

  /// Where Vobiz's registrar holds the call: handed back on the REGISTER that
  /// claims it, as X-Index, X-Label and X-vobiz-Registrar-Info.
  final String holdIndex;
  final String holdLabel;
  final String registrar;

  /// A call Vobiz's registrar holds until this phone claims it.
  bool get isVobiz => holdIndex.isNotEmpty && holdLabel.isNotEmpty && registrar.isNotEmpty;

  /// Who to show on the call screen: the caller's name or number.
  String get displayCaller => caller.isNotEmpty ? caller : callerNumber;

  /// The push as the SDK reads it, for `VobizClient.handleIncomingPush` and
  /// the call-screen reports. Null unless [isVobiz].
  VobizIncomingPush? get sdkPush => isVobiz
      ? VobizIncomingPush.tryParse(toExtra().map((key, value) => MapEntry(key, value as Object?)))
      : null;

  /// Who is calling, as Vobiz saw it.
  final String caller;

  /// The SIP user that was called.
  final String callee;

  /// When Vobiz stops holding the call.
  final DateTime? expiresAt;

  /// The fields the call screen keeps, so Accept and Decline can claim the
  /// call even when the app was closed.
  Map<String, dynamic> toExtra() => <String, dynamic>{
        'source': 'push',
        'type': 'incoming_call',
        'call_id': callId,
        'caller': caller,
        'callee': callee,
        if (expiresAt != null) 'expires_at': '${expiresAt!.millisecondsSinceEpoch}',
        if (callUuid.isNotEmpty) 'call_uuid': callUuid,
        if (callerNumber.isNotEmpty) 'caller_number': callerNumber,
        if (isVobiz) ...<String, dynamic>{'index': holdIndex, 'label': holdLabel, 'registrar': registrar},
      };

  @override
  String toString() => 'PushCall($callId, from $displayCaller)';
}

/// The sample server's reference for a call it rang (the `PushRef` header on
/// the INVITE): the caller's leg CallUUID, which the server acts on for
/// Conference and the connection watch.
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

/// The real caller the sample server passed on the INVITE (`X-VH-Caller`),
/// when its caller ID shows the Vobiz number instead.
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
