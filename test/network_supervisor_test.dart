// Issue #18: reconnect backoff with a cap, a terminal event, offline gating,
// and an immediate reconnect when the network comes back or changes.
// ignore_for_file: implementation_imports
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/network/connection_supervisor.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'network_fakes.dart';

class _Harness {
  _Harness({
    ReconnectPolicy policy = const ReconnectPolicy(jitter: 0, maxAttempts: 3),
    this.failAttempts = true,
    this.activeCall = false,
  }) {
    supervisor = ConnectionSupervisor(
      policy: policy,
      monitor: monitor,
      reconnect: () async {
        attempts++;
        if (failAttempts) throw StateError('refused');
      },
      onEvent: events.add,
      hasActiveCall: () => activeCall,
      onHandover: (NetworkStatus a, NetworkStatus b) => handovers.add('$a->$b'),
      random: Random(1),
    );
  }

  final FakeConnectivityMonitor monitor = FakeConnectivityMonitor();
  final List<NetworkEvent> events = <NetworkEvent>[];
  final List<String> handovers = <String>[];
  late final ConnectionSupervisor supervisor;
  int attempts = 0;
  bool failAttempts;
  bool activeCall;

  List<NetworkEventType> get types => events.map((e) => e.type).toList();
}

void main() {
  group('ReconnectPolicy', () {
    test('doubles from the initial delay and caps at maxDelay', () {
      const p = ReconnectPolicy(jitter: 0, maxDelay: Duration(seconds: 30));
      expect(
          <int>[for (var i = 1; i <= 7; i++) p.baseDelayFor(i).inSeconds],
          <int>[1, 2, 4, 8, 16, 30, 30]);
    });

    test('jitter stays within the spread and under maxDelay', () {
      const p = ReconnectPolicy(jitter: 0.2);
      final r = Random(7);
      for (var i = 0; i < 200; i++) {
        final d = p.delayFor(3, r).inMilliseconds;
        expect(d, inInclusiveRange(3200, 4800));
        expect(p.delayFor(20, r).inMilliseconds, lessThanOrEqualTo(30000));
      }
    });

    test('has a finite cap by default (the old loop retried forever)', () {
      const p = ReconnectPolicy();
      expect(p.maxAttempts, isNotNull);
      expect(p.allows(p.maxAttempts!), isFalse);
      expect(const ReconnectPolicy(maxAttempts: null).allows(1 << 20), isTrue);
    });
  });

  group('ConnectionSupervisor', () {
    test('backs off, then gives up with a terminal reconnectFailed event', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness();
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connected();
        h.supervisor.connectionLost('socket closed');

        expect(h.types, <NetworkEventType>[NetworkEventType.reconnecting]);
        expect(h.events.last.retryIn, const Duration(seconds: 1));
        async.elapse(const Duration(milliseconds: 999));
        expect(h.attempts, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(h.attempts, 1);
        expect(h.events.last.retryIn, const Duration(seconds: 2));
        async.elapse(const Duration(seconds: 2));
        expect(h.attempts, 2);
        async.elapse(const Duration(seconds: 4));
        expect(h.attempts, 3);

        expect(h.types.last, NetworkEventType.reconnectFailed);
        expect(h.events.last.attempt, 3);
        expect(h.events.last.quality, SignalingQuality.unavailable);
        expect(h.supervisor.hasGivenUp, isTrue);

        // No more attempts, however long we wait.
        async.elapse(const Duration(hours: 1));
        expect(h.attempts, 3);
        h.supervisor.stop();
      });
    });

    test('a successful attempt emits reconnected and resets the backoff', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(failAttempts: false);
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connectionLost('drop');
        async.elapse(const Duration(seconds: 1));
        expect(h.attempts, 1);
        h.supervisor.connected(); // REGISTER 200
        expect(h.types.last, NetworkEventType.reconnected);
        expect(h.supervisor.attempts, 0);
        expect(h.supervisor.quality, SignalingQuality.good);

        h.supervisor.connectionLost('drop again');
        expect(h.events.last.retryIn, const Duration(seconds: 1));
        h.supervisor.stop();
      });
    });

    test('an attempt that opens the socket but never registers counts as failed', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(failAttempts: false);
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connectionLost('drop');
        async.elapse(const Duration(seconds: 1));
        expect(h.attempts, 1);
        async.elapse(const Duration(seconds: 10)); // registerTimeout
        expect(h.events.last.reason, contains('No answer to REGISTER'));
        async.elapse(const Duration(seconds: 2));
        expect(h.attempts, 2);
        h.supervisor.stop();
      });
    });

    test('no attempts while offline; reconnects at once when the network returns', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(failAttempts: false);
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connected();

        h.monitor.goOffline();
        expect(h.types.last, NetworkEventType.offline);
        expect(h.supervisor.isOffline, isTrue);
        h.supervisor.connectionLost('ping timeout');
        async.elapse(const Duration(minutes: 10));
        expect(h.attempts, 0, reason: 'no TLS handshakes burnt while offline');
        expect(h.supervisor.attempts, 0);

        h.monitor.mobile();
        async.flushMicrotasks();
        expect(h.types, containsAllInOrder(<NetworkEventType>[
          NetworkEventType.online,
          NetworkEventType.reconnecting,
        ]));
        expect(h.attempts, 1, reason: 'reconnects immediately, no backoff wait');
        h.supervisor.stop();
      });
    });

    test('Wi-Fi to mobile while idle replaces the socket immediately', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(failAttempts: false);
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connected();

        h.monitor.mobile();
        async.flushMicrotasks();
        expect(h.types.first, NetworkEventType.networkChanged);
        expect(h.events.first.previousNetwork!.primary, NetworkType.wifi);
        expect(h.events.first.network.primary, NetworkType.mobile);
        expect(h.attempts, 1);
        h.supervisor.connected();
        expect(h.types.last, NetworkEventType.reconnected);
        h.supervisor.stop();
      });
    });

    // Seen live 2026-10-26: mobile data off with Wi-Fi already off, Wi-Fi back
    // 7 s later. The socket never reported its death, so nothing reconnected
    // until its ping timed out 20 s in, and the call ran out of grace.
    test('back from offline during a call, the old socket is replaced at once', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(failAttempts: false, activeCall: true);
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connected();

        h.monitor.goOffline();
        async.flushMicrotasks();
        expect(h.attempts, 0, reason: 'nothing to try while offline');
        h.monitor.wifi();
        async.flushMicrotasks();
        expect(h.handovers, hasLength(1));
        expect(h.attempts, 1, reason: 'a socket that lived through an outage is not trusted');
        h.supervisor.connected();
        expect(h.types.last, NetworkEventType.reconnected);
        h.supervisor.stop();
      });
    });

    test('a network change during a call goes to the handover hook, not a new socket', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(failAttempts: false, activeCall: true);
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connected();

        h.monitor.mobile();
        async.flushMicrotasks();
        expect(h.handovers, hasLength(1));
        expect(h.attempts, 0, reason: 'replacing the socket would drop the dialog');

        // If the socket then dies, the normal reconnect takes over.
        h.supervisor.connectionLost('ping timeout');
        async.elapse(const Duration(seconds: 1));
        expect(h.attempts, 1);
        h.supervisor.stop();
      });
    });

    test('a network change after giving up tries again', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(policy: const ReconnectPolicy(jitter: 0, maxAttempts: 1));
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connectionLost('drop');
        async.elapse(const Duration(seconds: 1));
        expect(h.supervisor.hasGivenUp, isTrue);
        h.failAttempts = false;
        h.monitor.mobile();
        async.flushMicrotasks();
        expect(h.attempts, 2);
        h.supervisor.connected();
        expect(h.supervisor.hasGivenUp, isFalse);
        h.supervisor.stop();
      });
    });

    test('reconnectNow skips the pending backoff', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(failAttempts: false,
            policy: const ReconnectPolicy(jitter: 0, initialDelay: Duration(seconds: 30)));
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connectionLost('drop');
        h.supervisor.reconnectNow(reason: 'app resumed');
        async.flushMicrotasks();
        expect(h.attempts, 1);
        async.elapse(const Duration(seconds: 31));
        expect(h.attempts, 1, reason: 'the cancelled timer must not fire');
        h.supervisor.stop();
      });
    });

    test('stop() cancels everything', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness();
        h.supervisor.start();
        async.flushMicrotasks();
        h.supervisor.connectionLost('drop');
        h.supervisor.stop();
        async.elapse(const Duration(minutes: 5));
        h.monitor.mobile();
        async.flushMicrotasks();
        expect(h.attempts, 0);
      });
    });
  });
}
