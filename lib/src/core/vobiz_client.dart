import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../calls/call_session.dart';
import '../events/call_event.dart';
import '../events/connection_event.dart';
import '../events/error_event.dart';
import '../events/media_event.dart';
import '../models/auth/credential_config.dart';
import '../models/auth/token_config.dart';
import '../signaling/sip_service.dart';
import '../state/call_state.dart';
import '../state/connection_state.dart';
import '../state/registration_state.dart';
import '../utils/logger.dart';
import '../utils/stream_extensions.dart';
import '../webrtc/peer_service.dart';
import 'sdk_config.dart';

class VobizClient {
  VobizClient({
    SdkConfig config = const SdkConfig(),
    Logger? logger,
  })  : _config = config,
        _logger = logger ?? Logger(writer: config.debug ? debugPrint : null),
        _sip = SIPService(
          wsUrl: config.wsUrl,
          sipServer: config.sipServer,
          logger: logger ?? Logger(writer: config.debug ? debugPrint : null),
        ),
        _peer = PeerService(
          iceConfig: config.iceConfig,
          mediaConstraints: config.mediaConstraints,
          logger: logger ?? Logger(writer: config.debug ? debugPrint : null),
        ) {
    _wireSip();
  }

  final SdkConfig _config;
  final Logger _logger;
  final SIPService _sip;
  final PeerService _peer;

  // Internal state
  String? _callId;
  String? _activeCallDestination;
  CallStateStatus _callState = CallStateStatus.idle;
  RegistrationState _registrationState = RegistrationState.unregistered;
  ConnectionStateStatus _connectionState = ConnectionStateStatus.disconnected;
  bool _isMuted = false;

  // Credentials stored for reconnection
  String? _username;
  String? _password;

  // Reconnection
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  // Inbound call state
  String? _pendingInboundCaller;
  String? _pendingInboundSdp;
  Timer? _callSetupTimer;

  // Event streams
  final _connectionEvents = StreamController<ConnectionEvent>.broadcast();
  final _callEvents = StreamController<CallEvent>.broadcast();
  final _mediaEvents = StreamController<MediaEvent>.broadcast();
  final _errorEvents = StreamController<ErrorEvent>.broadcast();

  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  Stream<CallEvent> get callEvents => _callEvents.stream;
  Stream<MediaEvent> get mediaEvents => _mediaEvents.stream;
  Stream<ErrorEvent> get errorEvents => _errorEvents.stream;

  RegistrationState get registrationState => _registrationState;
  ConnectionStateStatus get connectionState => _connectionState;

  bool get isConnected =>
      _connectionState == ConnectionStateStatus.connected &&
      _registrationState == RegistrationState.registered;

  String? get currentCallId => _callId;

  CallSession? get currentCall {
    final id = _callId;
    if (id == null) return null;
    return CallSession(
      callId: id,
      remoteIdentity: _pendingInboundCaller ?? _activeCallDestination ?? '',
      isIncoming: _pendingInboundCaller != null,
      answerUrl: null,
      state: _callState,
    );
  }

  Iterable<CallSession> get calls =>
      currentCall != null ? <CallSession>[currentCall!] : const [];

  // ---------------------------------------------------------------------------
  // Connect / Disconnect
  // ---------------------------------------------------------------------------

  Future<void> connect(Object credentials) async {
    if (credentials is CredentialConfig) {
      await _connectWithCredentials(credentials.username, credentials.password);
      return;
    }
    if (credentials is TokenConfig) {
      await _connectWithCredentials(
          credentials.displayName ?? 'token-user', credentials.token);
      return;
    }
    throw ArgumentError(
        'Unsupported credentials type: ${credentials.runtimeType}');
  }

