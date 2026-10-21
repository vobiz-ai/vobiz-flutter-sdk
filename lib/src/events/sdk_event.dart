/// Base class of every event the SDK emits.
abstract class SdkEvent {
  SdkEvent({DateTime? timestamp}) : timestamp = timestamp ?? DateTime.now();

  final DateTime timestamp;
}
