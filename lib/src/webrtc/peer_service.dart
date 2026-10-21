import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../audio/audio_route.dart';
import '../audio/proximity.dart';
import '../events/media_event.dart';
import '../media/call_media_event.dart';
import '../media/call_quality.dart';
import '../media/sdp_utils.dart';
import '../models/call/call_stats.dart';
import '../utils/logger.dart';
import '../utils/stream_extensions.dart';
import 'ice_config.dart';
import 'media_constraints.dart';

/// Creates a native peer connection. Tests substitute a fake.
typedef PeerConnectionFactory = Future<RTCPeerConnection> Function(
  Map<String, dynamic> configuration,
  Map<String, dynamic> constraints,
);

/// Opens the microphone. Tests substitute a fake.
typedef UserMediaFactory = Future<MediaStream> Function(
  Map<String, dynamic> constraints,
);

/// Thrown when a call is ended (hung up, cancelled) while its media was
/// still being set up. The half-built media has already been released.
class PeerCallEndedException implements Exception {
  PeerCallEndedException(this.callId);

  final String callId;

  @override
  String toString() => 'Call $callId ended while its media was being set up';
}

/// Per-call WebRTC resources — one instance per active call leg.
class _PeerCallState {
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  bool localAudioAttached = false;
  bool remoteDescriptionApplied = false;
  bool disposed = false;

  /// The user's mute choice. Applies to the track whenever it exists.
  bool muted = false;

  /// On hold: the track is silenced whatever [muted] says.
  bool held = false;

  /// The last remote SDP applied (offer, answer or provisional answer).
  String? remoteSdp;

  /// The SDP of a 183 applied as a provisional answer.
  String? provisionalSdp;
  String? provisionalPending;

  bool gatheringComplete = false;
  final Set<String> candidateTypes = <String>{};

  Timer? qualityTimer;
  final CallQualityAnalyzer qualityAnalyzer = CallQualityAnalyzer();
  final CallQualityLevelTracker levelTracker = CallQualityLevelTracker();
  final CallQualityAnalyzer pollAnalyzer = CallQualityAnalyzer();

  final List<RTCIceCandidate> pendingRemoteCandidates = <RTCIceCandidate>[];
}

/// Handles `flutter_webrtc` peer-connection work, supporting multiple
/// simultaneous call legs (e.g. for hold + add-call conference scenarios).
///
/// Each call is identified by its [callId]. Operations that do not receive an
/// explicit [callId] operate on the "active" call tracked by [_activeCallId].
@internal
class PeerService {
  PeerService({
    required this.iceConfig,
    required this.mediaConstraints,
    AudioRouteController? audioRoutes,
    ProximityController proximity = const NoProximityController(),
    PeerConnectionFactory? peerConnectionFactory,
    UserMediaFactory? userMediaFactory,
    this.qualityInterval = const Duration(seconds: 2),
    Logger? logger,
  })  : _logger = logger ?? Logger(),
        _proximity = proximity,
        _createPeer = peerConnectionFactory ?? flutterWebRTCCreatePeerConnection,
        _getUserMedia = userMediaFactory ??
            ((Map<String, dynamic> c) => navigator.mediaDevices.getUserMedia(c)) {
    this.audioRoutes = audioRoutes ?? AudioRouteController(logger: _logger);
    _routeSubscription = this.audioRoutes.routeChanges.listen((AudioRoute route) {
      _callMediaEvents.addIfOpen(
          AudioRouteChangedEvent(callId: _activeCallId, route: route));
      _updateProximity();
    });
  }

  final IceConfig iceConfig;
  final MediaConstraints mediaConstraints;
  final Logger _logger;
  final PeerConnectionFactory _createPeer;
  final UserMediaFactory _getUserMedia;

  /// How often call quality is sampled once media flows. Zero disables it.
  final Duration qualityInterval;

  /// Call audio outputs: list, select, and reset between calls.
  late final AudioRouteController audioRoutes;
  late final StreamSubscription<AudioRoute> _routeSubscription;

  ProximityController _proximity;
  bool _proximityEnabled = false;

  /// Turns the screen off at the ear; see [ProximityController].
  ProximityController get proximity => _proximity;
  set proximity(ProximityController value) {
    if (_proximityEnabled) unawaited(_safeProximity(_proximity, false));
    _proximity = value;
    _proximityEnabled = false;
    _updateProximity();
  }

