// Client and SIP checks: the access token's remaining time belongs to the
// current token, credentials are forgotten at sign-out, the account
// credentials go only over HTTPS, cleartext SIP is refused in release
// builds, the ICE servers can be changed for the next call, and the one
// media ICE restart is not used up while a hold is renegotiating.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';
import 'network_fakes.dart';
import 'sip_test_support.dart';

void main() {
  test('the access token\'s remaining time is forgotten when the token changes', () {
    final sent = <String>[];
    final s = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')..debugOnSend = sent.add;
    s.registerWithAccessToken('agent_MA1', 'h.c1.s');
    s.debugReceive(respond(sent.last, 200, 'OK', headers: <String>['X-vobiz-Jwt: expires=100;epoch-exp=1762900030']));
    expect(s.accessTokenExpiresIn, 100);

    s.updateAccessToken('h.c2.s');
    expect(s.accessTokenExpiresIn, isNull, reason: 'that was the old token');
    expect(s.refreshRegistration(), isFalse, reason: 'not connected in this test');
    s.registerWithAccessToken('agent_MA1', 'h.c2.s');
    s.debugReceive(respond(sent.last, 200, 'OK'));
    expect(s.accessTokenExpiresIn, isNull, reason: 'a 200 without X-vobiz-Jwt says nothing about the new token');

    s.debugReceive(respond(sent.last, 200, 'OK'));
    s.registerWithAccessToken('agent_MA1', 'h.c3.s');
    expect(s.accessTokenExpiresIn, isNull);
  });

  test('a caller ID needs its plus, the one E.164 rule transfers and conferences use too', () {
    expect(() => VobizClient.buildCallHeaders(callerId: '919876543210'), throwsArgumentError);
    expect(VobizClient.buildCallHeaders(callerId: '+919876543210')[VobizSipHeaders.callerId], '+919876543210');
  });

  test('sign-out leaves no password or token in the SIP layer', () async {
    final h = Harness();
    expect(h.sip.debugHasCredentials, isTrue);
    await h.client.disconnect();
    expect(h.sip.debugHasCredentials, isFalse);
    await h.dispose();
  });

  test('updateIceConfig gives the next call the new servers', () async {
    final h = Harness();
    const turn = IceConfig(servers: <IceServerConfig>[
      IceServerConfig(urls: <String>['turns:turn.example.com:443?transport=tcp'], username: 'u', credential: 'c'),
    ]);
    h.client.updateIceConfig(turn);
    expect(h.peer.iceConfig, same(turn));
    await h.dispose();
  });

  group('the account credentials go only over HTTPS', () {
    late List<http.Request> requests;

    VobizClient demoClient(String backendUrl) => VobizClient(
          config: SdkConfig(backendUrl: backendUrl, unsafeDemoZeroConfig: true, watchNetwork: false),
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{"error":"nope"}', 500);
          }),
          lifecycleMonitor: const NoAppLifecycleMonitor(),
        );

    setUp(() => requests = <http.Request>[]);

    test('a cleartext backendUrl is refused before anything is sent', () async {
      final client = demoClient('http://demo.example.com');
      await expectLater(client.connectWithAuthToken(authId: 'MA1', authToken: 'secret'), throwsArgumentError);
      expect(requests, isEmpty);
      await client.dispose();
    });

    test('https, and http to this device or an emulator\'s host, are allowed', () async {
      for (final url in <String>['https://demo.example.com', 'http://10.0.2.2:3000', 'http://127.0.0.1:3000']) {
        final client = demoClient(url);
        await expectLater(client.connectWithAuthToken(authId: 'MA1', authToken: 'secret'),
            throwsA(isA<VobizException>()), reason: url);
        await client.dispose();
      }
      expect(requests, hasLength(3));
    });
  });

  test('cleartext SIP is refused in a release build, except to this device', () {
    expect(SIPService.refusesCleartext(Uri.parse('ws://registrar.example.com/'), release: true), isTrue);
    expect(SIPService.refusesCleartext(Uri.parse('ws://127.0.0.1:5063/'), release: true), isFalse);
    expect(SIPService.refusesCleartext(Uri.parse('wss://registrar.vobiz.ai:5063/'), release: true), isFalse);
    expect(SIPService.refusesCleartext(Uri.parse('ws://registrar.example.com/'), release: false), isFalse);
  });

  test('connect() closes a socket still open from before', () async {
    final server = FakeSipServer();
    await server.start();
    final s = SIPService(wsUrl: server.url, sipServer: 'registrar.vobiz.ai');
    final old = FakeSocket();
    s.debugAttachSocket(old);
    await s.connect();
    expect(old.fakeSink.closed, isTrue);
    expect(s.connectionState.value, SipConnectionState.connected);
    await s.disconnect();
    await server.stop();
  });

  test('waitForRecording says at once that the shared demo list is off limits, without polling', () async {
    final client = VobizClient(config: const SdkConfig(watchNetwork: false), lifecycleMonitor: const NoAppLifecycleMonitor());
    await expectLater(
        client.waitForRecording('uuid', interval: const Duration(seconds: 5)).timeout(const Duration(seconds: 1)),
        throwsA(isA<VobizException>().having((e) => e.code, 'code', VobizErrorCode.recordingsFailed)));
    await client.dispose();
  });

  test('ICE lost while a hold renegotiates: the one restart waits for the next report', () async {
    final h = await answeredCall(grace: const Duration(seconds: 2));
    final id = h.client.currentCallId!;
    final holding = h.client.hold();
    await h.settle();
    h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateFailed);
    await h.settle();
    expect(h.peer.iceRestarts, isEmpty, reason: 'the hold re-INVITE is in flight');
    h.respondToReInvite(200, 'OK', body: 'v=0\r\na=recvonly');
    await holding;
    h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateFailed);
    await h.settle();
    expect(h.peer.iceRestarts, <String>['begin']);
    await h.dispose();
  });
}
