import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../events/media_event.dart';
import '../utils/logger.dart';
import '../utils/stream_extensions.dart';
import 'audio_router.dart';
import 'ice_config.dart';
import 'media_constraints.dart';

/// Per-call WebRTC resources — one instance per active call leg.
class _PeerCallState {
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  bool localAudioAttached = false;
  bool remoteDescriptionApplied = false;
  final List<RTCIceCandidate> pendingRemoteCandidates = <RTCIceCandidate>[];
}

/// Handles `flutter_webrtc` peer-connection work, supporting multiple
/// simultaneous call legs (e.g. for hold + add-call conference scenarios).
///
/// Each call is identified by its [callId]. Operations that do not receive an
/// explicit [callId] operate on the "active" call tracked by [_activeCallId].
class PeerService {
  PeerService({
    required this.iceConfig,
    required this.mediaConstraints,
    AudioRouter? audioRouter,
    Logger? logger,
  })  : _audioRouter = audioRouter ?? AudioRouter(),
        _logger = logger ?? Logger();

  final IceConfig iceConfig;
  final MediaConstraints mediaConstraints;
  final AudioRouter _audioRouter;
  final Logger _logger;

  final StreamController<MediaEvent> _mediaEvents =
      StreamController<MediaEvent>.broadcast();
  final StreamController<RTCIceCandidate> _iceCandidates =
      StreamController<RTCIceCandidate>.broadcast();

  /// Per-call state keyed by callId.
  final Map<String, _PeerCallState> _callStates = <String, _PeerCallState>{};

  /// Which call is "current" for operations that don't specify a callId.
  String? _activeCallId;

  /// Emits local/remote media lifecycle updates.
  Stream<MediaEvent> get mediaEvents => _mediaEvents.stream;

  /// Emits local ICE candidates so signaling can forward them to the far end.
  Stream<RTCIceCandidate> get iceCandidates => _iceCandidates.stream;

  /// Current peer connection for the active call.
  RTCPeerConnection? get peerConnection =>
      _activeCallId == null ? null : _callStates[_activeCallId]?.peerConnection;

  /// Current local media stream for the active call.
  MediaStream? get localStream =>
      _activeCallId == null ? null : _callStates[_activeCallId]?.localStream;