  final StreamController<MediaEvent> _mediaEvents =
      StreamController<MediaEvent>.broadcast();
  final StreamController<CallMediaEvent> _callMediaEvents =
      StreamController<CallMediaEvent>.broadcast();
  final StreamController<RTCIceCandidate> _iceCandidates =
      StreamController<RTCIceCandidate>.broadcast();

  /// Per-call state keyed by callId.
  final Map<String, _PeerCallState> _callStates = <String, _PeerCallState>{};

  /// Which call is "current" for operations that don't specify a callId.
  String? _activeCallId;

  /// Called with each ICE connection state change, so the client can tell
  /// when a call's media has been lost (failed/disconnected) or recovered.
  void Function(String callId, RTCIceConnectionState state)?
      onIceConnectionState;

  /// Emits local/remote media lifecycle updates.
  Stream<MediaEvent> get mediaEvents => _mediaEvents.stream;

  /// Typed updates: mute, hold, early media, route, quality.
  Stream<CallMediaEvent> get callMediaEvents => _callMediaEvents.stream;

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

  /// Whether the active call's microphone is muted by the user. False when
  /// there is no call.
  bool get isMuted => _activeState?.muted ?? false;

  /// Whether the active call is on hold.
  bool get isHeld => _activeState?.held ?? false;

  /// Whether the active call is playing early media from a 183.
  bool get hasEarlyMedia => _activeState?.provisionalSdp != null;

  /// How many call legs hold native resources.
  @visibleForTesting
  int get callCount => _callStates.length;

  _PeerCallState? get _activeState =>
      _activeCallId == null ? null : _callStates[_activeCallId];

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

    // Android 12+ only offers a Bluetooth headset if the permission was
    // granted before the audio switch starts with the first connection.
    await audioRoutes.ensureBluetoothPermission();

    try {
      final RTCPeerConnection connection = await _createPeer(
        iceConfig.toRtcConfiguration(),
        <String, dynamic>{},
      );

      if (!_isLive(callId, state)) {
        await _releasePeer(connection);
        throw PeerCallEndedException(callId);
      }

      state.peerConnection = connection;
      _wirePeerConnectionListeners(connection, callId, state);

      _mediaEvents.addIfOpen(
        MediaEvent(callId: callId, message: 'Peer connection created'),
      );

      return connection;
    } catch (error, stackTrace) {
      if (error is! PeerCallEndedException) {
        _logger.error(
          'Failed to create peer connection for $callId: $error\n$stackTrace',
        );
      }
      if (identical(_callStates[callId], state)) _callStates.remove(callId);
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
  ///
  /// Throws [PeerCallEndedException] if the call is disposed while the
  /// microphone is opening; the new stream is stopped and released then, so
  /// the microphone does not stay on.
  Future<MediaStream> attachLocalAudioStream(String callId) async {
    final _PeerCallState state = _requireState(callId);
    final RTCPeerConnection connection = _requirePeerForState(state, callId);

    if (state.localAudioAttached && state.localStream != null) {
      return state.localStream!;
    }

    try {
      final MediaStream stream = await _getUserMedia(
        mediaConstraints.toWebRtcConstraints(),
      );

      if (!_isLive(callId, state)) {
        await _releaseStream(stream);
        throw PeerCallEndedException(callId);
      }

      state.localStream = stream;

      for (final MediaStreamTrack track in stream.getAudioTracks()) {
        // A mute (or hold) asked for before the microphone opened applies now.
        track.enabled = !(state.muted || state.held);
        await connection.addTrack(track, stream);
        if (!_isLive(callId, state)) throw PeerCallEndedException(callId);
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
      _updateProximity();

      return stream;
    } catch (error, stackTrace) {
      if (error is! PeerCallEndedException) {
        _logger.error(
          'Failed to attach local audio for $callId: $error\n$stackTrace',
        );
      }
      state.localAudioAttached = false;
      rethrow;
    }
  }

  /// Creates an SDP offer for the active call.
  Future<RTCSessionDescription> createOffer() async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);
    final RTCPeerConnection peer = _requirePeerForState(state, callId);

    final RTCSessionDescription offer = _withPreferredCodecs(
      await peer.createOffer(
        <String, dynamic>{
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': false,
        },
      ),
    );
    _requireLive(callId, state);
    await peer.setLocalDescription(offer);
    _emitMediaMessage(callId, state, 'Local offer created');
    return offer;
  }

