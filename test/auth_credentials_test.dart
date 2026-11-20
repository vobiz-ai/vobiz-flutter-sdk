// Auth model: the account Auth Token never leaves the device unless the app
// opts into demo mode, and per-user SIP credentials come from the app's own
// backend through a provider that is asked again when they are refused.
// ignore_for_file: implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/src/backend/webhook_server_api.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

/// A loopback SIP-over-WebSocket registrar. It answers REGISTER with 200 when
/// the From user is in [accepted] and 403 otherwise, and records every user
/// that tried.
class _FakeRegistrar {
  _FakeRegistrar(this.accepted);

  final Set<String> accepted;
  final List<String> attempts = <String>[];
  late final HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];

  String get wsUrl => 'ws://127.0.0.1:${_server.port}/';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request,
          protocolSelector: (protocols) => 'sip');
      _sockets.add(ws);
      ws.listen((data) {
        final msg = '$data';
        if (!msg.startsWith('REGISTER ')) return;
        final lines = msg.split(RegExp(r'\r?\n'));
        String header(String name) => lines.firstWhere(
            (l) => l.toLowerCase().startsWith('${name.toLowerCase()}:'),
            orElse: () => '');
        final from = header('From');
        final user = RegExp(r'sip:([^@]+)@').firstMatch(from)?.group(1) ?? '';
        attempts.add(user);
        final ok = accepted.contains(user);
        ws.add(<String>[
          ok ? 'SIP/2.0 200 OK' : 'SIP/2.0 403 Forbidden',
          header('Via'),
          from,
          '${header('To')};tag=reg',
          header('Call-ID'),
          header('CSeq'),
          if (ok) 'Expires: 600',
          'Content-Length: 0',
          '',
          '',
        ].join('\r\n'));
      });
    });
  }

  Future<void> stop() async {
    for (final ws in _sockets) {
      await ws.close();
    }
    await _server.close(force: true);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('demo mode (account Auth Token on the device)', () {
    test('is off by default', () {
      expect(const SdkConfig().unsafeDemoZeroConfig, isFalse);
    });

    test('connectWithAuthToken refuses without the flag and sends nothing', () async {
      var requests = 0;
      final client = VobizClient(
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        client.connectWithAuthToken(authId: 'MA_TEST0001', authToken: 'token-1'),
        throwsA(isA<VobizDemoModeRequiredException>()
            .having((e) => e.code, 'code', VobizErrorCode.demoModeRequired)),
      );
      expect(requests, 0);
      expect(client.authMode, VobizAuthMode.none);
      expect(client.connectionState, ConnectionStateStatus.disconnected);
      await client.dispose();
    });

    test('connectWithAuthToken reaches the webhook server with the flag', () async {
      var requests = 0;
      final client = VobizClient(
        config: const SdkConfig(unsafeDemoZeroConfig: true, autoReconnect: false),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{"error":"nope"}', 500);
        }),
      );
      await expectLater(
        client.connectWithAuthToken(authId: 'MA_TEST0001', authToken: 'token-1'),
        throwsA(isA<VobizException>().having((e) => e.code, 'code', 'setup_failed')),
      );
      expect(requests, 1);
      await client.dispose();
    });

    test('the API layer refuses setup and transfer without the flag', () {
      final api = WebhookServerApi(
          client: MockClient((_) async => fail('no request may be sent')));
      expect(
        () => api.setup(
            webhookUrl: 'https://h.test', voiceApiUrl: 'https://a.test', authId: 'x', authToken: 'y'),
        throwsA(isA<VobizDemoModeRequiredException>()),
      );
      expect(
        () => api.transfer(
            webhookUrl: 'https://h.test',
            voiceApiUrl: 'https://a.test',
            authId: 'x',
            authToken: 'y',
            callUuid: 'u',
            leg: TransferLeg.aLeg,
            number: '+919999999999'),
        throwsA(isA<VobizDemoModeRequiredException>()),
      );
    });

    test('the shared demo server\'s recordings list is demo-only; your own server is not', () async {
      final api = WebhookServerApi(
          client: MockClient((_) async => http.Response('{"recordings":[]}', 200)));
      await expectLater(api.recordings(webhookUrl: SdkConfig.defaultWebhookUrl),
          throwsA(isA<VobizException>().having((e) => e.code, 'code', 'recordings_failed')));
      expect(await api.recordings(webhookUrl: 'https://voice.example.test'), isEmpty);

      final demo = WebhookServerApi(
          allowAccountCredentials: true,
          client: MockClient((_) async => http.Response('{"recordings":[]}', 200)));
      expect(await demo.recordings(webhookUrl: '${SdkConfig.defaultWebhookUrl}/'), isEmpty);
    });
  });

  group('VobizBackendCredentialsProvider', () {
    test('posts the reason with the app headers and reads the credentials', () async {
      late http.Request seen;
      final provider = VobizBackendCredentialsProvider(
        url: Uri.parse('https://voice.example.test/sip-credentials'),
        headers: () async => <String, String>{'Authorization': 'Bearer app-session'},
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
              jsonEncode(<String, String>{
                'sip_username': 'agent42',
                'sip_password': 'pw-1',
                'display_name': 'Asha',
              }),
              200);
        }),
      );
      final creds = await provider(VobizCredentialsRequest.rejected);
      expect(seen.method, 'POST');
      expect(seen.headers['Authorization'], 'Bearer app-session');
      expect(jsonDecode(seen.body), <String, String>{'reason': 'rejected'});
      expect(creds.username, 'agent42');
      expect(creds.password, 'pw-1');
    });

    test('a refusal or an incomplete reply is a VobizCredentialsException', () async {
      final refused = VobizBackendCredentialsProvider(
          url: Uri.parse('https://voice.example.test/c'),
          httpClient: MockClient((_) async => http.Response('no', 401)));
      await expectLater(refused(VobizCredentialsRequest.signIn),
          throwsA(isA<VobizCredentialsException>().having((e) => e.statusCode, 'status', 401)));

      final partial = VobizBackendCredentialsProvider(
          url: Uri.parse('https://voice.example.test/c'),
          httpClient: MockClient((_) async => http.Response('{"sip_username":"a"}', 200)));
      await expectLater(
          partial(VobizCredentialsRequest.signIn), throwsA(isA<VobizCredentialsException>()));
    });
  });

  group('connectWithCredentialsProvider', () {
    late _FakeRegistrar registrar;

    setUp(() async {
      registrar = _FakeRegistrar(<String>{'fresh'});
      await registrar.start();
    });

    tearDown(() => registrar.stop());

    VobizClient newClient() => VobizClient(
          config: SdkConfig(wsUrl: registrar.wsUrl, autoReconnect: false),
        );

    test('asks the provider at sign-in and registers with what it returns', () async {
      registrar.accepted.add('cached');
      final client = newClient();
      final asked = <VobizCredentialsRequest>[];
      final session = await client.connectWithCredentialsProvider((request) async {
        asked.add(request);
        return const CredentialConfig(username: 'cached', password: 'pw');
      });
      await _until(() => client.isConnected);
      expect(client.isConnected, isTrue);
      expect(asked, <VobizCredentialsRequest>[VobizCredentialsRequest.signIn]);
      expect(client.sipUsername, 'cached');
      await session.dispose();
      await client.dispose();
    });

    test('a refused registration asks the provider again and re-registers', () async {
      final client = newClient();
      final asked = <VobizCredentialsRequest>[];
      final session = await client.connectWithCredentialsProvider((request) async {
        asked.add(request);
        return request == VobizCredentialsRequest.signIn
            ? const CredentialConfig(username: 'stale', password: 'old')
            : const CredentialConfig(username: 'fresh', password: 'new');
      });
      await _until(() => client.isConnected);
      expect(client.isConnected, isTrue);
      expect(asked, <VobizCredentialsRequest>[
        VobizCredentialsRequest.signIn,
        VobizCredentialsRequest.rejected,
      ]);
      expect(registrar.attempts, <String>['stale', 'fresh']);
      await session.dispose();
      await client.dispose();
    });

    test('stops after maxRefreshes and reports a VobizRegistrationException', () async {
      final client = newClient();
      var calls = 0;
      final session = await client.connectWithCredentialsProvider((request) async {
        calls++;
        return const CredentialConfig(username: 'stale', password: 'old');
      }, maxRefreshes: 1);
      final failure = await session.failures.first.timeout(const Duration(seconds: 5));
      expect(failure, isA<VobizRegistrationException>());
      expect(calls, 2);
      expect(registrar.attempts, <String>['stale', 'stale']);
      await session.dispose();
      await client.dispose();
    });

    test('refresh() asks the provider with the refresh reason', () async {
      registrar.accepted.add('cached');
      final client = newClient();
      final asked = <VobizCredentialsRequest>[];
      final session = await client.connectWithCredentialsProvider((request) async {
        asked.add(request);
        return request == VobizCredentialsRequest.refresh
            ? const CredentialConfig(username: 'fresh', password: 'rotated')
            : const CredentialConfig(username: 'cached', password: 'pw');
      });
      await _until(() => client.isConnected);
      await session.refresh();
      await _until(() => client.sipUsername == 'fresh' && client.isConnected);
      expect(asked.last, VobizCredentialsRequest.refresh);
      expect(client.sipUsername, 'fresh');
      expect(client.isConnected, isTrue);
      await session.dispose();
      await client.dispose();
    });

    test('a provider that throws fails the sign-in with VobizCredentialsException', () async {
      final client = newClient();
      await expectLater(
        client.connectWithCredentialsProvider((_) async => throw StateError('backend down')),
        throwsA(isA<VobizCredentialsException>()
            .having((e) => e.code, 'code', VobizErrorCode.credentialsFailed)),
      );
      expect(registrar.attempts, isEmpty);
      await client.dispose();
    });
  });

  group('TokenConfig', () {
    test('connect(TokenConfig) registers as displayName, with the token as the SIP password', () async {
      final registrar = _FakeRegistrar(<String>{'u'});
      await registrar.start();
      final client = VobizClient(config: SdkConfig(wsUrl: registrar.wsUrl, autoReconnect: false));
      // ignore: deprecated_member_use_from_same_package
      await client.connect(const TokenConfig(token: 't', displayName: 'u'));
      await _until(() => client.isConnected);
      expect(registrar.attempts, <String>['u']);
      expect(client.authMode, VobizAuthMode.sipDirect);
      await client.dispose();
      await registrar.stop();
    });
  });
}
