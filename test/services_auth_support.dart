// Shared fixtures for the sign-in tests: access tokens shaped like Vobiz's,
// and a SIP layer whose registrar answers at once, without a socket.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';

import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'call_harness.dart';

/// A token shaped like the ones `POST /Account/{auth_id}/JWT/Token/` mints.
/// The signature is not checked on the device, so any will do here.
String jwt(Map<String, Object?> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part(<String, String>{'alg': 'HS256', 'typ': 'JWT', 'cty': 'auris;v=1'})}'
      '.${part(claims)}.c2lnbmF0dXJl';
}

int epochSeconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

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
    'nbf': epochSeconds(start),
    'exp': epochSeconds(start.add(lifetime)),
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

/// The SIP layer without a socket: REGISTERs are answered on the next
/// microtask, so the sign-in sessions can run under fake timers.
///
/// A REGISTER with an access token gets 200 OK, or 401 with
/// `X-vobiz-Jwt-Error-Code: 10006` when the token is in [refused] (10005,
/// once, for one in [notYetValidOnce]). A REGISTER with a password gets
/// 200 OK when its user is in [users], 403 otherwise.
class InstantRegistrar extends SIPService {
  InstantRegistrar() : super(wsUrl: 'wss://example.invalid', sipServer: sipServer) {
    debugOnSend = (message) {
      sent.add(message);
      if (!message.startsWith('REGISTER ')) return;
      final presented = header(message, 'X-Vobiz-Jwt');
      final List<String> reply;
      if (presented != null) {
        final notYet = notYetValidOnce.remove(presented);
        final ok = !refused.contains(presented) && !notYet;
        final left = tokenExpiresIn;
        reply = ok
            ? <String>[
                'SIP/2.0 200 OK',
                'Expires: 600',
                if (left != null) 'X-vobiz-Jwt: expires=$left',
              ]
            : <String>[
                'SIP/2.0 401 Unauthorized',
                'X-vobiz-Jwt-Error-Code: ${notYet ? 10005 : 10006}',
              ];
      } else {
        final user = RegExp(r'sip:([^@]+)@').firstMatch(header(message, 'From') ?? '')?.group(1);
        reply = users.contains(user)
            ? <String>['SIP/2.0 200 OK', 'Expires: 600']
            : <String>['SIP/2.0 403 Forbidden'];
      }
      scheduleMicrotask(() => debugReceive(<String>[
            reply.first,
            'Via: ${header(message, 'Via')}',
            'From: ${header(message, 'From')}',
            'To: ${header(message, 'To')};tag=reg',
            'Call-ID: ${header(message, 'Call-ID')}',
            'CSeq: ${header(message, 'CSeq')}',
            ...reply.skip(1),
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

  /// The users a password REGISTER is accepted for.
  final Set<String> users = <String>{};

  /// The seconds a token has left by the registrar's clock, sent as
  /// `X-vobiz-Jwt: expires=<seconds>` on a 200 OK when set.
  int? tokenExpiresIn;

  /// Thrown by [connect], as when the socket cannot be opened.
  Object? connectError;

  List<String> get registerTokens => <String>[
        for (final m in sent)
          if (m.startsWith('REGISTER ')) header(m, 'X-Vobiz-Jwt') ?? '',
      ];

  /// The user of each REGISTER sent, unregistrations included.
  List<String> get registerUsers => <String>[
        for (final m in sent)
          if (m.startsWith('REGISTER '))
            RegExp(r'sip:([^@]+)@').firstMatch(header(m, 'From') ?? '')?.group(1) ?? '',
      ];

  @override
  Future<void> connect() async {
    final error = connectError;
    if (error != null) throw error;
    connectionState.value = SipConnectionState.connected;
  }
}
