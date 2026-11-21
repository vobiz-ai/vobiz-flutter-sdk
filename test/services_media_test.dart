// Media fixes in PeerService and its helpers: a hold or ICE restart whose
// offer cannot be built leaves the call as it was, the far end's offer is
// not applied over our own pending one, the audio constraints reach Android
// and iOS, call quality reads the pair that carries the audio, the route is
// reset to the platform's default, the device-change handler is shared and
// handed back, and an interruption that ends early still resumes the call.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/src/audio/audio_route.dart';
import 'package:vobiz_webrtc/src/media/audio_interruption.dart';
import 'package:vobiz_webrtc/src/media/call_media_event.dart';
import 'package:vobiz_webrtc/src/media/call_quality.dart';
import 'package:vobiz_webrtc/src/webrtc/ice_config.dart';
import 'package:vobiz_webrtc/src/webrtc/media_constraints.dart';

import 'media_fakes.dart';

/// An answered call on a [MediaHarness].
Future<MediaHarness> _connected() async {
  final h = MediaHarness();
  await h.service.initialize('c1');
  await h.service.createOffer();
  await h.service.applyRemoteAnswer(audioSdp);
  return h;
}

final String _farOffer = audioSdp.replaceFirst('a=sendrecv', 'a=sendonly');

void main() {
  group('hold whose offer cannot be built', () {
    test('a failed hold leaves the microphone live and the call not held', () async {
      final h = await _connected();
      final sets = h.peer.localSet.length;
      h.peer.createOfferError = StateError('signalling state is not stable');
      await expectLater(h.service.beginHold(true), throwsStateError);
      expect(h.service.isHeld, isFalse);
      expect(h.stream.tracks.single.enabled, isTrue, reason: 'the other side heard nothing');
      expect(h.peer.transceivers_.single.direction, TransceiverDirection.SendRecv);
      expect(h.peer.localSet, hasLength(sets), reason: 'no offer was applied, so none rolled back');

      // The client's own clean-up finds nothing left to undo.
      await h.service.abortHold();
      expect(h.service.isHeld, isFalse);
      expect(h.stream.tracks.single.enabled, isTrue);
      expect(h.peer.localSet, hasLength(sets));
    });

    test('a failed resume leaves the call held with the microphone silenced', () async {
      final h = await _connected();
      await h.service.beginHold(true);
      await h.service.completeHold(audioSdp.replaceFirst('a=sendrecv', 'a=recvonly'));
      h.peer.createOfferError = StateError('signalling state is not stable');
      await expectLater(h.service.beginHold(false), throwsStateError);
      expect(h.service.isHeld, isTrue);
      expect(h.stream.tracks.single.enabled, isFalse, reason: 'the microphone went live on hold');
      expect(h.peer.transceivers_.single.direction, TransceiverDirection.SendOnly);
    });

    test('an offer applied before the failure is rolled back', () async {
      final h = await _connected();
      h.peer.localReadsLeft = 0;
      await expectLater(h.service.beginHold(true), throwsException);
      expect(h.peer.localSet.last.type, 'rollback');
      expect(h.service.isHeld, isFalse);
      expect(h.stream.tracks.single.enabled, isTrue);
    });
  });

  group('the far end\'s offer while ours is pending', () {
    test('is refused during a hold offer, and answered once it is done', () async {
      final h = await _connected();
      final hold = await h.service.beginHold(true);
      expect(await h.service.answerSessionOffer(_farOffer), isNull);
      expect(h.peer.remoteAttempts.where((d) => d.type == 'offer'), isEmpty,
          reason: 'applying it would discard our hold offer');
      expect(h.peer.local!.sdp, hold);

      await h.service.completeHold(audioSdp.replaceFirst('a=sendrecv', 'a=recvonly'));
      expect(await h.service.answerSessionOffer(_farOffer), isNotNull);
    });

    test('is refused during an ICE restart offer', () async {
      final h = await _connected();
      await h.service.beginIceRestart();
      expect(await h.service.answerSessionOffer(_farOffer), isNull);
      await h.service.completeIceRestart(audioSdp);
      expect(await h.service.answerSessionOffer(_farOffer), isNotNull);
    });

    test('an offer that cannot be applied is not followed by a rollback', () async {
      final h = await _connected();
      h.peer.failRemote = true;
      expect(await h.service.answerSessionOffer(_farOffer), isNull);
      expect(h.peer.remoteAttempts.map((d) => d.type), <String>['answer', 'offer'],
          reason: 'a rollback here would remove whatever offer of ours was pending');
    });
  });

  group('ICE restart whose offer cannot be built', () {
    test('a failure before the offer is applied leaves nothing pending', () async {
      final h = await _connected();
      h.peer.createOfferError = StateError('no');
      final sets = h.peer.localSet.length;
      await expectLater(h.service.beginIceRestart(), throwsStateError);
      expect(h.peer.localSet, hasLength(sets));
      h.peer.createOfferError = null;
      expect(await h.service.answerSessionOffer(_farOffer), isNotNull);
    });

    test('a failure after the offer is applied rolls it back', () async {
      final h = await _connected();
      h.peer.localReadsLeft = 1; // the old credentials are read, then reads fail
      await expectLater(h.service.beginIceRestart(), throwsException);
      expect(h.peer.localSet.last.type, 'rollback');
    });
  });

  test('a new ICE config applies from the next call', () async {
    final h = MediaHarness();
    await h.service.initialize('c1');
    await h.service.disposeCall('c1');
    h.service.iceConfig = const IceConfig(servers: <IceServerConfig>[
      IceServerConfig(urls: <String>['turns:turn.example.com:443'], username: 'u', credential: 'fresh'),
    ]);
    await h.service.initialize('c2');
    final servers = h.configs.last['iceServers'] as List<dynamic>;
    expect((servers.single as Map<String, dynamic>)['credential'], 'fresh');
  });

  group('getUserMedia constraints', () {
    test('the processing flags also go in the form Android and iOS read', () {
      const mc = MediaConstraints(echoCancellation: false, noiseSuppression: false);
      final audio = mc.toWebRtcConstraints()['audio'] as Map<String, dynamic>;
      final optional = <String, String>{
        for (final m in audio['optional'] as List<Map<String, String>>) ...m,
      };
      expect(optional['googEchoCancellation'], 'false');
      expect(optional['googNoiseSuppression'], 'false');
      expect(optional['googAutoGainControl'], 'true');
      expect(audio['echoCancellation'], isFalse, reason: 'the W3C form stays for the web');
    });

    test('the defaults keep the platform\'s own processing on', () {
      final audio = const MediaConstraints().toWebRtcConstraints()['audio'] as Map<String, dynamic>;
      final values = <String>{
        for (final m in audio['optional'] as List<Map<String, String>>) ...m.values,
      };
      expect(values, <String>{'true'});
    });
  });

  test('call quality reads the RTT of the pair that carries the audio', () {
    final analyzer = CallQualityAnalyzer();
    final sample = analyzer.add(<StatsReport>[
      inboundAudio(lost: 0, received: 1000),
      StatsReport('T01', 'transport', 0, <dynamic, dynamic>{'selectedCandidatePairId': 'cp-direct'}),
      StatsReport('cp-direct', 'candidate-pair', 0,
          <dynamic, dynamic>{'nominated': true, 'currentRoundTripTime': 0.05}),
      // A relay pair that also works, listed last.
      StatsReport('cp-relay', 'candidate-pair', 0,
          <dynamic, dynamic>{'state': 'succeeded', 'currentRoundTripTime': 0.4}),
    ])!;
    expect(sample.rttMs, closeTo(50, 0.001));

    // Without a transport report, a working pair's RTT is used as before.
    final fallback = CallQualityAnalyzer().add(<StatsReport>[
      inboundAudio(lost: 0, received: 1000),
      candidatePair(0.07),
    ])!;
    expect(fallback.rttMs, closeTo(70, 0.001));
  });

  group('audio routes', () {
    test('the route reset after a call is the platform\'s default: a connected headset', () async {
      final h = MediaHarness();
      h.backend.outputs.add(MediaDeviceInfo(label: 'BT', deviceId: 'bluetooth', kind: 'audiooutput'));
      final routes = <AudioRoute>[];
      h.service.callMediaEvents.listen((e) {
        if (e is AudioRouteChangedEvent) routes.add(e.route);
      });
      await h.service.initialize('c1');
      await h.service.enableSpeaker(true);
      await h.service.disposeCall('c1');
      expect(h.backend.speakerPreferred, isFalse);
      expect(h.service.audioRoutes.currentRoute, AudioRoute.bluetooth,
          reason: 'speaker-off plays on the headset, not the earpiece');
      await Future<void>.delayed(Duration.zero);
      expect(routes.last, AudioRoute.bluetooth);
    });

    test('dispose stops listening for device changes', () async {
      final backend = FakeAudioBackend();
      final controller = AudioRouteController(backend: backend);
      final changes = <AudioRoute>[];
      controller.routeChanges.listen(changes.add);
      await controller.availableRoutes();
      final onChange = backend.onChange!;
      await controller.dispose();
      expect(backend.onChange, isNull, reason: 'the handler was kept after dispose');

      // A change delivered late is ignored.
      backend.outputs.clear();
      onChange();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(changes, isEmpty);
    });

    group('flutter_webrtc\'s device-change handler', () {
      setUpAll(() {
        TestWidgetsFlutterBinding.ensureInitialized();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
            const EventChannel('FlutterWebRTC.Event'),
            MockStreamHandler.inline(onListen: (Object? arguments, MockStreamHandlerEventSink events) {}));
      });

      tearDown(() => navigator.mediaDevices.ondevicechange = null);

      test('the app\'s own handler keeps being called, and gets its place back', () {
        final devices = navigator.mediaDevices;
        var app = 0;
        var sdk = 0;
        void appHandler(dynamic _) => app++;
        devices.ondevicechange = appHandler;

        final stop = const FlutterWebRtcAudioBackend().listenForDeviceChanges(() => sdk++);
        devices.ondevicechange!(null);
        expect(app, 1, reason: 'the SDK used to replace the app\'s handler');
        expect(sdk, 1);

        stop();
        expect(devices.ondevicechange, same(appHandler));
      });

      test('a handler set after the SDK\'s is left in place', () {
        final devices = navigator.mediaDevices;
        final stop = const FlutterWebRtcAudioBackend().listenForDeviceChanges(() {});
        void later(dynamic _) {}
        devices.ondevicechange = later;
        stop();
        expect(devices.ondevicechange, same(later));
      });
    });
  });

  group('an interruption that ends while its hold is on its way', () {
    late bool held;
    late List<String> actions;
    late Completer<void> holdGate;
    late AudioInterruptionHandler handler;

    setUp(() {
      held = false;
      actions = <String>[];
      holdGate = Completer<void>();
      handler = AudioInterruptionHandler(
        isCallActive: () => true,
        isHeld: () => held,
        hold: () async {
          actions.add('hold');
          await holdGate.future;
          held = true;
        },
        resume: () async {
          actions.add('resume');
          held = false;
        },
      );
    });

    test('resumes the call once the hold is through', () async {
      final began = handler.began();
      await handler.ended();
      holdGate.complete();
      await began;
      expect(actions, <String>['hold', 'resume'], reason: 'the call used to stay on hold');
      expect(handler.heldByInterruption, isFalse);
    });

    test('stays held when the platform says not to resume', () async {
      final began = handler.began();
      await handler.ended(shouldResume: false);
      holdGate.complete();
      await began;
      expect(actions, <String>['hold']);
      expect(handler.heldByInterruption, isFalse);
    });

    test('a hold that completes after the call ended is not remembered', () async {
      final began = handler.began();
      handler.reset(); // the call ended
      holdGate.complete();
      await began;
      expect(handler.heldByInterruption, isFalse);
      await handler.ended();
      expect(actions, <String>['hold']);
    });
  });
}
