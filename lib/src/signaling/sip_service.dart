import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/sip_headers.dart';
import '../utils/logger.dart';

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
  int get statusCode => int.tryParse(firstLine.split(' ')[1]) ?? 0;

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
  static String register({
    required String sipServer,
    required String username,
    required String contactUri,
    required String localTag,
    required String callId,
    required int cseq,
    String? authHeader,
  }) {
    final from = 'sip:$username@$sipServer';
    final contact = '<$contactUri>';
    final buf = StringBuffer()
      ..writeln('Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bK${_branch()}')
      ..writeln('From: <$from>;tag=$localTag')
      ..writeln('To: <$from>')
      ..writeln('Call-ID: $callId')
      ..writeln('CSeq: $cseq REGISTER')
      ..writeln('Contact: $contact')
      ..writeln('Max-Forwards: 70')
      ..writeln('User-Agent: vobiz_flutter_sdk')
      ..writeln('Expires: 3600')
      ..writeln('Content-Length: 0');
    if (authHeader != null) buf.writeln('Authorization: $authHeader');
    return 'REGISTER sip:$sipServer SIP/2.0\r\n${buf.toString().trim()}\r\n\r\n';
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
    String? authHeaderName,
    String? authHeader,
    Map<String, String> extraHeaders = const <String, String>{},
  }) {
    final contentLength = utf8.encode(sdp).length;
    final lines = <String>[
      'INVITE sip:$toUser@$sipServer SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bK${_branch()}',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: <sip:$toUser@$sipServer>',
      'Call-ID: $callId',
      'CSeq: $cseq INVITE',
      'Contact: <$contactUri>',
      'Max-Forwards: 70',
      'Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO',
      'Supported: timer',
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
    required String sipServer,
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
        'Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO',
        'Supported: timer',
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
    List<String> routes = const <String>[],
  }) {
    return <String>[
      'ACK $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bK${_branch()}',
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
    List<String> routes = const <String>[],
  }) {
    return <String>[
      'BYE $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bK${_branch()}',
      for (final route in routes) 'Route: $route',
      'From: <sip:$fromUser@$sipServer>;tag=$localTag',
      'To: $toHeader',
      'Call-ID: $callId',
      'CSeq: $cseq BYE',
      'Max-Forwards: 70',
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
    String? authHeaderName,
    String? authHeader,
    List<String> routes = const <String>[],
  }) {
    return <String>[
      'INFO $requestUri SIP/2.0',
      'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bK${_branch()}',
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

    final qop = _extractUnquoted(wwwAuthenticate, 'qop');
    final algorithm = _extractUnquoted(wwwAuthenticate, 'algorithm') ?? 'MD5';

    final ha1 = _md5('$username:$realm:$password');
    final ha2 = _md5('$method:$uri');

    if (qop != null && qop.contains('auth')) {
      final cnonce = _rand();
      const nc = '00000001';
      final response = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
      return 'Digest username="$username", realm="$realm", '
          'nonce="$nonce", uri="$uri", qop=auth, nc=$nc, '
          'cnonce="$cnonce", response="$response", algorithm=$algorithm';
    } else {
      final response = _md5('$ha1:$nonce:$ha2');
      return 'Digest username="$username", realm="$realm", '
          'nonce="$nonce", uri="$uri", response="$response", algorithm=$algorithm';
    }
  }

  static String _md5(String input) =>
      md5.convert(utf8.encode(input)).toString();

  static String _rand() =>
      List.generate(8, (_) => Random().nextInt(16).toRadixString(16)).join();

  static String? _extract(String header, String key) =>
      RegExp('$key="([^"]+)"').firstMatch(header)?.group(1);

  static String? _extractUnquoted(String header, String key) {
    final quoted = RegExp('$key="([^"]+)"').firstMatch(header)?.group(1);
    if (quoted != null) return quoted;
    return RegExp('$key=([^,\\s;]+)').firstMatch(header)?.group(1);
  }
}

