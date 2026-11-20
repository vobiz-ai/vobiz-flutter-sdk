// Fakes for the flutter_webrtc objects PeerService drives, so media
// behaviour is testable without a device.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/src/audio/audio_route.dart';
import 'package:vobiz_webrtc/src/audio/proximity.dart';
import 'package:vobiz_webrtc/src/webrtc/ice_config.dart';
import 'package:vobiz_webrtc/src/webrtc/media_constraints.dart';
import 'package:vobiz_webrtc/src/webrtc/peer_service.dart';

class FakeTrack extends MediaStreamTrack {
  FakeTrack({this.kindName = 'audio'});

  final String kindName;
  bool _enabled = true;
  bool stopped = false;

  @override
  String? get kind => kindName;
  @override
  String? get id => 'track-$kindName';
  @override
  bool get enabled => _enabled;
  @override
  set enabled(bool b) => _enabled = b;
  @override
  Future<void> stop() async => stopped = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeStream extends MediaStream {
  FakeStream([List<FakeTrack>? tracks])
      : tracks = tracks ?? <FakeTrack>[FakeTrack()],
        super('stream', 'local');

  final List<FakeTrack> tracks;
  bool disposed = false;

  @override
  List<MediaStreamTrack> getTracks() => tracks;
  @override
  List<MediaStreamTrack> getAudioTracks() =>
      tracks.where((t) => t.kind == 'audio').toList();
  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeDtmfSender extends RTCDTMFSender {
  final List<String> sent = <String>[];

  @override
  Future<void> insertDTMF(String tones,
          {int duration = 100, int interToneGap = 70}) async =>
      sent.add(tones);
  @override
  Future<bool> canInsertDtmf() async => true;
}

class FakeSender extends RTCRtpSender {
  FakeSender(this._track);

  final MediaStreamTrack? _track;
  final FakeDtmfSender dtmf = FakeDtmfSender();

  @override
  MediaStreamTrack? get track => _track;
  @override
  RTCDTMFSender get dtmfSender => dtmf;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeTransceiver extends RTCRtpTransceiver {
  TransceiverDirection direction = TransceiverDirection.SendRecv;

  @override
  Future<void> setDirection(TransceiverDirection d) async => direction = d;
  @override
  Future<TransceiverDirection> getDirection() async => direction;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const String audioSdp = 'v=0\r\n'
    'o=- 1 1 IN IP4 0.0.0.0\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 0 8 126\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=rtpmap:0 PCMU/8000\r\n'
    'a=rtpmap:8 PCMA/8000\r\n'
    'a=rtpmap:126 telephone-event/8000\r\n'
    'a=sendrecv\r\n';

class FakePeer extends RTCPeerConnection {
  bool closed = false;
  bool disposed = false;
  final List<RTCSessionDescription> localSet = <RTCSessionDescription>[];
  final List<RTCSessionDescription> remoteSet = <RTCSessionDescription>[];
  final List<MediaStreamTrack> addedTracks = <MediaStreamTrack>[];
  List<FakeTransceiver> transceivers_ = <FakeTransceiver>[FakeTransceiver()];
  List<StatsReport> stats = <StatsReport>[];
  /// Already carries a srflx candidate, as a gathered offer would.
  String offerSdp =
      '${audioSdp}a=candidate:1 1 udp 1 203.0.113.1 4000 typ srflx raddr 0.0.0.0 rport 0\r\n';
  Completer<void>? addTrackGate;
  bool failRemote = false;

  /// Every remote description asked for, applied or not.
  final List<RTCSessionDescription> remoteAttempts = <RTCSessionDescription>[];

  /// Thrown by [createOffer] when set.
  Object? createOfferError;

  /// When set, [getLocalDescription] answers this many more times, then
  /// throws.
  int? localReadsLeft;

  RTCSessionDescription? get local => localSet.isEmpty ? null : localSet.last;

  @override
  Future<void> close() async => closed = true;
  @override
  Future<void> dispose() async => disposed = true;
  @override
  Future<RTCSessionDescription> createOffer(
      [Map<String, dynamic>? constraints]) async {
    final error = createOfferError;
    if (error != null) throw error;
    final direction = transceivers_.isEmpty
        ? 'sendrecv'
        : <TransceiverDirection, String>{
            TransceiverDirection.SendRecv: 'sendrecv',
            TransceiverDirection.SendOnly: 'sendonly',
            TransceiverDirection.RecvOnly: 'recvonly',
            TransceiverDirection.Inactive: 'inactive',
          }[transceivers_.first.direction]!;
    return RTCSessionDescription(
        offerSdp.replaceFirst('a=sendrecv', 'a=$direction'), 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer(
          [Map<String, dynamic>? constraints]) async =>
      RTCSessionDescription(offerSdp, 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async =>
      localSet.add(description);
  @override
  Future<RTCSessionDescription?> getLocalDescription() async {
    final left = localReadsLeft;
    if (left != null) {
      if (left <= 0) throw Exception('getLocalDescription failed');
      localReadsLeft = left - 1;
    }
    return local;
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteAttempts.add(description);
    if (failRemote) throw Exception('setRemoteDescription failed');
    remoteSet.add(description);
  }

  @override
  Future<RTCRtpSender> addTrack(MediaStreamTrack track,
      [MediaStream? stream]) async {
    addedTracks.add(track);
    await addTrackGate?.future;
    return FakeSender(track);
  }

  @override
  Future<List<RTCRtpSender>> getSenders() async =>
      <RTCRtpSender>[for (final t in addedTracks) FakeSender(t)];
  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => transceivers_;
  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => stats;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeAudioBackend implements AudioDeviceBackend {
  List<MediaDeviceInfo> outputs = <MediaDeviceInfo>[
    MediaDeviceInfo(label: 'Earpiece', deviceId: 'earpiece', kind: 'audiooutput'),
    MediaDeviceInfo(label: 'Speakerphone', deviceId: 'speaker', kind: 'audiooutput'),
  ];
  final List<String> calls = <String>[];
  void Function()? onChange;

  /// What the platform would play on: true = loudspeaker preferred.
  bool speakerPreferred = false;

  @override
  Future<List<MediaDeviceInfo>> audioOutputs() async => outputs;
  @override
  Future<void> selectAudioOutput(String deviceId) async =>
      calls.add('select:$deviceId');
  @override
  Future<void> setSpeakerphoneOn(bool enabled) async {
    speakerPreferred = enabled;
    calls.add('speaker:$enabled');
  }

  @override
  void Function() listenForDeviceChanges(void Function() onChange) {
    this.onChange = onChange;
    return () {
      if (identical(this.onChange, onChange)) this.onChange = null;
    };
  }
}

class FakeProximity extends ProximityController {
  final List<bool> calls = <bool>[];
  bool get enabled => calls.isNotEmpty && calls.last;

  @override
  Future<void> setEnabled(bool enabled) async => calls.add(enabled);
}

/// A PeerService wired to fakes. [peers] records every peer it created and
/// [streams] every microphone stream it opened.
class MediaHarness {
  MediaHarness({
    IceConfig iceConfig = const IceConfig(),
    MediaConstraints mediaConstraints = const MediaConstraints(),
    this.gumGate,
  }) {
    service = PeerService(
      iceConfig: iceConfig,
      mediaConstraints: mediaConstraints,
      audioRoutes: AudioRouteController(backend: backend),
      proximity: proximity,
      qualityInterval: Duration.zero,
      peerConnectionFactory: (config, constraints) async {
        configs.add(config);
        final peer = FakePeer();
        peers.add(peer);
        await peerGate?.future;
        return peer;
      },
      userMediaFactory: (constraints) async {
        final stream = FakeStream();
        streams.add(stream);
        await gumGate?.future;
        return stream;
      },
    );
  }

  late final PeerService service;
  final FakeAudioBackend backend = FakeAudioBackend();
  final FakeProximity proximity = FakeProximity();
  final List<FakePeer> peers = <FakePeer>[];
  final List<FakeStream> streams = <FakeStream>[];
  final List<Map<String, dynamic>> configs = <Map<String, dynamic>>[];
  Completer<void>? gumGate;
  Completer<void>? peerGate;

  FakePeer get peer => peers.last;
  FakeStream get stream => streams.last;
}

StatsReport inboundAudio({
  required num lost,
  required num received,
  num jitter = 0.01,
  String codecId = 'c1',
}) =>
    StatsReport('in', 'inbound-rtp', 0, <dynamic, dynamic>{
      'kind': 'audio',
      'packetsLost': lost,
      'packetsReceived': received,
      'jitter': jitter,
      'codecId': codecId,
    });

StatsReport candidatePair(num rttSeconds) =>
    StatsReport('cp', 'candidate-pair', 0, <dynamic, dynamic>{
      'nominated': true,
      'currentRoundTripTime': rttSeconds,
    });

StatsReport codec(String id, String mime) =>
    StatsReport(id, 'codec', 0, <dynamic, dynamic>{'mimeType': mime});
