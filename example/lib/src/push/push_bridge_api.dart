import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Whether plain http:// is accepted for the sample server and the token
/// server: only outside release builds, for a server on the developer's own
/// machine or network. A release build sends the server's key and access
/// tokens over https only.
const bool kAllowHttp = !kReleaseMode;

/// Where the sample server (`example/push_bridge`) is and the key the app
/// sends it.
///
/// The server prints both as one line, `https://<tunnel>#key=<key>`, so they
/// can be pasted into the app together.
class PushBridgeConfig {
  const PushBridgeConfig({required this.baseUrl, required this.key});

  /// Reads the line the server prints. Null when it is not one, or when it is
  /// plain http and [allowHttp] is false.
  static PushBridgeConfig? parse(String input, {bool allowHttp = kAllowHttp}) {
    final text = input.trim();
    final hash = text.indexOf('#');
    if (hash < 0) return null;
    final base = text.substring(0, hash).trim().replaceAll(RegExp(r'/+$'), '');
    final key = Uri.splitQueryString(text.substring(hash + 1))['key']?.trim() ?? '';
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty || key.isEmpty) return null;
    if (uri.scheme != 'https' && !(allowHttp && uri.scheme == 'http')) return null;
    return PushBridgeConfig(baseUrl: base, key: key);
  }

  final String baseUrl;
  final String key;

  /// Vobiz can only reach the server over HTTPS; plain http (not in release
  /// builds) is for a server on the same network as an emulator.
  bool get isHttps => baseUrl.startsWith('https://');
}

class PushBridgeException implements Exception {
  PushBridgeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The sample server's HTTP API, as the app uses it: access tokens and the
/// connection watch. (Conference goes through the SDK's `VobizConference`,
/// and Vobiz push sign-up through the SDK's `VobizPushDevices`, with the same
/// headers.)
///
/// Every request sends the server's key as `X-Bridge-Key`, and, when
/// [sipUser] is set, the SIP user the app is signed in as as
/// `X-Bridge-User`, so the server acts on that user's calls only.
class PushBridgeApi {
  PushBridgeApi(this.config, {http.Client? client, this.sipUser})
      : _http = client ?? http.Client(),
        _ownsHttp = client == null;

  final PushBridgeConfig config;
  final http.Client _http;
  final bool _ownsHttp;

  /// The SIP user the app is signed in as; null or empty when it is not.
  final String? sipUser;

  static const Duration _timeout = Duration(seconds: 10);

  /// Shorter for the once-a-second call reports: a late one is useless.
  static const Duration _aliveTimeout = Duration(seconds: 2);

  /// The headers the sample server authenticates the app by.
  static Map<String, String> headers(PushBridgeConfig config, {String? sipUser}) => <String, String>{
        'X-Bridge-Key': config.key,
        if (sipUser != null && sipUser.isNotEmpty) 'X-Bridge-User': sipUser,
      };

  /// An access token (JWT) the server mints with the account's Auth Token,
  /// for signing in as `<sub>_<auth id>` (the server's JWT_SUB unless [sub]
  /// is given). [reason] is the SDK's (`sign_in`, `expiring`, `rejected`,
  /// `refresh`).
  Future<String> accessToken({String? sub, required String reason}) async {
    final json = await _post('/token', <String, Object?>{'reason': reason, if (sub != null) 'sub': sub});
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw PushBridgeException('The sample server returned no token');
    }
    return token;
  }

  /// During a call, every second: this phone still has its network. When the
  /// reports stop, the server (still online) has Vobiz beep to the other
  /// party, and ends the call once the SDK's 12 s reconnect window is over:
  /// an offline phone's own hangup cannot reach Vobiz.
  Future<void> callAlive(String callUuid) =>
      _post('/call/alive', <String, Object?>{'call_uuid': callUuid}, timeout: _aliveTimeout);

  /// The call ended in the app: the server stops watching it.
  Future<void> callEnded(String callUuid) =>
      _post('/call/ended', <String, Object?>{'call_uuid': callUuid}, timeout: _aliveTimeout);

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body,
      {Duration timeout = _timeout}) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('${config.baseUrl}$path'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              ...headers(config, sipUser: sipUser),
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (e) {
      throw PushBridgeException('Could not reach the sample server at ${config.baseUrl} ($e)');
    }
    Map<String, dynamic> json = const <String, dynamic>{};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    if (response.statusCode == 401) {
      throw PushBridgeException(
          'The sample server did not accept the key. Paste the whole line it printed, including #key=…',
          statusCode: 401);
    }
    if (response.statusCode >= 400) {
      throw PushBridgeException(
          '${json['error'] ?? 'The sample server answered ${response.statusCode}'}',
          statusCode: response.statusCode);
    }
    return json;
  }

  /// Closes the HTTP client, unless it was passed in.
  void close() {
    if (_ownsHttp) _http.close();
  }
}
