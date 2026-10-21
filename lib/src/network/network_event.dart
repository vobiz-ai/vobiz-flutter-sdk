import '../events/sdk_event.dart';
import 'connectivity_monitor.dart';

/// What happened to the network or the signalling connection.
enum NetworkEventType {
  /// The device lost every network. Calls cannot be placed until it is back.
  offline,

  /// The device has a network again after being offline.
  online,

  /// The device moved to a different network (Wi-Fi to mobile, say). The
  /// old connection is bound to the previous network and is replaced.
  networkChanged,

  /// A reconnect attempt is scheduled or running.
  reconnecting,

  /// The connection is back and registered again.
  reconnected,

  /// Reconnecting gave up after [ReconnectPolicy.maxAttempts] attempts. The
  /// client tries again on the next network change, or when the app calls
  /// `VobizClient.reconnect()`.
  reconnectFailed,
}

/// How usable the signalling connection is right now, from the transport's
/// point of view. Media quality during a call is reported separately.
enum SignalingQuality {
  /// Connected and registered.
  good,

  /// Reconnecting, or connected through a network change that has not been
  /// confirmed yet. Calls may fail.
  degraded,

  /// No network, or reconnecting has given up.
  unavailable,
}

/// A change in the device's network or in the signalling connection.
class NetworkEvent extends SdkEvent {
  NetworkEvent({
    required this.type,
    required this.network,
    required this.quality,
    this.previousNetwork,
    this.attempt = 0,
    this.retryIn,
    this.reason,
    super.timestamp,
  });

  final NetworkEventType type;

  /// The network at the time of the event.
  final NetworkStatus network;

  /// The network before a [NetworkEventType.networkChanged],
  /// [NetworkEventType.online] or [NetworkEventType.offline] event.
  final NetworkStatus? previousNetwork;

  final SignalingQuality quality;

  /// Reconnect attempt number (1-based) for [NetworkEventType.reconnecting]
  /// and the number of attempts made for [NetworkEventType.reconnectFailed].
  final int attempt;

  /// When the next attempt runs, for a scheduled [NetworkEventType.reconnecting].
  final Duration? retryIn;

  /// Why, in words.
  final String? reason;

  @override
  String toString() => 'NetworkEvent(${type.name}, $network, ${quality.name}'
      '${attempt > 0 ? ', attempt $attempt' : ''}'
      '${retryIn != null ? ', retry in ${retryIn!.inMilliseconds} ms' : ''}'
      '${reason != null ? ', $reason' : ''})';
}
