import 'dart:math';

/// How the client retries after the signalling connection drops.
///
/// Delays grow exponentially from [initialDelay] by [multiplier] up to
/// [maxDelay]. After [maxAttempts] failed attempts the client stops, reports
/// [ConnectionStateStatus.failed] and a `reconnect_failed` error, and waits
/// for the network to change or for the app to sign in again. While the
/// device has no network at all no attempts are made and none are counted.
///
/// ```dart
/// const SdkConfig(
///   reconnectPolicy: ReconnectPolicy(maxAttempts: 8, maxDelay: Duration(seconds: 20)),
/// );
/// ```
class ReconnectPolicy {
  const ReconnectPolicy({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.maxAttempts = 10,
    this.jitter = 0.2,
  })  : assert(multiplier >= 1.0),
        assert(jitter >= 0 && jitter < 1),
        assert(maxAttempts == null || maxAttempts > 0);

  /// Delay before the first attempt.
  final Duration initialDelay;

  /// Longest delay between two attempts.
  final Duration maxDelay;

  /// Factor each delay is multiplied by.
  final double multiplier;

  /// Attempts before giving up. `null` retries forever (not recommended on
  /// mobile: every attempt is a TLS handshake).
  final int? maxAttempts;

  /// Random spread applied to each delay, as a fraction (0.2 = ±20 %), so a
  /// fleet of phones does not reconnect in lock-step after an outage.
  final double jitter;

  /// The delay before attempt number [attempt] (1-based), without jitter.
  Duration baseDelayFor(int attempt) {
    final n = attempt < 1 ? 0 : attempt - 1;
    final ms = initialDelay.inMilliseconds * pow(multiplier, n);
    final capped = min(ms, maxDelay.inMilliseconds.toDouble());
    return Duration(milliseconds: capped.round());
  }

  /// The delay before attempt number [attempt] (1-based), with jitter drawn
  /// from [random].
  Duration delayFor(int attempt, [Random? random]) {
    final base = baseDelayFor(attempt).inMilliseconds;
    if (jitter == 0 || base == 0) return Duration(milliseconds: base);
    final r = (random ?? _random).nextDouble() * 2 - 1; // -1 .. 1
    final ms = (base * (1 + jitter * r)).round();
    return Duration(milliseconds: min(ms, maxDelay.inMilliseconds));
  }

  /// Whether another attempt is allowed after [attemptsMade] attempts.
  bool allows(int attemptsMade) =>
      maxAttempts == null || attemptsMade < maxAttempts!;

  static final Random _random = Random();
}
