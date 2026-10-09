import 'package:meta/meta.dart';

import '../models/call/call_stats.dart';
import '../state/call_state.dart';
import 'call_actions.dart';

@internal
class CallSession {
  CallSession({
    required this.callId,
    required this.remoteIdentity,
    required this.isIncoming,
    required this.answerUrl,
    this.state = CallStateStatus.idle,
    Map<String, dynamic> metadata = const <String, dynamic>{},
    this.stats = const CallStats(),
    this.callUuid,
    Map<String, String> headers = const <String, String>{},
  })  : metadata = Map<String, dynamic>.from(metadata),
        headers = Map<String, String>.unmodifiable(headers);

  final String callId;
  final String remoteIdentity;
  final bool isIncoming;
  final String? answerUrl;
  final Map<String, dynamic> metadata;

  /// Vobiz's CallUUID for this leg, once the platform has reported it.
  final String? callUuid;

  /// Custom `X-VH-` headers sent (outbound) or received (inbound) on the call.
  final Map<String, String> headers;
  CallStateStatus state;
  CallStats stats;
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
