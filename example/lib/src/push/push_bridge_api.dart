import 'dart:convert';

import 'package:http/http.dart' as http;

import 'push_call.dart';

/// Where the push bridge is and the key that lets this app register with it.
///
/// The bridge prints both as one line, `https://<tunnel>#key=<key>`, so they
/// can be pasted into the app together.
class PushBridgeConfig {
  const PushBridgeConfig({required this.baseUrl, required this.key});

  /// Reads the line the bridge prints. Null when it is not one.
  static PushBridgeConfig? parse(String input) {
    final text = input.trim();
    final hash = text.indexOf('#');
    if (hash < 0) return null;
    final base = text.substring(0, hash).trim().replaceAll(RegExp(r'/+$'), '');
    final key = Uri.splitQueryString(text.substring(hash + 1))['key']?.trim() ?? '';
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty || key.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return PushBridgeConfig(baseUrl: base, key: key);
  }

  final String baseUrl;
  final String key;

  /// Vobiz can only reach the bridge over HTTPS; plain http is for a bridge
  /// on the same network as an emulator.
  bool get isHttps => baseUrl.startsWith('https://');
}

/// What the bridge said to a registration.
class PushRegistration {
  const PushRegistration({required this.username, required this.push, this.warning});

  final String username;

  /// The bridge has a Firebase token for this device and can wake it.
  final bool push;
  final String? warning;
}

class PushBridgeException implements Exception {
  PushBridgeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The push bridge's HTTP API, as the app uses it.
class PushBridgeApi {
  PushBridgeApi(this.config, {http.Client? client}) : _http = client ?? http.Client();

  final PushBridgeConfig config;
  final http.Client _http;

  static const Duration _timeout = Duration(seconds: 10);

  /// Rings this endpoint for inbound calls, and wakes this device with
  /// [token] when it is closed (no token: rings only while the app is open).
  Future<PushRegistration> register({
    required String username,
    String? token,
    String platform = 'android',
    String app = '',
  }) async {
    final json = await _post('/push/register', <String, Object?>{
      'username': username,
      'token': token,
      'platform': platform,
      'app': app,
    });
    return PushRegistration(
      username: '${json['username'] ?? username}',
      push: json['push'] == true,
      warning: json['warning'] as String?,
    );
  }

  /// Stops ringing this endpoint on this device.
  Future<void> unregister({required String username, String? token}) =>
      _post('/push/unregister', <String, Object?>{'username': username, 'token': token});

  /// A pretend incoming call, pushed after [delaySeconds] so there is time to
  /// lock the phone or swipe the app away.
  Future<void> sendTestCall({required String username, int delaySeconds = 10}) =>
      _post('/push/test', <String, Object?>{'username': username, 'delay_seconds': delaySeconds});

  /// Declines the newest call ringing [username] from [caller], for a call
  /// that rang over SIP without a push to identify it.
  Future<void> declineByCaller({required String username, required String caller}) =>
      _post('/push/decline', <String, Object?>{'username': username, 'caller': caller});

  /// Tells the bridge the user accepted [call]: it keeps the caller waiting
  /// while the app starts and signs in. Needs no bridge key, only the call's.
  static Future<void> accept(PushCall call, {http.Client? client}) =>
      _perCall('/push/accept', call, client);

  /// Tells the bridge the user declined [call]: the caller hears busy.
  static Future<void> decline(PushCall call, {http.Client? client}) =>
      _perCall('/push/decline', call, client);

  static Future<void> _perCall(String path, PushCall call, http.Client? client) async {
    if (call.server.isEmpty || call.callKey.isEmpty) return;
    final http_ = client ?? http.Client();
    try {
      await http_
          .post(
            Uri.parse('${call.server}$path'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{'call_id': call.callId, 'call_key': call.callKey}),
          )
          .timeout(_timeout);
    } finally {
      if (client == null) http_.close();
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('${config.baseUrl}$path'),
            headers: <String, String>{'Content-Type': 'application/json', 'X-Bridge-Key': config.key},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      throw PushBridgeException('Could not reach the push server at ${config.baseUrl} ($e)');
    }
    Map<String, dynamic> json = const <String, dynamic>{};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    if (response.statusCode == 401) {
      throw PushBridgeException(
          'The push server did not accept the key. Paste the whole line the bridge printed, '
          'including #key=…',
          statusCode: 401);
    }
    if (response.statusCode >= 400) {
      throw PushBridgeException(
          '${json['error'] ?? 'The push server answered ${response.statusCode}'}',
          statusCode: response.statusCode);
    }
    return json;
  }

  void close() => _http.close();
}
