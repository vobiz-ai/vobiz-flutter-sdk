import '../audio/audio_route.dart';
import '../events/sdk_event.dart';
import 'call_quality.dart';

/// Typed media updates for the current call: mute, hold, early media, audio
/// route and call quality. See `VobizClient.callMediaEvents`.
sealed class CallMediaEvent extends SdkEvent {
  CallMediaEvent({this.callId, super.timestamp});

  /// The call it concerns; null for a route change between calls.
  final String? callId;
}

/// The microphone was muted or unmuted. Fires whenever the SDK's mute state
/// changes, including when a new call starts unmuted.
class MuteChangedEvent extends CallMediaEvent {
  MuteChangedEvent({required super.callId, required this.muted, super.timestamp});

  final bool muted;
}

/// The call was put on hold (a re-INVITE with `a=sendonly`) or resumed.
class HoldChangedEvent extends CallMediaEvent {
  HoldChangedEvent({required super.callId, required this.held, super.timestamp});

  final bool held;
}

/// A 183 Session Progress carried SDP and its audio is now playing: ringback
/// or a carrier announcement ("the number you have dialled...").
class EarlyMediaEvent extends CallMediaEvent {
  EarlyMediaEvent({required super.callId, super.timestamp});
}

/// Call audio moved to another output.
class AudioRouteChangedEvent extends CallMediaEvent {
  AudioRouteChangedEvent({super.callId, required this.route, super.timestamp});

  final AudioRoute route;
}

/// A call-quality measurement. [levelChanged] is true when the quality level
/// moved (for example from good to poor): show a "poor network" warning on
/// those.
class CallQualityEvent extends CallMediaEvent {
  CallQualityEvent({
    required super.callId,
    required this.sample,
    required this.levelChanged,
    super.timestamp,
  });

  final CallQualitySample sample;
  final bool levelChanged;

  CallQualityLevel get level => sample.level;
}
