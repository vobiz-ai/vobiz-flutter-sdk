import 'dart:async';

import 'package:meta/meta.dart';

/// How the client keeps the signalling WebSocket open and notices when it has
/// died.
///
/// The SDK used to send a SIP OPTIONS to `sip:admin@<registrar>` every 60 s.
/// Vobiz's registrar answers that with "No contact found" and logs an error
/// each time, and it still took up to 60 s to notice a dead connection.
///
/// - [pingInterval]: a WebSocket ping (RFC 6455 §5.5.2), answered by the
///   server's WebSocket layer, never by SIP. If no pong arrives within one
///   interval the socket is closed and the client reconnects, so a silently
///   dead connection is noticed within twice this interval.
/// - [crlfInterval]: optionally also a SIP keep-alive "ping" (a double CRLF,
///   RFC 5626 §4.4.1) answered by a single CRLF "pong". Off by default; turn
///   it on only for a registrar that answers it. A missing pong within
///   [crlfPongTimeout] closes the socket.
class KeepAliveConfig {
  const KeepAliveConfig({
    this.pingInterval = const Duration(seconds: 15),
    this.crlfInterval,
    this.crlfPongTimeout = const Duration(seconds: 10),
  });

  /// WebSocket ping interval. `null` disables it (not recommended).
  final Duration? pingInterval;

  /// Double-CRLF keep-alive interval. `null` (default) disables it.
  final Duration? crlfInterval;

  /// How long to wait for the CRLF pong (RFC 5626 recommends 10 s).
  final Duration crlfPongTimeout;
}

/// Runs the RFC 5626 double-CRLF ping / single-CRLF pong exchange.
@internal
class CrlfKeepAlive {
  CrlfKeepAlive({
    required this.interval,
    required this.pongTimeout,
    required this.send,
    required this.onDead,
  });

  /// The ping a client sends.
  static const String ping = '\r\n\r\n';

  final Duration interval;
  final Duration pongTimeout;
  final void Function(String data) send;

  /// No pong arrived in time: the connection should be treated as dead.
  final void Function() onDead;

  Timer? _interval;
  Timer? _pongTimer;

  bool get isRunning => _interval != null;

  void start() {
    stop();
    _interval = Timer.periodic(interval, (_) => _ping());
  }

  void stop() {
    _interval?.cancel();
    _interval = null;
    _pongTimer?.cancel();
    _pongTimer = null;
  }

  /// Something arrived that consists only of CR/LF: the pong.
  void pongReceived() {
    _pongTimer?.cancel();
    _pongTimer = null;
  }

  void _ping() {
    send(ping);
    _pongTimer ??= Timer(pongTimeout, () {
      _pongTimer = null;
      stop();
      onDead();
    });
  }
}
