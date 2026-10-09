// ignore_for_file: implementation_imports
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/src/backend/webhook_server_api.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Header rules: must match vobiz-webrtc-sdk/lib/utils/headers.ts ──────────

  group('VobizSipHeaders', () {
    test('accepts X-VH- names of 1-19 letters, digits or hyphens', () {
      expect(VobizSipHeaders.validateName('X-VH-Order-Id'), isNull);
      expect(VobizSipHeaders.validateName('x-vh-lowercase'), isNull);
      expect(VobizSipHeaders.validateName('X-VH-${'a' * 19}'), isNull);
    });

    test('rejects names without the prefix, too long, or with other characters', () {
      expect(VobizSipHeaders.validateName('Order-Id'), 'Must start with X-VH-');
      expect(VobizSipHeaders.validateName('X-VH-${'a' * 20}'), isNotNull);
      expect(VobizSipHeaders.validateName('X-VH-Order_Id'), isNotNull);
      expect(VobizSipHeaders.validateName('X-VH-'), isNotNull);
      expect(VobizSipHeaders.validateName('  '), 'Name is required');
    });

    test('accepts the JWT header and gives it a 500-character value limit', () {
      expect(VobizSipHeaders.validateName('X-Vobiz-JWT'), isNull);
      expect(VobizSipHeaders.validateValue('X-Vobiz-JWT', 'a' * 500), isNull);
      expect(VobizSipHeaders.validateValue('X-Vobiz-JWT', 'a' * 501), isNotNull);
    });

    test('values allow A-Z a-z 0-9 _ - + ( ) % . up to 120 characters', () {
      expect(VobizSipHeaders.validateValue('X-VH-A', 'A1234_-+()%.'), isNull);
      expect(VobizSipHeaders.validateValue('X-VH-A', 'a' * 120), isNull);
      expect(VobizSipHeaders.validateValue('X-VH-A', 'a' * 121), isNotNull);
      expect(VobizSipHeaders.validateValue('X-VH-A', 'has space'), isNotNull);
      expect(VobizSipHeaders.validateValue('X-VH-A', 'sip:a@b'), isNotNull);
      expect(VobizSipHeaders.validateValue('X-VH-A', ''), 'Value is required');
    });

    test('check keeps valid headers and explains every rejected one', () {
      final result = VobizSipHeaders.check(<String, String>{
        'X-VH-Order-Id': 'A1234',
        'Order': 'nope',
        'X-VH-Plan': 'has space',
        'x-vh-order-id': 'B5678',
      });
      expect(result.valid, <String, String>{'X-VH-Order-Id': 'A1234'});
      expect(result.errors, hasLength(3));
      expect(result.errors.join(' '), contains('duplicate header'));
      expect(result.isValid, isFalse);
    });

    test('pick returns only the custom headers on a parsed INVITE', () {
      const raw = 'INVITE sip:play1@registrar.vobiz.ai SIP/2.0\r\n'
          'From: <sip:+919876543210@registrar.vobiz.ai>;tag=abc\r\n'
          'To: <sip:play1@registrar.vobiz.ai>\r\n'
          'Call-ID: in-1\r\n'
          'CSeq: 1 INVITE\r\n'
          'X-Calluuid: 11111111-2222-3333-4444-555555555555\r\n'
          'X-VH-Order-Id: A1234\r\n'
          'X-VH-Bad: has space\r\n'
          'X-Vobiz-JWT: abc.def\r\n'
          'Content-Length: 0\r\n'
          '\r\n';
      final msg = SipParser.parse(raw);
      expect(VobizSipHeaders.pick(msg.headers), <String, String>{
        'X-VH-Order-Id': 'A1234',
        'X-Vobiz-JWT': 'abc.def',
      });
      expect(msg.header('x-calluuid'), '11111111-2222-3333-4444-555555555555');
    });

    test('toXml strips the prefix, URL-encodes values and skips non-alphanumeric names', () {
      final xml = VobizSipHeaders.toXml(<String, String>{
        'X-VH-OrderId': 'A1234',
        'X-VH-Note': '50%',
        'X-VH-Order-Id': 'skipped',
      });
      expect(xml.value, 'OrderId=A1234,Note=50%25');
      expect(xml.skipped, <String>['X-VH-Order-Id']);
    });
  });

  // ── What makeCall sends ──────────────────────────────────────────────────────

  group('VobizClient.buildCallHeaders', () {
    test('turns caller ID, record and Dial-User into the reserved headers', () {
      final headers = VobizClient.buildCallHeaders(
        headers: <String, String>{'X-VH-Order-Id': 'A1234'},
        callerId: '+919876543210',
        record: true,
        dialUser: 'sip:play123@registrar.vobiz.ai',
      );
      expect(headers, <String, String>{
        'X-VH-Order-Id': 'A1234',
        'X-VH-Caller-ID': '+919876543210',
        'X-VH-Record': 'true',
        'X-VH-DialUser': 'play123',
      });
    });

    test('sends nothing extra when no options are given', () {
      expect(VobizClient.buildCallHeaders(), isEmpty);
    });

    test('refuses an invalid caller ID before dialling', () {
      expect(() => VobizClient.buildCallHeaders(callerId: '98765'),
          throwsArgumentError);
      expect(() => VobizClient.buildCallHeaders(callerId: '+91 98765 43210'),
          throwsArgumentError);
    });

    test('refuses invalid custom headers before dialling, naming each one', () {
      expect(
        () => VobizClient.buildCallHeaders(
            headers: <String, String>{'Bad': 'x', 'X-VH-A': 'has space'}),
        throwsA(isA<ArgumentError>().having(
            (e) => '${e.message}', 'message', allOf(contains('Bad'), contains('X-VH-A')))),
      );
    });

    test('endpointUsername strips the scheme and domain', () {
      expect(VobizClient.endpointUsername('sip:play1@registrar.vobiz.ai'), 'play1');
      expect(VobizClient.endpointUsername('play1@registrar.vobiz.ai'), 'play1');
      expect(VobizClient.endpointUsername(' play1 '), 'play1');
      expect(VobizClient.endpointUsername(null), '');
    });
  });

  // ── SIP messages ─────────────────────────────────────────────────────────────

  group('SipBuilder', () {
    // Vobiz's registrar (lua preserve_source_ip) rewrites the REGISTER Contact
    // with this exact expression; only a contact it matches can be rung.
    final registrarRewrite = RegExp(r'@[a-z0-9]+.invalid;');

    test('registers a JsSIP-style .invalid contact the registrar can rewrite', () {
      final service = SIPService(wsUrl: 'wss://registrar.vobiz.ai:5063', sipServer: 'registrar.vobiz.ai');
      final contact = service.contactUri;
      expect(contact, matches(RegExp(r'^sip:[a-z0-9]{8}@[a-z0-9]{12}\.invalid;transport=ws$')));
      expect(registrarRewrite.hasMatch(contact), isTrue);
      expect(contact, isNot(contains('registrar.vobiz.ai')));

      final register = SipParser.parse(SipBuilder.register(
        sipServer: 'registrar.vobiz.ai',
        username: 'play1',
        contactUri: contact,
        localTag: 'tag1',
        callId: 'reg1',
        cseq: 1,
      ));
      expect(register.header('Contact'), '<$contact>');
      expect(register.header('To'), '<sip:play1@registrar.vobiz.ai>');
      expect(register.header('User-Agent'), 'vobiz_flutter_sdk');
    });

    test('each client gets its own contact', () {
      final a = SIPService(wsUrl: 'wss://x', sipServer: 'registrar.vobiz.ai').contactUri;
      final b = SIPService(wsUrl: 'wss://x', sipServer: 'registrar.vobiz.ai').contactUri;
      expect(a, isNot(b));
    });

    test('INVITE and 200 OK carry the registered contact', () {
      const contact = 'sip:abcd1234@abcdefgh1234.invalid;transport=ws';
      final invite = SipParser.parse(SipBuilder.invite(
        sipServer: 'registrar.vobiz.ai',
        fromUser: 'play1',
        contactUri: contact,
        toUser: '+919876543210',
        localTag: 'tag1',
        callId: 'call1',
        cseq: 2,
        sdp: 'v=0',
      ));
      expect(invite.header('Contact'), '<$contact>');
      expect(invite.header('From'), '<sip:play1@registrar.vobiz.ai>;tag=tag1');

      final incoming = SipParser.parse('INVITE sip:abcd1234@203.0.113.5:40000;transport=ws SIP/2.0\r\n'
          'Via: SIP/2.0/WSS 10.0.0.1;branch=z9hG4bKx\r\n'
          'From: <sip:+918000000000@registrar.vobiz.ai>;tag=far\r\n'
          'To: <sip:play1@registrar.vobiz.ai>\r\n'
          'Call-ID: in1\r\n'
          'CSeq: 1 INVITE\r\n'
          'Content-Length: 0\r\n\r\n');
      final ok = SipParser.parse(SipBuilder.ok200(
        invite: incoming,
        contactUri: contact,
        sipServer: 'registrar.vobiz.ai',
        localTag: 'tag1',
        sdp: 'v=0',
      ));
      expect(ok.header('Contact'), '<$contact>');
    });

    test('INVITE carries the custom headers ahead of the body', () {
      final invite = SipBuilder.invite(
        sipServer: 'registrar.vobiz.ai',
        fromUser: 'play1',
        contactUri: 'sip:abcd1234@abcdefgh1234.invalid;transport=ws',
        toUser: '+919876543210',
        localTag: 'tag1',
        callId: 'call1',
        cseq: 2,
        sdp: 'v=0',
        extraHeaders: const <String, String>{
          'X-VH-Caller-ID': '+919999999999',
          'X-VH-Record': 'true',
        },
      );
      final parsed = SipParser.parse(invite);
      expect(parsed.header('X-VH-Caller-ID'), '+919999999999');
      expect(parsed.header('X-VH-Record'), 'true');
      expect(parsed.header('Allow'), contains('INFO'));
      expect(parsed.body, 'v=0');
      expect(invite.indexOf('X-VH-Record'), lessThan(invite.indexOf('Content-Type')));
    });

    test('INVITE without headers is unchanged apart from INFO in Allow', () {
      final invite = SipBuilder.invite(
        sipServer: 'registrar.vobiz.ai',
        fromUser: 'play1',
        contactUri: 'sip:abcd1234@abcdefgh1234.invalid;transport=ws',
        toUser: '+919876543210',
        localTag: 'tag1',
        callId: 'call1',
        cseq: 2,
        sdp: 'v=0',
      );
      expect(invite, isNot(contains('X-VH-')));
    });

    test('DTMF INFO matches what JsSIP sends', () {
      final body = SipBuilder.dtmfRelayBody('5');
      expect(body, 'Signal=5\r\nDuration=100');
      final info = SipBuilder.info(
        requestUri: 'sip:gw@10.0.0.1:5060',
        fromUser: 'play1',
        toHeader: '<sip:+919876543210@registrar.vobiz.ai>;tag=remote',
        sipServer: 'registrar.vobiz.ai',
        localTag: 'tag1',
        callId: 'call1',
        cseq: 7,
        contentType: 'application/dtmf-relay',
        body: body,
      );
      final parsed = SipParser.parse(info);
      expect(parsed.method, 'INFO');
      expect(parsed.header('CSeq'), '7 INFO');
      expect(parsed.header('Content-Type'), 'application/dtmf-relay');
      expect(parsed.header('Content-Length'), '${utf8.encode(body).length}');
      expect(info.startsWith('INFO sip:gw@10.0.0.1:5060 SIP/2.0'), isTrue);
    });
  });

  // ── Webhook server requests (the Playground's /api routes) ──────────────────

  group('WebhookServerApi', () {
    test('setup posts what the Playground posts and reads the credentials back', () async {
      late http.Request seen;
      final api = WebhookServerApi(client: MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, Object>{
            'success': true,
            'message': 'Reused existing infrastructure',
            'sip_username': 'play123',
            'sip_password': 'Pwd42',
            'application_id': '987',
          }),
          200,
        );
      }));

      final session = await api.setup(
        webhookUrl: 'https://hooks.example.test/',
        voiceApiUrl: 'https://api.vobiz.ai/',
        authId: 'MA_TEST0001',
        authToken: 'token-1',
      );

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://hooks.example.test/api/setup');
      expect(jsonDecode(seen.body), <String, String>{
        'auth_id': 'MA_TEST0001',
        'api_username': 'MA_TEST0001',
        'auth_token': 'token-1',
        'voice_api_url': 'https://api.vobiz.ai',
        'my_domain': 'https://hooks.example.test',
      });
      expect(session.sipUsername, 'play123');
      expect(session.sipPassword, 'Pwd42');
      expect(session.applicationId, '987');
      expect(session.reusedExisting, isTrue);
    });

    test('setup surfaces the server error', () async {
      final api = WebhookServerApi(client: MockClient((_) async => http.Response(
          jsonEncode(<String, String>{'error': 'Missing required API credentials'}), 400)));
      expect(
        () => api.setup(
            webhookUrl: 'https://h.test', voiceApiUrl: 'https://a.test', authId: 'x', authToken: 'y'),
        throwsA(isA<VobizException>()
            .having((e) => e.code, 'code', 'setup_failed')
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'Missing required API credentials')),
      );
    });

    test('setup refuses a reply without credentials', () async {
      final api = WebhookServerApi(
          client: MockClient((_) async => http.Response('{"success":true}', 200)));
      expect(
        () => api.setup(
            webhookUrl: 'https://h.test', voiceApiUrl: 'https://a.test', authId: 'x', authToken: 'y'),
        throwsA(isA<VobizException>()),
      );
    });

    test('transfer posts the Redirect API fields', () async {
      late http.Request seen;
      final api = WebhookServerApi(client: MockClient((request) async {
        seen = request;
        return http.Response('{"success":true,"message":"call transferred"}', 200);
      }));
      final reply = await api.transfer(
        webhookUrl: 'https://h.test',
        voiceApiUrl: 'https://api.vobiz.ai',
        authId: 'MA_TEST0001',
        authToken: 'token-1',
        callUuid: 'uuid-1',
        leg: TransferLeg.bLeg,
        sipUser: 'play9',
        callerId: '+919999999999',
        sipHeaders: 'OrderId=A1234',
      );
      expect(seen.url.toString(), 'https://h.test/api/transfer');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['call_uuid'], 'uuid-1');
      expect(body['legs'], 'bleg');
      expect(body['user'], 'play9');
      expect(body['number'], '');
      expect(body['sip_headers'], 'OrderId=A1234');
      expect(body['my_domain'], 'https://h.test');
      expect(reply['message'], 'call transferred');
    });

    test('recordings reads the list', () async {
      final api = WebhookServerApi(client: MockClient((request) async {
        expect(request.url.toString(), 'https://h.test/api/recording?list=1');
        return http.Response(
          jsonEncode(<String, Object>{
            'recordings': <Object>[
              <String, Object>{
                'recordingId': 'r1',
                'callUUID': 'uuid-1',
                'url': 'https://media.example/r1.mp3',
                'durationSecs': '12',
                'endReason': '',
                'receivedAt': 1760000000000,
              },
            ],
          }),
          200,
        );
      }));
      final list = await api.recordings(webhookUrl: 'https://h.test');
      expect(list, hasLength(1));
      expect(list.first.callUuid, 'uuid-1');
      expect(list.first.durationSecs, 12);
      expect(list.first.endReason, isNull);
      expect(list.first.receivedAt.millisecondsSinceEpoch, 1760000000000);
    });
  });

  // ── Client guard rails ───────────────────────────────────────────────────────

  group('VobizClient', () {
    test('starts signed out, with the hosted webhook server as default', () {
      final client = VobizClient();
      expect(client.authMode, VobizAuthMode.none);
      expect(client.backendUrl, SdkConfig.defaultWebhookUrl);
      expect(client.sipUsername, isNull);
      expect(client.callState, CallStateStatus.idle);
    });

    test('a rejected Auth Token gets a readable explanation and opens no socket', () async {
      final client = VobizClient(
        httpClient: MockClient((_) async => http.Response(
            jsonEncode(<String, String>{'error': 'Could not resolve Application ID'}), 500)),
      );
      final errors = <ErrorEvent>[];
      final sub = client.errorEvents.listen(errors.add);

      await expectLater(
        client.connectWithAuthToken(authId: 'MA_TEST0001', authToken: 'wrong'),
        throwsA(isA<VobizException>().having(
            (e) => e.message, 'message', contains('did not accept that Auth ID and Auth Token'))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(errors.single.code, 'setup_failed');
      expect(client.authMode, VobizAuthMode.none);
      expect(client.connectionState, ConnectionStateStatus.failed);
      await sub.cancel();
    });

    test('Zero-Config needs both values', () {
      final client = VobizClient();
      expect(() => client.connectWithAuthToken(authId: ' ', authToken: 'x'),
          throwsArgumentError);
    });

    test('calling, DTMF and transfer refuse to run without a call', () {
      final client = VobizClient();
      expect(() => client.makeCall('+919876543210'), throwsStateError);
      expect(() => client.sendDtmf('1'), throwsStateError);
      expect(() => client.transferCall(number: '+919876543210'), throwsStateError);
      expect(() => client.sendDtmf('Z'), throwsArgumentError);
    });
  });

  group('Models', () {
    test('ZeroConfigSession needs credentials in the reply', () {
      expect(() => ZeroConfigSession.fromJson(const <String, dynamic>{}),
          throwsFormatException);
      final created = ZeroConfigSession.fromJson(const <String, dynamic>{
        'sip_username': 'play1',
        'sip_password': 'p',
        'application_id': 1,
        'message': 'Provisioned new infrastructure',
      });
      expect(created.reusedExisting, isFalse);
      expect(created.applicationId, '1');
    });

    test('TransferLeg maps to the Redirect API values', () {
      expect(TransferLeg.aLeg.apiValue, 'aleg');
      expect(TransferLeg.bLeg.apiValue, 'bleg');
    });
  });
}
