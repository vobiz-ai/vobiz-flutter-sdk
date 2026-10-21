import '../calls/call_session.dart';
import '../models/call/call_direction.dart';
import '../state/call_state.dart';
import 'sdk_event.dart';

class CallEvent extends SdkEvent {
  CallEvent({
    required this.callId,
    required this.state,
    this.session,
    this.message,
    this.direction,
    this.remoteIdentity,
    this.callUuid,
    this.headers = const <String, String>{},
    this.sipCode,
    this.reason,
    super.timestamp,
  });

  final String callId;
  final CallStateStatus state;
  final CallSession? session;
  final String? message;

  /// Whether this client placed the call or it rang this client.
  final CallDirection? direction;

  /// The number or SIP user on the other end: the dialled destination for an
  /// outbound call, the caller for an inbound one.
  final String? remoteIdentity;

  /// Vobiz's CallUUID for this client's leg (the `X-Calluuid` SIP header).
  /// Needed to transfer the call and to find its recording.
  final String? callUuid;

  /// Custom `X-VH-` headers on the call: the ones this client sent on an
  /// outbound call, or the ones that arrived on an inbound INVITE.
  final Map<String, String> headers;

  /// The SIP status code when a call fails, such as 486 or 603.
  final int? sipCode;

  /// Why a call failed or ended, as specific as the far end reported it.
  final String? reason;
}
