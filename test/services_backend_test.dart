// The webhook server's /api routes that carry the account Auth Token
// refuse a plain http:// server on the network, even in demo mode.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/src/backend/webhook_server_api.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

void main() {
  group('the account Auth Token is never sent in clear', () {
    late List<Uri> sent;
    late WebhookServerApi api;

    setUp(() {
      sent = <Uri>[];
      api = WebhookServerApi(
        allowAccountCredentials: true,
        client: MockClient((request) async {
          sent.add(request.url);
          return http.Response(
              '{"sip_username":"u","sip_password":"p","app_id":"1","answer_url":"a"}', 200);
        }),
      );
    });

    Future<Object?> setup(String url) =>
        api.setup(webhookUrl: url, voiceApiUrl: 'https://api.vobiz.ai', authId: 'x', authToken: 'y');

    test('Zero-Config Setup refuses http:// on the network and sends nothing', () async {
      await expectLater(
          setup('http://192.168.1.20:8080'),
          throwsA(isA<VobizException>()
              .having((e) => e.code, 'code', 'setup_failed')
              .having((e) => e.message, 'message', contains('https'))));
      expect(sent, isEmpty);
    });

    test('the transfer refuses http:// on the network and sends nothing', () {
      expect(
          () => api.transfer(
              webhookUrl: 'http://hooks.example.test',
              voiceApiUrl: 'https://api.vobiz.ai',
              authId: 'x',
              authToken: 'y',
              callUuid: 'u',
              leg: TransferLeg.aLeg,
              number: '+919999999999'),
          throwsA(isA<VobizException>().having((e) => e.code, 'code', 'transfer_failed')));
      expect(sent, isEmpty);
    });

    test('https, and http to this device or the emulator\'s host, are allowed', () async {
      for (final url in <String>[
        'https://hooks.example.test',
        'http://localhost:8080',
        'http://127.0.0.1:8080/',
        'http://10.0.2.2:8080',
      ]) {
        await setup(url);
      }
      expect(sent, hasLength(4));
    });

    test('a client in demo mode reports the refusal as a failed setup', () async {
      var requests = 0;
      final client = VobizClient(
        config: const SdkConfig(
            unsafeDemoZeroConfig: true, autoReconnect: false, backendUrl: 'http://hooks.example.test'),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final errors = <ErrorEvent>[];
      client.errorEvents.listen(errors.add);
      await expectLater(client.connectWithAuthToken(authId: 'MA_TEST0001', authToken: 'token-1'),
          throwsA(isA<VobizException>().having((e) => e.code, 'code', 'setup_failed')));
      expect(requests, 0);
      expect(client.connectionState, ConnectionStateStatus.failed);
      await Future<void>.delayed(Duration.zero);
      expect(errors.map((e) => e.code), contains('setup_failed'));
      await client.dispose();
    });
  });
}