// ---------------------------------------------------------------------------
// SIPService
// ---------------------------------------------------------------------------

@internal
class SIPService {
  SIPService({
    required this.wsUrl,
    required this.sipServer,
    Logger? logger,
  })  : _logger = logger ?? Logger(),
        _localTag = _rand(8),
        _registerCallId = '${_rand(12)}@vobiz-client',
        _contactUri = 'sip:${_rand(8)}@${_rand(12)}.invalid;transport=ws';

  final String wsUrl;
  final String sipServer;
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

  String? _username;
  String? _password;
  int _cseq = 1;
  bool _manualDisconnect = false;
  int _registerAuthAttempts = 0;

  String? _activeCallId;
  String? _activeRemoteTag;
  String? _activeToUser;
  String? _activeRemoteTarget;
  String? _activeRemotePartyHeader;
  String? _activeInviteSdp;
  int? _activeInviteCSeq;
  SipMessage? _pendingInvite;
  SipMessage? _lastAnsweredInvite;
  String? _lastAnsweredSdp;

  // The current call's route set (RFC 3261 12.1): the Route headers its
  // in-dialog requests (ACK, BYE, INFO) carry, so they follow the call back
  // through Vobiz's registrar. Answering: the INVITE's Record-Routes in
  // order. Calling: the response's Record-Routes reversed.
  List<String> _routeSet = const <String>[];
  Map<String, String> _activeExtraHeaders = const <String, String>{};

  // Vobiz's CallUUID for the current (or most recent) call. Kept after the
  // call ends so the recording can still be matched to it; reset when the next
  // call starts.
  String? _callUuid;

  // The DTMF INFO in flight, kept so a 401/407 challenge can be answered once.
  String? _pendingInfoBody;
  int _infoAuthAttempts = 0;

  WebSocketChannel? _socket;
  Timer? _registrationRefreshTimer;
  Timer? _optionsKeepAliveTimer;

  final _connectionState =
      ValueNotifier<SipConnectionState>(SipConnectionState.disconnected);
  final _registrationState =
      ValueNotifier<SipRegistrationState>(SipRegistrationState.unregistered);

  ValueNotifier<SipConnectionState> get connectionState => _connectionState;
  ValueNotifier<SipRegistrationState> get registrationState =>
      _registrationState;

  /// Vobiz's CallUUID (`X-Calluuid`) for the current or most recent call.
  String? get callUuid => _callUuid;

  /// Whether an established call (dialog) exists that in-dialog requests,
  /// such as DTMF, can be sent on.
  bool get hasActiveDialog => _activeCallId != null && _pendingInvite == null;

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

  Future<void> connect() async {
    _manualDisconnect = false;
    _connectionState.value = SipConnectionState.connecting;
    try {
      _socket = IOWebSocketChannel.connect(
        Uri.parse(wsUrl),
        protocols: const <String>['sip'],
        pingInterval: const Duration(seconds: 30),
        connectTimeout: const Duration(seconds: 20),
      );
      // Await the actual TCP/TLS/WebSocket handshake. Without this, the
      // TimeoutException from connectTimeout escapes into an unguarded async
      // zone and becomes an Unhandled Exception in the Flutter error handler.
      await _socket!.ready;
      _connectionState.value = SipConnectionState.connected;
      _logger.info('SIP WebSocket connected to $wsUrl');
      _listenToSocket();
    } catch (e) {
      _connectionState.value = SipConnectionState.disconnected;
      _logger.error('SIP WebSocket connection failed: $e');
      // Don't call onSocketError here — the exception propagates to VobizClient
      // which emits the error event and schedules reconnects in its own catch.
      rethrow;
    }
  }

  void register(String username, String password) {
    _username = username;
    _password = password;
    _registerAuthAttempts = 0;
    _registrationState.value = SipRegistrationState.registering;
    _send(SipBuilder.register(
      sipServer: sipServer,
      username: username,
      contactUri: _contactUri,
      localTag: _localTag,
      callId: _registerCallId,
      cseq: _cseq++,
    ));
  }

