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

  /// The hold [began] asked for is still on its way (a re-INVITE).
  bool _holding = false;

  /// The interruption ended while that hold was on its way: its
  /// `shouldResume`. Null when it has not ended.
  bool? _endedWhileHolding;

  /// Bumped by [reset]: a hold that completes after it belongs to a call that
  /// has ended, or that the user has resumed.
  int _epoch = 0;

  /// Whether the call is on hold because of an interruption.
  bool get heldByInterruption => _heldByInterruption;

  Future<void> began() async {
    if (!isCallActive() || isHeld() || _holding) return;
    final epoch = _epoch;
    _holding = true;
    _endedWhileHolding = null;
    try {
      await hold();
    } catch (e) {
      if (epoch == _epoch) {
        _holding = false;
        _endedWhileHolding = null;
      }
      _logger.warn('Could not hold the call for an interruption: $e');
      return;
    }
    if (epoch != _epoch) return;
    _holding = false;
    final shouldResume = _endedWhileHolding;
    _endedWhileHolding = null;
    if (shouldResume == null) {
      _heldByInterruption = true;
      return;
    }
    // The interruption was already over when the hold went through.
    await _resume(shouldResume);
  }

  /// [shouldResume] is false when the platform says not to (iOS
  /// `shouldResume` absent), or the user should resume by hand.
  Future<void> ended({bool shouldResume = true}) async {
    if (_holding) {
      // The hold is still on its way: [began] resumes once it is through.
      _endedWhileHolding = shouldResume;
      return;
    }
    if (!_heldByInterruption) return;
    _heldByInterruption = false;
    await _resume(shouldResume);
  }

  Future<void> _resume(bool shouldResume) async {
    if (!shouldResume || !isHeld()) return;
    try {
      await resume();
    } catch (e) {
      _logger.warn('Could not resume the call after an interruption: $e');
    }
  }

  /// Forget an interruption hold, when the call ends or the user resumes.
  void reset() {
    _heldByInterruption = false;
    _holding = false;
    _endedWhileHolding = null;
    _epoch++;
  }
}
