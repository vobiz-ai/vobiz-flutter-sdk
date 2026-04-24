import 'dart:async';
import 'dart:convert';

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

/// Main entry point for SDK consumers.
///
/// Connect with SIP credentials, make and receive calls, and control call
/// state. All state changes are emitted as events on the public streams.
///
/// ```dart
/// final client = VobizClient(config: SdkConfig(
///   wsUrl: 'wss://registrar.vobiz.ai:5063/',
///   sipServer: 'registrar.vobiz.ai',
///   backendUrl: 'http://your-server:3000',
/// ));
///
/// await client.connect(CredentialConfig(
///   username: 'your-sip-username',
///   password: 'your-sip-password',
/// ));
///
/// client.callEvents.listen((event) {
///   if (event.state == CallStateStatus.incoming) {
///     await client.acceptCall();
///   }
/// });
///
/// await client.makeCall('+919876543210');
/// ```
class VobizClient {
  VobizClient({
    SdkConfig config = const SdkConfig(),
    Logger? logger,
  })  : _config = config,
        _logger = logger ?? Logger(),
        _sip = SIPService(
          wsUrl: config.wsUrl,
          sipServer: config.sipServer,
          logger: logger,
        ),
        _peer = PeerService(
          iceConfig: config.iceConfig,
          mediaConstraints: config.mediaConstraints,
          logger: logger,
        ) {
    _wireSip();
  }

  final SdkConfig _config;
  final Logger _logger;
  final SIPService _sip;
  final PeerService _peer;

  // Internal state
  String? _callId;
  CallStateStatus _callState = CallStateStatus.idle;
  RegistrationState _registrationState = RegistrationState.unregistered;
  ConnectionStateStatus _connectionState = ConnectionStateStatus.disconnected;
  bool _isMuted = false;

  // Inbound polling state
  String? _pendingInboundCaller;
  String? _pendingInboundJoinNumber;
  Timer? _pollTimer;
  Timer? _callSetupTimer;

  // Event streams
  final _connectionEvents =
      StreamController<ConnectionEvent>.broadcast();
  final _callEvents = StreamController<CallEvent>.broadcast();
  final _mediaEvents = StreamController<MediaEvent>.broadcast();
  final _errorEvents = StreamController<ErrorEvent>.broadcast();

  /// Broadcasts connection and registration changes.
  Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;

  /// Broadcasts call lifecycle changes.
  Stream<CallEvent> get callEvents => _callEvents.stream;

  /// Broadcasts local and remote media updates.
  Stream<MediaEvent> get mediaEvents => _mediaEvents.stream;

  /// Broadcasts SDK errors.
  Stream<ErrorEvent> get errorEvents => _errorEvents.stream;

  /// Current registration state snapshot.
  RegistrationState get registrationState => _registrationState;

  /// Current connection state snapshot.
  ConnectionStateStatus get connectionState => _connectionState;

  /// Whether the client is currently registered.
  bool get isConnected =>
      _connectionState == ConnectionStateStatus.connected &&
      _registrationState == RegistrationState.registered;

  /// The active call ID, if any.
  String? get currentCallId => _callId;

  /// Active call snapshot for consumers that prefer the CallSession model.
  CallSession? get currentCall {
    final id = _callId;
    if (id == null) return null;
    return CallSession(
      callId: id,
      remoteIdentity: _pendingInboundCaller ?? '',
      isIncoming: _pendingInboundCaller != null,
      answerUrl: null,
      state: _callState,
    );
  }

  /// All tracked calls (at most one in the current implementation).
  Iterable<CallSession> get calls =>
      currentCall != null ? <CallSession>[currentCall!] : const [];

  // ---------------------------------------------------------------------------
  // Connect / Disconnect
  // ---------------------------------------------------------------------------

  /// Connects and registers with either [CredentialConfig] or [TokenConfig].
  Future<void> connect(Object credentials) async {
    if (credentials is CredentialConfig) {
      await _connectWithSip(credentials.username, credentials.password);
      return;
    }
    if (credentials is TokenConfig) {
      // Token-based auth: token maps to a SIP username+password on the server.
      // Treat the token as password with a placeholder username for now.
      await _connectWithSip(credentials.displayName ?? 'token-user',
          credentials.token);
      return;
    }
    throw ArgumentError('Unsupported credentials type: ${credentials.runtimeType}');
  }

  /// Convenience: connect with username + password.
  Future<void> connectWithCredentials(CredentialConfig config) =>
      _connectWithSip(config.username, config.password);