  void call(String toUser, String sdp,
      {Map<String, String> extraHeaders = const <String, String>{}}) {
    _activeCallId = '${_rand(12)}@vobiz-client';
    _activeToUser = toUser;
    _activeInviteSdp = sdp;
    _activeRemoteTarget = 'sip:$toUser@$sipServer';
    _activeRemotePartyHeader = '<sip:$toUser@$sipServer>';
    _activeExtraHeaders = Map<String, String>.unmodifiable(extraHeaders);
    _callUuid = null;
    _sendInvite();
  }

  /// Sends one DTMF tone on the established call as an `application/dtmf-relay`
  /// INFO. Returns false when there is no established call to send it on.
  bool sendDtmf(String tone, {int durationMs = 100}) {
    if (!hasActiveDialog || _username == null) return false;
    _infoAuthAttempts = 0;
    _pendingInfoBody = SipBuilder.dtmfRelayBody(tone, durationMs: durationMs);
    _sendInfo();
    return true;
  }

  void answer(String sdp) {
    if (_pendingInvite == null) return;
    _lastAnsweredInvite = _pendingInvite;
    _lastAnsweredSdp = sdp;
    _send(SipBuilder.ok200(
      invite: _pendingInvite!,
      contactUri: _contactUri,
      sipServer: sipServer,
      localTag: _localTag,
      sdp: sdp,
    ));
    _pendingInvite = null;
  }

  /// Declines the ringing INVITE with [code] (486 Busy Here by default). Once
  /// the call has been answered there is no INVITE left to decline, so the
  /// call is hung up with a BYE instead of being dropped silently.
  void reject([int code = 486, String reason = 'Busy Here']) {
    final invite = _pendingInvite;
    if (invite == null) {
      if (_activeCallId != null) hangup();
      return;
    }
    _send(SipBuilder.response(
        request: invite, code: code, reason: reason, localTag: _localTag));
    _clearCallState();
  }

  void hangup() {
    if (_activeCallId == null || _username == null) return;
    _send(SipBuilder.bye(
      requestUri: _activeRemoteTarget ?? 'sip:${_activeToUser!}@$sipServer',
      fromUser: _username!,
      toHeader: _activeRemotePartyHeader ?? _buildFallbackToHeader(),
      sipServer: sipServer,
      localTag: _localTag,
      callId: _activeCallId!,
      cseq: _cseq++,
      routes: _routeSet,
    ));
    _clearCallState();
    onCallEnded?.call('Hung up');
  }

  /// Closes the socket. [keepCall] keeps the established call's dialog, so a
  /// reconnect can still hang it up (or be hung up) once it is registered
  /// again.
  void disconnect({bool keepCall = false}) {
    _manualDisconnect = true;
    _registrationRefreshTimer?.cancel();
    _optionsKeepAliveTimer?.cancel();
    if (!keepCall) _clearCallState();
    _socket?.sink.close();
    _socket = null;
    _connectionState.value = SipConnectionState.disconnected;
    _registrationState.value = SipRegistrationState.unregistered;
  }

  // ---------------------------------------------------------------------------
  // Private — sending
  // ---------------------------------------------------------------------------

  void _sendInvite({String? authHeaderName, String? authHeader}) {
    if (_activeCallId == null ||
        _activeToUser == null ||
        _activeInviteSdp == null ||
        _username == null) return;

    _activeInviteCSeq = _cseq;
    _send(SipBuilder.invite(
      sipServer: sipServer,
      fromUser: _username!,
      contactUri: _contactUri,
      toUser: _activeToUser!,
      localTag: _localTag,
      callId: _activeCallId!,
      cseq: _cseq++,
      sdp: _activeInviteSdp!,
      authHeaderName: authHeaderName,
      authHeader: authHeader,
      // The re-sent INVITE after a 407 must carry the same headers, or the
      // webhook never sees them.
      extraHeaders: _activeExtraHeaders,
    ));
  }

