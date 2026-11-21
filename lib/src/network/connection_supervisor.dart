import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../utils/logger.dart';
import 'connectivity_monitor.dart';
import 'network_event.dart';
import 'reconnect_policy.dart';

/// Keeps the signalling connection up across drops and network changes.
///
/// The client starts it at sign-in and stops it at sign-out. It decides when
/// to reconnect; the client does the reconnecting through [reconnect] (open
/// a socket and send REGISTER) and reports the outcome through [connected]
/// and [connectionLost].
///
/// - A drop schedules attempts with [ReconnectPolicy] backoff. After the
///   policy's last attempt it emits [NetworkEventType.reconnectFailed] and
///   stops trying until the network changes or [reconnectNow] is called.
/// - While the device is offline nothing is attempted and no attempts are
///   counted; [isOffline] lets callers fail fast.
/// - When the network comes back, or moves (Wi-Fi to mobile), the socket is
///   bound to an interface that no longer exists, so it reconnects at once
///   instead of waiting for the keep-alive to notice. During a call it calls
///   [onHandover] and leaves a socket that has not been reported dead alone;
///   the keep-alive still catches a dead one, and the call layer restarts
///   ICE if the call's audio is lost. Back from no network at all, it
///   reconnects even during a call.
/// - An attempt that opens the socket but is not registered within
///   [registerTimeout] counts as failed.
@internal
class ConnectionSupervisor {
  ConnectionSupervisor({
    required this.policy,
    required this.monitor,
    required this.reconnect,
    required this.onEvent,
    this.hasActiveCall,
    this.onHandover,
    this.registerTimeout = const Duration(seconds: 10),
    Random? random,
    Logger? logger,
  })  : _random = random,
        _logger = logger ?? Logger();

  final ReconnectPolicy policy;
  final ConnectivityMonitor monitor;

  /// Runs one reconnect attempt. Throws when the socket cannot be opened.
  final Future<void> Function() reconnect;

  final void Function(NetworkEvent event) onEvent;

  /// Whether a call is in progress; network changes then go to [onHandover]
  /// instead of replacing the socket.
  final bool Function()? hasActiveCall;

  /// Called when the network changes during a call while the socket is kept.
  /// The client only logs it: if the audio does not survive the change, ICE
  /// reports the loss and the client restarts ICE then.
  final void Function(NetworkStatus from, NetworkStatus to)? onHandover;

  final Duration registerTimeout;

  final Random? _random;
  final Logger _logger;

  StreamSubscription<NetworkStatus>? _sub;
  Timer? _retryTimer;
  Timer? _registerTimer;
  bool _running = false;
  bool _connected = false;
  // The socket has not been reported dead. Unlike [_connected] it survives
  // going offline: a short outage on the same address can leave it working.
  bool _socketAlive = false;
  bool _attemptInFlight = false;
  bool _gaveUp = false;
  bool _reconnecting = false;
  int _attempts = 0;
  NetworkStatus? _network;

  // Bumped by stop(): an attempt or a network read still pending from an
  // earlier sign-in must not act on the next one.
  int _generation = 0;

  bool get isRunning => _running;

  /// The device has no network.
  bool get isOffline => _network != null && !_network!.isOnline;

  /// Reconnecting has given up; see [NetworkEventType.reconnectFailed].
  bool get hasGivenUp => _gaveUp;

  /// Attempts made since the connection was last up.
  int get attempts => _attempts;

  NetworkStatus? get network => _network;

  SignalingQuality get quality {
    if (isOffline || _gaveUp) return SignalingQuality.unavailable;
    if (!_connected || _reconnecting) return SignalingQuality.degraded;
    return SignalingQuality.good;
  }

