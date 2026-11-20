// Early media (#23), hold and DTMF (#30), ICE wait and codecs (#20).
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/src/media/call_media_event.dart';
import 'package:vobiz_webrtc/src/media/sdp_utils.dart';
import 'package:vobiz_webrtc/src/webrtc/ice_config.dart';
import 'package:vobiz_webrtc/src/webrtc/media_constraints.dart';

import 'media_fakes.dart';

void main() {
  group('#23 early media', () {
    test('a 183 SDP is applied as a provisional answer and reported', () async {
      final h = MediaHarness();
      final events = <CallMediaEvent>[];
      h.service.callMediaEvents.listen(events.add);
      await h.service.initialize('c1');
      await h.service.createOffer();
      expect(await h.service.applyProvisionalAnswer(audioSdp), isTrue);
      expect(h.peer.remoteSet.single.type, 'pranswer');
      expect(h.service.hasEarlyMedia, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<EarlyMediaEvent>(), hasLength(1));
    });

    test('the 200 OK SDP replaces it as the final answer', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.applyProvisionalAnswer(audioSdp);
      final finalSdp = audioSdp.replaceFirst('111 0 8', '0 8');
      await h.service.applyRemoteAnswer(finalSdp);
      expect(h.peer.remoteSet.last.type, 'answer');
      expect(h.peer.remoteSet.last.sdp, finalSdp);
    });

    test('a 200 OK without SDP confirms the 183 SDP', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.applyProvisionalAnswer(audioSdp);
      await h.service.applyRemoteAnswer('');
      expect(h.peer.remoteSet.last.type, 'answer');
      expect(h.peer.remoteSet.last.sdp, audioSdp);
    });

    test('an unusable 183 SDP leaves the call alone', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      h.peer.failRemote = true;
      expect(await h.service.applyProvisionalAnswer(audioSdp), isFalse);
      expect(h.service.hasEarlyMedia, isFalse);
    });
  });

  group('#30 real hold', () {
    test('hold renegotiates sendonly and silences the mic', () async {
      final h = MediaHarness();
      final events = <HoldChangedEvent>[];
      h.service.callMediaEvents.listen((e) {
        if (e is HoldChangedEvent) events.add(e);
      });
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.applyRemoteAnswer(audioSdp);
      final offer = await h.service.beginHold(true);
      expect(SdpUtils.audioDirection(offer), 'sendonly');
      expect(h.peer.transceivers_.single.direction, TransceiverDirection.SendOnly);
      expect(h.stream.tracks.single.enabled, isFalse);
      await h.service.completeHold(audioSdp.replaceFirst('a=sendrecv', 'a=recvonly'));
      expect(h.service.isHeld, isTrue);

      final resume = await h.service.beginHold(false);
      expect(SdpUtils.audioDirection(resume), 'sendrecv');
      await h.service.completeHold(audioSdp);
      expect(h.service.isHeld, isFalse);
      expect(h.stream.tracks.single.enabled, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e.held), <bool>[true, false]);
    });

    test('without transceivers the SDP direction is edited', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      h.peer.transceivers_ = <FakeTransceiver>[];
      final offer = await h.service.beginHold(true);
      expect(SdpUtils.audioDirection(offer), 'sendonly');
    });

    test('a refused hold rolls back and restores the mic', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.applyRemoteAnswer(audioSdp);
      await h.service.beginHold(true);
      await h.service.abortHold();
      expect(h.service.isHeld, isFalse);
      expect(h.stream.tracks.single.enabled, isTrue);
      expect(h.peer.localSet.last.type, 'rollback');
      expect(h.peer.transceivers_.single.direction, TransceiverDirection.SendRecv);
    });
  });

  group('#30 RFC 4733 DTMF', () {
    test('uses RTCDTMFSender when telephone-event was negotiated', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.applyRemoteAnswer(audioSdp);
      expect(await h.service.insertDtmf('12#'), isTrue);
    });

    test('declines (for the INFO fallback) when it was not', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.applyRemoteAnswer(
          audioSdp.replaceAll(RegExp(r'a=rtpmap:126 telephone-event/8000\r\n'), ''));
      expect(await h.service.insertDtmf('1'), isFalse);
    });

    test('declines with no call', () async {
      final h = MediaHarness();
      expect(await h.service.insertDtmf('1'), isFalse);
    });
  });

  group('#20 ICE gathering wait', () {
    Future<Duration> timeWait(MediaHarness h, List<String> candidates) async {
      await h.service.initialize('c1');
      await h.service.createOffer();
      for (final c in candidates) {
        h.peer.onIceCandidate?.call(RTCIceCandidate(c, '0', 0));
      }
      final sw = Stopwatch()..start();
      await h.service.waitForIceGathering('c1',
          timeout: const Duration(milliseconds: 300),
          pollInterval: const Duration(milliseconds: 10));
      return sw.elapsed;
    }

    const srflx = 'candidate:2 1 udp 1 203.0.113.1 4000 typ srflx raddr 0.0.0.0';
    const relay = 'candidate:3 1 udp 1 198.51.100.1 5000 typ relay raddr 0.0.0.0';

    test('STUN only: returns at the first srflx candidate', () async {
      final elapsed = await timeWait(MediaHarness(), <String>[srflx]);
      expect(elapsed, lessThan(const Duration(milliseconds: 200)));
    });

    test('TURN configured: a srflx candidate does not cut the relay out', () async {
      final h = MediaHarness(
          iceConfig: const IceConfig(servers: <IceServerConfig>[
        IceServerConfig(urls: <String>['turns:turn.example.com:443?transport=tcp'],
            username: 'u', credential: 'p'),
      ]));
      final elapsed = await timeWait(h, <String>[srflx]);
      expect(elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 300)),
          reason: 'returned before any relay candidate');
    });

    test('TURN configured: returns once the relay candidate arrives', () async {
      final h = MediaHarness(
          iceConfig: const IceConfig(servers: <IceServerConfig>[
        IceServerConfig(urls: <String>['turn:turn.example.com:3478']),
      ]));
      final elapsed = await timeWait(h, <String>[srflx, relay]);
      expect(elapsed, lessThan(const Duration(milliseconds: 200)));
    });

    test('gathering complete ends the wait', () async {
      final h = MediaHarness(
          iceConfig: const IceConfig(servers: <IceServerConfig>[
        IceServerConfig(urls: <String>['turn:turn.example.com:3478']),
      ]));
      await h.service.initialize('c1');
      h.peer.onIceGatheringState
          ?.call(RTCIceGatheringState.RTCIceGatheringStateComplete);
      final sw = Stopwatch()..start();
      await h.service.waitForIceGathering('c1',
          timeout: const Duration(milliseconds: 300),
          pollInterval: const Duration(milliseconds: 10));
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)));
    });

    test('iceTransportPolicy relay reaches the PeerConnection config', () async {
      final h = MediaHarness(
          iceConfig: const IceConfig(iceTransportPolicy: IceTransportPolicy.relay));
      await h.service.initialize('c1');
      expect(h.configs.single['iceTransportPolicy'], 'relay');
      expect(const IceConfig().toRtcConfiguration().containsKey('iceTransportPolicy'),
          isFalse);
    });
  });

  group('#20 codec preference', () {
    test('preferred codecs move to the front of the audio m-line', () {
      final sdp = SdpUtils.preferAudioCodecs(audioSdp, <String>['PCMA', 'opus']);
      expect(sdp, contains('m=audio 9 UDP/TLS/RTP/SAVPF 8 111 0 126\r\n'));
      expect(SdpUtils.preferAudioCodecs(audioSdp, <String>['G729']), audioSdp);
    });

    test('the offer the SDK sets and sends carries the preference', () async {
      final h = MediaHarness(
          mediaConstraints: const MediaConstraints(preferredAudioCodecs: <String>['PCMU']));
      await h.service.initialize('c1');
      final offer = await h.service.createOffer();
      expect(offer.sdp, contains('SAVPF 0 111 8 126'));
      expect(h.peer.local!.sdp, offer.sdp);
    });
  });

  group('SdpUtils', () {
    test('direction is read from the audio section', () {
      expect(SdpUtils.audioDirection(audioSdp), 'sendrecv');
      expect(SdpUtils.audioDirection(audioSdp.replaceFirst('a=sendrecv\r\n', '')),
          'sendrecv');
      expect(
          SdpUtils.audioDirection(
              SdpUtils.setAudioDirection(audioSdp.replaceFirst('a=sendrecv\r\n', ''), 'inactive')),
          'inactive');
    });
    test('telephone-event detection', () {
      expect(SdpUtils.hasTelephoneEvent(audioSdp), isTrue);
      expect(SdpUtils.hasTelephoneEvent('m=audio 9 RTP/AVP 0\r\n'), isFalse);
      expect(SdpUtils.hasTelephoneEvent(null), isFalse);
    });
  });
}
