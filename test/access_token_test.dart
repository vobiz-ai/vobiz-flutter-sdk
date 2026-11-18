// Access-token (JWT) sign-in: the client registers as <sub>_<iss> with the
// token in X-Vobiz-Jwt instead of a password, sends it on its INVITEs, reports
// the registrar's 10001-10010 reasons, and renews it before it expires.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';

/// A token shaped like the ones `POST /Account/{auth_id}/JWT/Token/` mints.
/// The signature is not checked on the device, so any will do here.
String jwt(Map<String, Object?> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part(<String, String>{'alg': 'HS256', 'typ': 'JWT', 'cty': 'auris;v=1'})}'
      '.${part(claims)}.c2lnbmF0dXJl';
}

int _epoch(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

String token({
  String? sub = 'agent42',
  String iss = 'MA_TESTACCT',
  Duration lifetime = const Duration(hours: 1),
  bool? outgoing = true,
  bool? incoming = true,
  String? app = '12345678901234567',
  DateTime? from,
  String? nonce,
}) {
  final start = from ?? DateTime.now();
  return jwt(<String, Object?>{
    'iss': iss,
    if (sub != null) 'sub': sub,
    'nbf': _epoch(start),
    'exp': _epoch(start.add(lifetime)),
    if (app != null) 'app': app,
    'per': <String, Object?>{
      'voice': <String, Object?>{
        if (incoming != null) 'incoming_allow': incoming,
        if (outgoing != null) 'outgoing_allow': outgoing,
      },
    },
    if (nonce != null) 'jti': nonce,
  });
}

String? header(String message, String name) {
  for (final line in message.split('\r\n')) {
    final i = line.indexOf(':');
    if (i > 0 && line.substring(0, i).trim().toLowerCase() == name.toLowerCase()) {
      return line.substring(i + 1).trim();
    }
  }
  return null;
}

/// A loopback SIP-over-WebSocket registrar that validates access tokens the
/// way Vobiz's does: a REGISTER whose X-Vobiz-Jwt is in [accepted] gets 200
/// with `X-vobiz-Jwt: expires=…;epoch-exp=…`; any other gets 401 with a
/// digest challenge and `X-vobiz-Jwt-Error-Code: [refusalCode]`. INVITEs are
/// recorded and answered 100 Trying.
class _TokenRegistrar {
  final Set<String> accepted = <String>{};
  int refusalCode = 10006;
  final List<String> registers = <String>[];
  final List<String> invites = <String>[];
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
        String echo(String status, List<String> extra) => <String>[
              'SIP/2.0 $status',
              'Via: ${header(msg, 'Via')}',
              'From: ${header(msg, 'From')}',
              'To: ${header(msg, 'To')};tag=reg',
              'Call-ID: ${header(msg, 'Call-ID')}',
              'CSeq: ${header(msg, 'CSeq')}',
              ...extra,
              'Content-Length: 0',
              '',
              '',
            ].join('\r\n');
        if (msg.startsWith('REGISTER ')) {
          registers.add(msg);
          final presented = header(msg, 'X-Vobiz-Jwt');
          if ((header(msg, 'Expires') ?? '') == '0') {
            ws.add(echo('200 OK', const <String>[]));
          } else if (presented != null && accepted.contains(presented)) {
            final exp = DateTime.now().add(const Duration(minutes: 59));
            ws.add(echo('200 OK', <String>[
              'Expires: 600',
              'X-vobiz-Jwt: expires=3540;epoch-exp=${_epoch(exp)}',
            ]));
          } else {
            ws.add(echo('401 Unauthorized', <String>[
              'WWW-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n1"',
              'X-vobiz-Jwt-Error-Code: $refusalCode',
            ]));
          }
        } else if (msg.startsWith('INVITE ')) {
          invites.add(msg);
          ws.add(echo('100 Trying', const <String>[]));
        }
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
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// The SIP layer without a socket: REGISTERs are answered 200 OK on the next
/// microtask, so the provider session can run under fake timers.
class _InstantRegistrar extends SIPService {
  _InstantRegistrar() : super(wsUrl: 'wss://example.invalid', sipServer: sipServer) {
    debugOnSend = (message) {
      sent.add(message);
      if (!message.startsWith('REGISTER ')) return;
      final presented = header(message, 'X-Vobiz-Jwt');
      final notYet = presented != null && (notYetValidOnce.remove(presented));
      final ok = presented != null && !refused.contains(presented) && !notYet;
      scheduleMicrotask(() => debugReceive(<String>[
            ok ? 'SIP/2.0 200 OK' : 'SIP/2.0 401 Unauthorized',
            'Via: ${header(message, 'Via')}',
            'From: ${header(message, 'From')}',
            'To: ${header(message, 'To')};tag=reg',
            'Call-ID: ${header(message, 'Call-ID')}',
            'CSeq: ${header(message, 'CSeq')}',
            if (ok) 'Expires: 600' else 'X-vobiz-Jwt-Error-Code: ${notYet ? 10005 : 10006}',
            'Content-Length: 0',
            '',
            '',
          ].join('\r\n')));
    };
  }

  final List<String> sent = <String>[];
  final Set<String> refused = <String>{};

  /// Tokens refused once as not valid yet (10005), as by a registrar whose
  /// clock is a little behind the one that minted them.
  final Set<String> notYetValidOnce = <String>{};

  List<String> get registerTokens => <String>[
        for (final m in sent)
          if (m.startsWith('REGISTER ')) header(m, 'X-Vobiz-Jwt') ?? '',
      ];

  @override
  Future<void> connect() async {
    connectionState.value = SipConnectionState.connected;
  }
}

void main() {
  group('VobizAccessToken.parse', () {
    test('reads the identity, expiry, app and grants', () {
      final start = DateTime.utc(2026, 10, 25, 12);
      final t = VobizAccessToken.parse(token(from: start, outgoing: false));
      expect(t.accountId, 'MA_TESTACCT');
      expect(t.subject, 'agent42');
      expect(t.sipUsername, 'agent42_MA_TESTACCT');
      expect(t.appId, '12345678901234567');
      expect(t.notBefore, start);
      expect(t.expiresAt, start.add(const Duration(hours: 1)));
      expect(t.canReceiveCalls, isTrue);
      expect(t.canCallOut, isFalse);
      expect(t.timeLeft(start.add(const Duration(minutes: 10))), const Duration(minutes: 50));
      expect(t.isExpired(start.add(const Duration(hours: 1))), isTrue);
    });

    test('never prints the token itself', () {
      final raw = token();
      final t = VobizAccessToken.parse(raw);
      expect(t.toString(), isNot(contains(raw)));
      expect(t.toString(), contains('agent42_MA_TESTACCT'));
    });

    test('a token without sub gets a made-up name on the account, as the web SDK does', () {
      final t = VobizAccessToken.parse(token(sub: null));
      expect(t.subject, isNull);
      expect(t.sipUsername, matches(RegExp(r'^puser\d+jt_MA_TESTACCT$')));
    });

    test('outgoing calls need outgoing_allow: true', () {
      expect(VobizAccessToken.parse(token(outgoing: null)).canCallOut, isFalse);
      expect(VobizAccessToken.parse(token(outgoing: true)).canCallOut, isTrue);
    });

    test('refuses anything that is not a Vobiz token with INVALID_ACCESS_TOKEN', () {
      final now = _epoch(DateTime.now());
      final bad = <String>[
        'not-a-jwt',
        'a.b',
        'eyJhbGciOiJIUzI1NiJ9.bm90IGpzb24.c2ln',
        jwt(<String, Object?>{'sub': 'a', 'nbf': now, 'exp': now + 600}),
        jwt(<String, Object?>{'iss': 'MA_X', 'sub': 'a', 'nbf': '$now', 'exp': now + 600}),
        jwt(<String, Object?>{'iss': 'MA_X', 'sub': 'a', 'nbf': now}),
        jwt(<String, Object?>{'iss': 'MA_X', 'sub': 7, 'nbf': now, 'exp': now + 600}),
        jwt(<String, Object?>{
          'iss': 'MA_X',
          'nbf': now,
          'exp': now + 600,
          'per': <String, Object?>{
            'voice': <String, Object?>{'outgoing_allow': 'yes'}
          },
        }),
      ];
      for (final t in bad) {
        expect(
            () => VobizAccessToken.parse(t),
            throwsA(isA<VobizAccessTokenException>()
                .having((e) => e.tokenError, 'tokenError', VobizAccessTokenException.invalidToken)
                .having((e) => e.code, 'code', VobizErrorCode.accessTokenFailed)),
            reason: t);
      }
    });
  });

  group('VobizAccessTokenException', () {
    test('names the registrar codes as the web SDK does', () {
      expect(VobizAccessTokenException.errorName(10001), 'INVALID_ACCESS_TOKEN');
      expect(VobizAccessTokenException.errorName(10002), 'INVALID_ACCESS_TOKEN_HEADER');
      expect(VobizAccessTokenException.errorName(10003), 'INVALID_ACCESS_TOKEN_ISSUER');
      expect(VobizAccessTokenException.errorName(10004), 'INVALID_ACCESS_TOKEN_SUBJECT');
      expect(VobizAccessTokenException.errorName(10005), 'ACCESS_TOKEN_NOT_VALID_YET');
      expect(VobizAccessTokenException.errorName(10006), 'ACCESS_TOKEN_EXPIRED');
      expect(VobizAccessTokenException.errorName(10007), 'INVALID_ACCESS_TOKEN_SIGNATURE');
      expect(VobizAccessTokenException.errorName(10008), 'INVALID_ACCESS_TOKEN_GRANTS');
      expect(VobizAccessTokenException.errorName(10009), 'EXPIRATION_EXCEEDS_MAX_ALLOWED_TIME');
      expect(VobizAccessTokenException.errorName(10010), 'MAX_ALLOWED_LOGIN_REACHED');
      expect(VobizAccessTokenException.errorName(401), 'UNAUTHORISED');
      const e = VobizAccessTokenException('refused', tokenError: 10006);
      expect(e.tokenErrorName, 'ACCESS_TOKEN_EXPIRED');
      expect('$e', contains('10006 ACCESS_TOKEN_EXPIRED'));
    });
  });

  test('a REGISTER carries extra headers before Content-Length', () {
    final message = SipBuilder.register(
      sipServer: sipServer,
      username: 'agent42_MA_TESTACCT',
      contactUri: 'sip:x@y.invalid;transport=ws',
      localTag: 't',
      callId: 'c',
      cseq: 1,
      extraHeaders: const <String, String>{SipBuilder.accessTokenHeader: 'aaa.bbb.ccc'},
    );
    final lines = message.split('\r\n');
    expect(lines, contains('X-Vobiz-Jwt: aaa.bbb.ccc'));
    expect(lines.indexOf('X-Vobiz-Jwt: aaa.bbb.ccc'),
        lessThan(lines.indexOf('Content-Length: 0')));
  });

  group('connectWithAccessToken (loopback registrar)', () {
    late _TokenRegistrar registrar;

    setUp(() async {
      registrar = _TokenRegistrar();
      await registrar.start();
    });

    tearDown(() => registrar.stop());

    VobizClient newClient() => VobizClient.withServices(
          sip: SIPService(wsUrl: registrar.wsUrl, sipServer: sipServer)
            ..unregisterTimeout = const Duration(milliseconds: 200),
          peer: FakePeer(),
        );

    test('registers as <sub>_<iss> with X-Vobiz-Jwt and no password', () async {
      final t = token();
      registrar.accepted.add(t);
      final client = newClient();
      await client.connectWithAccessToken(t);
      await _until(() => client.isConnected);

      expect(client.isConnected, isTrue);
      expect(client.authMode, VobizAuthMode.accessToken);
      expect(client.sipUsername, 'agent42_MA_TESTACCT');
      expect(client.accessToken?.appId, '12345678901234567');
      expect(client.accessTokenTimeLeft, const Duration(seconds: 3540));
      final register = registrar.registers.single;
      expect(register, startsWith('REGISTER sip:$sipServer SIP/2.0'));
      expect(header(register, 'From'), contains('sip:agent42_MA_TESTACCT@$sipServer'));
      expect(header(register, 'To'), contains('sip:agent42_MA_TESTACCT@$sipServer'));
      expect(header(register, 'X-Vobiz-Jwt'), t);
      expect(header(register, 'Authorization'), isNull);
      await client.dispose();
    });

    test('a refused token fails the registration with the registrar\'s reason, '
        'and no digest answer is attempted', () async {
      registrar.refusalCode = VobizAccessTokenException.expired;
      final client = newClient();
      final errors = <ErrorEvent>[];
      client.errorEvents.listen(errors.add);
      await client.connectWithAccessToken(token());
      await _until(() => errors.isNotEmpty);

      expect(client.isConnected, isFalse);
      expect(client.registrationState, RegistrationState.failed);
      final error = errors.single;
      expect(error.code, VobizErrorCode.registrationFailed);
      expect(error.message, contains('ACCESS_TOKEN_EXPIRED (10006)'));
      expect(error.cause, isA<VobizAccessTokenException>()
          .having((e) => e.tokenError, 'tokenError', 10006)
          .having((e) => e.tokenErrorName, 'name', 'ACCESS_TOKEN_EXPIRED'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(registrar.registers, hasLength(1), reason: 'no Authorization retry');
      await client.dispose();
    });

    test('a malformed token is refused before anything is sent', () async {
      final client = newClient();
      await expectLater(client.connectWithAccessToken('nope'),
          throwsA(isA<VobizAccessTokenException>()));
      expect(registrar.registers, isEmpty);
      expect(client.authMode, VobizAuthMode.none);
      await client.dispose();
    });

    test('outbound INVITEs carry the token', () async {
      final t = token();
      registrar.accepted.add(t);
      final client = newClient();
      await client.connectWithAccessToken(t);
      await _until(() => client.isConnected);
      await client.makeCall('+919876543210');
      await _until(() => registrar.invites.isNotEmpty);

      final invite = registrar.invites.single;
      expect(invite, startsWith('INVITE sip:+919876543210@$sipServer SIP/2.0'));
      expect(header(invite, 'From'), contains('sip:agent42_MA_TESTACCT@$sipServer'));
      expect(header(invite, 'X-Vobiz-Jwt'), t);
      await client.dispose();
    });

    test('a token without outgoing_allow cannot place a call, and nothing is sent', () async {
      final t = token(outgoing: false);
      registrar.accepted.add(t);
      final client = newClient();
      await client.connectWithAccessToken(t);
      await _until(() => client.isConnected);

      await expectLater(
          client.makeCall('+919876543210'),
          throwsA(isA<VobizAccessTokenException>().having(
              (e) => e.tokenError, 'tokenError', VobizAccessTokenException.invalidGrants)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(registrar.invites, isEmpty);
      expect(client.callState, CallStateStatus.idle);
      await client.dispose();
    });

    test('updateAccessToken registers again at once with the new token', () async {
      final first = token(nonce: '1');
      final second = token(nonce: '2', lifetime: const Duration(hours: 2));
      registrar.accepted.addAll(<String>[first, second]);
      final client = newClient();
      await client.connectWithAccessToken(first);
      await _until(() => client.isConnected);

      await client.updateAccessToken(second);
      await _until(() => registrar.registers.length == 2);
      expect(header(registrar.registers.last, 'X-Vobiz-Jwt'), second);
      expect(client.accessToken?.token, second);
      await _until(() => client.isConnected);
      expect(client.isConnected, isTrue);
      await client.dispose();
    });

    test('updateAccessToken recovers a refused sign-in', () async {
      final good = token(nonce: 'good');
      registrar.accepted.add(good);
      final client = newClient();
      await client.connectWithAccessToken(token(nonce: 'stale'));
      await _until(() => client.registrationState == RegistrationState.failed);

      await client.updateAccessToken(good);
      await _until(() => client.isConnected);
      expect(client.isConnected, isTrue);
      expect(header(registrar.registers.last, 'X-Vobiz-Jwt'), good);
      await client.dispose();
    });

    test('updateAccessToken refuses another user, or a client not on a token', () async {
      final t = token();
      registrar.accepted.add(t);
      final client = newClient();
      await expectLater(client.updateAccessToken(t), throwsStateError);
      await client.connectWithAccessToken(t);
      await _until(() => client.isConnected);
      await expectLater(client.updateAccessToken(token(sub: 'someone-else')),
          throwsArgumentError);
      await client.dispose();
    });

    test('disconnect forgets the token', () async {
      final t = token();
      registrar.accepted.add(t);
      final client = newClient();
      await client.connectWithAccessToken(t);
      await _until(() => client.isConnected);
      await client.disconnect();
      expect(client.accessToken, isNull);
      expect(client.authMode, VobizAuthMode.none);
      expect(client.sipUsername, isNull);
      await client.dispose();
    });
  });

  group('connectWithAccessTokenProvider', () {
    tearDown(() => VobizAccessTokenSession.now = DateTime.now);

    test('fetches a new token 60 s before expiry and registers with it', () {
      fakeAsync((async) {
        // Token times are whole seconds.
        final start = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000);
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final sip = _InstantRegistrar();
        final client = VobizClient.withServices(sip: sip, peer: FakePeer());
        final tokens = <String>[
          token(from: start, lifetime: const Duration(minutes: 10), nonce: '1'),
          token(from: start, lifetime: const Duration(minutes: 30), nonce: '2'),
        ];
        final asked = <VobizAccessTokenRequest>[];
        late VobizAccessTokenSession session;
        client
            .connectWithAccessTokenProvider((request) async {
              asked.add(request);
              return tokens[asked.length - 1];
            })
            .then((s) => session = s);
        async.flushMicrotasks();

        expect(client.isConnected, isTrue);
        expect(asked, <VobizAccessTokenRequest>[VobizAccessTokenRequest.signIn]);
        expect(session.nextRefreshAt, start.add(const Duration(minutes: 9)));

        async.elapse(const Duration(minutes: 8, seconds: 59));
        expect(asked, hasLength(1));
        async.elapse(const Duration(seconds: 2));
        expect(asked.last, VobizAccessTokenRequest.expiring);
        expect(sip.registerTokens.last, tokens[1]);
        expect(client.isConnected, isTrue);
        expect(session.nextRefreshAt,
            start.add(const Duration(minutes: 29)));

        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('never asks sooner than the minimum delay, even for an almost expired token', () {
      fakeAsync((async) {
        final start = DateTime.now();
        VobizAccessTokenSession.now = () => start.add(async.elapsed);
        final client = VobizClient.withServices(sip: _InstantRegistrar(), peer: FakePeer());
        late VobizAccessTokenSession session;
        client
            .connectWithAccessTokenProvider(
                (_) async => token(from: start, lifetime: const Duration(seconds: 30)))
            .then((s) => session = s);
        async.flushMicrotasks();
        expect(session.nextRefreshAt, start.add(VobizAccessTokenSession.minimumRefreshDelay));
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a refused token makes the session ask again (rejected) and register', () {
      fakeAsync((async) {
        final sip = _InstantRegistrar();
        final stale = token(nonce: 'stale');
        final fresh = token(nonce: 'fresh');
        sip.refused.add(stale);
        final client = VobizClient.withServices(sip: sip, peer: FakePeer());
        final asked = <VobizAccessTokenRequest>[];
        late VobizAccessTokenSession session;
        client
            .connectWithAccessTokenProvider((request) async {
              asked.add(request);
              return request == VobizAccessTokenRequest.signIn ? stale : fresh;
            })
            .then((s) => session = s);
        async.flushMicrotasks();

        expect(asked, <VobizAccessTokenRequest>[
          VobizAccessTokenRequest.signIn,
          VobizAccessTokenRequest.rejected,
        ]);
        expect(sip.registerTokens, <String>[stale, fresh]);
        expect(client.isConnected, isTrue);
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a token "not valid yet" (10005) is presented again 3 s later, without a new one', () {
      fakeAsync((async) {
        final sip = _InstantRegistrar();
        final t = token(nonce: 'early');
        sip.notYetValidOnce.add(t);
        final client = VobizClient.withServices(sip: sip, peer: FakePeer());
        final asked = <VobizAccessTokenRequest>[];
        late VobizAccessTokenSession session;
        client.connectWithAccessTokenProvider((request) async {
          asked.add(request);
          return t;
        }).then((s) => session = s);
        async.flushMicrotasks();
        expect(client.registrationState, RegistrationState.failed);
        expect(sip.registerTokens, <String>[t]);

        async.elapse(const Duration(seconds: 2));
        expect(sip.registerTokens, hasLength(1), reason: 'waits for the registrar\'s clock');
        async.elapse(const Duration(seconds: 1, milliseconds: 100));
        expect(sip.registerTokens, <String>[t, t]);
        expect(asked, <VobizAccessTokenRequest>[VobizAccessTokenRequest.signIn]);
        expect(client.isConnected, isTrue);
        session.dispose();
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('gives up after maxRefreshes and reports the registrar\'s reason', () {
      fakeAsync((async) {
        final sip = _InstantRegistrar();
        final stale = token(nonce: 'stale');
        sip.refused.add(stale);
        final client = VobizClient.withServices(sip: sip, peer: FakePeer());
        final failures = <VobizException>[];
        var calls = 0;
        client.connectWithAccessTokenProvider((_) async {
          calls++;
          return stale;
        }).then((s) => s.failures.listen(failures.add));
        async.flushMicrotasks();

        expect(calls, 2);
        expect(failures.single, isA<VobizAccessTokenException>()
            .having((e) => e.tokenError, 'tokenError', 10006));
        expect(client.isConnected, isFalse);
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a provider that throws fails the sign-in with VobizAccessTokenException', () async {
      final client = VobizClient.withServices(sip: _InstantRegistrar(), peer: FakePeer());
      await expectLater(
        client.connectWithAccessTokenProvider((_) async => throw StateError('backend down')),
        throwsA(isA<VobizAccessTokenException>()
            .having((e) => e.code, 'code', VobizErrorCode.accessTokenFailed)),
      );
      expect(client.isConnected, isFalse);
      await client.dispose();
    });
  });

  group('VobizBackendAccessTokenProvider', () {
    test('posts the reason with the app headers and reads token', () async {
      late http.Request seen;
      final provider = VobizBackendAccessTokenProvider(
        url: Uri.parse('https://voice.example.test/token'),
        headers: () async => <String, String>{'Authorization': 'Bearer app-session'},
        httpClient: MockClient((request) async {
          seen = request;
          // The shape the Vobiz WebRTC demo backend answers with.
          return http.Response(
              jsonEncode(<String, Object>{
                'token': 'aaa.bbb.ccc',
                'mode': 'api',
                'sub': 'webrtc-demo',
                'exp': 1790003600,
                'sip_username': 'webrtc-demo_MA_TESTACCT',
              }),
              200);
        }),
      );
      expect(await provider(VobizAccessTokenRequest.expiring), 'aaa.bbb.ccc');
      expect(seen.method, 'POST');
      expect(seen.headers['Authorization'], 'Bearer app-session');
      expect(jsonDecode(seen.body), <String, String>{'reason': 'expiring'});
    });

    test('a refusal or a reply without a token is a VobizAccessTokenException', () async {
      final refused = VobizBackendAccessTokenProvider(
          url: Uri.parse('https://voice.example.test/token'),
          httpClient: MockClient((_) async => http.Response('no', 401)));
      await expectLater(refused(VobizAccessTokenRequest.signIn),
          throwsA(isA<VobizAccessTokenException>().having((e) => e.statusCode, 'status', 401)));

      final empty = VobizBackendAccessTokenProvider(
          url: Uri.parse('https://voice.example.test/token'),
          httpClient: MockClient((_) async => http.Response('{"error":"x"}', 200)));
      await expectLater(
          empty(VobizAccessTokenRequest.signIn), throwsA(isA<VobizAccessTokenException>()));
    });
  });
}