  Future<void> connectWithCredentials(CredentialConfig config) =>
      _connectWithCredentials(config.username, config.password);

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _clearCallSetupTimer();
    _sip.disconnect();
    await _peer.disposeAllCalls();
    _callId = null;
    _callState = CallStateStatus.idle;
    _registrationState = RegistrationState.unregistered;
    _connectionState = ConnectionStateStatus.disconnected;
    _connectionEvents.addIfOpen(ConnectionEvent(
      connectionState: _connectionState,
      registrationState: _registrationState,
      message: 'Disconnected',
    ));
  }

  Future<void> dispose() async {
    await disconnect();
    await _connectionEvents.close();
    await _callEvents.close();
    await _mediaEvents.close();
    await _errorEvents.close();
    await _peer.dispose();
  }

  // ---------------------------------------------------------------------------
  // Outbound call
  // ---------------------------------------------------------------------------

  Future<String> makeCall(String destination) async {
    if (!isConnected) throw StateError('Not registered — call connect() first');
    if (_callState != CallStateStatus.idle) {
      throw StateError('Already in a call');
    }

    final callId = DateTime.now().microsecondsSinceEpoch.toString();
    _callId = callId;
    _activeCallDestination = destination;
    _callState = CallStateStatus.connecting;
    _emitCallEvent(callId, CallStateStatus.connecting, 'Preparing outbound call');

    try {
      await _peer.initialize(callId);
      final offer = await _peer.createOffer();
      await _waitForIceGathering(callId);
      final local = await _peer.peerConnection?.getLocalDescription();
      final sdp = local?.sdp ?? offer.sdp ?? '';
      _sip.call(destination, sdp);
      _callState = CallStateStatus.ringing;
      _emitCallEvent(callId, CallStateStatus.ringing, 'Invite sent');
      _startCallSetupTimer(callId);
      return callId;
    } catch (e, st) {
      _logger.error('makeCall failed: $e\n$st');
      await _cleanupCall(callId);
      _emitError('make_call_failed', 'Could not start the call', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Inbound call
  // ---------------------------------------------------------------------------

  Future<void> acceptCall([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null || _callState != CallStateStatus.incoming) return;
    await _answerInvite(id);
  }

  Future<void> rejectCall([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    _sip.reject();
    await _cleanupCall(id);
  }

  Future<void> hangup([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    _sip.hangup();
    await _cleanupCall(id);
  }

  // ---------------------------------------------------------------------------
  // Audio control
  // ---------------------------------------------------------------------------

  Future<void> mute([String? callId]) async {
    await _peer.setMuted(true);
    _isMuted = true;
  }

  Future<void> unmute([String? callId]) async {
    await _peer.setMuted(false);
    _isMuted = false;
  }

  bool get isMuted => _isMuted;

  // ---------------------------------------------------------------------------
  // Call control — backend server
  // ---------------------------------------------------------------------------

  Future<void> hold([String? callId]) async {
    await _peer.setMuted(true);
    await _backend('/hold-start');
    final id = callId ?? _callId;
    if (id != null) {
      _callState = CallStateStatus.held;
      _emitCallEvent(id, CallStateStatus.held, 'On hold');
    }
  }

  Future<void> resume([String? callId]) async {
    await _peer.setMuted(false);
    await _backend('/resume');
    final id = callId ?? _callId;
    if (id != null) {
      _callState = CallStateStatus.active;
      _emitCallEvent(id, CallStateStatus.active, 'Resumed');
    }
  }

  Future<void> transfer(String to) =>
      _backend('/transfer', body: {'to': to});

  Future<void> warmTransferStart(String to) =>
      _backend('/warm-transfer/start', body: {'to': to});

  Future<void> warmTransferComplete() async {
    final id = _callId;
    _sip.hangup();
    if (id != null) await _cleanupCall(id);
  }

  Future<void> addCall(String to) => _backend('/add-call', body: {'to': to});
  Future<void> startSecondCall(String to) =>
      _backend('/second-call', body: {'to': to});
  Future<void> swapCalls() => _backend('/swap-calls');
  Future<void> mergeCalls() => _backend('/merge-calls');
  Future<void> endSecondCall() => _backend('/end-second-call');
  Future<void> removeAddedCall() => _backend('/remove-added-call');

  // ---------------------------------------------------------------------------
  // Private — SIP wiring
  // ---------------------------------------------------------------------------

  void _wireSip() {
    _sip.onRegistered = () {
      _registrationState = RegistrationState.registered;
      _connectionState = ConnectionStateStatus.connected;
      _reconnectAttempts = 0;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Registered',
      ));
    };

    _sip.onRegistrationFailed = (reason) {
      _registrationState = RegistrationState.failed;
      _connectionState = ConnectionStateStatus.failed;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Registration failed: $reason',
      ));
      _emitError('registration_failed', reason, null);
    };

    _sip.onSocketError = (reason) {
      _registrationState = RegistrationState.unregistered;
      _connectionState = ConnectionStateStatus.disconnected;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Socket error: $reason',
      ));
      _emitError('socket_error', reason, null);
      if (_config.autoReconnect) _scheduleReconnect();
    };

    _sip.onRemoteRinging = () {
      final id = _callId;
      if (id == null) return;
      _callState = CallStateStatus.ringing;
      _emitCallEvent(id, CallStateStatus.ringing, 'Remote ringing');
    };

    _sip.onCallProgress = (sdp) {
      final id = _callId;
      if (id == null) return;
      _callState = CallStateStatus.ringing;
      _emitCallEvent(id, CallStateStatus.ringing, 'Call progress');
    };

    _sip.onCallAnswered = (sdp) async {
      final id = _callId;
      if (id == null) return;
      _clearCallSetupTimer();
      try {
        await _peer.setRemoteDescription(
            RTCSessionDescription(sdp, 'answer'));
        _callState = CallStateStatus.active;
        _emitCallEvent(id, CallStateStatus.active, 'Call connected');
      } catch (e) {
        _logger.error('Failed to apply remote answer: $e');
        _emitError('answer_failed', 'Could not connect audio', e);
      }
    };

    _sip.onIncomingCall = (callerId, sdp) {
      if (_callState != CallStateStatus.idle) return;
      final callId = 'in_${DateTime.now().millisecondsSinceEpoch}';
      _callId = callId;
      _pendingInboundCaller = callerId;
      _pendingInboundSdp = sdp;
      _callState = CallStateStatus.incoming;
      _emitCallEvent(callId, CallStateStatus.incoming, callerId);
    };

    _sip.onCallEnded = () {
      final id = _callId;
      if (id != null) _cleanupCall(id);
    };

    _sip.onCallFailed = (reason) {
      final id = _callId;
      if (id != null) _cleanupCall(id);
      _emitError('call_failed', reason, null);
    };

    _peer.mediaEvents.listen((MediaEvent event) {
      _mediaEvents.addIfOpen(event);
    });
  }

  Future<void> _connectWithCredentials(
      String username, String password) async {
    _username = username;
    _password = password;
    _registrationState = RegistrationState.registering;
    _connectionState = ConnectionStateStatus.connecting;
    _connectionEvents.addIfOpen(ConnectionEvent(
      connectionState: _connectionState,
      registrationState: _registrationState,
      message: 'Connecting',
    ));

    try {
      await _sip.connect();
      _sip.register(username, password);
    } catch (e) {
      _registrationState = RegistrationState.failed;
      _connectionState = ConnectionStateStatus.failed;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Connection failed: $e',
      ));
      _emitError('connect_failed', 'Could not connect', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Private — reconnection
  // ---------------------------------------------------------------------------

  void _scheduleReconnect() {
    final username = _username;
    final password = _password;
    if (username == null || password == null) return;

    _reconnectTimer?.cancel();
    final delaySeconds =
        (_reconnectAttempts < 5) ? (1 << _reconnectAttempts) : 30;
    _reconnectAttempts++;

    _logger.warn(
        'Reconnecting in ${delaySeconds}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      if (_connectionState == ConnectionStateStatus.connected) return;
      _sip.disconnect();
      try {
        await _connectWithCredentials(username, password);
      } catch (_) {
        if (_config.autoReconnect) _scheduleReconnect();
      }
    });
  }

  Future<void> _answerInvite(String callId) async {
    _callState = CallStateStatus.connecting;
    _emitCallEvent(callId, CallStateStatus.connecting, 'Answering');

    try {
      await _peer.initialize(callId);
      final remoteSdp = _pendingInboundSdp;
      if (remoteSdp != null && remoteSdp.isNotEmpty) {
        await _peer.setRemoteDescription(
            RTCSessionDescription(remoteSdp, 'offer'));
      }
      final answer = await _peer.createAnswer();
      await _waitForIceGathering(callId);
      final local = await _peer.peerConnection?.getLocalDescription();
      final sdp = local?.sdp ?? answer.sdp ?? '';
      _sip.answer(sdp);
      _callState = CallStateStatus.active;
      _emitCallEvent(callId, CallStateStatus.active, 'Call connected');
    } catch (e, st) {
      _logger.error('Answer failed: $e\n$st');
      await _cleanupCall(callId);
      _emitError('answer_failed', 'Could not answer the call', e);
    }
  }

  // ---------------------------------------------------------------------------
  // Private — call setup timer
  // ---------------------------------------------------------------------------

  void _startCallSetupTimer(String callId) {
    _clearCallSetupTimer();
    _callSetupTimer = Timer(const Duration(seconds: 30), () async {
      if (_callState == CallStateStatus.connecting ||
          _callState == CallStateStatus.ringing) {
        _logger.warn('Call setup timeout for $callId');
        _sip.hangup();
        await _cleanupCall(callId);
        _emitError('call_timeout', 'Call setup timed out', null);
      }
    });
  }

  void _clearCallSetupTimer() {
    _callSetupTimer?.cancel();
    _callSetupTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Private — WebRTC helpers
  // ---------------------------------------------------------------------------

  Future<void> _waitForIceGathering(String callId) async {
    final pc = _peer.peerConnection;
    if (pc == null) return;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final state = await pc.getIceGatheringState();
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    }
    _logger.warn('ICE gathering timeout — proceeding with available candidates');
  }

  // ---------------------------------------------------------------------------
  // Private — cleanup
  // ---------------------------------------------------------------------------

  Future<void> _cleanupCall(String callId) async {
    _clearCallSetupTimer();
    _pendingInboundCaller = null;
    _pendingInboundSdp = null;
    _activeCallDestination = null;
    _callState = CallStateStatus.ended;
    _emitCallEvent(callId, CallStateStatus.ended, 'Call ended');
    await _peer.disposeCall(callId);
    _callId = null;
    _callState = CallStateStatus.idle;
    _isMuted = false;
  }

  // ---------------------------------------------------------------------------
  // Private — backend HTTP calls
  // ---------------------------------------------------------------------------

  static const Duration _backendTimeout = Duration(seconds: 10);

  Future<void> _backend(
    String path, {
    String method = 'POST',
    Map<String, String>? body,
  }) async {
    final url = Uri.parse('${_config.backendUrl}$path');
    try {
      final response = body != null
          ? await http
              .post(url,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode(body))
              .timeout(_backendTimeout)
          : method == 'DELETE'
              ? await http.delete(url).timeout(_backendTimeout)
              : await http.post(url).timeout(_backendTimeout);
      if (response.statusCode >= 400) {
        _logger.warn('Backend $path returned ${response.statusCode}');
      }
    } catch (e) {
      _logger.warn('Backend $path failed (non-fatal): $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Private — events
  // ---------------------------------------------------------------------------

  void _emitCallEvent(String callId, CallStateStatus state, String message) {
    _callEvents.addIfOpen(CallEvent(
      callId: callId,
      state: state,
      message: message,
    ));
  }

  void _emitError(String code, String message, Object? cause) {
    _errorEvents.addIfOpen(ErrorEvent(
      code: code,
      message: message,
      cause: cause,
    ));
  }
}
