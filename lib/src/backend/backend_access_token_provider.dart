import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/access_token_provider.dart';
import '../errors/vobiz_exception.dart';

/// A [VobizAccessTokenProvider] that asks your own backend for an access
/// token (JWT) over HTTPS.
///
/// It sends `POST <url>` with a JSON body `{"reason": "sign_in" | "expiring" |
/// "rejected" | "refresh"}` and the headers from [headers] (put your app's
/// own session token there), and reads the `token` field of the JSON reply:
///
/// ```json
/// {"token": "eyJhbGciOi..."}
/// ```
///
/// Anything else in the reply is ignored, so the `POST /token` route of the
/// Vobiz WebRTC demo backend (vobiz-ai/Vobiz-RTC-demo) works as it is. Your
/// backend mints the token with `POST /api/v1/Account/{auth_id}/JWT/Token/`;
/// see CREDENTIALS.md.
///
/// ```dart
/// final provider = VobizBackendAccessTokenProvider(
///   url: Uri.parse('https://api.example.com/voice/token'),
///   headers: () async => {'Authorization': 'Bearer ${await mySession.token()}'},
/// );
/// final session = await client.connectWithAccessTokenProvider(provider.call);
/// ```
class VobizBackendAccessTokenProvider {
  VobizBackendAccessTokenProvider({
    required this.url,
    this.headers,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// Your backend's token route. Must be HTTPS outside local testing.
  final Uri url;

  /// Headers for each request, typically your app's own `Authorization`.
  /// Called on every request, so it can return a freshly refreshed session.
  final FutureOr<Map<String, String>> Function()? headers;

  /// How long to wait for your backend.
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttp;

  /// Fetches a token. Matches [VobizAccessTokenProvider].
  Future<String> call(VobizAccessTokenRequest request) async {
    final extra = await headers?.call() ?? const <String, String>{};
    final http.Response response;
    try {
      response = await _http
          .post(
            url,
            headers: <String, String>{
              ...extra,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, String>{'reason': reasonValue(request)}),
          )
          .timeout(timeout);
    } on TimeoutException catch (e) {
      throw VobizAccessTokenException('Your token backend did not answer in time', cause: e);
    } catch (e) {
      throw VobizAccessTokenException('Could not reach your token backend: $e', cause: e);
    }
    if (response.statusCode >= 400) {
      throw VobizAccessTokenException(
          'Your token backend refused the request (HTTP ${response.statusCode})',
          statusCode: response.statusCode);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw VobizAccessTokenException('Your token backend did not answer with JSON', cause: e);
    }
    final token = decoded is Map ? decoded['token'] : null;
    if (token is! String || token.trim().isEmpty) {
      throw const VobizAccessTokenException('Your token backend\'s reply has no "token"');
    }
    return token.trim();
  }

  /// The `reason` value sent for [request].
  static String reasonValue(VobizAccessTokenRequest request) => switch (request) {
        VobizAccessTokenRequest.signIn => 'sign_in',
        VobizAccessTokenRequest.expiring => 'expiring',
        VobizAccessTokenRequest.rejected => 'rejected',
        VobizAccessTokenRequest.refresh => 'refresh',
      };

  /// Closes the HTTP client if this provider created it.
  void close() {
    if (_ownsHttp) _http.close();
  }
}