  void _sendInfo({String? authHeaderName, String? authHeader}) {
    final body = _pendingInfoBody;
    if (body == null || _activeCallId == null || _username == null) return;
    _send(SipBuilder.info(
      requestUri: _inDialogRequestUri(),
      fromUser: _username!,
      toHeader: _activeRemotePartyHeader ?? _buildFallbackToHeader(),
      sipServer: sipServer,
      localTag: _localTag,
      callId: _activeCallId!,
      cseq: _cseq++,
      contentType: 'application/dtmf-relay',
      body: body,
      authHeaderName: authHeaderName,
      authHeader: authHeader,
      routes: _routeSet,
    ));
  }

  String _inDialogRequestUri() =>
      _activeRemoteTarget ?? 'sip:${_activeToUser ?? 'unknown'}@$sipServer';

  void _send(String message) {
    _logger.info('SIP >> ${_summarize(message)}');
    debugOnSend?.call(message);
    _socket?.sink.add(message);
  }

  /// Test seam: sees every message this service sends.
  @visibleForTesting
  void Function(String message)? debugOnSend;

  /// Test seam: handles [raw] as if it had arrived on the WebSocket.
  @visibleForTesting
  void debugReceive(String raw) => _handleMessage(raw);

  // ---------------------------------------------------------------------------
  // Private — receiving
  // ---------------------------------------------------------------------------

  void _listenToSocket() {
    // Guard so onError + onDone both firing only triggers onSocketError once.
    var errorReported = false;
    // A sign-in replaces the socket. The old one's close arrives later and
    // must not be mistaken for the new connection dropping, which would
    // schedule a reconnect over a healthy session.
    final socket = _socket!;
    bool isCurrent() => identical(socket, _socket);

    socket.stream.listen(
      (raw) {
        if (isCurrent()) _handleMessage(raw.toString());
      },
      onError: (Object e) {
        if (!isCurrent()) return;
        _logger.error('SIP WebSocket error: $e');
        _connectionState.value = SipConnectionState.disconnected;
        _registrationState.value = SipRegistrationState.failed;
        _registrationRefreshTimer?.cancel();
        _optionsKeepAliveTimer?.cancel();
        if (!_manualDisconnect && !errorReported) {
          errorReported = true;
          onSocketError?.call('SIP socket error: $e');
        }
      },
      onDone: () {
        if (!isCurrent()) return;
        _logger.warn('SIP WebSocket closed');
        _connectionState.value = SipConnectionState.disconnected;
        _registrationRefreshTimer?.cancel();
        _optionsKeepAliveTimer?.cancel();
        if (!_manualDisconnect && !errorReported) {
          errorReported = true;
          _registrationState.value = SipRegistrationState.failed;
          onSocketError?.call('SIP socket closed unexpectedly');
        }
      },
    );
  }

  void _handleMessage(String raw) {
    if (raw.trim().isEmpty) return;
    _logger.info('SIP << ${_summarize(raw)}');
    final msg = SipParser.parse(raw);
    if (msg.isRequest) {
      _handleRequest(msg);
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
        if (!_isCurrentCall(msg)) break;
        // The cancelled INVITE still needs its own final answer, or the
        // registrar and media server keep its transaction open.
        final cancelled = _pendingInvite;
        if (cancelled != null) {
          _send(SipBuilder.requestTerminated(invite: cancelled, localTag: _localTag));
        }
        _clearCallState();
        onCallEnded?.call(_describeReason(msg.header('Reason')) ?? 'Caller cancelled');
        break;
      case 'ACK':
        break;
      case 'BYE':
        _replyOk(msg);
        if (!_isCurrentCall(msg)) break;
        _clearCallState();
        onCallEnded?.call(_describeReason(msg.header('Reason')) ?? 'Remote party hung up');
        break;
      case 'INFO':
        // Mid-call INFO from the far end (such as a DTMF relay). Acknowledge it
        // so the dialog is not torn down for an unanswered request.
        _replyOk(msg);
        break;
    }
  }