  /// Creates an SDP answer for the active call.
  Future<RTCSessionDescription> createAnswer() async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);
    final RTCPeerConnection peer = _requirePeerForState(state, callId);

    final RTCSessionDescription answer = _withPreferredCodecs(
      await peer.createAnswer(
        <String, dynamic>{
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': false,
        },
      ),
    );
    _requireLive(callId, state);
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
    _requireLive(callId, state);
    state.remoteDescriptionApplied = true;
    state.remoteSdp = description.sdp;
    await _flushPendingRemoteCandidates(callId, state);
    _emitMediaMessage(callId, state, 'Remote description applied');
  }

  /// Applies a 183 Session Progress SDP as a provisional answer, so ringback
  /// and carrier announcements play before the call is answered. Returns
  /// false (and leaves the call as it was) when it cannot be applied.
  Future<bool> applyProvisionalAnswer(String sdp) async {
    final String? callId = _activeCallId;
    final _PeerCallState? state = _activeState;
    if (callId == null || state == null || sdp.trim().isEmpty) return false;
    final RTCPeerConnection? peer = state.peerConnection;
    if (peer == null) return false;
    // A 200 without SDP can arrive while this is still being applied.
    state.provisionalPending = sdp;
    try {
      await peer.setRemoteDescription(RTCSessionDescription(sdp, 'pranswer'));
    } catch (e) {
      _logger.warn('Could not play early media for $callId: $e');
      if (identical(state.provisionalPending, sdp)) state.provisionalPending = null;
      return false;
    }
    if (!_isLive(callId, state)) return false;
    final bool first = state.provisionalSdp == null;
    state.provisionalSdp = sdp;
    state.remoteSdp = sdp;
    state.remoteDescriptionApplied = true;
    await _flushPendingRemoteCandidates(callId, state);
    _emitMediaMessage(callId, state, 'Early media applied');
    if (first) _callMediaEvents.addIfOpen(EarlyMediaEvent(callId: callId));
    return true;
  }

  /// Applies the final answer (a 200 OK) to the active call. A 200 with no
  /// SDP confirms the 183's SDP, which then becomes the answer.
  Future<void> applyRemoteAnswer(String? sdp) async {
    final _PeerCallState? state = _activeState;
    final String? effective =
        (sdp == null || sdp.trim().isEmpty)
            ? (state?.provisionalSdp ?? state?.provisionalPending)
            : sdp;
    if (effective == null || effective.trim().isEmpty) {
      throw StateError('The answer carried no SDP');
    }
    await handleRemoteAnswer(RTCSessionDescription(effective, 'answer'));
  }

  /// Answers a session change the far end offered mid-call (a re-INVITE or
  /// UPDATE with new SDP, such as the far end putting us on hold): applies
  /// the offer and returns the local answer's SDP. Returns null, leaving the
  /// session as it was, when it cannot be applied.
  Future<String?> answerSessionOffer(String offerSdp) async {
    final String? callId = _activeCallId;
    final _PeerCallState? state = _activeState;
    final RTCPeerConnection? peer = state?.peerConnection;
    if (callId == null || state == null || peer == null) return null;
    try {
      await setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
      await createAnswer();
      final RTCSessionDescription? local = await peer.getLocalDescription();
      if (!_isLive(callId, state)) return null;
      return local?.sdp;
    } catch (e) {
      _logger.warn('Could not answer the session change for $callId: $e');
      try {
        await peer.setRemoteDescription(RTCSessionDescription('', 'rollback'));
      } catch (_) {}
      return null;
    }
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

  /// Waits until the offer or answer can carry a candidate the media server
  /// can reach, then returns. That is: gathering complete; or a relay
  /// candidate; or, when no TURN server is configured, a server-reflexive
  /// one. With TURN configured the first srflx candidate does not end the
  /// wait, since it usually arrives before the relay one and the relay is
  /// what UDP-blocked networks need. Gives up after [timeout] (Android seldom
  /// reports gathering complete) or as soon as [cancelled] returns true.
  Future<void> waitForIceGathering(
    String callId, {
    Duration timeout = const Duration(seconds: 3),
    Duration pollInterval = const Duration(milliseconds: 50),
    bool Function()? cancelled,
  }) async {
    final _PeerCallState? state = _callStates[callId];
    final RTCPeerConnection? pc = state?.peerConnection;
    if (state == null || pc == null) return;
    final bool needRelay = iceConfig.hasTurnServer ||
        iceConfig.iceTransportPolicy == IceTransportPolicy.relay;
    final Stopwatch watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      if (cancelled?.call() ?? false) return;
      if (!_isLive(callId, state)) return;
      if (state.gatheringComplete) return;
      final String sdp = (await pc.getLocalDescription())?.sdp ?? '';
      final bool relay =
          state.candidateTypes.contains('relay') || sdp.contains(' typ relay');
      final bool srflx =
          state.candidateTypes.contains('srflx') || sdp.contains(' typ srflx');
      if (relay || (!needRelay && srflx)) return;
      await Future<void>.delayed(pollInterval);
    }
    _logger.warn(needRelay
        ? 'ICE gathering timeout with no relay candidate — proceeding without TURN'
        : 'ICE gathering timeout — proceeding with available candidates');
  }

  // -------------------------------------------------------------------------
  // Hold (re-INVITE)
  // -------------------------------------------------------------------------

  /// Starts a hold (or resume) renegotiation on the active call: silences
  /// (or restores) the microphone, sets the audio direction to `sendonly`
  /// (or `sendrecv`) and returns the new local offer's SDP for a re-INVITE.
  /// Finish with [completeHold] when the 200 OK arrives, or [abortHold].
  Future<String> beginHold(bool hold) async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);
    final RTCPeerConnection peer = _requirePeerForState(state, callId);
    final String direction = hold ? 'sendonly' : 'sendrecv';

    state.held = hold;
    _applyTrackEnabled(state);

    final bool viaTransceiver = await _setDirection(
        peer, hold ? TransceiverDirection.SendOnly : TransceiverDirection.SendRecv);
    RTCSessionDescription offer = await peer.createOffer(<String, dynamic>{});
    if (!viaTransceiver || SdpUtils.audioDirection(offer.sdp ?? '') != direction) {
      offer = RTCSessionDescription(
          SdpUtils.setAudioDirection(offer.sdp ?? '', direction), 'offer');
    }
    offer = _withPreferredCodecs(offer);
    _requireLive(callId, state);
    await peer.setLocalDescription(offer);
    final RTCSessionDescription? local = await peer.getLocalDescription();
    _emitMediaMessage(callId, state, hold ? 'Hold offer created' : 'Resume offer created');
    return local?.sdp ?? offer.sdp ?? '';
  }

  /// Applies the far end's answer to a [beginHold] offer.
  Future<void> completeHold(String answerSdp) async {
    final String callId = _requireActiveCallId();
    final _PeerCallState state = _requireState(callId);
    await setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
    _callMediaEvents.addIfOpen(HoldChangedEvent(callId: callId, held: state.held));
    _updateProximity();
  }

  /// Undoes a [beginHold] the far end refused: rolls the offer back and puts
  /// the microphone and direction back as they were.
  Future<void> abortHold() async {
    final String? callId = _activeCallId;
    final _PeerCallState? state = _activeState;
    final RTCPeerConnection? peer = state?.peerConnection;
    if (callId == null || state == null || peer == null) return;
    state.held = !state.held;
    _applyTrackEnabled(state);
    try {
      await peer.setLocalDescription(RTCSessionDescription('', 'rollback'));
    } catch (e) {
      _logger.warn('Could not roll back the hold offer for $callId: $e');
    }
    await _setDirection(peer,
        state.held ? TransceiverDirection.SendOnly : TransceiverDirection.SendRecv);
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
  /// The choice is kept with the call: asked before the microphone is open,
  /// it applies when it opens; asked while on hold, it applies on resume.
  Future<void> setMutedForCall(String callId, bool muted) async {
    final _PeerCallState? state = _callStates[callId];
    if (state == null) return;
    final bool changed = state.muted != muted;
    state.muted = muted;
    _applyTrackEnabled(state);

    _emitMediaMessage(
      callId,
      state,
      muted ? 'Microphone muted' : 'Microphone unmuted',
    );
    if (changed) {
      _callMediaEvents.addIfOpen(MuteChangedEvent(callId: callId, muted: muted));
    }
  }

  /// Switches audio output routing for the active call.
  Future<void> enableSpeaker(bool enabled) async {
    await audioRoutes.setSpeakerOn(enabled);
    _emitMediaMessage(
      _activeCallId ?? 'unknown',
      _callStates[_activeCallId],
      enabled ? 'Speaker enabled' : 'Speaker disabled',
    );
  }

  /// Sends [tones] as RFC 4733 telephone-events on the active call. Returns
  /// false, sending nothing, when the far end did not offer
  /// `telephone-event` or there is no audio sender.
  Future<bool> insertDtmf(
    String tones, {
    int durationMs = 100,
    int interToneGapMs = 70,
  }) async {
    final _PeerCallState? state = _activeState;
    final RTCPeerConnection? peer = state?.peerConnection;
    if (state == null || peer == null) return false;
    if (!SdpUtils.hasTelephoneEvent(state.remoteSdp)) return false;
    try {
      final List<RTCRtpSender> senders = await peer.getSenders();
      for (final RTCRtpSender sender in senders) {
        if (sender.track?.kind != 'audio') continue;
        await sender.dtmfSender.insertDTMF(tones,
            duration: durationMs, interToneGap: interToneGapMs);
        return true;
      }
    } catch (e) {
      _logger.warn('RFC 4733 DTMF failed: $e');
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Quality
  // -------------------------------------------------------------------------

  /// Audio quality for the active call, from the peer connection's stats:
  /// round-trip time, jitter and packet loss. Null when there is no call.
  /// Packet loss covers the time since the previous call to this method
  /// (the whole call on the first), so a burst shows up at once. A field is
  /// null when the platform has not measured it yet; nothing is estimated.
  Future<CallStats?> getStats() async {
    final _PeerCallState? state = _activeState;
    final RTCPeerConnection? pc = state?.peerConnection;
    if (state == null || pc == null) return null;

    final List<StatsReport> reports;
    try {
      reports = await pc.getStats();
    } catch (error) {
      _logger.warn('getStats failed: $error');
      return null;
    }
    final CallQualitySample? sample = state.pollAnalyzer.add(reports);
    return CallStats(
      rttMs: sample?.rttMs,
      jitterMs: sample?.jitterMs,
      packetLossPercent: sample?.packetLossPercent,
    );
  }

  /// Takes one quality sample for [callId] and emits a [CallQualityEvent].
  /// Runs every [qualityInterval] once media connects.
  @visibleForTesting
  Future<CallQualitySample?> sampleQuality(String callId) async {
    final _PeerCallState? state = _callStates[callId];
    final RTCPeerConnection? pc = state?.peerConnection;
    if (state == null || pc == null) return null;
    final List<StatsReport> reports;
    try {
      reports = await pc.getStats();
    } catch (error) {
      _logger.warn('getStats failed: $error');
      return null;
    }
    if (!_isLive(callId, state)) return null;
    final CallQualitySample? sample = state.qualityAnalyzer.add(reports);
    if (sample == null) return null;
    final bool changed = state.levelTracker.add(sample.level);
    _callMediaEvents.addIfOpen(
        CallQualityEvent(callId: callId, sample: sample, levelChanged: changed));
    return sample;
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

    if (_activeCallId == callId) {
      _activeCallId = _callStates.isEmpty ? null : _callStates.keys.last;
    }

    await _disposeState(state, callId);
  }

  /// Disposes all tracked call legs.
  Future<void> disposeAllCalls() async {
    final Map<String, _PeerCallState> states =
        Map<String, _PeerCallState>.from(_callStates);
    _callStates.clear();
    _activeCallId = null;
    for (final MapEntry<String, _PeerCallState> entry in states.entries) {
      await _disposeState(entry.value, entry.key);
    }
  }

  /// Closes the media event stream when the service is no longer reused.
  Future<void> dispose() async {
    await disposeAllCalls();
    await _routeSubscription.cancel();
    await audioRoutes.dispose();
    await _iceCandidates.close();
    await _mediaEvents.close();
    await _callMediaEvents.close();
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
      final RegExpMatch? type =
          RegExp(r' typ (\w+)').firstMatch(candidate.candidate ?? '');
      if (type != null) state.candidateTypes.add(type.group(1)!);
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

    connection.onIceGatheringState = (RTCIceGatheringState gathering) {
      if (gathering == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        state.gatheringComplete = true;
      }
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
      onIceConnectionState?.call(callId, iceState);
      if (iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _startQualityMonitor(callId, state);
      }
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

  void _startQualityMonitor(String callId, _PeerCallState state) {
    if (qualityInterval <= Duration.zero || state.qualityTimer != null) return;
    if (!_isLive(callId, state)) return;
    state.qualityTimer = Timer.periodic(qualityInterval, (_) {
      unawaited(sampleQuality(callId));
    });
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

  /// Releases everything a call holds. `close()` alone leaves the native
  /// PeerConnection (and on Android flutter_webrtc's audio switch: call
  /// mode, audio focus, speaker/Bluetooth route) alive until the app dies;
  /// `dispose()` frees it. Each step runs even if an earlier one fails.
  Future<void> _disposeState(_PeerCallState state, String callId) async {
    state.disposed = true;
    state.qualityTimer?.cancel();
    state.qualityTimer = null;
    final bool wasMuted = state.muted;

    final MediaStream? localStream = state.localStream;
    final MediaStream? remoteStream = state.remoteStream;
    final RTCPeerConnection? peerConnection = state.peerConnection;
    state.peerConnection = null;
    state.localStream = null;
    state.remoteStream = null;

    if (localStream != null) await _releaseStream(localStream);
    if (remoteStream != null) await _releaseStream(remoteStream);

    // The last call: put the route back before the audio switch stops, so the
    // next call does not start on the loudspeaker.
    if (_callStates.isEmpty && audioRoutes.currentRoute != AudioRoute.earpiece) {
      await audioRoutes.reset();
    }

    if (peerConnection != null) await _releasePeer(peerConnection);

    state.localAudioAttached = false;
    state.remoteDescriptionApplied = false;
    state.pendingRemoteCandidates.clear();

    _updateProximity();
    if (wasMuted) {
      _callMediaEvents.addIfOpen(MuteChangedEvent(callId: callId, muted: false));
    }
    _mediaEvents.addIfOpen(
      MediaEvent(callId: callId, message: 'Peer resources released'),
    );
  }

  Future<void> _releaseStream(MediaStream stream) async {
    for (final MediaStreamTrack track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (e) {
        _logger.warn('Could not stop a track: $e');
      }
    }
    try {
      await stream.dispose();
    } catch (e) {
      _logger.warn('Could not dispose a stream: $e');
    }
  }

  Future<void> _releasePeer(RTCPeerConnection peer) async {
    try {
      await peer.close();
    } catch (e) {
      _logger.warn('Could not close a peer connection: $e');
    }
    try {
      await peer.dispose();
    } catch (e) {
      _logger.warn('Could not dispose a peer connection: $e');
    }
  }

  void _applyTrackEnabled(_PeerCallState state) {
    final MediaStream? stream = state.localStream;
    if (stream == null) return;
    for (final MediaStreamTrack track in stream.getAudioTracks()) {
      track.enabled = !(state.muted || state.held);
    }
  }

  /// Sets every transceiver's direction. Returns false when the platform
  /// has none to set (the SDP is then edited instead).
  Future<bool> _setDirection(
      RTCPeerConnection peer, TransceiverDirection direction) async {
    try {
      final List<RTCRtpTransceiver> transceivers = await peer.getTransceivers();
      if (transceivers.isEmpty) return false;
      for (final RTCRtpTransceiver t in transceivers) {
        await t.setDirection(direction);
      }
      return true;
    } catch (e) {
      _logger.warn('Could not set the transceiver direction: $e');
      return false;
    }
  }

  RTCSessionDescription _withPreferredCodecs(RTCSessionDescription desc) {
    final List<String> preferred = mediaConstraints.preferredAudioCodecs;
    final String? sdp = desc.sdp;
    if (preferred.isEmpty || sdp == null) return desc;
    return RTCSessionDescription(
        SdpUtils.preferAudioCodecs(sdp, preferred), desc.type);
  }

  /// Proximity on while a call's microphone is live on the earpiece.
  void _updateProximity() {
    final bool want = audioRoutes.currentRoute == AudioRoute.earpiece &&
        _callStates.values.any((_PeerCallState s) =>
            !s.disposed && s.localAudioAttached && !s.held);
    if (want == _proximityEnabled) return;
    _proximityEnabled = want;
    unawaited(_safeProximity(_proximity, want));
  }

  Future<void> _safeProximity(ProximityController controller, bool enabled) async {
    try {
      await controller.setEnabled(enabled);
    } catch (e) {
      _logger.warn('Proximity control failed: $e');
    }
  }

  bool _isLive(String callId, _PeerCallState state) =>
      !state.disposed && identical(_callStates[callId], state);

  void _requireLive(String callId, _PeerCallState state) {
    if (!_isLive(callId, state)) throw PeerCallEndedException(callId);
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
