// VobizClient wiring of the media fixes: mute across hold (#43), real hold
// (#30), early media (#23), RFC 4733 DTMF (#30), hangup during setup (#28),
// interruptions (#17).
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'media_fakes.dart';
import 'sip_test_support.dart' show respond;

String _inboundInvite(String body) =>
    'INVITE sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKa\r\n'
    'From: <sip:+918000000000@10.0.2.9>;tag=ms\r\n'
    'To: <sip:play1@registrar.vobiz.ai>\r\n'
    'Call-ID: in-1\r\nCSeq: 101 INVITE\r\n'
    'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
    'Content-Type: application/sdp\r\n'
    'Content-Length: ${utf8.encode(body).length}\r\n\r\n$body';

class _Rig {
  _Rig() {
    sip = SIPService(wsUrl: 'wss://t', sipServer: 'registrar.vobiz.ai')
      ..debugOnSend = sent.add;
    client = VobizClient.withServices(
      sip: sip,
      peer: media.service,
    );
    client.errorEvents.listen(errors.add);
    sip.register('play1', 'secret');
  }

  final List<String> sent = <String>[];
  final MediaHarness media = MediaHarness();
  final List<ErrorEvent> errors = <ErrorEvent>[];
  late final SIPService sip;
  late final VobizClient client;

  Iterable<String> get methods => sent.map((m) => m.split(' ').first);

  /// A 200 OK to [request], echoing its Via, Call-ID and CSeq so the SIP
  /// transaction layer matches it.
  String okFor(String request, {String extra = ''}) {
    final lines = request.split('\r\n');
    String h(String name) => lines.firstWhere((l) => l.startsWith('$name:'));
    return <String>[
      'SIP/2.0 200 OK',
      h('Via'),
      h('From'),
      '${h('To')};tag=srv',
      h('Call-ID'),
      h('CSeq'),
      if (extra.isNotEmpty) extra,
      'Content-Length: 0',
      '',
      '',
    ].join('\r\n');
  }

  void registered() => sip.debugReceive(okFor(
      sent.lastWhere((m) => m.startsWith('REGISTER')),
      extra: 'Expires: 600'));

  /// An answered inbound call.
  Future<void> connectedCall() async {
    sip.debugReceive(_inboundInvite(audioSdp));
    await client.acceptCall();
    expect(client.callState, CallStateStatus.active);
    sent.clear();
  }

  /// Answers the last re-INVITE with [code].
  void answerReInvite(int code, {String body = ''}) {
    final reinvite = sent.lastWhere((m) => m.startsWith('INVITE'));
    sip.debugReceive(respond(reinvite, code, code == 200 ? 'OK' : 'Refused', body: body));
  }

