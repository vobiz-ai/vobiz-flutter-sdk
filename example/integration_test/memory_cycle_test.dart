// ignore_for_file: implementation_imports, avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vobiz_webrtc/src/webrtc/peer_service.dart';
import 'package:vobiz_webrtc/src/utils/logger.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

/// Runs the SDK's own per-call media lifecycle N times (what every call does:
/// PeerConnection + mic + offer + ICE gathering, then the SDK's dispose), so
/// the host can sample `dumpsys meminfo` between phases.
///   Phase A: SDK as shipped (close() only).
///   Phase B: same, plus RTCPeerConnection.dispose() after the SDK's dispose.
const int cycles = int.fromEnvironment('CYCLES', defaultValue: 40);
const String phase = String.fromEnvironment('PHASE', defaultValue: 'AB');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> runPhase(String name, {required bool extraDispose}) async {
    final peer = PeerService(iceConfig: const IceConfig(), mediaConstraints: const MediaConstraints(), logger: Logger());
    print('MARK $name start ${DateTime.now().toIso8601String()}');
    final sw = Stopwatch();
    final setupMs = <int>[];
    for (var i = 0; i < cycles; i++) {
      final id = '$name-$i';
      sw..reset()..start();
      await peer.initialize(id);
      await peer.attachLocalAudioStream(id);
      await peer.createOffer();
      sw.stop();
      setupMs.add(sw.elapsedMilliseconds);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final pc = peer.peerConnection;
      await peer.disposeCall(id);
      if (extraDispose) await pc?.dispose();
      if (i % 10 == 9) print('MARK $name cycle ${i + 1} ${DateTime.now().toIso8601String()}');
    }
    setupMs.sort();
    print('MARK $name end ${DateTime.now().toIso8601String()} '
        'setup_ms p50=${setupMs[setupMs.length ~/ 2]} p90=${setupMs[(setupMs.length * 9) ~/ 10]} max=${setupMs.last}');
    await peer.dispose();
    await Future<void>.delayed(const Duration(seconds: 8));
    print('MARK $name settled ${DateTime.now().toIso8601String()}');
  }

  testWidgets('media lifecycle memory', (tester) async {
    await Future<void>.delayed(const Duration(seconds: 8));
    print('MARK baseline ${DateTime.now().toIso8601String()}');
    if (phase.contains('A')) await runPhase('A_sdk_as_is', extraDispose: false);
    if (phase.contains('B')) await runPhase('B_with_pc_dispose', extraDispose: true);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