  void _handleIncomingInvite(SipMessage msg) {
    final incomingCallId = msg.header('Call-ID');

    if (_activeCallId != null || _pendingInvite != null) {
      final isSameDialog =
          incomingCallId != null && incomingCallId == _activeCallId;
      if (isSameDialog) {
        if (_pendingInvite != null) {
          _send(SipBuilder.ringing(invite: msg, localTag: _localTag, contactUri: _contactUri));
          return;
        }
        if (_lastAnsweredInvite != null && _lastAnsweredSdp != null) {
          _send(SipBuilder.ok200(
            invite: _lastAnsweredInvite!,
            contactUri: _contactUri,
            sipServer: sipServer,
            localTag: _localTag,
            sdp: _lastAnsweredSdp!,
          ));
          return;
        }
      }
      _send(SipBuilder.busyHere(invite: msg, localTag: _localTag));
      return;
    }

    _pendingInvite = msg;
    _activeCallId = msg.header('Call-ID');
    _callUuid = _nonEmpty(msg.header('X-Calluuid'));
    final callerId = _extractCallerId(msg);
    final parsedTo = _extractUser(msg.header('To') ?? '');
    _activeToUser = parsedTo == 'Unknown' ? callerId : parsedTo;
    final fromHeader = msg.header('From') ?? '';
    _activeRemoteTag = _extractTag(fromHeader);
    _activeRemoteTarget = _extractUri(msg.header('Contact') ?? fromHeader);
    _activeRemotePartyHeader = fromHeader;
    _routeSet = msg.headerValues('Record-Route');

    // Custom headers the caller (or <Dial><User sipHeaders="...">) attached.
    final headers = VobizSipHeaders.pick(msg.headers);

    _send(SipBuilder.ringing(invite: msg, localTag: _localTag, contactUri: _contactUri));
    _logger.info('Incoming call from $callerId');
    onIncomingCall?.call(callerId, msg.body, headers);
  }

  void _handleResponse(SipMessage msg) {
    final cseq = msg.header('CSeq') ?? '';
    if (cseq.contains('REGISTER')) {
      _handleRegisterResponse(msg);
    } else if (cseq.contains('INVITE')) {
      _handleInviteResponse(msg);
    } else if (cseq.contains('INFO')) {
      _handleInfoResponse(msg);
    }
  }

  void _handleInfoResponse(SipMessage msg) {
    final code = msg.statusCode;
    if ((code == 401 || code == 407) && _infoAuthAttempts == 0 &&
        _username != null && _password != null) {
      _infoAuthAttempts++;
      final challenge = msg.header('Proxy-Authenticate') ??
          msg.header('WWW-Authenticate') ??
          '';
      final auth = SipDigestAuth.buildAuthHeader(
        wwwAuthenticate: challenge,
        method: 'INFO',
        uri: _inDialogRequestUri(),
        username: _username!,
        password: _password!,
      );
      if (auth != null) {
        _sendInfo(
          authHeaderName: code == 407 ? 'Proxy-Authorization' : 'Authorization',
          authHeader: auth,
        );
        return;
      }
    }
    if (code >= 300) {
      _logger.warn('DTMF INFO refused: $code ${_reasonPhrase(msg)}');
    }
    if (code >= 200) _pendingInfoBody = null;
  }

