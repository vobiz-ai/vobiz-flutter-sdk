// Quality events (#20), audio routes and Bluetooth permission (#41),
// interruption hold/resume (#17).
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/src/audio/audio_route.dart';
import 'package:vobiz_webrtc/src/media/audio_interruption.dart';
import 'package:vobiz_webrtc/src/media/call_media_event.dart';
import 'package:vobiz_webrtc/src/media/call_quality.dart';

import 'media_fakes.dart';

void main() {
  group('#20 call quality', () {
    test('packet loss is per interval, so a burst shows at once', () async {
      final h = MediaHarness();
      await h.service.initialize('c1');
      h.peer.stats = <StatsReport>[inboundAudio(lost: 0, received: 30000)];
      expect((await h.service.getStats())!.packetLossPercent, 0);
      // 10 minutes in, a burst: 100 of the next 200 packets lost.
      h.peer.stats = <StatsReport>[inboundAudio(lost: 100, received: 30100)];
      final burst = (await h.service.getStats())!.packetLossPercent!;
      expect(burst, closeTo(50, 0.01),
          reason: 'lifetime counters would say ${100 / 30200 * 100}%');
    });

    test('MOS falls with loss, delay and jitter', () {
      final clean = CallQualityAnalyzer.estimateMos(rttMs: 40, jitterMs: 5, packetLossPercent: 0);
      final lossy = CallQualityAnalyzer.estimateMos(rttMs: 40, jitterMs: 5, packetLossPercent: 10);
      final slow = CallQualityAnalyzer.estimateMos(rttMs: 800, jitterMs: 60, packetLossPercent: 0);
      expect(clean, greaterThan(4.2));
      expect(lossy, lessThan(clean));
      expect(slow, lessThan(clean));
      expect(CallQualityAnalyzer.levelFor(clean), CallQualityLevel.good);
      expect(CallQualityAnalyzer.levelFor(
              CallQualityAnalyzer.estimateMos(rttMs: 600, jitterMs: 80, packetLossPercent: 15)),
          CallQualityLevel.poor);
    });

    test('quality events carry the codec and flag a level change once confirmed', () async {
      final h = MediaHarness();
      final events = <CallQualityEvent>[];
      h.service.callMediaEvents.listen((e) {
        if (e is CallQualityEvent) events.add(e);
      });
      await h.service.initialize('c1');
      List<StatsReport> report(num lost, num received) => <StatsReport>[
            inboundAudio(lost: lost, received: received),
            candidatePair(0.05),
            codec('c1', 'audio/PCMU'),
          ];
      h.peer.stats = report(0, 1000);
      await h.service.sampleQuality('c1');
      h.peer.stats = report(40, 1060); // 40% of this interval lost
      await h.service.sampleQuality('c1');
      h.peer.stats = report(80, 1120);
      await h.service.sampleQuality('c1');
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(3));
      expect(events.first.sample.codec, 'PCMU');
      expect(events.first.sample.rttMs, closeTo(50, 0.001));
      expect(events.map((e) => e.levelChanged), <bool>[false, false, true],
          reason: 'one bad sample must not flash a warning');
      expect(events.last.level, CallQualityLevel.poor);
    });
  });

  group('#41 audio routes', () {
    test('maps Android and iOS outputs to routes', () {
      expect(AudioRouteController.routeFor('bluetooth', 'Jabra'), AudioRoute.bluetooth);
      expect(AudioRouteController.routeFor('wired-headset', 'x'), AudioRoute.wiredHeadset);
      expect(AudioRouteController.routeFor('Built-In Receiver', 'Receiver'), AudioRoute.earpiece);
      expect(AudioRouteController.routeFor('Speaker', 'Speaker'), AudioRoute.speaker);
      expect(AudioRouteController.routeFor('00:11:22-tacl', 'AirPods Pro'), AudioRoute.bluetooth);
    });

    test('lists outputs and selects a Bluetooth headset', () async {
      final backend = FakeAudioBackend()
        ..outputs.add(MediaDeviceInfo(label: 'Car kit', deviceId: 'bluetooth', kind: 'audiooutput'));
      final routes = AudioRouteController(backend: backend);
      expect(await routes.availableRoutes(),
          <AudioRoute>[AudioRoute.earpiece, AudioRoute.speaker, AudioRoute.bluetooth]);
      await routes.selectRoute(AudioRoute.bluetooth);
      expect(backend.calls.last, 'select:bluetooth');
      expect(routes.currentRoute, AudioRoute.bluetooth);
    });

    test('selecting an absent output throws', () async {
      final routes = AudioRouteController(backend: FakeAudioBackend());
      expect(() => routes.selectRoute(AudioRoute.wiredHeadset), throwsStateError);
    });

    test('Bluetooth permission is asked once, before the first call', () async {
      final h = MediaHarness();
      var asked = 0;
      var peersAtAsk = -1;
      h.service.audioRoutes.bluetoothPermissionRequester = () async {
        asked++;
        peersAtAsk = h.peers.length;
        return true;
      };
      await h.service.initialize('c1');
      await h.service.disposeCall('c1');
      await h.service.initialize('c2');
      expect(asked, 1);
      expect(peersAtAsk, 0, reason: 'must be granted before the audio switch starts');
    });

    test('a refused permission blocks the Bluetooth route only', () async {
      final backend = FakeAudioBackend()
        ..outputs.add(MediaDeviceInfo(label: 'BT', deviceId: 'bluetooth', kind: 'audiooutput'));
      final routes = AudioRouteController(backend: backend)
        ..bluetoothPermissionRequester = () async => false;
      expect(() => routes.selectRoute(AudioRoute.bluetooth), throwsStateError);
      await routes.selectRoute(AudioRoute.speaker);
      expect(routes.currentRoute, AudioRoute.speaker);
    });

    test('speaker off falls back to a connected headset', () async {
      final backend = FakeAudioBackend()
        ..outputs.add(MediaDeviceInfo(label: 'Wired', deviceId: 'wired-headset', kind: 'audiooutput'));
      final routes = AudioRouteController(backend: backend);
      await routes.setSpeakerOn(true);
      await routes.setSpeakerOn(false);
      expect(routes.currentRoute, AudioRoute.wiredHeadset);
    });

    test('a headset that disconnects moves the reported route', () async {
      final backend = FakeAudioBackend()
        ..outputs.add(MediaDeviceInfo(label: 'BT', deviceId: 'bluetooth', kind: 'audiooutput'));
      final routes = AudioRouteController(backend: backend);
      await routes.selectRoute(AudioRoute.bluetooth);
      backend.outputs.removeLast();
      backend.onChange!();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(routes.currentRoute, AudioRoute.earpiece);
    });
  });

  group('#17 interruptions', () {
    late bool active;
    late bool held;
    late List<String> actions;
    late AudioInterruptionHandler handler;

    setUp(() {
      active = true;
      held = false;
      actions = <String>[];
      handler = AudioInterruptionHandler(
        isCallActive: () => active,
        isHeld: () => held,
        hold: () async {
          actions.add('hold');
          held = true;
        },
        resume: () async {
          actions.add('resume');
          held = false;
        },
      );
    });

    test('a SIM call holds the Vobiz call and its end resumes it', () async {
      await handler.began();
      await handler.ended();
      expect(actions, <String>['hold', 'resume']);
    });

    test('a call the user held stays held after the interruption', () async {
      held = true;
      await handler.began();
      await handler.ended();
      expect(actions, isEmpty);
    });

    test('shouldResume false leaves it held', () async {
      await handler.began();
      await handler.ended(shouldResume: false);
      expect(actions, <String>['hold']);
    });

    test('nothing to do without a connected call', () async {
      active = false;
      await handler.began();
      await handler.ended();
      expect(actions, isEmpty);
    });
  });
}
