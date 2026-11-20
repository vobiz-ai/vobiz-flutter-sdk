// Provider sign-in sessions keep a sign-in alive through failures: a token
// refresh that fails is retried with backoff, the expiry is timed by the
// registrar's clock, a sign-out stops the session, a refusal during a call
// does not end the call, and a sign-in that throws leaves nothing running.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';
import 'network_fakes.dart' show eventually;
import 'services_auth_support.dart';
import 'sip_test_support.dart' show inboundInvite;

/// Whole seconds, as token times are.
DateTime _wholeSeconds(DateTime t) =>
    DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch ~/ 1000 * 1000);

void main() {
  group('VobizAccessTokenSession', () {
    tearDown(() => VobizAccessTokenSession.now = DateTime.now);

    test('a refresh that fails is asked again after 5 s, then 10 s, until it works', () {
      fakeAsync((async) {
        final start = _wholeSeconds(DateTime.now());
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final sip = InstantRegistrar();
        final client = VobizClient.withServices(sip: sip, peer: FakePeer());
        final fresh = token(from: start, lifetime: const Duration(minutes: 30), nonce: '2');
        final asked = <VobizAccessTokenRequest>[];
        final failures = <VobizException>[];
        late VobizAccessTokenSession session;
        client.connectWithAccessTokenProvider((request) async {
          asked.add(request);
          if (request == VobizAccessTokenRequest.signIn) {
            return token(from: start, lifetime: const Duration(minutes: 10), nonce: '1');
          }
          if (asked.length <= 3) throw const SocketException('backend unreachable');
          return fresh;
        }).then((s) {
          session = s;
          s.failures.listen(failures.add);
        });
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 9, seconds: 1));
        expect(asked.last, VobizAccessTokenRequest.expiring);
        expect(failures, hasLength(1));
        final retryAt = start.add(const Duration(minutes: 9, seconds: 5));
        expect(session.nextRefreshAt, retryAt, reason: 'one failure used to end the renewal');

        async.elapse(const Duration(seconds: 5));
        expect(asked, hasLength(3));
        expect(failures, hasLength(2));
        expect(session.nextRefreshAt, retryAt.add(const Duration(seconds: 10)));

        async.elapse(const Duration(seconds: 10));
        expect(asked, hasLength(4));
        expect(sip.registerTokens.last, fresh);
        expect(client.isConnected, isTrue);
        expect(failures, hasLength(2));
        expect(session.nextRefreshAt, start.add(const Duration(minutes: 29)));

        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('the wait between failed attempts doubles up to 60 s', () {
      fakeAsync((async) {
        final start = _wholeSeconds(DateTime.now());
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final client = VobizClient.withServices(sip: InstantRegistrar(), peer: FakePeer());
        late VobizAccessTokenSession session;
        client.connectWithAccessTokenProvider((request) async {
          if (request == VobizAccessTokenRequest.signIn) {
            return token(from: start, lifetime: const Duration(minutes: 10));
          }
          throw const SocketException('backend unreachable');
        }).then((s) => session = s);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 9));

        final waits = <int>[];
        for (var i = 0; i < 6; i++) {
          final next = session.nextRefreshAt!;
          waits.add(next.difference(start.add(async.elapsed)).inSeconds);
          async.elapse(next.difference(start.add(async.elapsed)));
        }
        expect(waits, <int>[5, 10, 20, 40, 60, 60]);
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a failed fetch after a refusal is retried, and a refusal meanwhile does not end it', () {
      fakeAsync((async) {
        final sip = InstantRegistrar();
        final stale = token(nonce: 'stale');
        final fresh = token(nonce: 'fresh');
        sip.refused.add(stale);
        final client = VobizClient.withServices(sip: sip, peer: FakePeer());
        final asked = <VobizAccessTokenRequest>[];
        final failures = <VobizException>[];
        late VobizAccessTokenSession session;
        client.connectWithAccessTokenProvider((request) async {
          asked.add(request);
          if (request == VobizAccessTokenRequest.signIn) return stale;
          if (asked.length <= 3) throw const SocketException('backend unreachable');
          return fresh;
        }).then((s) {
          session = s;
          s.failures.listen(failures.add);
        });
        async.flushMicrotasks();
        expect(asked, <VobizAccessTokenRequest>[
          VobizAccessTokenRequest.signIn,
          VobizAccessTokenRequest.rejected,
        ]);
        expect(client.isConnected, isFalse);

        // The old token is refused again while the session waits to retry.
        sip.registerAgain();
        async.flushMicrotasks();
        expect(session.nextRefreshAt, isNotNull, reason: 'a second refusal used to end it');

        async.elapse(const Duration(seconds: 5));
        expect(asked, hasLength(3));
        async.elapse(const Duration(seconds: 10));
        expect(asked.last, VobizAccessTokenRequest.rejected);
        expect(sip.registerTokens.last, fresh);
        expect(client.isConnected, isTrue);
        expect(failures, hasLength(2));
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a token for another user is reported and not asked for again', () {
      fakeAsync((async) {
        final start = _wholeSeconds(DateTime.now());
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final client = VobizClient.withServices(sip: InstantRegistrar(), peer: FakePeer());
        final asked = <VobizAccessTokenRequest>[];
        final failures = <VobizException>[];
        late VobizAccessTokenSession session;
        client.connectWithAccessTokenProvider((request) async {
          asked.add(request);
          return request == VobizAccessTokenRequest.signIn
              ? token(from: start, lifetime: const Duration(minutes: 10))
              : token(from: start, sub: 'someone-else');
        }).then((s) {
          session = s;
          s.failures.listen(failures.add);
        });
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 9, seconds: 1));
        expect(failures, hasLength(1));
        expect(session.nextRefreshAt, isNull);
        async.elapse(const Duration(minutes: 30));
        expect(asked, hasLength(2));
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('client.disconnect() stops the refresh: the provider is not asked after sign-out', () {
      fakeAsync((async) {
        final start = _wholeSeconds(DateTime.now());
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final client = VobizClient.withServices(
            sip: InstantRegistrar()..unregisterTimeout = const Duration(milliseconds: 10),
            peer: FakePeer());
        final asked = <VobizAccessTokenRequest>[];
        final failures = <VobizException>[];
        late VobizAccessTokenSession session;
        client.connectWithAccessTokenProvider((request) async {
          asked.add(request);
          return token(from: start, lifetime: const Duration(minutes: 10));
        }).then((s) {
          session = s;
          s.failures.listen(failures.add);
        });
        async.flushMicrotasks();
        expect(session.nextRefreshAt, isNotNull);

        client.disconnect();
        async.elapse(const Duration(seconds: 1));
        expect(session.nextRefreshAt, isNull);
        async.elapse(const Duration(minutes: 20));
        expect(asked, <VobizAccessTokenRequest>[VobizAccessTokenRequest.signIn]);
        expect(failures, isEmpty, reason: 'used to report a StateError after sign-out');
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('the refresh is timed by the registrar\'s count of the time left, not the device clock', () {
      for (final skew in <Duration>[const Duration(hours: 2), const Duration(minutes: -30)]) {
        fakeAsync((async) {
          final start = _wholeSeconds(DateTime.now());
          // The phone's clock is [skew] off; the token server's and the
          // registrar's are right.
          DateTime deviceNow() => start.add(skew).add(async.elapsed);
          VobizAccessTokenSession.now = deviceNow;
          final sip = InstantRegistrar()..tokenExpiresIn = 3540;
          final client = VobizClient.withServices(sip: sip, peer: FakePeer());
          var asked = 0;
          late VobizAccessTokenSession session;
          client.connectWithAccessTokenProvider((request) async {
            asked++;
            return token(from: start, lifetime: const Duration(hours: 1), nonce: '$asked');
          }).then((s) => session = s);
          async.flushMicrotasks();

          expect(client.isConnected, isTrue);
          expect(session.nextRefreshAt, deviceNow().add(const Duration(seconds: 3540 - 60)),
              reason: 'clock off by $skew');
          async.elapse(const Duration(minutes: 5));
          expect(asked, 1, reason: 'a clock ahead used to make it ask every 5 s');
          async.elapse(const Duration(minutes: 54));
          expect(asked, 2, reason: 'a clock behind used to make it ask after the expiry');
          session.dispose();
          client.dispose();
          async.flushMicrotasks();
        });
      }
    });

    test('tokens that arrive nearly expired are asked for less and less often', () {
      fakeAsync((async) {
        final start = _wholeSeconds(DateTime.now());
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final client = VobizClient.withServices(sip: InstantRegistrar(), peer: FakePeer());
        var n = 0;
        late VobizAccessTokenSession session;
        client.connectWithAccessTokenProvider((_) async {
          n++;
          return token(
              from: start.add(async.elapsed), lifetime: const Duration(seconds: 30), nonce: '$n');
        }).then((s) => session = s);
        async.flushMicrotasks();

        final waits = <int>[];
        for (var i = 0; i < 6; i++) {
          final next = session.nextRefreshAt!;
          waits.add(next.difference(start.add(async.elapsed)).inSeconds);
          async.elapse(next.difference(start.add(async.elapsed)));
        }
        expect(waits, <int>[5, 10, 20, 40, 60, 60]);
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a socket that cannot be opened keeps the session while the client retries by itself', () {
      fakeAsync((async) {
        final start = _wholeSeconds(DateTime.now());
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final sip = InstantRegistrar()..connectError = const SocketException('offline');
        final client = VobizClient.withServices(
            sip: sip, peer: FakePeer(), config: const SdkConfig(autoReconnect: true));
        final asked = <VobizAccessTokenRequest>[];
        VobizAccessTokenSession? session;
        Object? thrown;
        client.connectWithAccessTokenProvider((request) async {
          asked.add(request);
          return token(from: start.add(async.elapsed), lifetime: const Duration(minutes: 10));
        }).then((s) => session = s, onError: (Object e) {
          thrown = e;
        });
        async.flushMicrotasks();
        expect(thrown, isNull, reason: 'the sign-in used to throw and drop the session');
        expect(session, isNotNull);
        expect(client.connectionState, ConnectionStateStatus.reconnecting);

        sip.connectError = null;
        async.elapse(const Duration(seconds: 5));
        expect(client.isConnected, isTrue);
        async.elapse(const Duration(minutes: 9));
        expect(asked.last, VobizAccessTokenRequest.expiring,
            reason: 'the token of a client that reconnected by itself is renewed');
        session!.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('without auto-reconnect a socket failure fails the sign-in and leaves nothing running',
        () async {
      final sip = InstantRegistrar()..connectError = const SocketException('offline');
      final client = VobizClient.withServices(sip: sip, peer: FakePeer());
      var asked = 0;
      await expectLater(
          client.connectWithAccessTokenProvider((_) async {
            asked++;
            return token(lifetime: const Duration(minutes: 10));
          }),
          throwsA(isA<SocketException>()));
      // No session is left to answer a refusal.
      final stale = token(nonce: 'stale');
      sip
        ..connectError = null
        ..refused.add(stale);
      await client.connectWithAccessToken(stale);
      await eventually(() => client.registrationState == RegistrationState.failed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(asked, 1);
      await client.dispose();
    });
  });

  group('VobizCredentialsSession', () {
    late InstantRegistrar sip;
    late VobizClient client;

    setUp(() {
      sip = InstantRegistrar()..unregisterTimeout = const Duration(milliseconds: 10);
      client = VobizClient.withServices(sip: sip, peer: FakePeer());
    });

    tearDown(() => client.dispose());

    test('a refusal during a call waits for the call to end before signing in again', () async {
      sip.users.add('agent');
      final asked = <VobizCredentialsRequest>[];
      final calls = <CallEvent>[];
      client.callEvents.listen(calls.add);
      final session = await client.connectWithCredentialsProvider((request) async {
        asked.add(request);
        return request == VobizCredentialsRequest.signIn
            ? const CredentialConfig(username: 'agent', password: 'pw')
            : const CredentialConfig(username: 'agent2', password: 'rotated');
      });
      await eventually(() => client.isConnected);
      sip.debugReceive(inboundInvite(callId: 'in-1'));
      await client.acceptCall();
      expect(client.callState, CallStateStatus.active);

      // The password was rotated: the next REGISTER is refused mid-call.
      sip.users
        ..clear()
        ..add('agent2');
      expect(sip.refreshRegistration(), isTrue);
      await eventually(() => client.registrationState == RegistrationState.failed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.callState, CallStateStatus.active,
          reason: 'signing in again used to end the call as "Signed out"');
      expect(asked, <VobizCredentialsRequest>[VobizCredentialsRequest.signIn]);

      await client.hangup();
      await eventually(() => client.isConnected && client.sipUsername == 'agent2');
      expect(asked, <VobizCredentialsRequest>[
        VobizCredentialsRequest.signIn,
        VobizCredentialsRequest.rejected,
      ]);
      expect(calls.where((e) => e.reason == 'disconnected'), isEmpty);
      await session.dispose();
    });

    test('a sign-out while the provider answers a refusal does not sign in again', () async {
      for (final signOut in <String>['disconnect', 'dispose']) {
        final registrar = InstantRegistrar()..unregisterTimeout = const Duration(milliseconds: 10);
        final c = VobizClient.withServices(sip: registrar, peer: FakePeer());
        final pending = Completer<CredentialConfig>();
        final asked = <VobizCredentialsRequest>[];
        final session = await c.connectWithCredentialsProvider((request) {
          asked.add(request);
          return request == VobizCredentialsRequest.signIn
              ? Future<CredentialConfig>.value(
                  const CredentialConfig(username: 'stale', password: 'old'))
              : pending.future;
        });
        await eventually(() => asked.length == 2, reason: signOut);
        if (signOut == 'disconnect') {
          await c.disconnect();
        } else {
          await session.dispose();
        }
        final sentBefore = registrar.registerUsers.length;
        pending.complete(const CredentialConfig(username: 'fresh', password: 'new'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(registrar.registerUsers.skip(sentBefore), isNot(contains('fresh')),
            reason: 'signed in again after $signOut');
        await session.dispose();
        await c.dispose();
      }
    });

    test('a socket that cannot be opened keeps the session while the client retries by itself', () {
      fakeAsync((async) {
        final registrar = InstantRegistrar()
          ..connectError = const SocketException('offline')
          ..users.add('agent');
        final c = VobizClient.withServices(
            sip: registrar, peer: FakePeer(), config: const SdkConfig(autoReconnect: true));
        VobizCredentialsSession? session;
        Object? thrown;
        c
            .connectWithCredentialsProvider(
                (_) async => const CredentialConfig(username: 'agent', password: 'pw'))
            .then((s) => session = s, onError: (Object e) {
          thrown = e;
        });
        async.flushMicrotasks();
        expect(thrown, isNull, reason: 'the sign-in used to throw and drop the session');
        expect(session, isNotNull);
        registrar.connectError = null;
        async.elapse(const Duration(seconds: 5));
        expect(c.isConnected, isTrue);
        session!.dispose();
        c.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