  void _handleRegisterResponse(SipMessage msg) {
    switch (msg.statusCode) {
      case 200:
        _registerAuthAttempts = 0;
        _logger.info('SIP registered as $_username');
        _registrationState.value = SipRegistrationState.registered;
        _startRegistrationRefresh();
        _startOptionsKeepAlive();
        onRegistered?.call();
        break;
      case 401:
      case 407:
        if (_registerAuthAttempts >= 1) {
          _registrationState.value = SipRegistrationState.failed;
          onRegistrationFailed?.call('Authentication failed (401 after auth response — wrong password?)');
          return;
        }
        _registerAuthAttempts++;
        final challenge = msg.header('WWW-Authenticate') ??
            msg.header('Proxy-Authenticate') ??
            '';
        _logger.info('Auth challenge: $challenge');
        final auth = SipDigestAuth.buildAuthHeader(
          wwwAuthenticate: challenge,
          method: 'REGISTER',
          uri: 'sip:$sipServer',
          username: _username!,
          password: _password!,
        );
        if (auth == null) {
          _registrationState.value = SipRegistrationState.failed;
          onRegistrationFailed?.call('Could not parse auth challenge');
          return;
        }
        _send(SipBuilder.register(
          sipServer: sipServer,
          username: _username!,
          contactUri: _contactUri,
          localTag: _localTag,
          callId: _registerCallId,
          cseq: _cseq++,
          authHeader: auth,
        ));
        break;
      case 403:
        _logger.error('Registration forbidden — wrong credentials');
        _registrationState.value = SipRegistrationState.failed;
        onRegistrationFailed?.call('Wrong credentials (403 Forbidden)');
        break;
      default:
        _logger.warn('Unhandled REGISTER response: ${msg.statusCode}');
    }
  }

  void _handleInviteResponse(SipMessage msg) {
    // A late response for a call that has already ended (or for another
    // call) has no dialog to update here.
    if (_activeCallId == null || msg.header('Call-ID') != _activeCallId) return;

    // Vobiz names its CallUUID on the provisional and final responses. The
    // web SDK reads it from the same header, and a transfer needs it.
    final uuid = _nonEmpty(msg.header('X-Calluuid'));
    if (uuid != null) _callUuid = uuid;

    switch (msg.statusCode) {
      case 100:
        onTrying?.call();
        break;
      case 180:
        _updateDialog(msg);
        onRemoteRinging?.call();
        break;
      case 183:
        _updateDialog(msg);
        onCallProgress?.call(msg.body.isEmpty ? null : msg.body);
        break;
      case 200:
        _updateDialog(msg);
        _send(SipBuilder.ack(
          requestUri:
              _activeRemoteTarget ?? 'sip:${_activeToUser!}@$sipServer',
          fromUser: _username!,
          toHeader: _activeRemotePartyHeader ?? _buildFallbackToHeader(),
          sipServer: sipServer,
          localTag: _localTag,
          callId: _activeCallId!,
          cseq: _activeInviteCSeq ??
              _extractCSeqNumber(msg.header('CSeq')),
          routes: _routeSet,
        ));
        onCallAnswered?.call(msg.body);
        break;
      case 401:
      case 407:
        _handleInviteAuthChallenge(msg);
        break;
      case 486:
        _clearCallState();
        onCallFailed?.call(
            _withDetail('Remote party is busy', msg), msg.statusCode);
        break;
      case 603:
        _clearCallState();
        onCallFailed?.call(
            _withDetail('Remote party declined the call', msg), msg.statusCode);
        break;
      default:
        if (msg.statusCode >= 300) {
          final reason = _reasonPhrase(msg);
          _clearCallState();
          onCallFailed?.call(
              _withDetail('Call failed (${msg.statusCode} $reason)', msg),
              msg.statusCode);
        }
    }
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

  void _handleInviteAuthChallenge(SipMessage msg) {
    final challenge = msg.header('Proxy-Authenticate') ??
        msg.header('WWW-Authenticate') ??
        '';
    if (challenge.isEmpty ||
        _username == null ||
        _password == null ||
        _activeToUser == null ||
        _activeInviteSdp == null) {
      _clearCallState();
      onCallFailed?.call('Call authentication failed', msg.statusCode);
      return;
    }
    final auth = SipDigestAuth.buildAuthHeader(
      wwwAuthenticate: challenge,
      method: 'INVITE',
      uri: 'sip:${_activeToUser!}@$sipServer',
      username: _username!,
      password: _password!,
    );
    if (auth == null) {
      _clearCallState();
      onCallFailed?.call(
          'Could not parse call authentication challenge', msg.statusCode);
      return;
    }
    _sendInvite(
      authHeaderName:
          msg.statusCode == 407 ? 'Proxy-Authorization' : 'Authorization',
      authHeader: auth,
    );
  }

  void _replyOk(SipMessage msg) {
    _send(SipBuilder.response(request: msg, code: 200, reason: 'OK'));
  }

  void _updateDialog(SipMessage msg) {
    _activeRemoteTag = _extractTag(msg.header('To') ?? '');
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

  void _startRegistrationRefresh() {
    _registrationRefreshTimer?.cancel();
    _registrationRefreshTimer = Timer.periodic(
      const Duration(minutes: 55),
      (_) {
        if (_username == null || _password == null) return;
        register(_username!, _password!);
      },
    );
  }

  void _startOptionsKeepAlive() {
    _optionsKeepAliveTimer?.cancel();
    _optionsKeepAliveTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        if (_username == null ||
            _connectionState.value != SipConnectionState.connected) return;
        final callId = '${_rand(12)}@vobiz-client';
        _send(<String>[
          'OPTIONS sip:admin@$sipServer SIP/2.0',
          'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bK${SipBuilder._branch()}',
          'From: <sip:${_username!}@$sipServer>;tag=$_localTag',
          'To: <sip:admin@$sipServer>',
          'Call-ID: $callId',
          'CSeq: ${_cseq++} OPTIONS',
          'Content-Length: 0',
          '',
          '',
        ].join('\r\n'));
      },
    );
  }

