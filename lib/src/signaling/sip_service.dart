import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/sip_headers.dart';
import '../errors/vobiz_exception.dart';
import '../network/keep_alive.dart';
import '../utils/logger.dart';
import '../utils/sip_text.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum SipConnectionState { disconnected, connecting, connected }

enum SipRegistrationState { unregistered, registering, registered, failed }

// ---------------------------------------------------------------------------
// SIP Message Model
// ---------------------------------------------------------------------------

class SipMessage {
  const SipMessage({
    required this.firstLine,
    required this.headers,
    required this.body,
    this.headerLines = const <MapEntry<String, String>>[],
  });

  final String firstLine;

  /// One value per header name; for a name that repeats, the last one.
  final Map<String, String> headers;
  final String body;

  /// Every header line, in the order received. Repeated headers such as Via
  /// and Record-Route only survive here.
  final List<MapEntry<String, String>> headerLines;

  /// Every value of [name] in the order received (compact forms included),
  /// for headers that repeat. A response must copy all of a request's Via
  /// headers, and a dialog's route set comes from all of its Record-Routes.
  List<String> headerValues(String name) {
    final key = name.toLowerCase();
    final compact = _compactForms[key];
    return <String>[
      for (final line in headerLines)
        if (line.key.toLowerCase() == key || line.key.toLowerCase() == compact) line.value,
    ];
  }

  static const Map<String, String> _compactForms = <String, String>{
    'via': 'v',
    'contact': 'm',
    'from': 'f',
    'to': 't',
    'call-id': 'i',
  };

  bool get isRequest => !firstLine.startsWith('SIP/');
  String get method => firstLine.split(' ').first;

  /// The response's status code; 0 when the status line has none.
  int get statusCode {
    final parts = firstLine.split(' ');
    return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  }

  String? header(String name) {
    final key = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == key) return entry.value;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// SIP Parser
// ---------------------------------------------------------------------------

class SipParser {
  static SipMessage parse(String raw) {
    final separator = raw.contains('\r\n\r\n') ? '\r\n\r\n' : '\n\n';
    final separatorIndex = raw.indexOf(separator);

    final headerSection =
        separatorIndex >= 0 ? raw.substring(0, separatorIndex) : raw;
    var body = separatorIndex >= 0
        ? raw.substring(separatorIndex + separator.length)
        : '';

    final lines = headerSection.split(RegExp(r'\r?\n'));
    final firstLine = lines[0].trim();
    final headers = <String, String>{};
    final headerLines = <MapEntry<String, String>>[];

    for (int i = 1; i < lines.length; i++) {
      final colon = lines[i].indexOf(':');
      if (colon == -1) continue;
      final name = lines[i].substring(0, colon).trim();
      final value = lines[i].substring(colon + 1).trim();
      headers[name] = value;
      headerLines.add(MapEntry<String, String>(name, value));
    }

    final contentLength =
        int.tryParse((headers['Content-Length'] ?? headers['l'] ?? '').trim());
    if (contentLength != null && contentLength >= 0 &&
        body.length >= contentLength) {
      body = body.substring(0, contentLength);
    }

    body = body.replaceAll('\u0000', '');
    return SipMessage(
      firstLine: firstLine,
      headers: headers,
      body: body,
      headerLines: List<MapEntry<String, String>>.unmodifiable(headerLines),
    );
  }

  /// Splits a header value that lists several addresses
  /// (`<sip:a;lr>, <sip:b;lr>`), ignoring commas inside `<…>` or quotes.
  static List<String> splitAddressList(String value) {
    final parts = <String>[];
    final current = StringBuffer();
    var inAngle = false;
    var inQuote = false;
    for (final char in value.split('')) {
      if (char == '"') inQuote = !inQuote;
      if (!inQuote && char == '<') inAngle = true;
      if (!inQuote && char == '>') inAngle = false;
      if (char == ',' && !inAngle && !inQuote) {
        if (current.toString().trim().isNotEmpty) parts.add(current.toString().trim());
        current.clear();
      } else {
        current.write(char);
      }
    }
    if (current.toString().trim().isNotEmpty) parts.add(current.toString().trim());
    return parts;
  }
}

// ---------------------------------------------------------------------------
// SIP Message Builder
// ---------------------------------------------------------------------------

class SipBuilder {
  /// The methods this client answers. Session timers (RFC 4028) are not
  /// implemented, so no `Supported: timer` is advertised: a far end that
  /// wants refreshes then does them itself, and its re-INVITEs are answered.
  static const String allow = 'INVITE, ACK, CANCEL, BYE, OPTIONS, INFO';

  /// A fresh RFC 3261 branch, magic cookie included. Each new client
  /// transaction gets one; a CANCEL and the ACK for a non-2xx reuse the
  /// INVITE's.
  static String newBranch() => 'z9hG4bK${_branch()}';

  /// The header an access-token (JWT) sign-in sends on REGISTER and INVITE
  /// instead of answering a digest challenge, spelled as Vobiz's web clients
  /// send it.
  static const String accessTokenHeader = 'X-Vobiz-Jwt';

  static String register({
    required String sipServer,
    required String username,
    required String contactUri,
    required String localTag,
    required String callId,
    required int cseq,
    int expires = 600,
    String? branch,
    String? authHeaderName,
    String? authHeader,
    Map<String, String> extraHeaders = const <String, String>{},
  }) {
    final from = 'sip:$username@$sipServer';
    // CRLF line ends throughout (RFC 3261 7), as every other message here.
    return <String>[
      'REGISTER sip:$sipServer SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=${branch ?? newBranch()}',
      'From: <$from>;tag=$localTag',
      'To: <$from>',
      'Call-ID: $callId',
      'CSeq: $cseq REGISTER',
      'Contact: <$contactUri>',
      'Max-Forwards: 70',
      'User-Agent: vobiz_flutter_sdk',
      'Expires: $expires',
      for (final header in extraHeaders.entries) '${header.key}: ${header.value}',
      'Content-Length: 0',
      if (authHeader != null) '${authHeaderName ?? 'Authorization'}: $authHeader',
      '',
      '',
    ].join('\r\n');
  }

  static String invite({
    required String sipServer,
    required String fromUser,
    required String contactUri,
    required String toUser,
    required String localTag,
    required String callId,
    required int cseq,
    required String sdp,
    String? branch,
    String? authHeaderName,
    String? authHeader,
    Map<String, String> extraHeaders = const <String, String>{},
  }) {
    final contentLength = utf8.encode(sdp).length;
    final lines = <String>[
      'INVITE sip:$toUser@$sipServer SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=${branch ?? newBranch()}',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: <sip:$toUser@$sipServer>',
      'Call-ID: $callId',
      'CSeq: $cseq INVITE',
      'Contact: <$contactUri>',
      'Max-Forwards: 70',
      'Allow: $allow',
      'User-Agent: vobiz_flutter_sdk',
      // Custom X-VH- headers. Vobiz hands each one to the answer webhook as a
      // top-level parameter.
      for (final header in extraHeaders.entries) '${header.key}: ${header.value}',
    ];
    if (authHeaderName != null && authHeader != null) {
      lines.add('$authHeaderName: $authHeader');
    }
    lines.addAll(<String>[
      'Content-Type: application/sdp',
      'Content-Length: $contentLength',
      '',
      sdp,
    ]);
    return lines.join('\r\n');
  }

  /// Cancels an INVITE that has no final response yet (RFC 3261 9.1). The
  /// Request-URI, Call-ID, From, To and CSeq number are the INVITE's, and so
  /// is the Via branch: that is how the server finds the INVITE to stop.
  static String cancel({
    required String requestUri,
    required String fromUser,
    required String toHeader,
    required String sipServer,
    required String localTag,
    required String callId,
    required int cseq,
    required String branch,
  }) {
    return <String>[
      'CANCEL $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=$branch',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: $toHeader',
      'Call-ID: $callId',
      'CSeq: $cseq CANCEL',
      'Max-Forwards: 70',
      'Reason: SIP;cause=487;text="Request Terminated"',
      'Content-Length: 0',
      '',
      '',
    ].join('\r\n');
  }

  /// A response to [request] (RFC 3261 8.2.6.2): every Via in the order
  /// received, since each proxy matches its transaction on the top one and
  /// forwards on the next. With [recordRoute] (a 1xx or 2xx that sets up a
  /// dialog) it also copies every Record-Route, so the far end keeps routing
  /// the call through Vobiz's registrar (RFC 3261 12.1.1). [localTag] is added
  /// to To when the request had none.
  static String response({
    required SipMessage request,
    required int code,
    required String reason,
    String? localTag,
    bool recordRoute = false,
    List<String> headers = const <String>[],
    String? contentType,
    String body = '',
  }) {
    final to = request.header('To') ?? '';
    final taggedTo =
        localTag == null || to.contains('tag=') ? to : '$to;tag=$localTag';
    return <String>[
      'SIP/2.0 $code $reason',
      for (final via in request.headerValues('Via')) 'Via: $via',
      if (recordRoute)
        for (final route in request.headerValues('Record-Route')) 'Record-Route: $route',
      'From: ${request.header('From') ?? ''}',
      'To: $taggedTo',
      'Call-ID: ${request.header('Call-ID') ?? ''}',
      'CSeq: ${request.header('CSeq') ?? ''}',
      ...headers,
      if (contentType != null) 'Content-Type: $contentType',
      'Content-Length: ${utf8.encode(body).length}',
      '',
      body,
    ].join('\r\n');
  }

  static String ok200({
    required SipMessage invite,
    required String contactUri,
    required String localTag,
    required String sdp,
  }) {
    return response(
      request: invite,
      code: 200,
      reason: 'OK',
      localTag: localTag,
      recordRoute: true,
      headers: <String>[
        'Contact: <$contactUri>',
        'Allow: $allow',
        'User-Agent: vobiz_flutter_sdk',
      ],
      contentType: 'application/sdp',
      body: sdp,
    );
  }

  static String ringing({
    required SipMessage invite,
    required String localTag,
    String? contactUri,
  }) {
    return response(
      request: invite,
      code: 180,
      reason: 'Ringing',
      localTag: localTag,
      recordRoute: true,
      headers: <String>[if (contactUri != null) 'Contact: <$contactUri>'],
    );
  }

  /// The final answer to an INVITE the caller cancelled (RFC 3261 9.2).
  static String requestTerminated({
    required SipMessage invite,
    required String localTag,
  }) {
    return response(request: invite, code: 487, reason: 'Request Terminated', localTag: localTag);
  }

  static String ack({
    required String requestUri,
    required String fromUser,
    required String toHeader,
    required String sipServer,
    required String localTag,
    required String callId,
    required int cseq,
    String? branch,
    List<String> routes = const <String>[],
  }) {
    return <String>[
      'ACK $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=${branch ?? newBranch()}',
      for (final route in routes) 'Route: $route',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: $toHeader',
      'Call-ID: $callId',
      'CSeq: $cseq ACK',
      'Max-Forwards: 70',
      'Content-Length: 0',
      '',
      '',
    ].join('\r\n');
  }

  static String bye({
    required String requestUri,
    required String fromUser,
    required String toHeader,
    required String sipServer,
    required String localTag,
    required String callId,
    required int cseq,
    String? branch,
    String? authHeaderName,
    String? authHeader,
    List<String> routes = const <String>[],
  }) {
    return <String>[
      'BYE $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=${branch ?? newBranch()}',
      for (final route in routes) 'Route: $route',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: $toHeader',
      'Call-ID: $callId',
      'CSeq: $cseq BYE',
      'Max-Forwards: 70',
      if (authHeaderName != null && authHeader != null) '$authHeaderName: $authHeader',
      'Content-Length: 0',
      '',
      '',
    ].join('\r\n');
  }

  /// An in-dialog INFO. Used for DTMF, which is how the Vobiz web SDK sends
  /// keypad tones (JsSIP's default `sendDTMF` transport).
  static String info({
    required String requestUri,
    required String fromUser,
    required String toHeader,
    required String sipServer,
    required String localTag,
    required String callId,
    required int cseq,
    required String contentType,
    required String body,
    String? branch,
    String? authHeaderName,
    String? authHeader,
    List<String> routes = const <String>[],
  }) {
    return <String>[
      'INFO $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=${branch ?? newBranch()}',
      for (final route in routes) 'Route: $route',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: $toHeader',
      'Call-ID: $callId',
      'CSeq: $cseq INFO',
      'Max-Forwards: 70',
      if (authHeaderName != null && authHeader != null) '$authHeaderName: $authHeader',
      'Content-Type: $contentType',
      'Content-Length: ${utf8.encode(body).length}',
      '',
      body,
    ].join('\r\n');
  }

