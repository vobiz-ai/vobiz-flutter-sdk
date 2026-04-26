import 'package:meta/meta.dart';

@internal
abstract class SdkEvent {
  SdkEvent({DateTime? timestamp}) : timestamp = timestamp ?? DateTime.now();

  final DateTime timestamp;
}
