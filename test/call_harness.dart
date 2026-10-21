// Shared harness for the call-lifecycle tests: a VobizClient driven by a real
// SIPService (messages captured, responses injected) and a fake PeerService,
// so no socket, microphone or WebRTC engine is touched.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/src/webrtc/peer_service.dart';

const sipServer = 'registrar.vobiz.ai';

class FakePeerConnection extends Fake implements RTCPeerConnection {
  FakePeerConnection(this.peer);
  final FakePeer peer;

  @override
  Future<RTCIceGatheringState?> getIceGatheringState() async =>
      RTCIceGatheringState.RTCIceGatheringStateComplete;

  @override
  Future<RTCSessionDescription?> getLocalDescription() {
    final gate = peer.localDescriptionGate;
    if (gate != null) return gate.future;
    return Future<RTCSessionDescription?>.value(
        RTCSessionDescription('v=0\r\nlocal', 'answer'));
  }
}

/// Stands in for the WebRTC engine. Set the error fields to make a step fail.
class FakePeer extends PeerService {
  FakePeer()
      : super(
          iceConfig: const IceConfig(),
          mediaConstraints: const MediaConstraints(),
        );

  Object? initializeError;
  Object? remoteDescriptionError;
  Completer<RTCSessionDescription?>? localDescriptionGate;
  FakePeerConnection? _pc;
  final List<RTCSessionDescription> remoteDescriptions = <RTCSessionDescription>[];

  @override
  RTCPeerConnection? get peerConnection => _pc;

  @override
  Future<void> initialize(String callId) async {
    final error = initializeError;
    if (error != null) throw error;
    _pc = FakePeerConnection(this);
  }

  @override
  Future<RTCSessionDescription> createOffer() async =>
      RTCSessionDescription('v=0\r\noffer', 'offer');

  @override
  Future<RTCSessionDescription> createAnswer() async =>
      RTCSessionDescription('v=0\r\nanswer', 'answer');

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteDescriptions.add(description);
    final error = remoteDescriptionError;
    if (error != null) throw error;
  }

  @override
  Future<void> disposeCall(String callId) async => _pc = null;

  @override
  Future<void> disposeAllCalls() async => _pc = null;

  @override
  Future<void> dispose() async => _pc = null;

  /// What the WebRTC engine would report for the call's ICE connection.
  void ice(String callId, RTCIceConnectionState state) =>
      onIceConnectionState?.call(callId, state);
}

/// A registered client with everything it sends captured in [sent].
class Harness {
  Harness({
    Duration setupTimeout = const Duration(seconds: 30),
    Duration networkLossGrace = const Duration(seconds: 12),
  }) {
    sip = SIPService(wsUrl: 'wss://example.invalid', sipServer: sipServer)
      ..debugOnSend = sent.add;
    client = VobizClient.withServices(
      sip: sip,
      peer: peer,
      setupTimeout: setupTimeout,
      networkLossGrace: networkLossGrace,
    );
    client.callEvents.listen(events.add);
    client.errorEvents.listen(errors.add);
    client.connectionEvents.listen(connection.add);
    sip.register('play1', 'secret');
    registered();
    sent.clear();
  }

  late final SIPService sip;
  late final VobizClient client;
  final FakePeer peer = FakePeer();
  final List<String> sent = <String>[];
  final List<CallEvent> events = <CallEvent>[];
  final List<ErrorEvent> errors = <ErrorEvent>[];
  final List<ConnectionEvent> connection = <ConnectionEvent>[];

  /// The registrar's 200 OK to REGISTER.
  void registered() => sip.debugReceive('SIP/2.0 200 OK\r\n'
      'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKr\r\n'
      'From: <sip:play1@$sipServer>;tag=t\r\nTo: <sip:play1@$sipServer>;tag=r\r\n'
      'Call-ID: reg\r\nCSeq: 1 REGISTER\r\nContent-Length: 0\r\n\r\n');

  /// First lines of what was sent ("SIP/2.0 486 Busy Here", "BYE sip:...").
  List<String> get firstLines =>
      sent.map((m) => m.split('\r\n').first).toList();

  bool sentRequest(String method) =>
      firstLines.any((l) => l.startsWith('$method '));

  bool sentStatus(int code) =>
      firstLines.any((l) => l.startsWith('SIP/2.0 $code '));

  CallEvent get lastEnded =>
      events.lastWhere((e) => e.state == CallStateStatus.ended);

  Future<void> settle([int ms = 0]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  // ── Inbound ────────────────────────────────────────────────────────────

  void invite(String callId, {String sdp = 'v=0', String branch = 'z9hG4bKa'}) =>
      sip.debugReceive('INVITE sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
          'Via: SIP/2.0/WSS 10.0.1.5:443;branch=$branch\r\n'
          'From: <sip:+918000000000@10.0.2.9>;tag=ms\r\n'
          'To: <sip:play1@$sipServer>\r\n'
          'Call-ID: $callId\r\nCSeq: 101 INVITE\r\n'
          'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
          '${sdp.isEmpty ? '' : 'Content-Type: application/sdp\r\n'}'
          'Content-Length: ${sdp.length}\r\n\r\n$sdp');

  void cancel(String callId) =>
      sip.debugReceive('CANCEL sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
          'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKa\r\n'
          'From: <sip:+918000000000@10.0.2.9>;tag=ms\r\n'
          'To: <sip:play1@$sipServer>\r\n'
          'Call-ID: $callId\r\nCSeq: 101 CANCEL\r\nContent-Length: 0\r\n\r\n');

  // ── Outbound ───────────────────────────────────────────────────────────

  /// The Call-ID of the INVITE this client sent.
  String get outboundCallId {
    final invite = sent.lastWhere((m) => m.startsWith('INVITE '));
    return SipParser.parse(invite).header('Call-ID')!;
  }

  void respond(int code, String phrase, {String body = ''}) {
    final invite =
        SipParser.parse(sent.lastWhere((m) => m.startsWith('INVITE ')));
    sip.debugReceive('SIP/2.0 $code $phrase\r\n'
        'Via: ${invite.header('Via')}\r\n'
        'From: ${invite.header('From')}\r\n'
        'To: ${invite.header('To')}${code > 100 ? ';tag=far' : ''}\r\n'
        'Call-ID: ${invite.header('Call-ID')}\r\n'
        'CSeq: ${invite.header('CSeq')}\r\n'
        'Contact: <sip:far@10.0.2.9:5060>\r\n'
        '${body.isEmpty ? '' : 'Content-Type: application/sdp\r\n'}'
        'Content-Length: ${body.length}\r\n\r\n$body');
  }

  /// Places an outbound call and waits until its INVITE is on the wire.
  Future<String> dial([String to = '+919876543210']) async {
    final id = await client.makeCall(to);
    return id;
  }

  Future<void> dispose() => client.dispose();
}

/// An inbound call, answered: the client is active and the 200 OK is sent.
Future<Harness> answeredCall({Duration grace = const Duration(seconds: 12)}) async {
  final h = Harness(networkLossGrace: grace);
  h.invite('in-1');
  await h.client.acceptCall();
  expect(h.client.callState, CallStateStatus.active);
  expect(h.sentStatus(200), isTrue);
  h.sent.clear();
  return h;
}
