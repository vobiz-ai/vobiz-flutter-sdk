// PlatformAppLifecycleMonitor maps Flutter's lifecycle onto foreground and
// background. Kept apart from the socket tests: the test binding it needs
// stubs out HTTP.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

void main() {
  test('resumed is foreground; hidden, paused, detached are background; inactive is neither',
      () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final seen = <bool>[];
    final sub = PlatformAppLifecycleMonitor().foregroundChanges.listen(seen.add);

    for (final state in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
    }
    await Future<void>.delayed(Duration.zero);
    expect(seen, <bool>[false, false, false, true]);

    await sub.cancel();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(4), reason: 'the observer is removed on cancel');
  });
}
