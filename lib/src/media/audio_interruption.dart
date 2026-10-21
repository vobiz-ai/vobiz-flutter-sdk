import 'package:meta/meta.dart';

import '../utils/logger.dart';

/// Holds the call while another app's call (a SIM, WhatsApp or other VoIP
/// call) has the microphone, and resumes it afterwards if the SDK was the one
/// that held it.
///
/// The SDK cannot see those interruptions itself: flutter_webrtc ignores
/// Android audio-focus changes and iOS `AVAudioSession` interruptions, and
/// the SDK has no platform code. The app forwards them to
/// `VobizClient.audioInterruptionBegan` / `audioInterruptionEnded`, for
/// example from the `audio_session` package's `interruptionEventStream`, or
/// from `flutter_callkit_incoming`'s `ACTION_CALL_TOGGLE_HOLD`.
@internal
class AudioInterruptionHandler {
  AudioInterruptionHandler({
    required this.isCallActive,
    required this.isHeld,
    required this.hold,
    required this.resume,
    Logger? logger,
  }) : _logger = logger ?? Logger();

  final bool Function() isCallActive;
  final bool Function() isHeld;
  final Future<void> Function() hold;
  final Future<void> Function() resume;
  final Logger _logger;

  bool _heldByInterruption = false;

  /// Whether the call is on hold because of an interruption.
  bool get heldByInterruption => _heldByInterruption;

  Future<void> began() async {
    if (!isCallActive() || isHeld()) return;
    try {
      await hold();
      _heldByInterruption = true;
    } catch (e) {
      _logger.warn('Could not hold the call for an interruption: $e');
    }
  }

  /// [shouldResume] is false when the platform says not to (iOS
  /// `shouldResume` absent), or the user should resume by hand.
  Future<void> ended({bool shouldResume = true}) async {
    if (!_heldByInterruption) return;
    _heldByInterruption = false;
    if (!shouldResume || !isHeld()) return;
    try {
      await resume();
    } catch (e) {
      _logger.warn('Could not resume the call after an interruption: $e');
    }
  }

  /// Forget an interruption hold, when the call ends or the user resumes.
  void reset() => _heldByInterruption = false;
}
