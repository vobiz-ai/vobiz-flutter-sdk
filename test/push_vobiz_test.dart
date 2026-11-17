// Incoming calls to a closed app through Vobiz's own push: the registrar
// holds the call, pushes, and sends the held INVITE to the REGISTER that
// hands back the push's hold reference (X-Index, X-Label,
// X-vobiz-Registrar-Info).
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'call_harness.dart' as harness;
import 'sip_test_support.dart';

const String _challenge = 'WWW-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n1", qop="auth"';

/// A push as Vobiz's registrar sends it, through Vobiz's push service.
Map<String, Object?> vobizPush({
  String callId = 'held-call-1@10.0.2.9',
  int? expiresAt,
  bool test = false,
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
      if (test) 'test': '1',
    };

void main() {
  group('reading a Vobiz push', () {
    test('reads the call, the hold reference and an expiry in seconds', () {
      final push = VobizIncomingPush.tryParse(vobizPush(expiresAt: 1762900030))!;
      expect(push.kind, VobizPushKind.incomingCall);
      expect(push.callId, 'held-call-1@10.0.2.9');
      expect(push.callUuid, '5f0c5c7e-0000-4000-8000-000000000001');
      expect(push.caller, 'Asha');
      expect(push.callerNumber, '+918000000000');
      expect(push.callee, 'play1');
      expect(push.isHeldByVobiz, isTrue);
      expect(push.hold!.registerHeaders, <String, String>{
        'X-Index': '4211',
        'X-Label': '1938273',
        'X-vobiz-Registrar-Info': '203.0.113.10',
      });
      // Unix seconds, not milliseconds: read as 1970 it would be stale at once.
      expect(push.expiresAt, DateTime.fromMillisecondsSinceEpoch(1762900030000));
      expect(push.isExpired(DateTime.fromMillisecondsSinceEpoch(1762900029000)), isFalse);
      expect(push.isExpired(DateTime.fromMillisecondsSinceEpoch(1762900030000)), isTrue);
    });

    test('the push bridge\'s milliseconds are still milliseconds', () {
      final push = VobizIncomingPush.tryParse(<String, Object?>{
        'type': 'incoming_call',
        'call_id': 'c-1',
        'expires_at': '1762900030000',
      })!;
      expect(push.expiresAt, DateTime.fromMillisecondsSinceEpoch(1762900030000));
      expect(push.isHeldByVobiz, isFalse);
    });

    test('without all three of index, label and registrar there is no hold', () {
      for (final missing in <String>['index', 'label', 'registrar']) {
        final data = vobizPush()..remove(missing);
        expect(VobizIncomingPush.tryParse(data)!.hold, isNull, reason: 'without $missing');
      }
    });

    test('a held call matches its INVITE by Call-ID only, never by a header or the number', () {
      final push = VobizIncomingPush.tryParse(vobizPush())!;
      expect(push.matchesIncomingCall(headers: const <String, String>{}, sipCallId: 'held-call-1@10.0.2.9'),
          isTrue);
      expect(push.matchesIncomingCall(headers: const <String, String>{}, sipCallId: 'other@10.0.2.9'), isFalse);
      expect(push.matchesIncomingCall(headers: const <String, String>{}), isFalse);
      expect(
          push.matchesIncomingCall(
              headers: <String, String>{'X-VH-PushRef': 'held-call-1@10.0.2.9'}, sipCallId: 'other'),
          isFalse);
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

    test('no INVITE by the push\'s expiry: expired, and the claim is dropped', () async {
      final soon = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1;
      h.sip.connectionState.value = SipConnectionState.disconnected;
      h.client.handleIncomingPush(push(expiresAt: soon));
      expect(h.sip.hasPendingClaim, isTrue);
      await h.settle(2100);
      expect(statuses().last, VobizPushCallStatus.expired);
      expect(h.sip.hasPendingClaim, isFalse);
      expect(h.client.pushedCall, isNull);
    });

    test('a push that is not a call Vobiz holds, a test or a stale one is not acted on', () {
      final bridge = VobizIncomingPush.tryParse(<String, Object?>{'type': 'incoming_call', 'call_id': 'c-1'})!;
      final testPush = VobizIncomingPush.tryParse(vobizPush(test: true))!;
      final stale = push(expiresAt: 1000);
      for (final p in <VobizIncomingPush>[bridge, testPush, stale]) {
        expect(h.client.handleIncomingPush(p), isFalse);
      }
      expect(h.sent, isEmpty);
      expect(updates, isEmpty);
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
        authHeaders: () => VobizPushDevices.accountHeaders(' MA_TESTACCT ', 'tok'),
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