  void _clearCallState() {
    _activeCallId = null;
    _activeRemoteTag = null;
    _activeToUser = null;
    _activeRemoteTarget = null;
    _activeRemotePartyHeader = null;
    _activeInviteSdp = null;
    _activeInviteCSeq = null;
    _pendingInvite = null;
    _lastAnsweredInvite = null;
    _lastAnsweredSdp = null;
    _activeExtraHeaders = const <String, String>{};
    _pendingInfoBody = null;
    _routeSet = const <String>[];
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

  int _extractCSeqNumber(String? header) =>
      int.tryParse((header ?? '').split(' ').first.trim()) ?? 1;

  String _extractTag(String header) =>
      RegExp(r'tag=([^;>\s]+)').firstMatch(header)?.group(1) ?? '';

  String? _extractUri(String header) =>
      RegExp(r'sip:[^>;]+').firstMatch(header)?.group(0);

  String _extractUser(String header) =>
      RegExp(r'sip:([^@>]+)').firstMatch(header)?.group(1) ?? 'Unknown';

  String _buildFallbackToHeader() {
    final toUser = _activeToUser;
    if (toUser == null) return '<sip:unknown@$sipServer>';
    if (_activeRemoteTag == null || _activeRemoteTag!.isEmpty) {
      return '<sip:$toUser@$sipServer>';
    }
    return '<sip:$toUser@$sipServer>;tag=$_activeRemoteTag';
  }

  String _reasonPhrase(SipMessage msg) {
    final parts = msg.firstLine.split(' ');
    return parts.length > 2 ? parts.sublist(2).join(' ') : 'Unknown error';
  }

  String _extractCallerId(SipMessage msg) {
    final candidates = <String>[
      msg.header('P-Asserted-Identity') ?? '',
      msg.header('Remote-Party-ID') ?? '',
      msg.header('From') ?? '',
      msg.header('Contact') ?? '',
    ];
    for (final h in candidates) {
      final phone = RegExp(r'\+?\d{8,15}').firstMatch(h)?.group(0);
      if (phone != null) return phone;
      final user = _extractUser(h);
      if (user != 'Unknown' && user != _username) return user;
    }
    return _extractUser(msg.header('From') ?? '');
  }

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