  /// The body of an `application/dtmf-relay` INFO for one tone, exactly as
  /// JsSIP writes it.
  static String dtmfRelayBody(String tone, {int durationMs = 100}) =>
      'Signal=$tone\r\nDuration=$durationMs';

  /// An in-dialog re-INVITE carrying a new offer, used to hold (`a=sendonly`)
  /// and resume (`a=sendrecv`) the call (RFC 3264 8.4, RFC 6337 5.3).
  static String reInvite({
    required String requestUri,
    required String fromUser,
    required String toHeader,
    required String sipServer,
    required String localTag,
    required String callId,
    required int cseq,
    required String contactUri,
    required String sdp,
    String? branch,
    String? authHeaderName,
    String? authHeader,
    List<String> routes = const <String>[],
  }) {
    return <String>[
      'INVITE $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=${branch ?? newBranch()}',
      for (final route in routes) 'Route: $route',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: $toHeader',
      'Call-ID: $callId',
      'CSeq: $cseq INVITE',
      'Contact: <$contactUri>',
      'Max-Forwards: 70',
      'Allow: $allow',
      'User-Agent: vobiz_flutter_sdk',
      if (authHeaderName != null && authHeader != null) '$authHeaderName: $authHeader',
      'Content-Type: application/sdp',
      'Content-Length: ${utf8.encode(sdp).length}',
      '',
      sdp,
    ].join('\r\n');
  }

  static String busyHere({
    required SipMessage invite,
    required String localTag,
  }) {
    return response(request: invite, code: 486, reason: 'Busy Here', localTag: localTag);
  }

  static String _branch() =>
      Random().nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0');
}

// ---------------------------------------------------------------------------
// SIP Digest Auth
// ---------------------------------------------------------------------------

class SipDigestAuth {
  /// The `Authorization` value answering [wwwAuthenticate], or null when the
  /// challenge cannot be answered: no realm or nonce, or an algorithm other
  /// than MD5 (MD5-sess and SHA-256 are not implemented).
  static String? buildAuthHeader({
    required String wwwAuthenticate,
    required String method,
    required String uri,
    required String username,
    required String password,
  }) {
    final realm = _extract(wwwAuthenticate, 'realm');
    final nonce = _extract(wwwAuthenticate, 'nonce');
    if (realm == null || nonce == null) return null;

    final algorithm = _extractUnquoted(wwwAuthenticate, 'algorithm');
    if (algorithm != null && algorithm.toUpperCase() != 'MD5') return null;

    final qopOptions = (_extractUnquoted(wwwAuthenticate, 'qop') ?? '')
        .split(',')
        .map((q) => q.trim().toLowerCase());
    final opaque = _extract(wwwAuthenticate, 'opaque');
    // RFC 2617 3.2.2: the opaque value goes back to the server unchanged.
    final opaquePart = opaque == null ? '' : ', opaque="$opaque"';

    final ha1 = _md5('$username:$realm:$password');
    final ha2 = _md5('$method:$uri');

    if (qopOptions.contains('auth')) {
      final cnonce = _rand();
      const nc = '00000001';
      final response = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
      return 'Digest username="$username", realm="$realm", '
          'nonce="$nonce", uri="$uri", qop=auth, nc=$nc, '
          'cnonce="$cnonce", response="$response", algorithm=MD5$opaquePart';
    } else {
      final response = _md5('$ha1:$nonce:$ha2');
      return 'Digest username="$username", realm="$realm", '
          'nonce="$nonce", uri="$uri", response="$response", algorithm=MD5$opaquePart';
    }
  }

  /// Whether the server refused the previous credentials only because their
  /// nonce had expired (`stale=true`, RFC 2617 3.2.1). The password was
  /// right; answering the new nonce is expected.
  static bool isStale(String challenge) =>
      (_extractUnquoted(challenge, 'stale') ?? '').toLowerCase() == 'true';

  static String _md5(String input) =>
      md5.convert(utf8.encode(input)).toString();

  static String _rand() =>
      List.generate(8, (_) => Random().nextInt(16).toRadixString(16)).join();

  static String? _extract(String header, String key) =>
      RegExp('\\b$key\\s*=\\s*"([^"]*)"', caseSensitive: false).firstMatch(header)?.group(1);

  static String? _extractUnquoted(String header, String key) {
    final quoted = _extract(header, key);
    if (quoted != null) return quoted;
    return RegExp('\\b$key\\s*=\\s*([^,\\s;"]+)', caseSensitive: false)
        .firstMatch(header)
        ?.group(1);
  }
}

/// How many times one request may answer a digest challenge: once with the
/// credentials, and once more only when the server says the nonce was stale.
/// A second plain 401/407 means the credentials are wrong, and sending them
/// again would only loop.
class _AuthRetries {
  _AuthRetries({
    this.refresh = false,
    this.timeout,
    this.extraHeaders = const <String, String>{},
  });

  /// A REGISTER refreshing a live registration rather than a sign-in's
  /// first: no answer then means the transport is dead.
  final bool refresh;

  /// How long each REGISTER of this attempt waits for a final response;
  /// null for [SIPService.transactionTimeout].
  final Duration? timeout;

  /// Headers every REGISTER of this attempt carries, its digest answer too:
  /// the reference of a call the registrar holds ([SIPService.claimHeldCall]),
  /// which it reads only once the REGISTER is authenticated.
  final Map<String, String> extraHeaders;

  /// Whether this attempt claims a held call.
  bool get claims => extraHeaders.isNotEmpty;

  int _attempts = 0;
  bool _usedStale = false;

  /// Whether this request has answered a challenge yet.
  bool get tried => _attempts > 0;

