// Media lifecycle: native disposal (#28), audio session release (#37),
// speaker reset between calls (#42), mute (#43), proximity (#44).
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/audio/audio_route.dart';
import 'package:vobiz_webrtc/src/media/call_media_event.dart';
import 'package:vobiz_webrtc/src/webrtc/peer_service.dart';

import 'media_fakes.dart';

void main() {
  group('#28/#37 native resources are released', () {
    test('ending a call closes AND disposes the native PeerConnection', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.disposeCall('c1');
      expect(h.peer.closed, isTrue);
      expect(h.peer.disposed, isTrue,
          reason: 'close() alone leaks the native PC and keeps the audio '
              'switch (call mode, focus, route) active');
      expect(h.stream.tracks.single.stopped, isTrue);
      expect(h.stream.disposed, isTrue);
    });

    test('disposeAllCalls and dispose() release every leg', () async {
      final h = MediaHarness();
      await h.service.initialize('a');
      await h.service.initialize('b');
      await h.service.disposeAllCalls();
      expect(h.peers.every((p) => p.closed && p.disposed), isTrue);
      expect(h.service.callCount, 0);
    });

    test('150 call cycles leave nothing behind', () async {
      final h = MediaHarness();
      for (var i = 0; i < 150; i++) {
        await h.service.initialize('c$i');
        await h.service.createOffer();
        await h.service.disposeCall('c$i');
      }
      expect(h.peers, hasLength(150));
      expect(h.peers.where((p) => !p.disposed), isEmpty);
      expect(h.streams.where((s) => !s.disposed), isEmpty);
      expect(h.service.callCount, 0);
    });

    test('hangup while getUserMedia is pending stops the late microphone', () async {
      final h = MediaHarness(gumGate: Completer<void>());
      await h.service.createPeerConnection('c1');
      final attaching = h.service.attachLocalAudioStream('c1');
      await Future<void>.delayed(Duration.zero);
      await h.service.disposeCall('c1'); // hung up meanwhile
      h.gumGate!.complete();
      await expectLater(attaching, throwsA(isA<PeerCallEndedException>()));
      expect(h.stream.tracks.single.stopped, isTrue,
          reason: 'the mic indicator would stay on');
      expect(h.stream.disposed, isTrue);
      expect(h.peer.addedTracks, isEmpty);
    });

    test('hangup while the PeerConnection is being created disposes it', () async {
      final h = MediaHarness()..peerGate = Completer<void>();
      final creating = h.service.createPeerConnection('c1');
      await Future<void>.delayed(Duration.zero);
      await h.service.disposeCall('c1');
      h.peerGate!.complete();
      await expectLater(creating, throwsA(isA<PeerCallEndedException>()));
      expect(h.peer.closed && h.peer.disposed, isTrue);
      expect(h.service.peerConnection, isNull);
    });

    test('hangup while a track is being added releases the stream', () async {
      final h = MediaHarness();
      await h.service.createPeerConnection('c1');
      h.peer.addTrackGate = Completer<void>();
      final attaching = h.service.attachLocalAudioStream('c1');
      await Future<void>.delayed(Duration.zero);
      await h.service.disposeCall('c1');
      h.peer.addTrackGate!.complete();
      await expectLater(attaching, throwsA(isA<PeerCallEndedException>()));
      expect(h.stream.tracks.single.stopped, isTrue);
      expect(h.stream.disposed, isTrue);
    });
  });

  group('#42 speaker does not leak into the next call', () {
    test('the route is reset to earpiece when the last call ends', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.enableSpeaker(true);
      expect(h.service.audioRoutes.currentRoute, AudioRoute.speaker);
      await h.service.disposeCall('c1');
      expect(h.backend.speakerPreferred, isFalse,
          reason: 'the plugin keeps preferring the speaker otherwise');
      expect(h.service.audioRoutes.currentRoute, AudioRoute.earpiece);
      // The reset happens before the PC is disposed: on Android the audio
      // switch stops with the last connection.
      expect(h.log, containsAllInOrder(<String>['speaker:false', 'peer:dispose']));
      expect(h.log.lastIndexOf('speaker:false'), lessThan(h.log.indexOf('peer:dispose')));
    });

    test('a route change is reported as an event', () async {
      final h = MediaHarness();
      final events = <CallMediaEvent>[];
      h.service.callMediaEvents.listen(events.add);
      await h.service.initialize('c1');
      await h.service.enableSpeaker(true);
      await h.service.disposeCall('c1');
      await Future<void>.delayed(Duration.zero);
      final routes = events.whereType<AudioRouteChangedEvent>().map((e) => e.route);
      expect(routes, <AudioRoute>[AudioRoute.speaker, AudioRoute.earpiece]);
    });

    test('ending one leg while another is live keeps the speaker', () async {
      final h = MediaHarness();
      await h.service.initialize('a');
      await h.service.initialize('b');
      await h.service.enableSpeaker(true);
      await h.service.disposeCall('b');
      expect(h.service.audioRoutes.currentRoute, AudioRoute.speaker);
    });
  });

  group('#43 mute has one source of truth', () {
    test('mute before the microphone opens applies when it opens', () async {
      final h = MediaHarness();
      await h.service.createPeerConnection('c1');
      await h.service.setMuted(true);
      expect(h.service.isMuted, isTrue);
      await h.service.attachLocalAudioStream('c1');
      expect(h.stream.tracks.single.enabled, isFalse,
          reason: 'reported muted but the mic was live');
    });

    test('resume after hold keeps the user muted', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.setMuted(true);
      await h.service.beginHold(true);
      await h.service.completeHold(audioSdp.replaceFirst('a=sendrecv', 'a=recvonly'));
      await h.service.beginHold(false);
      await h.service.completeHold(audioSdp);
      expect(h.service.isMuted, isTrue);
      expect(h.stream.tracks.single.enabled, isFalse);
    });

    test('mute changes are events; a new call starts unmuted', () async {
      final h = MediaHarness();
      final events = <MuteChangedEvent>[];
      h.service.callMediaEvents.listen((e) {
        if (e is MuteChangedEvent) events.add(e);
      });
      await h.service.initialize('c1');
      await h.service.setMuted(true);
      await h.service.setMuted(true); // no change, no event
      await h.service.disposeCall('c1');
      await h.service.initialize('c2');
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e.muted), <bool>[true, false]);
      expect(h.service.isMuted, isFalse);
      expect(h.stream.tracks.single.enabled, isTrue);
    });
  });

  group('#44 proximity', () {
    test('on while the call is live on the earpiece, off otherwise', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await Future<void>.delayed(Duration.zero);
      expect(h.proximity.enabled, isTrue);
      await h.service.enableSpeaker(true);
      await Future<void>.delayed(Duration.zero);
      expect(h.proximity.enabled, isFalse);
      await h.service.enableSpeaker(false);
      await Future<void>.delayed(Duration.zero);
      expect(h.proximity.enabled, isTrue);
      await h.service.disposeCall('c1');
      await Future<void>.delayed(Duration.zero);
      expect(h.proximity.enabled, isFalse);
    });

    test('off while on hold', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      await h.service.createOffer();
      await h.service.beginHold(true);
      await h.service.completeHold(audioSdp);
      await Future<void>.delayed(Duration.zero);
      expect(h.proximity.enabled, isFalse);
    });
  });
}
