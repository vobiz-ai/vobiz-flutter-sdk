import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/logger.dart';
import 'socket_message_parser.dart';
import 'socket_protocol.dart';

class SocketService {
  SocketService({
    required this.wsUrl,
    Logger? logger,
  })  : _logger = logger ?? Logger(),
        _parser = SocketMessageParser();

  final String wsUrl;
  final Logger _logger;
  final SocketMessageParser _parser;

  final StreamController<SocketEnvelope> _messages =
      StreamController<SocketEnvelope>.broadcast();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  bool _manualClose = false;

  Stream<SocketEnvelope> get messages => _messages.stream;

  Future<void> connect() async {
    _manualClose = false;
    _logger.info('Connecting to $wsUrl');
    try {
      _socket = await WebSocket.connect(
        wsUrl,
        protocols: ['sip'],
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('WS connect timeout: $wsUrl'),
      );
      _logger.info('WebSocket connected');
      _socketSub = _socket!.listen(
        _onMessage,
        onDone: _onDone,
        onError: _onError,
        cancelOnError: true,
      );
    } catch (e) {
      _logger.error('WebSocket connect failed: $e');
      rethrow;
    }
  }

  Future<void> send(SocketEnvelope envelope) async {
    final ws = _socket;
    if (ws == null || ws.readyState != WebSocket.open) {
      throw StateError('Socket is not connected');
    }
    final msg = jsonEncode(envelope.toJson());
    _logger.info('>> $msg');
    ws.add(msg);
  }

  Future<void> close() async {
    _manualClose = true;
    await _socketSub?.cancel();
    await _socket?.close();
    _socketSub = null;
    _socket = null;
  }

  void _onMessage(dynamic raw) {
    _logger.info('<< $raw');
    try {
      _messages.add(_parser.parse(raw));
    } catch (e) {
      _logger.error('Failed to parse socket message: $e');
    }
  }

  void _onDone() {
    final code = _socket?.closeCode;
    final reason = _socket?.closeReason;
    _logger.warn('WebSocket closed (code=$code reason=$reason)');
    _socketSub = null;
    _socket = null;
    if (!_manualClose) {
      _messages.addError(StateError('Socket closed unexpectedly'));
    }
  }

  void _onError(Object e) {
    _logger.error('WebSocket error: $e');
    if (!_manualClose) {
      _messages.addError(e);
    }
  }

  Future<void> dispose() async {
    await close();
    await _messages.close();
  }
}