  /// Disconnects the SIP session and clears all call state.
  Future<void> disconnect() async {
    _stopPolling();
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

  /// Releases all resources. Call when the client is no longer needed.
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

  /// Initiates an outbound call to [destination] (E.164 phone number or SIP user).
  Future<String> makeCall(String destination) async {
    if (!isConnected) throw StateError('Not registered — call connect() first');
    if (_callState != CallStateStatus.idle) {
      throw StateError('Already in a call');
    }

    final callId = 'out_${DateTime.now().millisecondsSinceEpoch}';
    _callId = callId;
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
      _emitCallEvent(callId, CallStateStatus.ringing, 'INVITE sent');
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
  // Inbound call (SIP INVITE from Vobiz)
  // ---------------------------------------------------------------------------

  /// Accepts the current incoming call.
  Future<void> acceptCall([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null || _callState != CallStateStatus.incoming) return;

    // Polling-detected inbound: Flutter dials out to join the conference.
    if (_pendingInboundCaller != null) {
      await _answerViaConference(id);
      return;
    }

    // True SIP INVITE inbound: answer with SDP.
    await _answerSipInvite(id);
  }

  /// Rejects the current incoming call.
  Future<void> rejectCall([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    _sip.reject();
    await _backend('/answer-inbound', method: 'DELETE').catchError((_) {});
    await _cleanupCall(id);
  }

  /// Hangs up the active call.
  Future<void> hangup([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    _sip.hangup();
    await _cleanupCall(id);
  }

  // ---------------------------------------------------------------------------
  // Audio control
  // ---------------------------------------------------------------------------

  /// Mutes the local microphone.
  Future<void> mute([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    await _peer.setMuted(true);
    _isMuted = true;
  }

  /// Unmutes the local microphone.
  Future<void> unmute([String? callId]) async {
    final id = callId ?? _callId;
    if (id == null) return;
    await _peer.setMuted(false);
    _isMuted = false;
  }

  bool get isMuted => _isMuted;

  // ---------------------------------------------------------------------------
  // Call control — all go through the backend server
  // ---------------------------------------------------------------------------

  /// Puts the active PSTN leg on hold (plays on-hold music to the caller).
  Future<void> hold([String? callId]) async {
    await _peer.setMuted(true);
    await _backend('/hold-start');
    final id = callId ?? _callId;
    if (id != null) {
      _callState = CallStateStatus.held;
      _emitCallEvent(id, CallStateStatus.held, 'On hold');
    }
  }

  /// Resumes a held call.
  Future<void> resume([String? callId]) async {
    await _peer.setMuted(false);
    await _backend('/resume');
    final id = callId ?? _callId;
    if (id != null) {
      _callState = CallStateStatus.active;
      _emitCallEvent(id, CallStateStatus.active, 'Resumed');
    }
  }

  /// Blind-transfers the PSTN caller to [to].
  Future<void> transfer(String to) =>
      _backend('/transfer', body: {'to': to});

  /// Starts a warm (consultative) transfer to [to].
  Future<void> warmTransferStart(String to) =>
      _backend('/warm-transfer/start', body: {'to': to});

  /// Completes a warm transfer (hangs up the SDK leg, leaves PSTN + target).
  Future<void> warmTransferComplete() async {
    _sip.hangup();
    final id = _callId;
    if (id != null) await _cleanupCall(id);
  }

  /// Merges a third party into the conference call.
  Future<void> addCall(String to) => _backend('/add-call', body: {'to': to});

  /// Starts a separate second call to [to] (puts first call on hold).
  Future<void> startSecondCall(String to) =>
      _backend('/second-call', body: {'to': to});

  /// Swaps between the two active calls (Option B).
  Future<void> swapCalls() => _backend('/swap-calls');

  /// Merges two separate calls into a conference.
  Future<void> mergeCalls() => _backend('/merge-calls');

  /// Ends the second call and resumes the first.
  Future<void> endSecondCall() => _backend('/end-second-call');

  /// Removes the added conference party.
  Future<void> removeAddedCall() => _backend('/remove-added-call');

  // ---------------------------------------------------------------------------
  // Private — SIP wiring
  // ---------------------------------------------------------------------------

  void _wireSip() {
    _sip.onRegistered = () {
      _registrationState = RegistrationState.registered;
      _connectionState = ConnectionStateStatus.connected;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: 'Registered',
      ));
      _startPolling();
    };

    _sip.onRegistrationFailed = (String reason) {
      _registrationState = RegistrationState.failed;
      _connectionState = ConnectionStateStatus.failed;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: reason,
      ));
    };

    _sip.onSocketError = (String reason) {
      _stopPolling();
      _registrationState = RegistrationState.unregistered;
      _connectionState = ConnectionStateStatus.disconnected;
      _connectionEvents.addIfOpen(ConnectionEvent(
        connectionState: _connectionState,
        registrationState: _registrationState,
        message: reason,
      ));
      _emitError('socket_error', reason, null);
    };

    _sip.onRemoteRinging = () {
      final id = _callId;
      if (id == null) return;
      _callState = CallStateStatus.ringing;
      _emitCallEvent(id, CallStateStatus.ringing, 'Remote ringing');
    };

    _sip.onCallAnswered = (String sdp) async {
      final id = _callId;
      if (id == null) return;
      _clearCallSetupTimer();
      try {
        await _peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        _callState = CallStateStatus.active;
        _emitCallEvent(id, CallStateStatus.active, 'Call connected');
      } catch (e) {
        _logger.error('Failed to apply remote answer: $e');
        _emitError('answer_failed', 'Could not connect audio', e);
      }
    };

    _sip.onIncomingCall = (String callerId, String sdp) {
      // True SIP INVITE inbound — not the polling path.
      // We only handle this if the call was not already detected via polling.
      if (_callState != CallStateStatus.idle) return;
      final id = 'in_${DateTime.now().millisecondsSinceEpoch}';
      _callId = id;
      _callState = CallStateStatus.incoming;
      _emitCallEvent(id, CallStateStatus.incoming, callerId);
    };

    _sip.onCallEnded = () {
      final id = _callId;
      if (id == null) return;
      _cleanupCall(id);
    };

    _sip.onCallFailed = (String reason) {
      final id = _callId;
      _clearCallSetupTimer();
      if (id != null) _cleanupCall(id);
      _emitError('call_failed', reason, null);
    };

    _peer.mediaEvents.listen((MediaEvent event) {
      _mediaEvents.addIfOpen(event);
    });
  }

  Future<void> _connectWithSip(String username, String password) async {
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
      _emitError('connect_failed', 'Could not connect to SIP server', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Private — inbound conference (polling path)
  // ---------------------------------------------------------------------------

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!isConnected) return;
      try {
        final result = await _backendGet('/pending-call');
        if (result == null) return;

        // If showing incoming screen and PSTN hung up → revert to idle.
        if (_callState == CallStateStatus.incoming &&
            _pendingInboundCaller != null) {
          if (result['pending'] != true) {
            _pendingInboundCaller = null;
            _pendingInboundJoinNumber = null;
            final id = _callId;
            if (id != null) await _cleanupCall(id);
          }
          return;
        }

        if (_callState != CallStateStatus.idle) return;
        if (result['pending'] != true) return;

        final caller = result['caller'] as String? ?? 'Unknown';
        final joinNumber = result['joinNumber'] as String? ?? '';
        _pendingInboundCaller = caller;
        _pendingInboundJoinNumber = joinNumber;
        final id = 'inbound_${DateTime.now().millisecondsSinceEpoch}';
        _callId = id;
        _callState = CallStateStatus.incoming;
        _emitCallEvent(id, CallStateStatus.incoming, 'Inbound from $caller');
      } catch (_) {}
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _answerViaConference(String callId) async {
    final caller = _pendingInboundCaller;
    _pendingInboundCaller = null;
    final joinTarget = _pendingInboundJoinNumber?.isNotEmpty == true
        ? _pendingInboundJoinNumber!
        : '';
    _pendingInboundJoinNumber = null;

    _callState = CallStateStatus.connecting;
    _emitCallEvent(callId, CallStateStatus.connecting, 'Joining conference');

    try {
      if (joinTarget.isEmpty) {
        throw StateError('No join number from server — check CALLER_ID in .env');
      }
      await _peer.initialize(callId);
      final offer = await _peer.createOffer();
      await _waitForIceGathering(callId);
      final local = await _peer.peerConnection?.getLocalDescription();
      final sdp = local?.sdp ?? offer.sdp ?? '';

      await _backend('/answer-inbound');
      _logger.info('Joining inbound conference via $joinTarget');
      _sip.call(joinTarget, sdp);
      _startCallSetupTimer(callId);
    } catch (e, st) {
      _logger.error('Inbound conference join failed: $e\n$st');
      await _cleanupCall(callId);
      _emitError('inbound_failed', 'Could not join the call', e);
    }
  }

  Future<void> _answerSipInvite(String callId) async {
    _callState = CallStateStatus.connecting;
    _emitCallEvent(callId, CallStateStatus.connecting, 'Answering');

    try {
      await _peer.initialize(callId);
      final answer = await _peer.createAnswer();
      await _waitForIceGathering(callId);
      final local = await _peer.peerConnection?.getLocalDescription();
      final sdp = local?.sdp ?? answer.sdp ?? '';
      _sip.answer(sdp);
      _callState = CallStateStatus.active;
      _emitCallEvent(callId, CallStateStatus.active, 'Call connected');
    } catch (e, st) {
      _logger.error('SIP answer failed: $e\n$st');
      await _cleanupCall(callId);
      _emitError('answer_failed', 'Could not answer the call', e);
    }
  }

  // ---------------------------------------------------------------------------
  // Private — call setup timer
  // ---------------------------------------------------------------------------

  void _startCallSetupTimer(String callId) {
    _clearCallSetupTimer();
    _callSetupTimer = Timer(const Duration(seconds: 30), () {
      if (_callState == CallStateStatus.connecting ||
          _callState == CallStateStatus.ringing) {
        _logger.warn('Call setup timeout for $callId');
        _sip.hangup();
        _cleanupCall(callId);
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
    _pendingInboundJoinNumber = null;
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

  Future<Map<String, dynamic>?> _backendGet(String path) async {
    try {
      final response = await http
          .get(Uri.parse('${_config.backendUrl}$path'))
          .timeout(_backendTimeout);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
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