  Future<void> dispose() async {
    sip.disconnect();
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  group('#30 hold is a real re-INVITE', () {
    test('hold sends a=sendonly, resume a=sendrecv', () async {
      final rig = _Rig();
      await rig.connectedCall();

      final holding = rig.client.hold();
      await _settle();
      final reinvite = rig.sent.lastWhere((m) => m.startsWith('INVITE'));
      expect(reinvite, contains('a=sendonly'));
      expect(rig.media.stream.tracks.single.enabled, isFalse);
      rig.answerReInvite(200, body: audioSdp.replaceFirst('a=sendrecv', 'a=recvonly'));
      await holding;
      expect(rig.client.callState, CallStateStatus.held);
      expect(rig.methods, contains('ACK'));

      final resuming = rig.client.resume();
      await _settle();
      expect(rig.sent.lastWhere((m) => m.startsWith('INVITE')), contains('a=sendrecv'));
      rig.answerReInvite(200, body: audioSdp);
      await resuming;
      expect(rig.client.callState, CallStateStatus.active);
      expect(rig.media.stream.tracks.single.enabled, isTrue);
      await rig.dispose();
    });

    test('a refused hold throws and leaves the call as it was', () async {
      final rig = _Rig();
      await rig.connectedCall();
      final holding = rig.client.hold();
      await _settle();
      rig.answerReInvite(488);
      await expectLater(holding,
          throwsA(isA<VobizException>().having((e) => e.code, 'code', 'hold_failed')));
      expect(rig.client.callState, CallStateStatus.active);
      expect(rig.media.stream.tracks.single.enabled, isTrue);
      await _settle();
      expect(rig.errors.map((e) => e.code), contains('hold_failed'));
      await rig.dispose();
    });

    test('hold without a connected call is an error, not a silent no-op', () async {
      final rig = _Rig();
      expect(() => rig.client.hold(), throwsStateError);
      expect(() => rig.client.resume(), throwsStateError);
      await rig.dispose();
    });
  });

  group('#43 mute', () {
    test('resume keeps a mute the user chose before hold', () async {
      final rig = _Rig();
      await rig.connectedCall();
      await rig.client.mute();
      final holding = rig.client.hold();
      await _settle();
      rig.answerReInvite(200, body: audioSdp);
      await holding;
      final resuming = rig.client.resume();
      await _settle();
      rig.answerReInvite(200, body: audioSdp);
      await resuming;
      expect(rig.client.isMuted, isTrue, reason: 'resume() used to unmute');
      expect(rig.media.stream.tracks.single.enabled, isFalse);
      await rig.dispose();
    });

    test('isMuted is the media state, not a separate flag', () async {
      final rig = _Rig();
      await rig.client.mute(); // no call: nothing to mute
      expect(rig.client.isMuted, isFalse,
          reason: 'used to report muted with no microphone to mute');
      await rig.connectedCall();
      expect(rig.client.isMuted, isFalse);
      await rig.client.mute();
      expect(rig.client.isMuted, isTrue);
      await rig.client.hangup();
      expect(rig.client.isMuted, isFalse);
      await rig.dispose();
    });
  });

  group('#30 DTMF', () {
    test('RFC 4733 when telephone-event was negotiated: no INFO', () async {
      final rig = _Rig();
      await rig.connectedCall();
      await rig.client.sendDtmf('123');
      expect(rig.methods, isNot(contains('INFO')));
      expect(rig.media.peer.fakeSenders.single.dtmf.sent, <String>['123/100/70']);
      await rig.dispose();
    });

    test('SIP INFO when asked for, or when telephone-event is missing', () async {
      final rig = _Rig();
      rig.sip.debugReceive(_inboundInvite(
          audioSdp.replaceFirst('a=rtpmap:126 telephone-event/8000\r\n', '')));
      await rig.client.acceptCall();
      rig.sent.clear();
      await rig.client.sendDtmf('1');
      expect(rig.methods, contains('INFO'));
      // Tones go one INFO at a time: answer this one so the next is sent.
      rig.sip.debugReceive(rig.okFor(rig.sent.lastWhere((m) => m.startsWith('INFO'))));
      rig.sent.clear();
      await rig.client.sendDtmf('2', transport: DtmfTransport.sipInfo);
      expect(rig.methods, contains('INFO'));
      expect(() => rig.client.sendDtmf('3', transport: DtmfTransport.rfc4733),
          throwsStateError);
      await rig.dispose();
    });
  });

  group('#23 early media through the client', () {
    test('183 SDP plays; a 200 without SDP confirms it', () async {
      final rig = _Rig();
      final early = <EarlyMediaEvent>[];
      rig.client.callMediaEvents.listen((e) {
        if (e is EarlyMediaEvent) early.add(e);
      });
      rig.registered();
      expect(rig.client.isConnected, isTrue);
      await rig.client.makeCall('+919876543210');
      final invite = rig.sent.lastWhere((m) => m.startsWith('INVITE'));
      rig.sip.debugReceive(respond(invite, 183, 'Session Progress', body: audioSdp));
      await _settle();
      expect(rig.media.peer.remoteSet.single.type, 'pranswer');
      expect(early, hasLength(1));
      rig.sip.debugReceive(respond(invite, 200, 'OK'));
      await _settle();
      expect(rig.media.peer.remoteSet.last.type, 'answer');
      expect(rig.media.peer.remoteSet.last.sdp, audioSdp);
      expect(rig.client.callState, CallStateStatus.active);
      expect(rig.errors, isEmpty);
      await rig.dispose();
    });
  });

  group('#28 hangup during call setup', () {
    test('releases the late microphone and is not reported as a failure', () async {
      final rig = _Rig();
      rig.registered();
      rig.media.gumGate = Completer<void>();
      final placing = rig.client.makeCall('+919876543210');
      await _settle();
      await rig.client.hangup();
      rig.media.gumGate!.complete();
      final id = await placing;
      expect(id, isNotEmpty);
      expect(rig.media.stream.tracks.single.stopped, isTrue);
      expect(rig.media.peer.disposed, isTrue);
      expect(rig.methods, isNot(contains('INVITE')));
      expect(rig.errors, isEmpty);
      await rig.dispose();
    });
  });

  group('#17 interruptions', () {
    test('another app taking the mic holds the call; its end resumes it', () async {
      final rig = _Rig();
      await rig.connectedCall();
      final began = rig.client.audioInterruptionBegan();
      await _settle();
      rig.answerReInvite(200, body: audioSdp);
      await began;
      expect(rig.client.callState, CallStateStatus.held);
      final ended = rig.client.audioInterruptionEnded();
      await _settle();
      rig.answerReInvite(200, body: audioSdp);
      await ended;
      expect(rig.client.callState, CallStateStatus.active);
      await rig.dispose();
    });
  });

  group('#42 speaker state', () {
    test('a new call starts off the loudspeaker', () async {
      final rig = _Rig();
      await rig.connectedCall();
      await rig.client.setSpeakerphone(true);
      expect(rig.client.isSpeakerOn, isTrue);
      await rig.client.hangup();
      expect(rig.client.isSpeakerOn, isFalse);
      expect(rig.media.backend.speakerPreferred, isFalse);
      await rig.dispose();
    });
  });

  group('far-end session change', () {
    test('a re-INVITE with a new offer is answered from the PeerConnection', () async {
      final rig = _Rig();
      await rig.connectedCall();
      final held = audioSdp
          .replaceFirst('o=- 1 1', 'o=- 1 2')
          .replaceFirst('a=sendrecv', 'a=sendonly');
      rig.sip.debugReceive(_inboundInvite(held)
          .replaceFirst('CSeq: 101', 'CSeq: 102')
          .replaceFirst('z9hG4bKa', 'z9hG4bKb')
          .replaceFirst('To: <sip:play1@registrar.vobiz.ai>',
              'To: <sip:play1@registrar.vobiz.ai>;tag=x'));
      await _settle();
      expect(rig.media.peer.remoteSet.last.sdp!.trim(), held.trim());
      expect(rig.media.peer.remoteSet.last.type, 'offer');
      final reply = rig.sent.lastWhere((m) => m.startsWith('SIP/2.0'));
      expect(reply.split('\r\n').first, 'SIP/2.0 200 OK');
      expect(reply, contains('m=audio'));
      await rig.dispose();
    });
  });
}