  /// Current remote media stream for the active call.
  MediaStream? get remoteStream =>
      _activeCallId == null ? null : _callStates[_activeCallId]?.remoteStream;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Creates a new peer connection for [callId] and sets it as the active call.
  ///
  /// If [callId] already has a state entry it is disposed first (re-init).
  /// Other call legs are left untouched.
  Future<RTCPeerConnection> createPeerConnection(String callId) async {
    if (_callStates.containsKey(callId)) {
      await disposeCall(callId);
    }

    _activeCallId = callId;

    final _PeerCallState state = _PeerCallState();
    _callStates[callId] = state;

    try {
      final RTCPeerConnection connection =
          await flutterWebRTCCreatePeerConnection(
        iceConfig.toRtcConfiguration(),
        <String, dynamic>{},
      );

      state.peerConnection = connection;
      _wirePeerConnectionListeners(connection, callId, state);

      _mediaEvents.addIfOpen(
        MediaEvent(callId: callId, message: 'Peer connection created'),
      );

      return connection;
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to create peer connection for $callId: $error\n$stackTrace',
      );
      _callStates.remove(callId);
      if (_activeCallId == callId) _activeCallId = null;
      rethrow;
    }
  }

  /// Convenience entry point: creates the peer connection and captures mic audio.
  Future<void> initialize(String callId) async {
    await createPeerConnection(callId);
    await attachLocalAudioStream(callId);
  }

  /// Switches which call is treated as "active" for operations without an
  /// explicit [callId]. Does nothing if [callId] has no state entry.
  void setActiveCall(String callId) {
    if (_callStates.containsKey(callId)) {
      _activeCallId = callId;
    }
  }

  // -------------------------------------------------------------------------
  // Offer / Answer exchange
  // -------------------------------------------------------------------------

  /// Captures mic audio and attaches it to [callId]'s peer connection.
  Future<MediaStream> attachLocalAudioStream(String callId) async {
    final _PeerCallState state = _requireState(callId);
    final RTCPeerConnection connection = _requirePeerForState(state, callId);

    if (state.localAudioAttached && state.localStream != null) {
      return state.localStream!;
    }

    try {
      final MediaStream stream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints.toWebRtcConstraints(),
      );

      state.localStream = stream;

      for (final MediaStreamTrack track in stream.getAudioTracks()) {
        await connection.addTrack(track, stream);
      }

      state.localAudioAttached = true;
      _mediaEvents.addIfOpen(
        MediaEvent(
          callId: callId,
          localStream: state.localStream,
          remoteStream: state.remoteStream,
          message: 'Local audio stream attached',
        ),
      );

      return stream;
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to attach local audio for $callId: $error\n$stackTrace',
      );
      state.localAudioAttached = false;
      rethrow;
    }
  }

  /// Creates an SDP offer for the active call.
  Future<RTCSessionDescription> createOffer() async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);
    final RTCPeerConnection peer = _requirePeerForState(state, callId);

    final RTCSessionDescription offer = await peer.createOffer(
      <String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      },
    );
    await peer.setLocalDescription(offer);
    _emitMediaMessage(callId, state, 'Local offer created');
    return offer;
  }

  /// Creates an SDP answer for the active call.
  Future<RTCSessionDescription> createAnswer() async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);
    final RTCPeerConnection peer = _requirePeerForState(state, callId);

    final RTCSessionDescription answer = await peer.createAnswer(
      <String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      },
    );
    await peer.setLocalDescription(answer);
    _emitMediaMessage(callId, state, 'Local answer created');
    return answer;
  }

  /// Creates an offer for the active call after ensuring local audio is ready.
  Future<RTCSessionDescription> createOfferExchange() async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);

    if (state.peerConnection == null) {
      throw StateError('Peer connection has not been created for $callId');
    }
    if (!state.localAudioAttached) {
      await attachLocalAudioStream(callId);
    }
    return createOffer();
  }

  /// Accepts a remote offer and produces a local answer for the active call.
  Future<RTCSessionDescription> handleRemoteOffer(
    RTCSessionDescription offer,
  ) async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);

    if (state.peerConnection == null) {
      throw StateError('Peer connection has not been created for $callId');
    }
    if (!state.localAudioAttached) {
      await attachLocalAudioStream(callId);
    }
    await setRemoteDescription(offer);
    return createAnswer();
  }

  /// Applies a remote answer to complete an outbound offer/answer exchange.
  Future<void> handleRemoteAnswer(RTCSessionDescription answer) async {
    await setRemoteDescription(answer);
    _emitMediaMessage(
      _activeCallId ?? 'unknown',
      _callStates[_activeCallId],
      'Remote answer applied',
    );
  }

  /// Applies the remote SDP description to the active call.
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);

    await _requirePeerForState(state, callId).setRemoteDescription(description);
    state.remoteDescriptionApplied = true;
    await _flushPendingRemoteCandidates(callId, state);
    _emitMediaMessage(callId, state, 'Remote description applied');
  }

  /// Adds a remote ICE candidate to the active call.
  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);

    if (!state.remoteDescriptionApplied) {
      state.pendingRemoteCandidates.add(candidate);
      _emitMediaMessage(callId, state, 'Remote ICE candidate queued');
      return;
    }

    await _requirePeerForState(state, callId).addCandidate(candidate);
    _emitMediaMessage(callId, state, 'Remote ICE candidate added');
  }

  // -------------------------------------------------------------------------
  // Audio control
  // -------------------------------------------------------------------------

  /// Mutes/unmutes the active call's local microphone.
  Future<void> setMuted(bool muted) async {
    final String? callId = _activeCallId;
    if (callId == null) return;
    await setMutedForCall(callId, muted);
  }

  /// Mutes/unmutes a specific call's local microphone.
  ///
  /// This lets the SDK silence a held call's audio without affecting the active
  /// call's peer connection.
  Future<void> setMutedForCall(String callId, bool muted) async {
    final _PeerCallState? state = _callStates[callId];
    if (state?.localStream == null) return;

    for (final MediaStreamTrack track
        in state!.localStream!.getAudioTracks()) {
      track.enabled = !muted;
    }

    _emitMediaMessage(
      callId,
      state,
      muted ? 'Microphone muted' : 'Microphone unmuted',
    );
  }

  /// Switches audio output routing for the active call.
  Future<void> enableSpeaker(bool enabled) async {
    await _audioRouter.enableSpeaker(enabled);
    _emitMediaMessage(
      _activeCallId ?? 'unknown',
      _callStates[_activeCallId],
      enabled ? 'Speaker enabled' : 'Speaker disabled',
    );
  }

  // -------------------------------------------------------------------------
  // Disposal
  // -------------------------------------------------------------------------

  /// Disposes the active call's peer connection and removes its state entry.
  ///
  /// Other call legs are unaffected. After disposal [_activeCallId] is cleared.
  Future<void> disposeCurrentCall() async {
    final String? callId = _activeCallId;
    if (callId != null) {
      await disposeCall(callId);
    }
  }

  /// Disposes a specific call leg by [callId].
  Future<void> disposeCall(String callId) async {
    final _PeerCallState? state = _callStates.remove(callId);
    if (state == null) return;

    await _disposeState(state, callId);

    if (_activeCallId == callId) {
      _activeCallId = _callStates.isEmpty ? null : _callStates.keys.last;
    }
  }

  /// Disposes all tracked call legs.
  Future<void> disposeAllCalls() async {
    for (final MapEntry<String, _PeerCallState> entry
        in Map<String, _PeerCallState>.from(_callStates).entries) {
      await _disposeState(entry.value, entry.key);
    }
    _callStates.clear();
    _activeCallId = null;
  }

  /// Closes the media event stream when the service is no longer reused.
  Future<void> dispose() async {
    await disposeAllCalls();
    await _iceCandidates.close();
    await _mediaEvents.close();
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  void _wirePeerConnectionListeners(
    RTCPeerConnection connection,
    String callId,
    _PeerCallState state,
  ) {
    connection.onTrack = (RTCTrackEvent event) {
      if (event.streams.isEmpty) return;
      state.remoteStream = event.streams.first;
      _mediaEvents.addIfOpen(
        MediaEvent(
          callId: callId,
          localStream: state.localStream,
          remoteStream: state.remoteStream,
          message: 'Remote stream attached',
        ),
      );
    };

    connection.onIceCandidate = (RTCIceCandidate candidate) {
      _logger.info('ICE candidate generated for $callId');
      _iceCandidates.addIfOpen(candidate);
      _mediaEvents.addIfOpen(
        MediaEvent(
          callId: callId,
          localStream: state.localStream,
          remoteStream: state.remoteStream,
          message: 'Local ICE candidate generated',
        ),
      );
    };

    connection.onConnectionState = (RTCPeerConnectionState connectionState) {
      _logger.info('Peer connection state for $callId: $connectionState');
      _mediaEvents.addIfOpen(
        MediaEvent(
          callId: callId,
          localStream: state.localStream,
          remoteStream: state.remoteStream,
          message: 'Peer connection state changed to $connectionState',
        ),
      );
    };

    connection.onIceConnectionState = (RTCIceConnectionState iceState) {
      _logger.info('ICE connection state for $callId: $iceState');
      _mediaEvents.addIfOpen(
        MediaEvent(
          callId: callId,
          localStream: state.localStream,
          remoteStream: state.remoteStream,
          message: 'ICE connection state changed to $iceState',
        ),
      );
    };
  }

  Future<void> _flushPendingRemoteCandidates(
    String callId,
    _PeerCallState state,
  ) async {
    if (!state.remoteDescriptionApplied ||
        state.pendingRemoteCandidates.isEmpty) {
      return;
    }

    final RTCPeerConnection peer = _requirePeerForState(state, callId);
    for (final RTCIceCandidate candidate
        in List<RTCIceCandidate>.from(state.pendingRemoteCandidates)) {
      await peer.addCandidate(candidate);
    }
    state.pendingRemoteCandidates.clear();
    _emitMediaMessage(callId, state, 'Queued remote ICE candidates applied');
  }

  Future<void> _disposeState(_PeerCallState state, String callId) async {
    final MediaStream? localStream = state.localStream;
    final MediaStream? remoteStream = state.remoteStream;
    final RTCPeerConnection? peerConnection = state.peerConnection;

    if (localStream != null) {
      for (final MediaStreamTrack track in localStream.getTracks()) {
        await track.stop();
      }
      await localStream.dispose();
    }

    if (remoteStream != null) {
      for (final MediaStreamTrack track in remoteStream.getTracks()) {
        await track.stop();
      }
      await remoteStream.dispose();
    }

    if (peerConnection != null) {
      await peerConnection.close();
    }

    state.peerConnection = null;
    state.localStream = null;
    state.remoteStream = null;
    state.localAudioAttached = false;
    state.remoteDescriptionApplied = false;
    state.pendingRemoteCandidates.clear();

    _mediaEvents.addIfOpen(
      MediaEvent(callId: callId, message: 'Peer resources released'),
    );
  }

  void _emitMediaMessage(
    String callId,
    _PeerCallState? state,
    String message,
  ) {
    _mediaEvents.addIfOpen(
      MediaEvent(
        callId: callId,
        localStream: state?.localStream,
        remoteStream: state?.remoteStream,
        message: message,
      ),
    );
  }

  String _requireActiveCallId() {
    final String? id = _activeCallId;
    if (id == null) {
      throw StateError('PeerService has no active call');
    }
    return id;
  }

  _PeerCallState _requireState(String callId) {
    final _PeerCallState? state = _callStates[callId];
    if (state == null) {
      throw StateError('No peer state for call $callId');
    }
    return state;
  }

  RTCPeerConnection _requirePeerForState(
    _PeerCallState state,
    String callId,
  ) {
    final RTCPeerConnection? peer = state.peerConnection;
    if (peer == null) {
      throw StateError('Peer connection not initialized for call $callId');
    }
    return peer;
  }
}

/// Wraps `createPeerConnection` so the service code stays explicit about the
/// `flutter_webrtc` entry point it uses.
Future<RTCPeerConnection> flutterWebRTCCreatePeerConnection(
  Map<String, dynamic> configuration,
  Map<String, dynamic> constraints,
) {
  return createPeerConnection(configuration, constraints);
}