  bool allow(String challenge) {
    if (_attempts == 0) {
      _attempts++;
      return true;
    }
    if (!_usedStale && SipDigestAuth.isStale(challenge)) {
      _usedStale = true;
      _attempts++;
      return true;
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Client transactions and dialogs
// ---------------------------------------------------------------------------

/// One request this client sent and is waiting on (RFC 3261 17.1). Responses
/// are matched to it by the top Via branch and the CSeq method (17.1.3), not
/// by method name alone, so a late or repeated response cannot be taken for
/// the answer to some other request.
class _ClientTransaction {
  _ClientTransaction({
    required this.branch,
    required this.method,
    required this.cseq,
    required this.callId,
    required this.socket,
    required this.onResponse,
    this.onTimeout,
    this.timeout,
  });

  final String branch;
  final String method;
  final int cseq;
  final String callId;

  /// The socket it was sent on. A retry after a challenge goes back the same
  /// way, even while that socket is closing.
  final WebSocketChannel? socket;
  final void Function(_ClientTransaction tx, SipMessage response) onResponse;
  final void Function()? onTimeout;

  /// Overrides [SIPService.transactionTimeout] for this request.
  final Duration? timeout;
  Timer? timer;

  String get key => '$branch $method';
}

/// The outbound INVITE of one call, from the first send until its final
/// response. It outlives a hang-up: the CANCEL waits for a provisional
/// response, and a 200 OK that crosses the CANCEL still has to be ACKed and
/// then ended with BYE (RFC 3261 9.1, 15).
class _OutgoingInvite {
  _OutgoingInvite({
    required this.callId,
    required this.toUser,
    required this.sdp,
    required this.extraHeaders,
    required this.requestUri,
    required this.toHeader,
  });

  final String callId;
  final String toUser;
  final String sdp;
  final Map<String, String> extraHeaders;
  final String requestUri;

  /// The To of the INVITE, without a tag. A CANCEL repeats it.
  final String toHeader;
  final _AuthRetries auth = _AuthRetries();

  // The INVITE in flight. A retry after a challenge is a new transaction.
  String branch = '';
  int cseq = 0;
  WebSocketChannel? socket;

  /// A 1xx has arrived, so the INVITE can be cancelled.
  bool provisional = false;

  /// A 2xx has arrived.
  bool answered = false;

  /// The app hung up before a final response.
  bool hungUp = false;
  bool cancelSent = false;
}

/// What an in-dialog request (BYE, INFO) needs, copied so that a retry after
/// a challenge still works once the call state has been cleared.
class _Dialog {
  const _Dialog({
    required this.callId,
    required this.remoteTarget,
    required this.remoteParty,
    required this.routes,
  });

  final String callId;
  final String remoteTarget;
  final String remoteParty;
  final List<String> routes;
}

/// A BYE or CANCEL that has had no final response yet. One sent while the
/// connection is down (a call that ran out of network grace) never arrives,
/// and Vobiz then keeps the far end up, silent and billed, until its media
/// proxy times the leg out (about 300 s), or keeps a callee ringing. Once the
/// client has registered on a new connection it is sent again.
class _PendingEnd {
  _PendingEnd(this.method, this.callId, this.username, this.resend);

  final String method;
  final String callId;
  final String username;
  final void Function() resend;
  final DateTime since = DateTime.now();

  /// The socket it last went out on (null: there was none).
  WebSocketChannel? sentOn;
  int resends = 0;
}

// ---------------------------------------------------------------------------
// SIPService
// ---------------------------------------------------------------------------

@internal
class SIPService {
  SIPService({
    required this.wsUrl,
    required this.sipServer,
    this.registerExpires = 3600,
    this.keepAlive = const KeepAliveConfig(),
    Logger? logger,
  })  : _logger = logger ?? Logger(),
        _localTag = _rand(8),
        _registerCallId = '${_rand(12)}@vobiz-client',
        _contactUri = 'sip:${_rand(8)}@${_rand(12)}.invalid;transport=ws';

  final String wsUrl;
  final String sipServer;

  /// The registration lifetime this client asks for, in seconds. The
  /// registrar may grant less (or, after a 423, require more); the refresh
  /// follows what it granted.
  ///
  /// An hour by default: Vobiz's registrar keeps this SDK's registration
  /// after its socket closes (the app killed or put to sleep) until it
  /// expires, and while it lasts a call reaches the app by push. Every
  /// REGISTER (sign-in, the refresh, the return to the foreground, the claim
  /// of a pushed call) starts that hour again.
  final int registerExpires;

  /// The WebSocket ping and the optional RFC 5626 CRLF keep-alive.
  final KeepAliveConfig keepAlive;
  final Logger _logger;

  final String _localTag;
  final String _registerCallId;

  /// Where this client says it can be reached. A WebSocket client has no
  /// address of its own, so, as JsSIP does (RFC 7118), it registers a made-up
  /// `<random>.invalid` host. Vobiz's registrar swaps that host for the
  /// connection's real address when it saves the registration, which is how
  /// an inbound INVITE finds its way back down this WebSocket. A real host
  /// here (`@registrar.vobiz.ai`) was saved as it was, so inbound calls were
  /// sent to the registrar itself and timed out unanswered.
  final String _contactUri;

  /// The Contact this client registers and puts on its calls.
  @visibleForTesting
  String get contactUri => _contactUri;

  /// How long a request waits for its final response (RFC 3261 Timer B/F,
  /// 64 × T1).
  @visibleForTesting
  Duration transactionTimeout = const Duration(seconds: 32);

  /// How long [disconnect] waits for the registrar to confirm the
  /// unregistration before it closes the socket anyway.
  @visibleForTesting
  Duration unregisterTimeout = const Duration(seconds: 2);

  /// How long a BYE or CANCEL that may not have arrived is sent again after a
  /// reconnect (at most [_pendingEndMaxResends] times). Vobiz's media proxy
  /// ends an abandoned leg after about 300 s, so later there is nothing left
  /// to end.
  @visibleForTesting
  Duration pendingEndWindow = const Duration(minutes: 5);
  static const int _pendingEndMaxResends = 3;

  /// How long [refreshRegistration] waits for the registrar before treating
  /// the socket as dead. After a phone is locked the socket is often dead
  /// without having been closed, and waiting the full [transactionTimeout]
  /// would leave the app unreachable that long.
  @visibleForTesting
  Duration refreshTimeout = const Duration(seconds: 5);

  /// How long [reserveForOutgoingCall] holds the line if [call] never comes.
  @visibleForTesting
  Duration outgoingReservation = const Duration(seconds: 60);

  String? _username;
  String? _password;

  // An access-token (JWT) sign-in sends this on REGISTER and INVITE instead
  // of a password; it never answers a digest challenge.
  String? _accessToken;
  int? _accessTokenError;
  int? _accessTokenExpiresIn;
  int _cseq = 1;
  bool _manualDisconnect = false;

  // The reference of a call the registrar holds for this user (from a push),
  // waiting for the next REGISTER to hand it back: see [claimHeldCall].
  Map<String, String>? _pendingClaim;

  String? _activeCallId;
  String? _activeToUser;
  String? _activeRemoteTarget;
  String? _activeRemotePartyHeader;
  SipMessage? _pendingInvite;
  SipMessage? _lastAnsweredInvite;
  String? _lastAnsweredSdp;

  // The outbound INVITE of the current call, until the call ends.
  _OutgoingInvite? _outgoing;

  // Whether the current call is established (answered, or 2xx received):
  // in-dialog requests such as DTMF can only be sent once it is.
  bool _dialogConfirmed = false;

  // The session as negotiated, for answering re-INVITEs and UPDATEs.
  String? _localSdp;
  String? _remoteSdp;

  // The last answer to a re-INVITE or UPDATE, by its CSeq, so a repeat of
  // the same request gets the same answer.
  String? _lastOfferReplyCSeq;
  String? _lastOfferReply;
  bool _offerInProgress = false;

  // Our own hold/resume re-INVITE in flight (see reInvite).
  Completer<String>? _reInvite;

  // The ACK for the last 2xx to one of our INVITEs, re-sent if the far end
  // repeats the 2xx (it does until the ACK arrives, RFC 3261 13.3.1.4).
  String? _last2xxKey;
  String? _last2xxAck;

  // The current call's route set (RFC 3261 12.1): the Route headers its
  // in-dialog requests (ACK, BYE, INFO) carry, so they follow the call back
  // through Vobiz's registrar. Answering: the INVITE's Record-Routes in
  // order. Calling: the response's Record-Routes reversed.
  List<String> _routeSet = const <String>[];

  // Vobiz's CallUUID for the current (or most recent) call. Kept after the
  // call ends so the recording can still be matched to it; reset when the next
  // call starts.
  String? _callUuid;

  // DTMF tones go one INFO at a time, so a challenge on one cannot reorder
  // them or re-send another tone's body.
  final List<String> _dtmfQueue = <String>[];
  bool _dtmfInFlight = false;

  final Map<String, _ClientTransaction> _transactions = <String, _ClientTransaction>{};

  // BYEs and CANCELs with no final response yet, by "<Call-ID> <method>".
  final Map<String, _PendingEnd> _pendingEnds = <String, _PendingEnd>{};

  // Set while an outbound call is being prepared: an inbound INVITE then gets
  // 486 instead of ringing a client that will never show it.
  bool _outgoingReserved = false;
  Timer? _reservationTimer;

  // Registration failed while a call was up: close the socket when it ends.
  bool _closeWhenCallEnds = false;

  WebSocketChannel? _socket;

  // The socket [disconnect] is unregistering on. Its responses are still
  // read until it closes.
  WebSocketChannel? _closingSocket;
  Timer? _registrationRefreshTimer;
  CrlfKeepAlive? _crlfKeepAlive;
  Duration? _registrationRefreshDelay;

  final _connectionState =
      ValueNotifier<SipConnectionState>(SipConnectionState.disconnected);
  final _registrationState =
      ValueNotifier<SipRegistrationState>(SipRegistrationState.unregistered);

  ValueNotifier<SipConnectionState> get connectionState => _connectionState;
  ValueNotifier<SipRegistrationState> get registrationState =>
      _registrationState;

  /// Vobiz's CallUUID (`X-Calluuid`) for the current or most recent call.
  String? get callUuid => _callUuid;

  /// The SIP Call-ID of the current call: for an incoming call, its INVITE's.
  /// Null with no call.
  String? get activeSipCallId => _activeCallId;

  /// The registrar took a REGISTER that claimed a held call
  /// ([claimHeldCall]): the held INVITE should follow on this connection.
  void Function()? onHeldCallClaimed;

  /// Whether an established call (dialog) exists that in-dialog requests,
  /// such as DTMF, can be sent on.
  bool get hasActiveDialog => _activeCallId != null && _dialogConfirmed;

  /// When the registration will next be refreshed, after the last 200 OK.
  @visibleForTesting
  Duration? get registrationRefreshDelay => _registrationRefreshDelay;

  // Callbacks wired by VobizClient
  void Function()? onRegistered;
  void Function(String reason)? onRegistrationFailed;
  void Function()? onRemoteRinging;
  /// The far end received the INVITE (100 Trying): the call is no longer
  /// waiting on a response at all.
  void Function()? onTrying;
  void Function(String? sdp)? onCallProgress;
  void Function(String callerId, String sdp, Map<String, String> headers)?
      onIncomingCall;
  void Function(String sdp)? onCallAnswered;
  void Function(String? reason)? onCallEnded;
  void Function(String reason, int? sipCode)? onCallFailed;
  void Function(String reason)? onSocketError;

  /// The socket stopped answering (a REGISTER refresh timed out) and has been
  /// closed. Falls back to [onSocketError] when unset.
  void Function(String reason)? onTransportDead;

  /// Answers a re-INVITE or UPDATE that changes the session (new media, a
  /// hold): given the far end's offer, returns the answer SDP, or null to
  /// refuse it. The call then carries on unchanged (488, RFC 3261 14.2).
  /// Unset, such changes are refused. Refreshes that change nothing are
  /// answered without it.
  Future<String?> Function(String offerSdp)? onSessionOffer;

  /// Opens the WebSocket. Throws when it cannot be opened, and
  /// [SipConnectSuperseded] when [disconnect] or another [connect] replaced
  /// it before its handshake finished: that socket is closed, and the state
  /// is left to whatever replaced it.
  Future<void> connect() async {
    _manualDisconnect = false;
    _connectionState.value = SipConnectionState.connecting;
    WebSocketChannel? socket;
    try {
      socket = IOWebSocketChannel.connect(
        Uri.parse(wsUrl),
        protocols: const <String>['sip'],
        pingInterval: keepAlive.pingInterval,
        connectTimeout: const Duration(seconds: 20),
      );
      _socket = socket;
      // Await the actual TCP/TLS/WebSocket handshake. Without this, the
      // TimeoutException from connectTimeout escapes into an unguarded async
      // zone and becomes an Unhandled Exception in the Flutter error handler.
      await socket.ready;
    } catch (e) {
      if (socket != null && !identical(socket, _socket)) {
        throw const SipConnectSuperseded();
      }
      _connectionState.value = SipConnectionState.disconnected;
      _logger.error('SIP WebSocket connection failed: $e');
      // Don't call onSocketError here — the exception propagates to VobizClient
      // which emits the error event and schedules reconnects in its own catch.
      rethrow;
    }
    if (!identical(socket, _socket)) {
      _logger.info('SIP WebSocket to $wsUrl replaced before it opened; closing it');
      _closeQuietly(socket);
      throw const SipConnectSuperseded();
    }
    _connectionState.value = SipConnectionState.connected;
    _logger.info('SIP WebSocket connected to $wsUrl');
    _listenToSocket(socket);
  }

  void register(String username, String password) {
    _username = username;
    _password = password;
    _accessToken = null;
    _startRegistration();
  }

  /// Registers as [username] with an access token (JWT) instead of a
  /// password: every REGISTER and INVITE carries it as `X-Vobiz-Jwt`, and the
  /// registrar validates it in place of a digest challenge.
  void registerWithAccessToken(String username, String accessToken) {
    _username = username;
    _password = null;
    _accessToken = accessToken;
    _startRegistration();
  }

  /// Swaps the access token the next REGISTER and INVITE carry. Sends
  /// nothing: call [refreshRegistration] to present it now.
  void updateAccessToken(String accessToken) {
    if (_password != null) return;
    _accessToken = accessToken;
  }

  /// The registrar's reason for its last refusal of the access token (10001
  /// to 10010, from `X-vobiz-Jwt-Error-Code`), until the next REGISTER is
  /// accepted.
  int? get accessTokenError => _accessTokenError;

  /// From the registrar's last 200 OK (`X-vobiz-Jwt: expires=<s>;epoch-exp=<t>`):
  /// seconds the token had left by the server's clock.
  int? get accessTokenExpiresIn => _accessTokenExpiresIn;

  /// Whether the registration failure just reported to [onRegistrationFailed]
  /// was temporary: no answer, or a 408, 480 or 5xx without an access-token
  /// error. Registering again later may work. False for a refusal of the
  /// credentials (401, 403, 407, a token error code) and any other answer.
  bool get registrationFailureTemporary => _registrationFailureTemporary;
  bool _registrationFailureTemporary = false;

  /// A REGISTER answer, or no answer at all ([code] null), that says the
  /// registrar could not take the registration now rather than refused it.
  static bool _isTemporaryRegisterFailure(int? code) =>
      code == null || code == 408 || code == 480 || (code >= 500 && code < 600);

  bool get _hasCredentials =>
      _username != null && (_password != null || _accessToken != null);

  void _startRegistration() {
    _accessTokenError = null;
    _closeWhenCallEnds = false;
    _registrationState.value = SipRegistrationState.registering;
    final claim = _pendingClaim;
    _pendingClaim = null;
    _sendRegister(
        expires: registerExpires,
        auth: _AuthRetries(extraHeaders: claim ?? const <String, String>{}));
  }

  /// Claims a call Vobiz's registrar is holding for this user while a push
  /// wakes the app: the REGISTER that follows carries [headers]
  /// (`VobizPushHold.registerHeaders`: `X-Index`, `X-Label`,
  /// `X-vobiz-Registrar-Info`), its digest answer too, and the registrar then
  /// sends the held INVITE to this registration.
  ///
  /// Registered on an open socket, that REGISTER goes now and this returns
  /// true. Otherwise it returns false and the headers ride on the next
  /// REGISTER: the sign-in's ([register], [registerWithAccessToken]), a
  /// reconnect's, or another right after the one in flight is answered. Only
  /// that one REGISTER carries them; refreshes after it do not.
  ///
  /// Headers that cannot go on a header line as they are (a name that is not
  /// a SIP token, a control character in a name or value) are refused: this
  /// returns false and nothing is sent or kept.
  bool claimHeldCall(Map<String, String> headers) {
    if (headers.isEmpty) return false;
    if (!headers.entries.every((h) => _headerToken.hasMatch(h.key) && !hasControlCharacter(h.value))) {
      _logger.warn('Not claiming the held call: its hold reference cannot go into a SIP header');
      return false;
    }
    final registered = _connectionState.value == SipConnectionState.connected &&
        _registrationState.value == SipRegistrationState.registered;
    final inFlight = _transactions.values.any((tx) => tx.method == 'REGISTER');
    if (!_hasCredentials || !registered || inFlight) {
      _pendingClaim = Map<String, String>.unmodifiable(headers);
      return false;
    }
    _registrationRefreshTimer?.cancel();
    _sendRegister(
        expires: registerExpires,
        auth: _AuthRetries(refresh: true, timeout: refreshTimeout, extraHeaders: headers));
    return true;
  }

  /// Drops a claim no REGISTER has carried yet: the pushed call expired or
  /// was taken some other way.
  void cancelHeldCallClaim() => _pendingClaim = null;

  /// Whether a held call's reference is waiting for the next REGISTER.
  bool get hasPendingClaim => _pendingClaim != null;

  /// Refreshes the registration now, on the open socket: the same REGISTER
  /// (and digest retry) as the periodic refresh, whose timer is re-armed from
  /// the new grant. A call in progress is not affected.
  ///
  /// No answer within [refreshTimeout] means the socket is dead: it is closed
  /// and [onTransportDead] reports it, so the client reconnects. A final
  /// refusal (403, say) fails the registration as usual.
  ///
  /// Returns false, sending nothing, unless the socket is connected and the
  /// registration is up; reconnecting is then the caller's job. Returns true
  /// without sending when a REGISTER is already in flight.
  bool refreshRegistration() {
    if (!_hasCredentials) return false;
    if (_connectionState.value != SipConnectionState.connected ||
        _registrationState.value != SipRegistrationState.registered) {
      return false;
    }
    if (_transactions.values.any((tx) => tx.method == 'REGISTER')) return true;
    _registrationRefreshTimer?.cancel();
    _sendRegister(
        expires: registerExpires,
        auth: _AuthRetries(refresh: true, timeout: refreshTimeout));
    return true;
  }

  /// Registers again on the socket that is still open, after the registrar
  /// refused the last REGISTER: with a fresh access token, say. A call on
  /// the socket keeps it (a refused registration only closes it once the
  /// call ends), and this keeps it open afterwards too.
  ///
  /// Returns false, sending nothing, when the socket is closed: connect
  /// again instead. Returns true without sending when a REGISTER is already
  /// in flight.
  bool registerAgain() {
    if (!_hasCredentials) return false;
    if (_connectionState.value != SipConnectionState.connected) return false;
    if (_transactions.values.any((tx) => tx.method == 'REGISTER')) return true;
    _registrationRefreshTimer?.cancel();
    _startRegistration();
    return true;
  }

  /// Marks the line busy while an outbound call is being prepared (microphone,
  /// ICE gathering), so an inbound INVITE arriving meanwhile is turned away
  /// with 486 instead of ringing unseen and tangling with the new dialog.
  /// [call] and [hangup] end the reservation; so does [outgoingReservation]
  /// passing without either.
  void reserveForOutgoingCall() {
    _outgoingReserved = true;
    _reservationTimer?.cancel();
    _reservationTimer = Timer(outgoingReservation, _releaseReservation);
  }

  /// Sends the INVITE for a new outbound call to [toUser]. Throws
  /// [ArgumentError], sending nothing, when [toUser] or a header in
  /// [extraHeaders] could not go into the message as it is.
  void call(String toUser, String sdp,
      {Map<String, String> extraHeaders = const <String, String>{}}) {
    if (toUser.isEmpty || hasControlCharacter(toUser)) {
      throw ArgumentError.value(toUser, 'toUser', 'cannot go into a SIP Request-URI');
    }
    if (!extraHeaders.entries.every((h) => _headerToken.hasMatch(h.key) && !hasControlCharacter(h.value))) {
      throw ArgumentError.value(extraHeaders.keys.join(', '), 'extraHeaders', 'cannot all go into SIP headers');
    }
    _releaseReservation();
    // An inbound INVITE that arrived while this call was being prepared was
    // never shown to the app. Give its caller a final answer now rather than
    // let it ring out, and start the new dialog from clean state.
    final waiting = _pendingInvite;
    if (waiting != null) {
      _send(SipBuilder.busyHere(invite: waiting, localTag: _localTag));
    }
    _clearCallState();
    _activeCallId = '${_rand(12)}@vobiz-client';
    _activeToUser = toUser;
    _activeRemoteTarget = 'sip:$toUser@$sipServer';
    _activeRemotePartyHeader = '<sip:$toUser@$sipServer>';
    _localSdp = sdp;
    _callUuid = null;
    final invite = _OutgoingInvite(
      callId: _activeCallId!,
      toUser: toUser,
      sdp: sdp,
      extraHeaders: Map<String, String>.unmodifiable(extraHeaders),
      requestUri: 'sip:$toUser@$sipServer',
      toHeader: '<sip:$toUser@$sipServer>',
    );
    _outgoing = invite;
    _sendInvite(invite);
  }

  /// Sends one DTMF tone on the established call as an `application/dtmf-relay`
  /// INFO. Tones are sent one at a time, each after the previous one's final
  /// response. Returns false when there is no established call to send it on.
  bool sendDtmf(String tone, {int durationMs = 100}) {
    if (!hasActiveDialog || _username == null) return false;
    _dtmfQueue.add(SipBuilder.dtmfRelayBody(tone, durationMs: durationMs));
    _sendNextDtmf();
    return true;
  }

  /// Sends a re-INVITE with [sdp] on the established call (hold or resume)
  /// as a client transaction, answers a digest challenge the usual way, ACKs
  /// the 2xx and completes with its SDP. Fails with [SipRequestFailed] on a
  /// final error response (the call carries on as it was, RFC 3261 14.1), if
  /// the call ends first, or after [transactionTimeout].
  Future<String> reInvite(String sdp) {
    if (!hasActiveDialog || _username == null) {
      return Future<String>.error(StateError('No connected call to renegotiate'));
    }
    if (_reInvite != null || _offerInProgress) {
      return Future<String>.error(StateError('A session change is already in progress'));
    }
    final completer = Completer<String>();
    _reInvite = completer;
    _sendReInvite(_currentDialog(), sdp, _AuthRetries(), completer);
    return completer.future;
  }

  void answer(String sdp) {
    if (_pendingInvite == null) return;
    _lastAnsweredInvite = _pendingInvite;
    _lastAnsweredSdp = sdp;
    _localSdp = sdp;
    _send(SipBuilder.ok200(
      invite: _pendingInvite!,
      contactUri: _contactUri,
      localTag: _localTag,
      sdp: sdp,
    ));
    _pendingInvite = null;
    _dialogConfirmed = true;
  }

  /// Declines the ringing INVITE with [code] (486 Busy Here by default). Once
  /// the call has been answered there is no INVITE left to decline, so the
  /// call is hung up with a BYE instead of being dropped silently.
  void reject([int code = 486, String reason = 'Busy Here']) {
    final invite = _pendingInvite;
    if (invite == null) {
      if (_dialogConfirmed) hangup();
      return;
    }
    _send(SipBuilder.response(
        request: invite, code: code, reason: reason, localTag: _localTag));
    _endCall();
  }

  /// Forgets the established call without signalling it. For a call the far
  /// end no longer has: it answered a request within the dialog with 481
  /// (Call/Transaction Does Not Exist), so a BYE would only be refused too.
  /// RFC 3261 12.2.1.2: the UAC SHOULD then terminate the dialog.
  void abandonCall() {
    if (_activeCallId == null) return;
    _endCall();
    onCallEnded?.call('The call no longer exists');
  }

  void hangup() {
    _releaseReservation();

    // Ringing inbound call: the callee must not send BYE on an early dialog
    // (RFC 3261 15). It ends the INVITE with a final response.
    final ringing = _pendingInvite;
    if (ringing != null) {
      _send(SipBuilder.busyHere(invite: ringing, localTag: _localTag));
      _endCall();
      onCallEnded?.call('Hung up');
      return;
    }

    // Outbound call with no final response: a BYE would not stop it, the far
    // phone would keep ringing. CANCEL it (RFC 3261 9.1), and only once a
    // provisional response has arrived; until then the CANCEL waits. A 2xx
    // that gets there first is ACKed and ended with BYE.
    final outgoing = _outgoing;
    if (outgoing != null && !outgoing.answered) {
      outgoing.hungUp = true;
      if (outgoing.provisional) _sendCancel(outgoing);
      _endCall();
      onCallEnded?.call('Hung up');
      return;
    }

    if (_activeCallId == null || _username == null) return;
    _sendBye(_currentDialog());
    _endCall();
    onCallEnded?.call('Hung up');
  }

  /// Ends any call, unregisters (REGISTER with `Expires: 0`, waiting up to
  /// [unregisterTimeout] for the registrar) and closes the socket. Completes
  /// once the socket is closed; the state reads disconnected at once.
  ///
  /// For a reconnect, which replaces the socket rather than signing out:
  /// [unregister] false sends no `Expires: 0` (a new REGISTER follows at
  /// once, and the old socket is usually dead), and [keepCall] keeps the
  /// established call's dialog, so it can still be hung up (or be hung up)
  /// once registered again. [keepCall] implies no unregistration.
  Future<void> disconnect({bool keepCall = false, bool unregister = true}) async {
    // A held call can only be claimed by a sign-in that is still wanted.
    _pendingClaim = null;
    _releaseReservation();
    _registrationRefreshTimer?.cancel();
    _crlfKeepAlive?.stop();
    _registrationRefreshDelay = null;
    if (!keepCall) {
      // End the call properly while the socket is still up.
      if (_activeCallId != null || _pendingInvite != null) hangup();
      _clearCallState();
    }
    _closeWhenCallEnds = false;
    _manualDisconnect = true;

    final socket = _socket;
    final wasRegistered = !keepCall &&
        unregister &&
        _registrationState.value == SipRegistrationState.registered &&
        _username != null;
    // A REGISTER still in flight must not mark this client registered again.
    _dropTransactions('REGISTER');
    _socket = null;
    _connectionState.value = SipConnectionState.disconnected;
    _registrationState.value = SipRegistrationState.unregistered;

    if (wasRegistered) {
      final done = Completer<void>();
      _closingSocket = socket;
      _sendRegister(
        expires: 0,
        auth: _AuthRetries(),
        socket: socket,
        onUnregistered: () {
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(unregisterTimeout, onTimeout: () {
        _logger.warn('No answer to the unregistration; closing anyway');
      });
      // Only this socket's: a sign-in on a new socket may have sent its
      // REGISTER meanwhile.
      _dropRegistersSentOn(socket);
      if (identical(_closingSocket, socket)) _closingSocket = null;
    }
    _closeQuietly(socket);
  }

  // ---------------------------------------------------------------------------
  // Private — sending
  // ---------------------------------------------------------------------------

  /// Sends a request and waits for its responses as a client transaction.
  void _sendRequest({
    required String message,
    required String branch,
    required String method,
    required int cseq,
    required String callId,
    required void Function(_ClientTransaction tx, SipMessage response) onResponse,
    void Function()? onTimeout,
    WebSocketChannel? socket,
    Duration? timeout,
  }) {
    final tx = _ClientTransaction(
      branch: branch,
      method: method,
      cseq: cseq,
      callId: callId,
      socket: socket ?? _socket,
      onResponse: onResponse,
      onTimeout: onTimeout,
      timeout: timeout,
    );
    _transactions[tx.key] = tx;
    _armTimer(tx);
    _send(message, socket: tx.socket);
  }

  void _armTimer(_ClientTransaction tx) {
    tx.timer?.cancel();
    tx.timer = Timer(tx.timeout ?? transactionTimeout, () {
      if (!identical(_transactions[tx.key], tx)) return;
      _transactions.remove(tx.key);
      _logger.warn('No final response to ${tx.method} (CSeq ${tx.cseq})');
      tx.onTimeout?.call();
    });
  }

  void _dropTransactions(String method) => _dropWhere((tx) => tx.method == method);

  /// A socket that closed, or was replaced, never brings the answer to a
  /// REGISTER sent on it: drop those, so their timeouts cannot fail a later
  /// registration.
  void _dropRegistersSentOn(WebSocketChannel? socket) =>
      _dropWhere((tx) => tx.method == 'REGISTER' && identical(tx.socket, socket));

  void _dropWhere(bool Function(_ClientTransaction tx) test) {
    _transactions.removeWhere((_, tx) {
      if (!test(tx)) return false;
      tx.timer?.cancel();
      return true;
    });
  }

  void _sendRegister({
    required int expires,
    required _AuthRetries auth,
    String? authHeaderName,
    String? authHeader,
    WebSocketChannel? socket,
    void Function()? onUnregistered,
  }) {
    final username = _username;
    if (username == null) return;
    final branch = SipBuilder.newBranch();
    final cseq = _cseq++;
    final unregistering = onUnregistered != null;
    final sentOn = socket ?? _socket;
    _sendRequest(
      message: SipBuilder.register(
        sipServer: sipServer,
        username: username,
        contactUri: _contactUri,
        localTag: _localTag,
        callId: _registerCallId,
        cseq: cseq,
        expires: expires,
        branch: branch,
        authHeaderName: authHeaderName,
        authHeader: authHeader,
        extraHeaders: <String, String>{..._accessTokenHeaders, ...auth.extraHeaders},
      ),
      branch: branch,
      method: 'REGISTER',
      cseq: cseq,
      callId: _registerCallId,
      socket: socket,
      timeout: unregistering ? null : auth.timeout,
      onResponse: (tx, msg) => _handleRegisterResponse(
        tx,
        msg,
        expires: expires,
        auth: auth,
        onUnregistered: onUnregistered,
      ),
      onTimeout: unregistering
          ? onUnregistered
          : auth.refresh
              ? () => _transportDead(sentOn, 'No answer to the REGISTER refresh')
              : () => _failRegistration('Registration timed out: no answer from the registrar',
                  temporary: true),
    );
  }

  /// The access token, as the header a REGISTER or INVITE carries it in.
  Map<String, String> get _accessTokenHeaders {
    final token = _accessToken;
    return token == null
        ? const <String, String>{}
        : <String, String>{SipBuilder.accessTokenHeader: token};
  }

  void _sendInvite(_OutgoingInvite invite, {String? authHeaderName, String? authHeader}) {
    final username = _username;
    if (username == null) return;
    invite.branch = SipBuilder.newBranch();
    invite.cseq = _cseq++;
    invite.provisional = false;
    invite.socket = _socket;
    _sendRequest(
      message: SipBuilder.invite(
        sipServer: sipServer,
        fromUser: username,
        contactUri: _contactUri,
        toUser: invite.toUser,
        localTag: _localTag,
        callId: invite.callId,
        cseq: invite.cseq,
        sdp: invite.sdp,
        branch: invite.branch,
        authHeaderName: authHeaderName,
        authHeader: authHeader,
        // The re-sent INVITE after a 407 must carry the same headers, or the
        // webhook never sees them. A token sign-in adds its token, read now
        // so a refreshed one is used.
        extraHeaders: <String, String>{...invite.extraHeaders, ..._accessTokenHeaders},
      ),
      branch: invite.branch,
      method: 'INVITE',
      cseq: invite.cseq,
      callId: invite.callId,
      onResponse: (tx, msg) => _handleInviteResponse(invite, tx, msg),
      onTimeout: () => _onInviteTimeout(invite),
    );
  }

  void _sendCancel(_OutgoingInvite invite) {
    if (invite.cancelSent || _username == null) return;
    invite.cancelSent = true;
    final pendingKey = '${invite.callId} CANCEL';
    final pending =
        _pendingEnds[pendingKey] ??= _PendingEnd('CANCEL', invite.callId, _username!, () {
      // The INVITE's branch and CSeq again, on the connection the client has
      // now: the registrar matches a CANCEL to its INVITE by those.
      invite.cancelSent = false;
      invite.socket = _socket;
      _sendCancel(invite);
    });
    pending.sentOn = invite.socket;
    _sendRequest(
      message: SipBuilder.cancel(
        requestUri: invite.requestUri,
        fromUser: _username!,
        toHeader: invite.toHeader,
        sipServer: sipServer,
        localTag: _localTag,
        callId: invite.callId,
        cseq: invite.cseq,
        branch: invite.branch,
      ),
      branch: invite.branch,
      method: 'CANCEL',
      cseq: invite.cseq,
      callId: invite.callId,
      socket: invite.socket,
      // A 200 to the CANCEL only means it arrived; the INVITE's own 487 (or
      // a 2xx that crossed it) is what ends the call.
      onResponse: (_, msg) {
        if (msg.statusCode >= 200) _pendingEnds.remove(pendingKey);
        if (msg.statusCode >= 300) {
          _logger.warn('CANCEL refused: ${msg.statusCode} ${_reasonPhrase(msg)}');
        }
      },
    );
    // RFC 3261 9.1: an INVITE with no final response 64 × T1 after its
    // CANCEL is over.
    final tx = _transactions['${invite.branch} INVITE'];
    if (tx != null) _armTimer(tx);
  }

  void _sendBye(
    _Dialog dialog, {
    WebSocketChannel? socket,
    _AuthRetries? auth,
    String? authHeaderName,
    String? authHeader,
  }) {
    final username = _username;
    if (username == null) return;
    final retries = auth ?? _AuthRetries();
    final branch = SipBuilder.newBranch();
    final cseq = _cseq++;
    final pendingKey = '${dialog.callId} BYE';
    final pending = _pendingEnds[pendingKey] ??=
        _PendingEnd('BYE', dialog.callId, username, () => _sendBye(dialog));
    pending.sentOn = socket ?? _socket;
    _sendRequest(
      message: SipBuilder.bye(
        requestUri: dialog.remoteTarget,
        fromUser: username,
        toHeader: dialog.remoteParty,
        sipServer: sipServer,
        localTag: _localTag,
        callId: dialog.callId,
        cseq: cseq,
        branch: branch,
        authHeaderName: authHeaderName,
        authHeader: authHeader,
        routes: dialog.routes,
      ),
      branch: branch,
      method: 'BYE',
      cseq: cseq,
      callId: dialog.callId,
      socket: socket,
      onResponse: (tx, msg) {
        final code = msg.statusCode;
        if (code < 200) return;
        // A challenged BYE that is never answered leaves the far leg up, and
        // billed, while the app shows the call ended.
        if (code == 401 || code == 407) {
          final challenge = _challenge(msg);
          if (_password != null && challenge.isNotEmpty && retries.allow(challenge)) {
            final authValue = SipDigestAuth.buildAuthHeader(
              wwwAuthenticate: challenge,
              method: 'BYE',
              uri: dialog.remoteTarget,
              username: username,
              password: _password!,
            );
            if (authValue != null) {
              _sendBye(
                dialog,
                socket: tx.socket,
                auth: retries,
                authHeaderName: _authorizationHeaderFor(code),
                authHeader: authValue,
              );
              return;
            }
          }
        }
        // Answered, even refused (481: the far end already ended the call):
        // nothing to send again.
        _pendingEnds.remove(pendingKey);
        if (code >= 300) _logger.warn('BYE refused: $code ${_reasonPhrase(msg)}');
      },
    );
  }

  /// Registered on a (possibly new) connection: sends again each BYE and
  /// CANCEL that went out with no connection, or on one that has since been
  /// replaced, and has had no answer. Ones that are too old, or belong to
  /// another sign-in, are dropped.
  void _resendPendingEnds() {
    if (_pendingEnds.isEmpty) return;
    final now = DateTime.now();
    for (final entry in _pendingEnds.entries.toList()) {
      final pending = entry.value;
      if (now.difference(pending.since) > pendingEndWindow ||
          pending.username != _username ||
          pending.resends >= _pendingEndMaxResends) {
        _pendingEnds.remove(entry.key);
        continue;
      }
      // In flight on this very connection: its answer may still come.
      if (pending.sentOn != null && identical(pending.sentOn, _socket)) continue;
      pending.resends++;
      _logger.info('Sending ${pending.method} again for call ${pending.callId}: the '
          'connection was down when it went out');
      pending.resend();
    }
  }

  void _sendNextDtmf() {
    if (_dtmfInFlight || _dtmfQueue.isEmpty || !hasActiveDialog) return;
    _dtmfInFlight = true;
    _sendInfo(_currentDialog(), _dtmfQueue.removeAt(0), _AuthRetries());
  }

  void _sendInfo(
    _Dialog dialog,
    String body,
    _AuthRetries auth, {
    WebSocketChannel? socket,
    String? authHeaderName,
    String? authHeader,
  }) {
    final username = _username;
    if (username == null) return;
    final branch = SipBuilder.newBranch();
    final cseq = _cseq++;
    void done() {
      // Only the current call's queue moves on.
      if (dialog.callId != _activeCallId) return;
      _dtmfInFlight = false;
      _sendNextDtmf();
    }

    _sendRequest(
      message: SipBuilder.info(
        requestUri: dialog.remoteTarget,
        fromUser: username,
        toHeader: dialog.remoteParty,
        sipServer: sipServer,
        localTag: _localTag,
        callId: dialog.callId,
        cseq: cseq,
        contentType: 'application/dtmf-relay',
        body: body,
        branch: branch,
        authHeaderName: authHeaderName,
        authHeader: authHeader,
        routes: dialog.routes,
      ),
      branch: branch,
      method: 'INFO',
      cseq: cseq,
      callId: dialog.callId,
      socket: socket,
      onResponse: (tx, msg) {
        final code = msg.statusCode;
        if (code < 200) return;
        if (code == 401 || code == 407) {
          // The retry carries this INFO's own tone, not whichever was sent last.
          final challenge = _challenge(msg);
          if (_password != null && challenge.isNotEmpty && auth.allow(challenge)) {
            final authValue = SipDigestAuth.buildAuthHeader(
              wwwAuthenticate: challenge,
              method: 'INFO',
              uri: dialog.remoteTarget,
              username: username,
              password: _password!,
            );
            if (authValue != null) {
              _sendInfo(
                dialog,
                body,
                auth,
                socket: tx.socket,
                authHeaderName: _authorizationHeaderFor(code),
                authHeader: authValue,
              );
              return;
            }
          }
        }
        if (code >= 300) {
          _logger.warn('DTMF INFO refused: $code ${_reasonPhrase(msg)}');
        }
        done();
      },
      onTimeout: done,
    );
  }

  void _sendReInvite(
    _Dialog dialog,
    String sdp,
    _AuthRetries auth,
    Completer<String> completer, {
    WebSocketChannel? socket,
    String? authHeaderName,
    String? authHeader,
  }) {
    final username = _username;
    if (username == null) return;
    final branch = SipBuilder.newBranch();
    final cseq = _cseq++;

    void fail(String message, int? code) {
      if (identical(_reInvite, completer)) _reInvite = null;
      if (!completer.isCompleted) {
        completer.completeError(SipRequestFailed(message, code));
      }
    }

    _sendRequest(
      message: SipBuilder.reInvite(
        requestUri: dialog.remoteTarget,
        fromUser: username,
        toHeader: dialog.remoteParty,
        sipServer: sipServer,
        localTag: _localTag,
        callId: dialog.callId,
        cseq: cseq,
        contactUri: _contactUri,
        sdp: sdp,
        branch: branch,
        authHeaderName: authHeaderName,
        authHeader: authHeader,
        routes: dialog.routes,
      ),
      branch: branch,
      method: 'INVITE',
      cseq: cseq,
      callId: dialog.callId,
      socket: socket,
      onResponse: (tx, msg) {
        final code = msg.statusCode;
        if (code < 200) return;
        if (code < 300) {
          // ACK every 2xx, even for a call that has ended meanwhile.
          final ack = SipBuilder.ack(
            requestUri: dialog.remoteTarget,
            fromUser: username,
            toHeader: dialog.remoteParty,
            sipServer: sipServer,
            localTag: _localTag,
            callId: dialog.callId,
            cseq: cseq,
            routes: dialog.routes,
          );
          _last2xxKey = '${dialog.callId} $cseq';
          _last2xxAck = ack;
          _send(ack, socket: tx.socket);
          if (dialog.callId != _activeCallId) {
            fail('The call ended', null);
            return;
          }
          if (identical(_reInvite, completer)) _reInvite = null;
          if (msg.body.trim().isNotEmpty) {
            _localSdp = sdp;
            _remoteSdp = msg.body;
          }
          if (!completer.isCompleted) completer.complete(msg.body);
          return;
        }
        if (code == 401 || code == 407) {
          final challenge = _challenge(msg);
          if (_password != null && challenge.isNotEmpty && auth.allow(challenge)) {
            final authValue = SipDigestAuth.buildAuthHeader(
              wwwAuthenticate: challenge,
              method: 'INVITE',
              uri: dialog.remoteTarget,
              username: username,
              password: _password!,
            );
            if (authValue != null) {
              _sendReInvite(
                dialog,
                sdp,
                auth,
                completer,
                socket: tx.socket,
                authHeaderName: _authorizationHeaderFor(code),
                authHeader: authValue,
              );
              return;
            }
          }
        }
        fail('re-INVITE refused ($code ${_reasonPhrase(msg)})', code);
      },
      onTimeout: () => fail('No answer to the re-INVITE', null),
    );
  }

  String _inDialogRequestUri() =>
      _activeRemoteTarget ?? 'sip:${_activeToUser ?? 'unknown'}@$sipServer';

  _Dialog _currentDialog() => _Dialog(
        callId: _activeCallId!,
        remoteTarget: _inDialogRequestUri(),
        remoteParty: _activeRemotePartyHeader!,
        routes: _routeSet,
      );

  void _send(String message, {WebSocketChannel? socket}) {
    _logger.info('SIP >> ${_summarize(message)}');
    debugOnSend?.call(message);
    try {
      (socket ?? _socket)?.sink.add(message);
    } catch (e) {
      // A socket that has started closing refuses new messages.
      _logger.warn('SIP send failed: $e');
    }
  }

  void _closeQuietly(WebSocketChannel? socket) {
    if (socket == null) return;
    try {
      socket.sink.close();
    } catch (_) {}
  }

  /// Test seam: sees every message this service sends.
  @visibleForTesting
  void Function(String message)? debugOnSend;

  /// Test seam: handles [raw] as if it had arrived on the WebSocket.
  @visibleForTesting
  void debugReceive(String raw) => _handleMessage(raw);

  /// Test seam: uses [socket] as if [connect] had opened it.
  @visibleForTesting
  void debugAttachSocket(WebSocketChannel socket) {
    _manualDisconnect = false;
    _socket = socket;
    _connectionState.value = SipConnectionState.connected;
    _listenToSocket(socket);
  }

  // ---------------------------------------------------------------------------
  // Private — receiving
  // ---------------------------------------------------------------------------

  void _listenToSocket(WebSocketChannel socket) {
    // Guard so onError + onDone both firing only triggers onSocketError once.
    var errorReported = false;
    // A sign-in replaces the socket. The old one's close arrives later and
    // must not be mistaken for the new connection dropping, which would
    // schedule a reconnect over a healthy session.
    bool isCurrent() => identical(socket, _socket);

    socket.stream.listen(
      (raw) {
        // A binary frame carries the message as bytes: the WebSocket module
        // sends one when the text is not valid UTF-8 (a Latin-1 caller name).
        final text = raw is List<int> ? utf8.decode(raw, allowMalformed: true) : raw.toString();
        if (isCurrent()) {
          _handleMessage(text);
        } else if (identical(socket, _closingSocket)) {
          // Unregistering: only the answers to our own requests matter.
          _handleMessage(text, responsesOnly: true);
        }
      },
      onError: (Object e) {
        if (!isCurrent()) return;
        _logger.error('SIP WebSocket error: $e');
        _dropRegistersSentOn(socket);
        _connectionState.value = SipConnectionState.disconnected;
        _registrationState.value = SipRegistrationState.failed;
        _registrationRefreshTimer?.cancel();
        _crlfKeepAlive?.stop();
        if (!_manualDisconnect && !errorReported) {
          errorReported = true;
          onSocketError?.call('SIP socket error: $e');
        }
      },
      onDone: () {
        if (!isCurrent()) return;
        _logger.warn('SIP WebSocket closed');
        _dropRegistersSentOn(socket);
        _connectionState.value = SipConnectionState.disconnected;
        _registrationRefreshTimer?.cancel();
        _crlfKeepAlive?.stop();
        if (!_manualDisconnect && !errorReported) {
          errorReported = true;
          _registrationState.value = SipRegistrationState.failed;
          onSocketError?.call('SIP socket closed unexpectedly');
        }
      },
    );
  }

  void _handleMessage(String raw, {bool responsesOnly = false}) {
    if (raw.trim().isEmpty) {
      // A bare CRLF is the RFC 5626 keep-alive pong.
      _crlfKeepAlive?.pongReceived();
      return;
    }
    _logger.info('SIP << ${_summarize(raw)}');
    final SipMessage msg;
    try {
      msg = SipParser.parse(raw);
    } catch (e) {
      _logger.warn('Dropped a SIP message that could not be read: $e');
      return;
    }
    if (!msg.isRequest && (msg.statusCode < 100 || msg.statusCode > 699)) {
      _logger.warn('Dropped a response with no valid status code: ${_summarize(raw)}');
      return;
    }
    if (msg.isRequest) {
      if (!responsesOnly) _handleRequest(msg);
    } else {
      _handleResponse(msg);
    }
  }

  void _handleRequest(SipMessage msg) {
    switch (msg.method) {
      case 'INVITE':
        _handleIncomingInvite(msg);
        break;
      case 'OPTIONS':
        _replyOk(msg);
        break;
      case 'CANCEL':
        _replyOk(msg);
        // A CANCEL only stops an INVITE still waiting for its final
        // response; after the 200 OK it changes nothing (RFC 3261 9.2).
        final cancelled = _pendingInvite;
        if (!_isCurrentCall(msg) || cancelled == null) break;
        // The cancelled INVITE still needs its own final answer, or the
        // registrar and media server keep its transaction open.
        _send(SipBuilder.requestTerminated(invite: cancelled, localTag: _localTag));
        _endCall();
        onCallEnded?.call(_describeReason(msg.header('Reason')) ?? 'Caller cancelled');
        break;
      case 'ACK':
        break;
      case 'BYE':
        _replyOk(msg);
        if (!_isCurrentCall(msg)) break;
        _endCall();
        onCallEnded?.call(_describeReason(msg.header('Reason')) ?? 'Remote party hung up');
        break;
      case 'INFO':
        // Mid-call INFO from the far end (such as a DTMF relay). Acknowledge it
        // so the dialog is not torn down for an unanswered request.
        _replyOk(msg);
        break;
      case 'UPDATE':
        if (!_isCurrentCall(msg)) {
          _send(SipBuilder.response(
              request: msg, code: 481, reason: 'Call/Transaction Does Not Exist'));
          break;
        }
        _handleSessionOffer(msg);
        break;
      case 'REFER':
      case 'NOTIFY':
      case 'SUBSCRIBE':
      case 'MESSAGE':
      case 'PRACK':
      case 'PUBLISH':
        // Known methods this client does not take part in. Every request
        // gets a final response, or its sender retries and then may end the
        // dialog (RFC 3261 8.2.1).
        _send(SipBuilder.response(
          request: msg,
          code: 405,
          reason: 'Method Not Allowed',
          headers: const <String>['Allow: ${SipBuilder.allow}'],
        ));
        break;
      default:
        _send(SipBuilder.response(request: msg, code: 501, reason: 'Not Implemented'));
    }
  }

  void _handleIncomingInvite(SipMessage msg) {
    final incomingCallId = msg.header('Call-ID');

    if (incomingCallId != null && incomingCallId == _activeCallId) {
      _handleInviteInDialog(msg);
      return;
    }
    if (_outgoingReserved || _activeCallId != null || _pendingInvite != null) {
      _send(SipBuilder.busyHere(invite: msg, localTag: _localTag));
      return;
    }

    _pendingInvite = msg;
    _dialogConfirmed = false;
    _activeCallId = msg.header('Call-ID');
    _callUuid = _nonEmpty(msg.header('X-Calluuid'));
    final callerId = _extractCallerId(msg);
    final parsedTo = _extractUser(msg.header('To') ?? '');
    _activeToUser = parsedTo == 'Unknown' ? callerId : parsedTo;
    final fromHeader = msg.header('From') ?? '';
    _activeRemoteTarget = _extractUri(msg.header('Contact') ?? fromHeader);
    _activeRemotePartyHeader = fromHeader;
    _routeSet = msg.headerValues('Record-Route');
    _remoteSdp = msg.body;

    // Custom headers the caller (or <Dial><User sipHeaders="...">) attached.
    final headers = VobizSipHeaders.pick(msg.headers);

    _send(SipBuilder.ringing(invite: msg, localTag: _localTag, contactUri: _contactUri));
    _logger.info('Incoming call from $callerId');
    onIncomingCall?.call(callerId, msg.body, headers);
  }

  /// An INVITE on the current call's Call-ID: a repeat of the INVITE being
  /// answered, or a re-INVITE (a session refresh, a hold, new media).
  void _handleInviteInDialog(SipMessage msg) {
    final cseq = _extractCSeqNumber(msg.header('CSeq'));
    final ringing = _pendingInvite;
    if (ringing != null) {
      // The INVITE that is ringing, sent again: ring again.
      if (cseq == _extractCSeqNumber(ringing.header('CSeq'))) {
        _send(SipBuilder.ringing(invite: msg, localTag: _localTag, contactUri: _contactUri));
      } else {
        // A second INVITE before the first has its final response (RFC 3261 14.2).
        _send(SipBuilder.response(
          request: msg,
          code: 500,
          reason: 'Server Internal Error',
          localTag: _localTag,
          headers: const <String>['Retry-After: 1'],
        ));
      }
      return;
    }
    final answered = _lastAnsweredInvite;
    if (answered != null &&
        _lastAnsweredSdp != null &&
        cseq == _extractCSeqNumber(answered.header('CSeq'))) {
      // The answered INVITE, sent again because our 200 was not seen yet.
      _send(SipBuilder.ok200(
        invite: answered,
        contactUri: _contactUri,
        localTag: _localTag,
        sdp: _lastAnsweredSdp!,
      ));
      return;
    }
    if (!_dialogConfirmed) {
      // Our own INVITE for this call is still pending.
      _send(SipBuilder.response(request: msg, code: 491, reason: 'Request Pending'));
      return;
    }
    _handleSessionOffer(msg);
  }

  /// A re-INVITE or UPDATE on the current call. Each is a transaction of its
  /// own and gets its own final response: its own Via and CSeq (RFC 3261
  /// 14.2), never a replay of the call's first 200 OK.
  void _handleSessionOffer(SipMessage msg) {
    final cseq = msg.header('CSeq') ?? '';
    if (cseq == _lastOfferReplyCSeq && _lastOfferReply != null) {
      _send(_lastOfferReply!);
      return;
    }
    if (_reInvite != null && msg.method == 'INVITE') {
      // Both ends renegotiating at once (RFC 3261 14.2): the far end retries.
      _send(SipBuilder.response(request: msg, code: 491, reason: 'Request Pending'));
      return;
    }
    if (_offerInProgress) {
      _send(SipBuilder.response(
        request: msg,
        code: 500,
        reason: 'Server Internal Error',
        headers: const <String>['Retry-After: 1'],
      ));
      return;
    }
    final isInvite = msg.method == 'INVITE';
    final offer = msg.body.trim();
    final local = _localSdp;

    void reply(int code, String reason, {String? sdp}) {
      final response = SipBuilder.response(
        request: msg,
        code: code,
        reason: reason,
        headers: code == 200
            ? <String>[
                'Contact: <$_contactUri>',
                'Allow: ${SipBuilder.allow}',
                'User-Agent: vobiz_flutter_sdk',
              ]
            : const <String>[],
        contentType: sdp == null ? null : 'application/sdp',
        body: sdp ?? '',
      );
      _lastOfferReplyCSeq = cseq;
      _lastOfferReply = response;
      _send(response);
    }

    if (offer.isEmpty) {
      // An UPDATE without a body only refreshes the dialog. A re-INVITE
      // without one asks for an offer: the session as it stands.
      if (!isInvite) {
        reply(200, 'OK');
      } else if (local != null) {
        reply(200, 'OK', sdp: local);
      } else {
        reply(488, 'Not Acceptable Here');
      }
      return;
    }
    if (local == null) {
      // No session of ours yet (the call is still ringing).
      reply(488, 'Not Acceptable Here');
      return;
    }
    if (_sameSession(offer, _remoteSdp)) {
      // Same session version (RFC 3264 8): a refresh. Answer with ours,
      // unchanged.
      reply(200, 'OK', sdp: local);
      return;
    }
    final handler = onSessionOffer;
    if (handler == null) {
      // A change this client cannot make on its own. Refusing it keeps the
      // call up as it was (RFC 3261 14.2).
      reply(488, 'Not Acceptable Here');
      return;
    }
    final callId = _activeCallId;
    _offerInProgress = true;
    Future<String?>.sync(() => handler(offer)).then((answerSdp) {
      if (_activeCallId != callId) return;
      _offerInProgress = false;
      if (answerSdp == null) {
        reply(488, 'Not Acceptable Here');
        return;
      }
      _remoteSdp = offer;
      _localSdp = answerSdp;
      reply(200, 'OK', sdp: answerSdp);
    }, onError: (Object e) {
      if (_activeCallId != callId) return;
      _offerInProgress = false;
      _logger.warn('Could not answer the session change: $e');
      reply(488, 'Not Acceptable Here');
    });
  }

  /// Whether two SDPs describe the same session version: the same `o=` line
  /// (or, without one, the same text).
  static bool _sameSession(String offer, String? current) {
    if (current == null) return false;
    String? origin(String sdp) => RegExp(r'^o=.*$', multiLine: true)
        .firstMatch(sdp)
        ?.group(0)
        ?.trim();
    final a = origin(offer);
    final b = origin(current);
    if (a == null || b == null) return offer.trim() == current.trim();
    return a == b;
  }

  void _handleResponse(SipMessage msg) {
    final cseqParts = (msg.header('CSeq') ?? '').trim().split(RegExp(r'\s+'));
    final number = int.tryParse(cseqParts.first);
    final method = cseqParts.length > 1 ? cseqParts[1].toUpperCase() : '';
    final callId = msg.header('Call-ID');

    var tx = _transactions['${_topBranch(msg)} $method'];
    // A hop that rewrote the Via: fall back to Call-ID, CSeq number and
    // method, which are unique for this client's requests.
    tx ??= _transactions.values
        .where((t) => t.method == method && t.cseq == number && t.callId == callId)
        .firstOrNull;
    if (tx == null) {
      if (method == 'INVITE' && msg.statusCode >= 200 && msg.statusCode < 300) {
        _resendAckFor(msg);
      } else {
        _logger.info('No request waiting for ${msg.firstLine} (${msg.header('CSeq')})');
      }
      return;
    }
    if (msg.statusCode >= 200) {
      tx.timer?.cancel();
      _transactions.remove(tx.key);
    }
    tx.onResponse(tx, msg);
  }

  /// A 2xx repeated after its INVITE transaction ended: the far end did not
  /// get our ACK yet. Send it again; the call is already set up.
  void _resendAckFor(SipMessage msg) {
    final key = '${msg.header('Call-ID')} ${_extractCSeqNumber(msg.header('CSeq'))}';
    if (key == _last2xxKey && _last2xxAck != null) {
      _send(_last2xxAck!);
    }
  }

  void _handleRegisterResponse(
    _ClientTransaction tx,
    SipMessage msg, {
    required int expires,
    required _AuthRetries auth,
    void Function()? onUnregistered,
  }) {
    final code = msg.statusCode;
    if (code < 200) return;
    final unregistering = onUnregistered != null;

    // An access token is validated by the registrar itself. A refusal comes
    // back as 401 with a digest challenge (and, when the token was the
    // problem, X-vobiz-Jwt-Error-Code); there is no password to answer it.
    if (_accessToken != null && code >= 300 && code != 423) {
      if (unregistering) {
        onUnregistered();
        return;
      }
      final tokenError = _accessTokenErrorIn(msg);
      _accessTokenError = tokenError;
      _failRegistration(_accessTokenRefusal(code, msg, tokenError),
          temporary: tokenError == null && _isTemporaryRegisterFailure(code));
      return;
    }

    if (code == 401 || code == 407) {
      final challenge = _challenge(msg);
      _logger.info('Auth challenge: $challenge');
      final firstTry = !auth.tried;
      if (_username != null && _password != null && challenge.isNotEmpty && auth.allow(challenge)) {
        final authValue = SipDigestAuth.buildAuthHeader(
          wwwAuthenticate: challenge,
          method: 'REGISTER',
          uri: 'sip:$sipServer',
          username: _username!,
          password: _password!,
        );
        if (authValue != null) {
          _sendRegister(
            expires: expires,
            auth: auth,
            authHeaderName: _authorizationHeaderFor(code),
            authHeader: authValue,
            socket: tx.socket,
            onUnregistered: onUnregistered,
          );
          return;
        }
      }
      if (unregistering) {
        onUnregistered();
        return;
      }
      _failRegistration(firstTry
          ? 'Could not parse auth challenge'
          : 'Authentication failed ($code after auth response — wrong password?)');
      return;
    }

    if (code == 423 && !unregistering) {
      // Interval Too Brief: ask again for at least what the registrar wants.
      final minimum = int.tryParse((msg.header('Min-Expires') ?? '').trim());
      if (minimum != null && minimum > expires) {
        _sendRegister(
            expires: minimum,
            auth: _AuthRetries(
                refresh: auth.refresh, timeout: auth.timeout, extraHeaders: auth.extraHeaders),
            socket: tx.socket);
        return;
      }
    }

    if (unregistering) {
      if (code >= 300) _logger.warn('Unregistration refused: $code ${_reasonPhrase(msg)}');
      onUnregistered();
      return;
    }

    if (code >= 200 && code < 300) {
      final granted = _grantedExpires(msg) ?? expires;
      if (_accessToken != null) _readAccessTokenExpiry(msg);
      _logger.info('SIP registered as $_username for ${granted}s');
      _registrationState.value = SipRegistrationState.registered;
      _scheduleRegistrationRefresh(granted);
      _startKeepAlive();
      _resendPendingEnds();
      onRegistered?.call();
      if (auth.claims) {
        _logger.info('The registrar took the REGISTER that claims a held call '
            '(X-Index ${auth.extraHeaders['X-Index']}, X-Label ${auth.extraHeaders['X-Label']})');
        onHeldCallClaimed?.call();
      }
      // A claim that came while this REGISTER was in flight goes now.
      final pending = _pendingClaim;
      if (pending != null && _registrationState.value == SipRegistrationState.registered) {
        _pendingClaim = null;
        _registrationRefreshTimer?.cancel();
        _sendRegister(
            expires: registerExpires,
            auth: _AuthRetries(refresh: true, timeout: refreshTimeout, extraHeaders: pending));
      }
      return;
    }

    if (code == 403) {
      _logger.error('Registration forbidden — wrong credentials');
      _failRegistration('Wrong credentials (403 Forbidden)');
      return;
    }
    _failRegistration('Registration failed ($code ${_reasonPhrase(msg)})',
        temporary: _isTemporaryRegisterFailure(code));
  }

  /// The token error code on a refusal (`X-vobiz-Jwt-Error-Code: 10006`).
  static int? _accessTokenErrorIn(SipMessage msg) =>
      int.tryParse((msg.header('X-vobiz-Jwt-Error-Code') ?? '').trim());

  /// Why the registrar refused this token sign-in, in words.
  String _accessTokenRefusal(int code, SipMessage msg, int? tokenError) {
    if (tokenError != null) {
      return 'Access token refused: ${VobizAccessTokenException.errorName(tokenError)} '
          '($tokenError)';
    }
    if (code == 401 || code == 407) {
      return 'Access token refused ($code ${_reasonPhrase(msg)})';
    }
    if (code == 403) return 'Access token refused (403 ${_reasonPhrase(msg)})';
    return 'Registration failed ($code ${_reasonPhrase(msg)})';
  }

  /// Why an outbound call was refused for its access token, in words.
  static String _accessTokenCallRefusal(int tokenError) => 'Call refused: access token '
      '${VobizAccessTokenException.errorName(tokenError)} ($tokenError)';

  /// The registrar's view of the token on a 200 OK:
  /// `X-vobiz-Jwt: expires=<seconds left>;epoch-exp=<exp>`.
  void _readAccessTokenExpiry(SipMessage msg) {
    final value = msg.header('X-vobiz-Jwt');
    if (value == null) return;
    int? param(String name) => int.tryParse(
        RegExp('(?:^|;)\\s*$name\\s*=\\s*(-?\\d+)').firstMatch(value)?.group(1) ?? '');
    _accessTokenExpiresIn = param('expires') ?? _accessTokenExpiresIn;
  }

  /// The lifetime the registrar granted: our Contact's `expires` parameter
  /// in the 200 OK, else its Expires header (RFC 3261 10.2.4).
  int? _grantedExpires(SipMessage msg) {
    final ours = _contactUri.split(';').first.toLowerCase();
    final contacts = <String>[
      for (final line in msg.headerValues('Contact')) ...SipParser.splitAddressList(line),
    ];
    String? match;
    for (final contact in contacts) {
      if (contact.toLowerCase().contains(ours)) match = contact;
    }
    match ??= contacts.length == 1 ? contacts.single : null;
    if (match != null) {
      final param = RegExp(r'expires\s*=\s*(\d+)', caseSensitive: false)
          .firstMatch(match.substring(match.lastIndexOf('>') + 1))
          ?.group(1);
      final value = int.tryParse(param ?? '');
      if (value != null) return value;
    }
    return int.tryParse((msg.header('Expires') ?? '').trim());
  }

  /// A registration that cannot go on: report it, stop refreshing and
  /// pinging, and close the socket (once any call on it has ended).
  /// [temporary] says whether registering again later may work
  /// ([registrationFailureTemporary]).
  void _failRegistration(String reason, {bool temporary = false}) {
    _registrationRefreshTimer?.cancel();
    _crlfKeepAlive?.stop();
    _registrationRefreshDelay = null;
    _registrationState.value = SipRegistrationState.failed;
    _registrationFailureTemporary = temporary;
    onRegistrationFailed?.call(reason);
    if (_activeCallId != null || _pendingInvite != null) {
      _closeWhenCallEnds = true;
    } else {
      _closeAfterRegistrationFailure();
    }
  }

  /// A refresh went unanswered: the socket is dead even though it was never
  /// closed. Drop it and report it, so the client reconnects (keeping a
  /// call's dialog) instead of giving up on the registration.
  void _transportDead(WebSocketChannel? socket, String reason) {
    if (socket == null || !identical(socket, _socket)) return;
    _logger.warn('$reason: the WebSocket is dead, closing it');
    // Its close, whenever it comes, is no longer the current socket's.
    _socket = null;
    _dropRegistersSentOn(socket);
    _registrationRefreshTimer?.cancel();
    _crlfKeepAlive?.stop();
    _registrationRefreshDelay = null;
    _connectionState.value = SipConnectionState.disconnected;
    _registrationState.value = SipRegistrationState.failed;
    _closeQuietly(socket);
    (onTransportDead ?? onSocketError)?.call(reason);
  }

  void _closeAfterRegistrationFailure() {
    _closeWhenCallEnds = false;
    final socket = _socket;
    if (socket == null) return;
    // Our own close, not a dropped connection to reconnect from.
    _manualDisconnect = true;
    _socket = null;
    _connectionState.value = SipConnectionState.disconnected;
    _closeQuietly(socket);
  }

  void _handleInviteResponse(_OutgoingInvite invite, _ClientTransaction tx, SipMessage msg) {
    final code = msg.statusCode;
    final live = identical(invite, _outgoing) && !invite.hungUp;

    // Vobiz names its CallUUID on the provisional and final responses. The
    // web SDK reads it from the same header, and a transfer needs it.
    if (live) {
      final uuid = _nonEmpty(msg.header('X-Calluuid'));
      if (uuid != null) _callUuid = uuid;
    }

    if (code < 200) {
      // Ringing can go on for minutes: Timer B stops at the first 1xx.
      tx.timer?.cancel();
      invite.provisional = true;
      if (invite.hungUp) {
        _sendCancel(invite);
        return;
      }
      if (!live) return;
      if (code == 100) {
        onTrying?.call();
      } else if (code == 180) {
        _updateDialog(msg);
        onRemoteRinging?.call();
      } else if (code == 183) {
        _updateDialog(msg);
        onCallProgress?.call(msg.body.isEmpty ? null : msg.body);
      }
      return;
    }

    if (code < 300) {
      _handleInvite2xx(invite, tx, msg, live: live);
      return;
    }

    // 300-699: the INVITE transaction ACKs it itself, on the INVITE's own
    // branch, Request-URI and CSeq (RFC 3261 17.1.1.3).
    if (_username != null) {
      _send(
        SipBuilder.ack(
          requestUri: invite.requestUri,
          fromUser: _username!,
          toHeader: msg.header('To') ?? invite.toHeader,
          sipServer: sipServer,
          localTag: _localTag,
          callId: invite.callId,
          cseq: invite.cseq,
          branch: invite.branch,
        ),
        socket: tx.socket,
      );
    }
    if (!live) return;

    switch (code) {
      case 401:
      case 407:
        _handleInviteAuthChallenge(invite, msg);
        break;
      case 486:
        _failOutgoing(_withDetail('Remote party is busy', msg), code);
        break;
      case 603:
        _failOutgoing(_withDetail('Remote party declined the call', msg), code);
        break;
      default:
        final tokenError = _accessToken != null ? _accessTokenErrorIn(msg) : null;
        _failOutgoing(
            tokenError != null
                ? _accessTokenCallRefusal(tokenError)
                : _withDetail('Call failed ($code ${_reasonPhrase(msg)})', msg),
            code);
    }
  }

  void _handleInvite2xx(_OutgoingInvite invite, _ClientTransaction tx, SipMessage msg,
      {required bool live}) {
    final first = !invite.answered;
    invite.answered = true;
    if (live) _updateDialog(msg);
    final dialog = live ? _currentDialog() : _dialogFrom2xx(invite, msg);
    if (_username == null) return;
    final ack = SipBuilder.ack(
      requestUri: dialog.remoteTarget,
      fromUser: _username!,
      toHeader: dialog.remoteParty,
      sipServer: sipServer,
      localTag: _localTag,
      callId: dialog.callId,
      cseq: invite.cseq,
      routes: dialog.routes,
    );
    _last2xxKey = '${invite.callId} ${invite.cseq}';
    _last2xxAck = ack;
    _send(ack, socket: tx.socket);
    if (!first) return;
    if (live) {
      _dialogConfirmed = true;
      _remoteSdp = msg.body;
      onCallAnswered?.call(msg.body);
    } else {
      // Answered after the app hung up (the 2xx crossed the CANCEL, or came
      // before any provisional): the call exists now, so end it.
      _sendBye(dialog, socket: tx.socket);
    }
  }

  _Dialog _dialogFrom2xx(_OutgoingInvite invite, SipMessage msg) {
    final to = msg.header('To') ?? invite.toHeader;
    return _Dialog(
      callId: invite.callId,
      remoteTarget: _extractUri(msg.header('Contact') ?? to) ?? invite.requestUri,
      remoteParty: to,
      routes: <String>[
        for (final line in msg.headerValues('Record-Route')) ...SipParser.splitAddressList(line),
      ].reversed.toList(growable: false),
    );
  }

  void _onInviteTimeout(_OutgoingInvite invite) {
    if (!identical(invite, _outgoing) || invite.hungUp) return;
    _failOutgoing('No answer from the server (timed out)', 408);
  }

  void _failOutgoing(String reason, int? sipCode) {
    _endCall();
    onCallFailed?.call(reason, sipCode);
  }

  /// Appends the Q.850 (or SIP) detail from a `Reason` header, when the far end
  /// sent one, so "Busy" can become "Busy — USER_BUSY (Q.850 17)".
  String _withDetail(String summary, SipMessage msg) {
    final detail = _describeReason(msg.header('Reason'));
    return detail == null ? summary : '$summary — $detail';
  }

  /// `Q.850;cause=17;text="USER_BUSY"` becomes `USER_BUSY (Q.850 17)`.
  String? _describeReason(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final protocol = header.split(';').first.trim();
    final cause = RegExp(r'cause=(\d+)').firstMatch(header)?.group(1);
    final text = RegExp(r'text="([^"]*)"').firstMatch(header)?.group(1);
    final parts = <String>[
      if (text != null && text.isNotEmpty) text,
      if (cause != null) '($protocol $cause)',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  static String? _nonEmpty(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  void _handleInviteAuthChallenge(_OutgoingInvite invite, SipMessage msg) {
    // A token sign-in has no password: a challenge means the token was not
    // accepted for this call.
    if (_accessToken != null) {
      final tokenError = _accessTokenErrorIn(msg);
      _failOutgoing(
          tokenError != null
              ? _accessTokenCallRefusal(tokenError)
              : 'Call refused: the access token was not accepted '
                  '(${msg.statusCode} ${_reasonPhrase(msg)})',
          msg.statusCode);
      return;
    }
    final challenge = _challenge(msg);
    if (challenge.isEmpty || _username == null || _password == null) {
      _failOutgoing('Call authentication failed', msg.statusCode);
      return;
    }
    // One answer per challenge, one more only for a stale nonce. Anything
    // else is a refusal; answering it again would loop.
    if (!invite.auth.allow(challenge)) {
      _failOutgoing('Call authentication failed (credentials refused)', msg.statusCode);
      return;
    }
    final auth = SipDigestAuth.buildAuthHeader(
      wwwAuthenticate: challenge,
      method: 'INVITE',
      uri: invite.requestUri,
      username: _username!,
      password: _password!,
    );
    if (auth == null) {
      _failOutgoing('Could not parse call authentication challenge', msg.statusCode);
      return;
    }
    _sendInvite(
      invite,
      authHeaderName: _authorizationHeaderFor(msg.statusCode),
      authHeader: auth,
    );
  }

  static String _challenge(SipMessage msg) =>
      msg.header('Proxy-Authenticate') ?? msg.header('WWW-Authenticate') ?? '';

  static String _authorizationHeaderFor(int code) =>
      code == 407 ? 'Proxy-Authorization' : 'Authorization';

  void _replyOk(SipMessage msg) {
    _send(SipBuilder.response(request: msg, code: 200, reason: 'OK'));
  }

  void _updateDialog(SipMessage msg) {
    _activeRemoteTarget =
        _extractUri(msg.header('Contact') ?? msg.header('To') ?? '');
    _activeRemotePartyHeader =
        msg.header('To') ?? _activeRemotePartyHeader;
    // Calling out: the route set is the response's Record-Routes, reversed.
    final recordRoutes = msg.headerValues('Record-Route');
    if (recordRoutes.isNotEmpty) {
      _routeSet = <String>[
        for (final line in recordRoutes) ...SipParser.splitAddressList(line),
      ].reversed.toList(growable: false);
    }
  }

  /// Refreshes before the granted lifetime runs out: at 80 % of it, as a
  /// single timer re-armed by each 200 OK.
  void _scheduleRegistrationRefresh(int grantedSeconds) {
    _registrationRefreshTimer?.cancel();
    if (grantedSeconds <= 0) {
      _registrationRefreshDelay = null;
      return;
    }
    final delay = Duration(milliseconds: max(1000, grantedSeconds * 800));
    _registrationRefreshDelay = delay;
    _registrationRefreshTimer = Timer(delay, () {
      if (!_hasCredentials) return;
      _sendRegister(expires: registerExpires, auth: _AuthRetries(refresh: true));
    });
  }

  /// Starts the SIP-level keep-alive, if configured. The WebSocket ping
  /// ([KeepAliveConfig.pingInterval]) runs from connect() regardless.
  ///
  /// This used to send OPTIONS to `sip:admin@<registrar>` every 60 s, which
  /// the registrar rejects ("No contact found") and logs as an error.
  void _startKeepAlive() {
    _crlfKeepAlive?.stop();
    _crlfKeepAlive = null;
    final interval = keepAlive.crlfInterval;
    if (interval == null) return;
    _crlfKeepAlive = CrlfKeepAlive(
      interval: interval,
      pongTimeout: keepAlive.crlfPongTimeout,
      send: (String ping) {
        if (_connectionState.value == SipConnectionState.connected) {
          debugOnSend?.call(ping);
          _socket?.sink.add(ping);
        }
      },
      onDead: () {
        _logger.warn('No keep-alive pong: closing the dead WebSocket');
        // Closing fires onDone, which reports the drop and reconnects.
        _socket?.sink.close();
      },
    )..start();
  }

  void _releaseReservation() {
    _outgoingReserved = false;
    _reservationTimer?.cancel();
    _reservationTimer = null;
  }

  /// The current call is over: clear it, and close the socket if the
  /// registration failed while it was up.
  void _endCall() {
    _clearCallState();
    if (_closeWhenCallEnds) _closeAfterRegistrationFailure();
  }

  void _clearCallState() {
    _activeCallId = null;
    _activeToUser = null;
    _activeRemoteTarget = null;
    _activeRemotePartyHeader = null;
    _pendingInvite = null;
    _lastAnsweredInvite = null;
    _lastAnsweredSdp = null;
    _outgoing = null;
    _dialogConfirmed = false;
    _localSdp = null;
    _remoteSdp = null;
    _lastOfferReplyCSeq = null;
    _lastOfferReply = null;
    _offerInProgress = false;
    _dtmfQueue.clear();
    _dtmfInFlight = false;
    _routeSet = const <String>[];
    final reInvite = _reInvite;
    _reInvite = null;
    if (reInvite != null && !reInvite.isCompleted) {
      reInvite.completeError(SipRequestFailed('The call ended', null));
    }
  }

  /// Whether [msg] belongs to the current call. A CANCEL or BYE for some
  /// other call (an earlier attempt, a retry that was turned away) must not
  /// end this one.
  bool _isCurrentCall(SipMessage msg) {
    final callId = msg.header('Call-ID');
    return callId != null && callId == _activeCallId;
  }

  // ---------------------------------------------------------------------------
  // Private — helpers
  // ---------------------------------------------------------------------------

  static String? _topBranch(SipMessage msg) {
    final vias = msg.headerValues('Via');
    if (vias.isEmpty) return null;
    final top = SipParser.splitAddressList(vias.first);
    if (top.isEmpty) return null;
    return RegExp(r'branch=([^;,\s]+)', caseSensitive: false).firstMatch(top.first)?.group(1);
  }

  int _extractCSeqNumber(String? header) =>
      int.tryParse((header ?? '').trim().split(' ').first.trim()) ?? 1;

  String? _extractUri(String header) =>
      RegExp(r'sip:[^>;]+').firstMatch(header)?.group(0);

  String _extractUser(String header) =>
      RegExp(r'sip:([^@>]+)').firstMatch(header)?.group(1) ?? 'Unknown';

  String _reasonPhrase(SipMessage msg) {
    final parts = msg.firstLine.split(' ');
    return parts.length > 2 ? parts.sublist(2).join(' ') : 'Unknown error';
  }

  /// Who is calling: from each of P-Asserted-Identity, Remote-Party-ID,
  /// From and Contact in turn, a phone number that is the whole user part of
  /// its URI (`sip:`, `sips:` or `tel:`) or the whole quoted display name,
  /// else that header's SIP user when it is not this client's own. Digits
  /// elsewhere in a header (inside a user name, a tag) are not a number.
  String _extractCallerId(SipMessage msg) {
    final candidates = <String>[
      msg.header('P-Asserted-Identity') ?? '',
      msg.header('Remote-Party-ID') ?? '',
      msg.header('From') ?? '',
      msg.header('Contact') ?? '',
    ];
    for (final h in candidates) {
      final uriUser = RegExp(r'(?:sips?|tel):([^@;>\s]+)', caseSensitive: false).firstMatch(h)?.group(1);
      if (uriUser != null && _phoneNumber.hasMatch(uriUser)) return uriUser;
      final displayName = RegExp(r'^\s*"([^"]*)"').firstMatch(h)?.group(1)?.trim();
      if (displayName != null && _phoneNumber.hasMatch(displayName)) return displayName;
      final user = _extractUser(h);
      if (user != 'Unknown' && user != _username) return user;
    }
    return _extractUser(msg.header('From') ?? '');
  }

  static final RegExp _phoneNumber = RegExp(r'^\+?\d{8,15}$');

  /// A SIP header name (RFC 3261 25.1 `token`).
  static final RegExp _headerToken = RegExp(r"^[A-Za-z0-9\-.!%*_+`'~]+$");

  String _summarize(String msg) {
    final first = msg.split(RegExp(r'\r?\n')).first.trim();
    return first.length > 80 ? first.substring(0, 80) : first;
  }

  static String _rand(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List<String>.generate(
      length,
      (_) => chars[rand.nextInt(chars.length)],
    ).join();
  }
}

/// [SIPService.connect] was overtaken: a sign-out or a newer connect replaced
/// the socket before its handshake finished. Not a connection failure.
class SipConnectSuperseded implements Exception {
  const SipConnectSuperseded();

  @override
  String toString() => 'The connection was replaced before it opened';
}

/// A SIP request the far end refused or never answered.
class SipRequestFailed implements Exception {
  SipRequestFailed(this.message, this.statusCode);

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
