import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../errors/vobiz_exception.dart';
import '../models/auth/zero_config_session.dart';
import '../models/call/recording.dart';
import '../models/call/transfer_leg.dart';

/// The webhook server's `/api` routes: the same ones the Vobiz WebRTC
/// Playground calls, so the hosted Playground server works for this SDK
/// unchanged.
///
/// - `POST /api/setup`         Zero-Config Setup (find or create app + endpoint)
/// - `POST /api/transfer`      move a live leg with the Vobiz Redirect API
/// - `GET  /api/recording?list` recordings reported by Vobiz
///
/// `/api/answer`, `/api/transfer-xml`, `/api/recording` (POST) and
/// `/api/dial-status` are called by Vobiz itself, never by the client.
///
/// `/api/setup` and `/api/transfer` take the account Auth ID and Auth Token in
/// the request body, and the hosted server's recordings list is shared by all
/// of its users. All three refuse to run unless [allowAccountCredentials] is
/// true (`SdkConfig.unsafeDemoZeroConfig`), so a production build cannot send
/// the account credential off the device by accident. Even then, the two
/// that carry the Auth Token refuse a plain `http://` server unless it is
/// this device or the Android emulator's host.
@internal
class WebhookServerApi {
  WebhookServerApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.allowAccountCredentials = false,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// Demo mode: the account Auth ID and Auth Token may leave the device.
  final bool allowAccountCredentials;

  /// Host of the shared Vobiz demo server (`SdkConfig.defaultWebhookUrl`).
  static const String demoHost = 'rtc-demo.vobiz.ai';

  /// True when [url] points at the shared demo server.
  static bool isDemoServer(String url) =>
      Uri.tryParse(normalizeBase(url))?.host.toLowerCase() == demoHost;

  void _requireDemoMode(String operation) {
    if (!allowAccountCredentials) {
      throw VobizDemoModeRequiredException(operation);
    }
  }

  /// Hosts a plain `http://` server may be on: this device, or the host of
  /// the Android emulator, for a server run on the developer's machine.
  static const Set<String> _localHosts = <String>{'localhost', '127.0.0.1', '::1', '10.0.2.2'};

  /// The account Auth Token is in the request body: never send it in clear
  /// over a network.
  static void _requireSecure(String code, String base) {
    final uri = Uri.tryParse(base);
    final scheme = uri?.scheme.toLowerCase();
    if (scheme == 'https') return;
    if (scheme == 'http' && _localHosts.contains(uri!.host.toLowerCase())) return;
    throw VobizException(
        code,
        'The webhook server must use https: it receives the account Auth Token '
        '($base)');
  }

  /// Strips trailing slashes so `$base/api/...` never doubles them.
  static String normalizeBase(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  /// Zero-Config Setup. [webhookUrl] doubles as `my_domain`: the public origin
  /// Vobiz will call for this account's answer URL.
  Future<ZeroConfigSession> setup({
    required String webhookUrl,
    required String voiceApiUrl,
    required String authId,
    required String authToken,
    String? userName,
  }) async {
    _requireDemoMode('Zero-Config Setup');
    final base = normalizeBase(webhookUrl);
    _requireSecure('setup_failed', base);
    final response = await _post(
      'setup_failed',
      Uri.parse('$base/api/setup'),
      <String, String>{
        'auth_id': authId,
        // The server authenticates to the Vobiz API as api_username:auth_token.
        'api_username': authId,
        'auth_token': authToken,
        'voice_api_url': normalizeBase(voiceApiUrl),
        'my_domain': base,
        if (userName != null && userName.trim().isNotEmpty) 'user_name': userName.trim(),
      },
    );
    try {
      return ZeroConfigSession.fromJson(response);
    } on FormatException catch (e) {
      throw VobizException('setup_failed', e.message);
    }
  }

  /// Moves a live leg onto a phone number or SIP endpoint through the Vobiz
  /// Redirect API. Returns the server's reply (Vobiz's own response fields).
  Future<Map<String, dynamic>> transfer({
    required String webhookUrl,
    required String voiceApiUrl,
    required String authId,
    required String authToken,
    required String callUuid,
    required TransferLeg leg,
    String? number,
    String? sipUser,
    String? callerId,
    String sipHeaders = '',
  }) {
    _requireDemoMode('The Playground transfer');
    final base = normalizeBase(webhookUrl);
    _requireSecure('transfer_failed', base);
    return _post(
      'transfer_failed',
      Uri.parse('$base/api/transfer'),
      <String, String>{
        'auth_id': authId,
        'auth_token': authToken,
        'voice_api_url': normalizeBase(voiceApiUrl),
        'my_domain': base,
        'call_uuid': callUuid,
        'user': sipUser ?? '',
        'number': number ?? '',
        'caller_id': callerId ?? '',
        'sip_headers': sipHeaders,
        'legs': leg.apiValue,
      },
    );
  }

  /// Recordings the server has received, most recent first.
  ///
  /// Refuses the shared demo server outside demo mode: its list is not scoped
  /// to an account, so one customer would read another's recording URLs.
  Future<List<VobizRecording>> recordings({required String webhookUrl}) async {
    final base = normalizeBase(webhookUrl);
    if (isDemoServer(base) && !allowAccountCredentials) {
      throw const VobizException(
          VobizErrorCode.recordingsFailed,
          'The shared demo server\'s recordings list is readable by everyone '
          'who uses it, so it is only available with '
          'SdkConfig(unsafeDemoZeroConfig: true). This request carries no '
          'credentials: list recordings through your own authenticated API in '
          'production.');
    }
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$base/api/recording?list=1'))
          .timeout(timeout);
    } on TimeoutException {
      throw const VobizException('recordings_failed', 'The webhook server did not answer in time');
    } catch (e) {
      throw VobizException('recordings_failed', 'Could not reach the webhook server: $e');
    }
    if (response.statusCode >= 400) {
      throw VobizException('recordings_failed', _errorText(response),
          statusCode: response.statusCode);
    }
    final decoded = _decode(response.body);
    final list = decoded is Map ? decoded['recordings'] : null;
    if (list is! List) return const <VobizRecording>[];
    return list
        .whereType<Map>()
        .map((m) => VobizRecording.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<Map<String, dynamic>> _post(
      String code, Uri uri, Map<String, String> body) async {
    final http.Response response;
    try {
      response = await _client
          .post(uri,
              headers: const <String, String>{'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(timeout);
    } on TimeoutException {
      throw VobizException(code, 'The webhook server did not answer in time');
    } catch (e) {
      throw VobizException(code, 'Could not reach the webhook server: $e');
    }
    if (response.statusCode >= 400) {
      throw VobizException(code, _errorText(response), statusCode: response.statusCode);
    }
    final decoded = _decode(response.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{'message': response.body};
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// The server's own reason when it gave one: `{"error": "..."}` or plain text.
  static String _errorText(http.Response response) {
    final decoded = _decode(response.body);
    if (decoded is Map && decoded['error'] != null) return '${decoded['error']}';
    final text = response.body.trim();
    if (text.isNotEmpty && text.length < 400 && !text.startsWith('<')) return text;
    return 'The webhook server answered HTTP ${response.statusCode}';
  }
}
