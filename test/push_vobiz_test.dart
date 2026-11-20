// Incoming calls to a closed app through Vobiz's own push: the registrar
// holds the call, pushes, and sends the held INVITE to the REGISTER that
// hands back the push's hold reference (X-Index, X-Label,
// X-vobiz-Registrar-Info).
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'call_harness.dart' as harness;
import 'network_fakes.dart';
import 'sip_test_support.dart';

const String _challenge = 'WWW-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n1", qop="auth"';

/// A push as Vobiz's registrar sends it, through Vobiz's push service.
Map<String, Object?> vobizPush({
  String callId = 'held-call-1@10.0.2.9',
  int? expiresAt,
}) =>
    <String, Object?>{
      'type': 'incoming_call',
      'call_id': callId,
      'call_uuid': '5f0c5c7e-0000-4000-8000-000000000001',
      'caller': 'Asha',
      'caller_number': '+918000000000',
      'callee': 'play1',
      'index': '4211',
      'label': '1938273',
      'registrar': '203.0.113.10',
      'expires_at': '${expiresAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30}',
    };

void main() {
  group('reading a Vobiz push', () {
    test('reads the call, the hold reference and an expiry in seconds', () {
      final push = VobizIncomingPush.tryParse(vobizPush(expiresAt: 1762900030))!;
      expect(push.callId, 'held-call-1@10.0.2.9');
      expect(push.callUuid, '5f0c5c7e-0000-4000-8000-000000000001');
      expect(push.caller, 'Asha');
      expect(push.callerNumber, '+918000000000');
      expect(push.callee, 'play1');
      expect(push.hold.registerHeaders, <String, String>{
        'X-Index': '4211',
        'X-Label': '1938273',
        'X-vobiz-Registrar-Info': '203.0.113.10',
      });
      // Unix seconds, not milliseconds: read as 1970 it would be stale at once.
      expect(push.expiresAt, DateTime.fromMillisecondsSinceEpoch(1762900030000));
      expect(push.isExpired(DateTime.fromMillisecondsSinceEpoch(1762900029000)), isFalse);
      expect(push.isExpired(DateTime.fromMillisecondsSinceEpoch(1762900030000)), isTrue);
    });

    test('a time too large to be seconds is read as milliseconds', () {
      expect(VobizIncomingPush.epochToDateTime(1762900030000), DateTime.fromMillisecondsSinceEpoch(1762900030000));
      expect(VobizIncomingPush.epochToDateTime(1762900030), DateTime.fromMillisecondsSinceEpoch(1762900030000));
    });

    test('ignores other data messages', () {
      expect(VobizIncomingPush.tryParse(<String, Object?>{'type': 'check'}), isNull);
      expect(VobizIncomingPush.tryParse(<String, Object?>{'type': 'incoming_call'}), isNull);
      expect(VobizIncomingPush.tryParse(<String, Object?>{...vobizPush(), 'type': 'call_ended'}), isNull);
      expect(VobizIncomingPush.tryParse(<String, Object?>{...vobizPush(), 'call_id': ''}), isNull);
    });

    test('without any one of index, label and registrar it is not a push to act on', () {
      for (final missing in <String>['index', 'label', 'registrar']) {
        final data = vobizPush()..remove(missing);
        expect(VobizIncomingPush.tryParse(data), isNull, reason: 'without $missing');
      }
    });

    test('a held call matches its INVITE by Call-ID only', () {
      final push = VobizIncomingPush.tryParse(vobizPush())!;
      expect(push.matchesIncomingCall(sipCallId: 'held-call-1@10.0.2.9'), isTrue);
      expect(push.matchesIncomingCall(sipCallId: 'other@10.0.2.9'), isFalse);
      expect(push.matchesIncomingCall(sipCallId: null), isFalse);
    });
  });

  group('the REGISTER that claims a held call', () {
    late List<String> sent;
    late SIPService s;
    late int claimed;

    setUp(() {
      sent = <String>[];
      claimed = 0;
      s = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
        ..debugOnSend = sent.add
        ..onHeldCallClaimed = () => claimed++;
    });

    const hold = <String, String>{
      'X-Index': '4211',
      'X-Label': '1938273',
      'X-vobiz-Registrar-Info': '203.0.113.10',
    };

    void expectClaims(String register) {
      expect(headerOf(register, 'X-Index'), '4211');
      expect(headerOf(register, 'X-Label'), '1938273');
      expect(headerOf(register, 'X-vobiz-Registrar-Info'), '203.0.113.10');
    }

    test('signed in and registered: goes at once, and only that REGISTER carries it', () {
      s.connectionState.value = SipConnectionState.connected;
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.last, 200, 'OK'));
      sent.clear();

      expect(s.claimHeldCall(hold), isTrue);
      expect(methods(sent), <String>['REGISTER']);
      expectClaims(sent.single);
      s.debugReceive(respond(sent.single, 200, 'OK'));
      expect(claimed, 1);

      // The next refresh is a plain one.
      sent.clear();
      expect(s.refreshRegistration(), isTrue);
      expect(headerOf(sent.single, 'X-Index'), isEmpty);
    });

    test('before sign-in: the sign-in carries it, its digest answer too', () {
      expect(s.claimHeldCall(hold), isFalse);
      expect(sent, isEmpty);
      s.register('play1', 'secret');
      expectClaims(sent.single);
      s.debugReceive(respond(sent.single, 401, 'Unauthorized', headers: <String>[_challenge]));
      // The registrar reads the reference only on the authenticated REGISTER.
      expect(headerOf(sent.last, 'Authorization'), startsWith('Digest '));
      expectClaims(sent.last);
      expect(claimed, 0);
      s.debugReceive(respond(sent.last, 200, 'OK'));
      expect(claimed, 1);
      expect(s.hasPendingClaim, isFalse);
    });

    test('while a REGISTER is in flight: a second one carries it once the first is answered', () {
      s.connectionState.value = SipConnectionState.connected;
      s.register('play1', 'secret');
      expect(s.claimHeldCall(hold), isFalse);
      expect(headerOf(sent.single, 'X-Index'), isEmpty);
      s.debugReceive(respond(sent.single, 200, 'OK'));
      expect(methods(sent), <String>['REGISTER', 'REGISTER']);
      expectClaims(sent.last);
    });

    test('a 423 asks again with the reference', () {
      s.claimHeldCall(hold);
      s.register('play1', 'secret');
      s.debugReceive(respond(sent.single, 423, 'Interval Too Brief', headers: <String>['Min-Expires: 7200']));
      expect(headerOf(sent.last, 'Expires'), '7200');
      expectClaims(sent.last);
    });

    test('a claim nobody sent yet is dropped by a sign-out and by cancelHeldCallClaim', () async {
      s.claimHeldCall(hold);
      s.cancelHeldCallClaim();
      s.register('play1', 'secret');
      expect(headerOf(sent.single, 'X-Index'), isEmpty);

      s.claimHeldCall(hold);
      s.unregisterTimeout = const Duration(milliseconds: 1);
      await s.disconnect();
      expect(s.hasPendingClaim, isFalse);
    });
  });

  group('VobizClient.handleIncomingPush', () {
    late harness.Harness h;
    late List<VobizPushCallUpdate> updates;

    setUp(() {
      h = harness.Harness();
      h.sip.connectionState.value = SipConnectionState.connected;
      updates = <VobizPushCallUpdate>[];
      h.client.pushCallUpdates.listen(updates.add);
    });

    tearDown(() => h.dispose());

    VobizIncomingPush push({String callId = 'held-call-1@10.0.2.9', int? expiresAt}) =>
        VobizIncomingPush.tryParse(vobizPush(callId: callId, expiresAt: expiresAt))!;

    List<VobizPushCallStatus> statuses() => updates.map((u) => u.status).toList();

    test('registered: claims the call at once, and says when the registrar took the claim', () async {
      expect(h.client.handleIncomingPush(push()), isTrue);
      final register = h.sent.single;
      expect(firstLine(register), startsWith('REGISTER '));
      expect(headerOf(register, 'X-Index'), '4211');
      h.registered();
      await h.settle();
      expect(statuses(), <VobizPushCallStatus>[VobizPushCallStatus.claiming, VobizPushCallStatus.claimed]);
      // FCM can deliver one push twice: the second is the same call.
      expect(h.client.handleIncomingPush(push()), isTrue);
      expect(h.sent.where((m) => m.startsWith('REGISTER ')), hasLength(1));
    });

    test('Accept before the INVITE: the held call is answered the moment it arrives', () async {
      final p = push();
      h.client.handleIncomingPush(p);
      h.registered();
      h.client.reportCallScreenAccepted(p);
      h.sent.clear();

      h.invite('held-call-1@10.0.2.9');
      await h.settle();
      final incoming = h.events.firstWhere((e) => e.state == CallStateStatus.incoming);
      expect(incoming.sipCallId, 'held-call-1@10.0.2.9');
      expect(h.client.isPushedCall(incoming.callId), isTrue);
      expect(h.sentStatus(200), isTrue, reason: 'answered without another tap');
      expect(h.client.callState, CallStateStatus.active);
      expect(statuses(), containsAllInOrder(<VobizPushCallStatus>[
        VobizPushCallStatus.ringing,
        VobizPushCallStatus.answering,
      ]));
    });

    test('Decline before the INVITE: the held call is turned away the moment it arrives', () async {
      final p = push();
      h.client.handleIncomingPush(p);
      h.registered();
      h.client.reportCallScreenDeclined(p);
      h.sent.clear();

      h.invite('held-call-1@10.0.2.9');
      await h.settle();
      expect(h.sentStatus(200), isFalse);
      expect(h.firstLines.where((l) => RegExp(r'^SIP/2\.0 (486|603|480) ').hasMatch(l)), isNotEmpty,
          reason: 'a final refusal, so the caller stops waiting');
      expect(statuses(), contains(VobizPushCallStatus.declining));
    });

    test('ringing already: Accept answers it then', () async {
      final p = push();
      h.client.handleIncomingPush(p);
      h.registered();
      h.invite('held-call-1@10.0.2.9');
      await h.settle();
      expect(h.client.callState, CallStateStatus.incoming);
      h.client.reportCallScreenAccepted(p);
      await h.settle();
      expect(h.client.callState, CallStateStatus.active);
    });

    test('another call meanwhile, even from the same caller, is not answered for the push', () async {
      final p = push();
      h.client.handleIncomingPush(p);
      h.registered();
      h.client.reportCallScreenAccepted(p);
      h.sent.clear();
      h.invite('some-other-call@10.0.2.9');
      await h.settle();
      expect(h.sentStatus(200), isFalse);
      expect(h.client.callState, CallStateStatus.incoming);
      expect(h.client.isPushedCall(h.events.last.callId), isFalse);
    });

    test('no INVITE by the push\'s expiry plus the clock margin: expired, and the claim is dropped', () async {
      // expires_at 28 s ago by this clock: still awaited, for 1 to 2 s more.
      final lately = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 28;
      h.sip.connectionState.value = SipConnectionState.disconnected;
      expect(h.client.handleIncomingPush(push(expiresAt: lately)), isTrue);
      expect(h.sip.hasPendingClaim, isTrue);
      await h.settle(2100);
      expect(statuses().last, VobizPushCallStatus.expired);
      expect(h.sip.hasPendingClaim, isFalse);
      expect(h.client.pushedCall, isNull);
    });

    test('a phone whose clock runs ahead: a push 20 s past its expiry by this clock is still claimed', () async {
      final skewed = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 20;
      expect(h.client.handleIncomingPush(push(expiresAt: skewed)), isTrue);
      expect(headerOf(h.sent.single, 'X-Index'), '4211');
      await h.settle();
      expect(statuses(), <VobizPushCallStatus>[VobizPushCallStatus.claiming]);
    });

    test('a push without a hold does not parse, and a stale one is not acted on', () {
      expect(VobizIncomingPush.tryParse(<String, Object?>{'type': 'incoming_call', 'call_id': 'c-1'}), isNull);
      expect(h.client.handleIncomingPush(push(expiresAt: 1000)), isFalse);
      expect(h.sent, isEmpty);
      expect(updates, isEmpty);
    });
  });

  group('how long a pushed call is awaited', () {
    List<VobizPushCallStatus> awaitPush(Map<String, Object?> data, Duration first, Duration then) {
      late List<VobizPushCallStatus> seen;
      fakeAsync((FakeAsync async) {
        final h = harness.Harness();
        h.sip.connectionState.value = SipConnectionState.disconnected;
        final updates = <VobizPushCallUpdate>[];
        h.client.pushCallUpdates.listen(updates.add);
        expect(h.client.handleIncomingPush(VobizIncomingPush.tryParse(data)!), isTrue);
        async.elapse(first);
        expect(updates.map((u) => u.status), isNot(contains(VobizPushCallStatus.expired)));
        async.elapse(then);
        seen = updates.map((u) => u.status).toList();
        h.dispose();
        async.elapse(const Duration(seconds: 1));
      });
      return seen;
    }

    test('an expiry far in the future is awaited 60 s at most', () {
      final farFuture = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      expect(awaitPush(vobizPush(expiresAt: farFuture), const Duration(seconds: 59), const Duration(seconds: 2)).last,
          VobizPushCallStatus.expired);
    });

    test('a push without an expiry is awaited for the registrar\'s 30 s hold', () {
      expect(
          awaitPush(vobizPush()..remove('expires_at'), const Duration(seconds: 29), const Duration(seconds: 2)).last,
          VobizPushCallStatus.expired);
    });

    test('an expiry outside what a DateTime holds reads as none instead of throwing', () {
      final push = VobizIncomingPush.tryParse(<String, Object?>{...vobizPush(), 'expires_at': '9223372036854775807'});
      expect(push, isNotNull);
      expect(push!.expiresAt, isNull);
    });
  });

  group('claiming against a registrar', () {
    late FakeSipServer server;
    late VobizClient client;
    late List<VobizPushCallStatus> updates;

    setUp(() async {
      server = FakeSipServer();
      await server.start();
      updates = <VobizPushCallStatus>[];
      client = VobizClient.withServices(
        sip: SIPService(wsUrl: server.url, sipServer: 'registrar.vobiz.ai'),
        peer: harness.FakePeer(),
        config: SdkConfig(
            wsUrl: server.url,
            reconnectPolicy: const ReconnectPolicy(
                initialDelay: Duration(milliseconds: 20), maxDelay: Duration(milliseconds: 40), jitter: 0, maxAttempts: 2)),
        connectivityMonitor: FakeConnectivityMonitor(),
      );
      client.pushCallUpdates.listen((u) => updates.add(u.status));
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    Future<void> signIn() => client.connectWithCredentials(const CredentialConfig(username: 'play1', password: 'secret'));

    test('a closed app: the push first, then the sign-in, whose REGISTER claims the call', () async {
      expect(client.handleIncomingPush(VobizIncomingPush.tryParse(vobizPush())!), isTrue);
      await signIn();
      await eventually(() => updates.contains(VobizPushCallStatus.claimed));
      expect(headerOf(server.registers.first, 'X-Index'), '4211');
      expect(updates.first, VobizPushCallStatus.claiming);
    });

    test('after reconnecting gave up, a push reconnects at once and claims the call', () async {
      await signIn();
      await eventually(() => client.isConnected);
      server.acceptConnections = false;
      await server.dropAll();
      await eventually(() => client.connectionState == ConnectionStateStatus.failed, reason: 'gave up');

      server.acceptConnections = true;
      expect(client.handleIncomingPush(VobizIncomingPush.tryParse(vobizPush())!), isTrue);
      await eventually(() => updates.contains(VobizPushCallStatus.claimed));
      expect(server.registers.where((m) => headerOf(m, 'X-Index') == '4211'), isNotEmpty);
    });
  });

  group('VobizClient.disconnect', () {
    test('signs off with REGISTER Expires: 0 by default', () async {
      final h = harness.Harness();
      h.sip.connectionState.value = SipConnectionState.connected;
      await h.client.disconnect();
      final registers = h.sent.where((m) => m.startsWith('REGISTER ')).toList();
      expect(registers, hasLength(1));
      expect(headerOf(registers.single, 'Expires'), '0');
      await h.dispose();
    });

    test('unregister false: the connection goes with no sign-off, as a killed app goes, so Vobiz keeps the '
        'registration and can push', () async {
      final h = harness.Harness();
      h.sip.connectionState.value = SipConnectionState.connected;
      await h.client.disconnect(unregister: false);
      expect(h.sent.where((m) => m.startsWith('REGISTER ')), isEmpty);
      expect(h.client.isConnected, isFalse);
      expect(h.client.sipUsername, isNull, reason: 'signed out locally all the same');
      await h.dispose();
    });
  });

  group('VobizPushDevices', () {
    late List<http.Request> requests;
    late int status;
    late String reply;
    late VobizPushDevices devices;

    setUp(() {
      requests = <http.Request>[];
      status = 200;
      reply = '{"status":"ok"}';
      devices = VobizPushDevices(
        authHeaders: () => VobizPushDevices.accountHeaders(' MA_TESTACCT ', 'tok', unsafeDemo: true),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(reply, status);
        }),
      );
    });

    const device = VobizPushDevice(
      deviceId: 'install-1',
      pushToken: 'fcm-token',
      sipUsername: 'play1',
      appBundleId: 'ai.vobiz.vobiz_webrtc_example',
      appVersion: '1.0.0',
      sdkVersion: VobizClient.sdkVersion,
    );

    test('register: POST /api/v1/devices/register with the SIP user it is for', () async {
      await devices.register(device);
      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.vobiz.ai/api/v1/devices/register');
      expect(r.headers['X-Auth-ID'], 'MA_TESTACCT');
      expect(r.headers['X-Auth-Token'], 'tok');
      expect(jsonDecode(r.body), <String, String>{
        'device_id': 'install-1',
        'push_token': 'fcm-token',
        'platform': 'android',
        'push_type': 'voip',
        'app_bundle_id': 'ai.vobiz.vobiz_webrtc_example',
        'app_version': '1.0.0',
        'sdk_version': '0.2.0',
        'sip_username': 'play1',
      });
    });

    test('logout: DELETE /api/v1/devices/logout with the device id', () async {
      await devices.logout('install-1');
      final r = requests.single;
      expect(r.method, 'DELETE');
      expect(r.url.path, '/api/v1/devices/logout');
      expect(jsonDecode(r.body), <String, String>{'device_id': 'install-1'});
    });

    test('a refusal says what Vobiz said', () async {
      status = 403;
      reply = '{"message":"auth_id does not match authenticated account"}';
      await expectLater(
        devices.register(device),
        throwsA(isA<VobizException>()
            .having((e) => e.code, 'code', 'push_device_failed')
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.message, 'message', contains('auth_id does not match'))),
      );
    });

    test('no SIP user, no registration: it would never be pushed', () {
      expect(
        () => devices.register(const VobizPushDevice(
            deviceId: 'd', pushToken: 't', sipUsername: ' ', appBundleId: 'b')),
        throwsArgumentError,
      );
    });

    test('the account headers need the explicit demo opt-in', () {
      expect(() => VobizPushDevices.accountHeaders('MA_TESTACCT', 'tok', unsafeDemo: false),
          throwsA(isA<VobizDemoModeRequiredException>()));
    });

    test('a path on baseUrl is kept in front of the prefix', () async {
      final proxied = VobizPushDevices(
        baseUrl: Uri.parse('https://api.example.com/vobiz/'),
        pathPrefix: 'push/devices/',
        authHeaders: () => const <String, String>{'Authorization': 'Bearer s'},
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      await proxied.register(device);
      expect(requests.single.url.toString(), 'https://api.example.com/vobiz/push/devices/register');
      // The sample server's form: an origin and an absolute prefix.
      final sample = VobizPushDevices(
        baseUrl: Uri.parse('https://bridge.example.com'),
        pathPrefix: '/push/devices',
        authHeaders: () => const <String, String>{},
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      await sample.logout('install-1');
      expect(requests.last.url.toString(), 'https://bridge.example.com/push/devices/logout');
    });

    test('a reply that stalls after its headers times out too', () async {
      final stalled = VobizPushDevices(
        authHeaders: () => const <String, String>{},
        timeout: const Duration(milliseconds: 50),
        httpClient: MockClient.streaming(
            (_, __) async => http.StreamedResponse(StreamController<List<int>>().stream, 200)),
      );
      await expectLater(
          stalled.register(device).timeout(const Duration(seconds: 2)),
          throwsA(isA<VobizException>()
              .having((e) => e.code, 'code', VobizErrorCode.pushDeviceFailed)
              .having((e) => e.message, 'message', contains('did not answer'))));
    });

    test('a timeout is a failure, not a hang', () async {
      final slow = VobizPushDevices(
        authHeaders: () => const <String, String>{},
        timeout: const Duration(milliseconds: 20),
        httpClient: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(slow.register(device),
          throwsA(isA<VobizException>().having((e) => e.message, 'message', contains('did not answer'))));
    });
  });
}
