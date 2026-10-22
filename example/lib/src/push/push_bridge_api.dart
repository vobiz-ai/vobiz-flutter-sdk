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
  const PushRegistration({required this.username, required this.push, this.warning, this.deviceToken});

  final String username;

  /// The bridge has a Firebase token for this device and can wake it.
  final bool push;
  final String? warning;

  /// This phone's own credential with the bridge, returned once when the
  /// phone pairs (registers with the bridge key). Keep it secret; send it
  /// from then on instead of the bridge key.
  final String? deviceToken;
}

/// What the bridge said to Accept, Decline or "registered" for one call.
class PerCallReply {
  const PerCallReply({this.finished = false, this.reason = ''});

  /// The call is already over: nothing to answer.
  final bool finished;

  /// Why it ended, when the bridge says.
  final String reason;
}

class PushBridgeException implements Exception {
  PushBridgeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The push bridge's HTTP API, as the app uses it.
///
/// The bridge key only pairs a phone: the first registration sends it and
/// gets a [PushRegistration.deviceToken] back. Everything after that
/// (re-registering, unregistering, test calls) sends the device token as
/// `Authorization: Bearer`, and acts on this phone only.
class PushBridgeApi {
  PushBridgeApi(this.config, {http.Client? client, this.deviceToken}) : _http = client ?? http.Client();

  final PushBridgeConfig config;
  final http.Client _http;

  /// This phone's token from an earlier pairing, if any.
  final String? deviceToken;

  static const Duration _timeout = Duration(seconds: 10);

  /// Rings this endpoint for inbound calls, and wakes this device with
  /// [token] when it is closed (no token: rings only while the app is open).
  ///
  /// With a [deviceToken] it re-registers this phone; if the bridge no longer
  /// knows it (401), it pairs again with the bridge key.
  Future<PushRegistration> register({
    required String username,
    String? token,
    String platform = 'android',
    String app = '',
  }) async {
    final body = <String, Object?>{
      'username': username,
      'token': token,
      'platform': platform,
      'app': app,
    };
    Map<String, dynamic> json;
    if (deviceToken != null) {
      try {
        json = await _post('/push/register', body, pair: false);
      } on PushBridgeException catch (e) {
        if (e.statusCode != 401) rethrow;
        json = await _post('/push/register', body, pair: true);
      }
    } else {
      json = await _post('/push/register', body, pair: true);
    }
    return PushRegistration(
      username: '${json['username'] ?? username}',
      push: json['push'] == true,
      warning: json['warning'] as String?,
      deviceToken: json['device_token'] as String?,
    );
  }

  /// Forgets this phone on the bridge (device token).
  Future<void> unregister() => _post('/push/unregister', const <String, Object?>{});

  /// A pretend incoming call to this phone (device token), pushed after
  /// [delaySeconds] so there is time to lock the phone or swipe the app away.
  Future<void> sendTestCall({int delaySeconds = 10}) =>
      _post('/push/test', <String, Object?>{'delay_seconds': delaySeconds});

  /// Tells the bridge the user accepted [call]: it keeps the caller waiting
  /// while the app starts and signs in. Needs no bridge key, only the call's.
  /// [PerCallReply.finished] when the call is already over.
  static Future<PerCallReply> accept(PushCall call, {http.Client? client}) =>
      _perCall('/push/accept', call, client);

  /// Tells the bridge the user declined [call]: the caller hears busy.
  static Future<PerCallReply> decline(PushCall call, {http.Client? client}) =>
      _perCall('/push/decline', call, client);

  /// Tells the bridge this phone is registered while [call] rings, so it
  /// dials now instead of at the end of its push wait. A reply of
  /// `too_late` (the Dial already started) needs nothing: the bridge's
  /// `call_ended` push closes the call screen.
  static Future<PerCallReply> registered(PushCall call, {http.Client? client}) =>
      _perCall('/push/registered', call, client);

  static Future<PerCallReply> _perCall(String path, PushCall call, http.Client? client) async {
    if (call.server.isEmpty || call.callKey.isEmpty) return const PerCallReply();
    final http_ = client ?? http.Client();
    try {
      final response = await http_
          .post(
            Uri.parse('${call.server}$path'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{'call_id': call.callId, 'call_key': call.callKey}),
          )
          .timeout(_timeout);
      Object? json;
      try {
        json = jsonDecode(response.body);
      } catch (_) {}
      if (json is! Map) return const PerCallReply();
      return PerCallReply(finished: json['finished'] == true, reason: '${json['reason'] ?? ''}');
    } finally {
      if (client == null) http_.close();
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body, {bool pair = false}) async {
    final device = deviceToken;
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('${config.baseUrl}$path'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              if (pair || device == null) 'X-Bridge-Key': config.key,
              if (!pair && device != null) 'Authorization': 'Bearer $device',
            },
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
