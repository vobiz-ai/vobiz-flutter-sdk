import '../state/call_state.dart';
import 'call_actions.dart';

/// A snapshot of the current call (`VobizClient.currentCall`).
///
/// Changing its fields does not affect the call; use the [VobizClient]
/// methods for that.
class CallSession {
  CallSession({
    required this.callId,
    required this.remoteIdentity,
    required this.isIncoming,
    this.state = CallStateStatus.idle,
    this.callUuid,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(headers);

  final String callId;
  final String remoteIdentity;
  final bool isIncoming;

  /// Vobiz's CallUUID for this leg, once the platform has reported it.
  final String? callUuid;

  /// Custom `X-VH-` headers sent (outbound) or received (inbound) on the call.
  final Map<String, String> headers;
  CallStateStatus state;
  bool muted = false;
  bool speakerEnabled = false;

  CallActions get actions {
    switch (state) {
      case CallStateStatus.incoming:
        return const CallActions(canAnswer: true, canReject: true);
      case CallStateStatus.connecting:
      case CallStateStatus.ringing:
        return const CallActions(
          canHangup: true,
          canMute: true,
          canSendDtmf: true,
        );
      case CallStateStatus.active:
        return const CallActions(
          canHangup: true,
          canMute: true,
          canHold: true,
          canSendDtmf: true,
        );
      case CallStateStatus.held:
        return const CallActions(
          canHangup: true,
          canResume: true,
        );
      default:
        return const CallActions();
    }
  }
}