  /// Starts watching the network. Call at sign-in, before the first connect.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _sub = monitor.changes.listen(_onNetwork);
    final now = await monitor.current();
    // A change may have arrived while current() was pending; it is newer.
    if (_running) _network ??= now;
  }

  /// Stops everything. Call at sign-out.
  void stop() {
    _running = false;
    _generation++;
    _sub?.cancel();
    _sub = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _registerTimer?.cancel();
    _registerTimer = null;
    _connected = false;
    _socketAlive = false;
    _attemptInFlight = false;
    _gaveUp = false;
    _reconnecting = false;
    _attempts = 0;
    // The next sign-in reads the network afresh: a stale one would make its
    // first report look like a change.
    _network = null;
  }

  /// The connection is up and registered.
  void connected() {
    _registerTimer?.cancel();
    _registerTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connected = true;
    _socketAlive = true;
    final wasReconnecting = _reconnecting;
    final made = _attempts;
    _attempts = 0;
    _gaveUp = false;
    _reconnecting = false;
    if (wasReconnecting) {
      _emit(NetworkEventType.reconnected,
          attempt: made, reason: made == 1 ? 'Reconnected' : 'Reconnected after $made attempts');
    }
  }

  /// The connection dropped, or an attempt failed. Schedules the next attempt
  /// unless one is already pending.
  void connectionLost(String reason) {
    if (!_running) return;
    _connected = false;
    _socketAlive = false;
    _registerTimer?.cancel();
    _registerTimer = null;
    if (_attemptInFlight || _retryTimer != null || _gaveUp) return;
    _reconnecting = true;
    if (isOffline) {
      _emit(NetworkEventType.reconnecting, reason: 'Waiting for the network');
      return;
    }
    if (!policy.allows(_attempts)) {
      _gaveUp = true;
      _reconnecting = false;
      _logger.warn('Reconnect gave up after $_attempts attempts');
      _emit(NetworkEventType.reconnectFailed,
          attempt: _attempts, reason: 'Gave up after $_attempts attempts: $reason');
      return;
    }
    final delay = policy.delayFor(_attempts + 1, _random);
    _logger.warn('Reconnecting in ${delay.inMilliseconds} ms '
        '(attempt ${_attempts + 1}): $reason');
    _emit(NetworkEventType.reconnecting,
        attempt: _attempts + 1, retryIn: delay, reason: reason);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _attempt();
    });
  }

  /// Reconnects now, resetting the backoff: for app resume, a push, or a user
  /// tapping "retry" after [NetworkEventType.reconnectFailed].
  ///
  /// While marked offline it asks the monitor again first: a report that the
  /// network came back can be missed (iOS sends none while the app is in the
  /// background), and an online answer then reconnects at once.
  void reconnectNow({String reason = 'Reconnect requested'}) {
    if (!_running) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempts = 0;
    _gaveUp = false;
    if (isOffline) {
      _connected = false;
      _reconnecting = true;
      _emit(NetworkEventType.reconnecting, reason: 'Waiting for the network');
      final generation = _generation;
      monitor.current().then((NetworkStatus status) {
        if (_running && generation == _generation) _onNetwork(status);
      }, onError: (Object e) => _logger.warn('Could not read the network: $e'));
      return;
    }
    if (_attemptInFlight) return;
    _reconnecting = true;
    _emit(NetworkEventType.reconnecting, attempt: 1, retryIn: Duration.zero, reason: reason);
    _attempt();
  }

  Future<void> _attempt() async {
    if (!_running || _attemptInFlight) return;
    if (isOffline) {
      _emit(NetworkEventType.reconnecting, reason: 'Waiting for the network');
      return;
    }
    final generation = _generation;
    _attemptInFlight = true;
    _attempts++;
    _connected = false;
    _socketAlive = false;
    try {
      await reconnect();
      if (generation != _generation) return;
      _attemptInFlight = false;
      if (!_running || _connected) return;
      // Socket open; REGISTER must succeed in time or this attempt failed.
      _registerTimer?.cancel();
      _registerTimer = Timer(registerTimeout, () {
        _registerTimer = null;
        if (!_connected) connectionLost('No answer to REGISTER');
      });
    } catch (e) {
      if (generation != _generation) return;
      _attemptInFlight = false;
      connectionLost('Reconnect failed: $e');
    }
  }

  void _onNetwork(NetworkStatus next) {
    if (!_running) return;
    final prev = _network;
    _network = next;
    if (prev == next) return;

    if (!next.isOnline) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _registerTimer?.cancel();
      _registerTimer = null;
      _connected = false;
      _reconnecting = true;
      _emit(NetworkEventType.offline, previous: prev, reason: 'No network');
      return;
    }

    // The first report after start() is not a change.
    if (prev == null) return;
    final cameBack = !prev.isOnline;
    _emit(cameBack ? NetworkEventType.online : NetworkEventType.networkChanged,
        previous: prev,
        reason: cameBack
            ? 'Network is back (${next.primary.name})'
            : 'Network changed to ${next.primary.name}');

    if (cameBack) {
      // Every network was down. The old socket may never report its death
      // (seen live on the emulator: nothing until a WebSocket ping timed out,
      // after the call's grace period had run out), so it is not trusted:
      // reconnect now, even during a call. The call keeps its dialog, and its
      // audio moves with an ICE restart once the client is registered again.
      _socketAlive = false;
    }
    if (hasActiveCall?.call() ?? false) {
      // A socket still up is kept during a call. Let the call layer move the
      // media (ICE restart); the keep-alive catches a dead socket and the
      // normal reconnect takes over after the call.
      onHandover?.call(prev, next);
      if (_socketAlive) return;
    }
    reconnectNow(reason: cameBack ? 'Network is back' : 'Network changed');
  }

  void _emit(NetworkEventType type,
      {NetworkStatus? previous, int attempt = 0, Duration? retryIn, String? reason}) {
    onEvent(NetworkEvent(
      type: type,
      network: _network ?? NetworkStatus(const <NetworkType>[NetworkType.other]),
      previousNetwork: previous,
      quality: quality,
      attempt: attempt,
      retryIn: retryIn,
      reason: reason,
    ));
  }
}
