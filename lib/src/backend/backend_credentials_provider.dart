import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/credentials_provider.dart';
import '../errors/vobiz_exception.dart';
import '../models/auth/credential_config.dart';

/// A [VobizCredentialsProvider] that asks your own backend for the signed-in
/// user's SIP endpoint credentials over HTTPS.
///
/// It sends `POST <url>` with a JSON body `{"reason": "sign_in" | "rejected" |
/// "refresh"}` and the headers from [headers] (put your app's own session
/// token there), and expects:
///
/// ```json
/// {"sip_username": "agent42", "sip_password": "..."}
/// ```
///
/// Anything else in the reply (a `display_name`, say) is ignored: the SDK
/// signs in with the username and password only. See CREDENTIALS.md for a
/// reference backend that creates one Vobiz endpoint per user and never
/// rotates its password on sign-in.
///
/// ```dart
/// final provider = VobizBackendCredentialsProvider(
///   url: Uri.parse('https://api.example.com/voice/sip-credentials'),
///   headers: () async => {'Authorization': 'Bearer ${await mySession.token()}'},
/// );
/// final session = await client.connectWithCredentialsProvider(provider.call);
/// ```
class VobizBackendCredentialsProvider {
  VobizBackendCredentialsProvider({
    required this.url,
    this.headers,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// Your backend's credentials route. Must be HTTPS outside local testing.
  final Uri url;

  /// Headers for each request, typically your app's own `Authorization`.
  /// Called on every request, so it can return a freshly refreshed token.
  final FutureOr<Map<String, String>> Function()? headers;

  /// How long to wait for your backend.
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttp;

  /// Fetches the credentials. Matches [VobizCredentialsProvider].
  Future<CredentialConfig> call(VobizCredentialsRequest request) async {
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
      throw VobizCredentialsException('Your backend did not answer in time', cause: e);
    } catch (e) {
      throw VobizCredentialsException('Could not reach your backend: $e', cause: e);
    }
    if (response.statusCode >= 400) {
      throw VobizCredentialsException(
          'Your backend refused the credentials request (HTTP ${response.statusCode})',
          statusCode: response.statusCode);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw VobizCredentialsException('Your backend did not answer with JSON', cause: e);
    }
    if (decoded is! Map) {
      throw const VobizCredentialsException('Your backend did not answer with a JSON object');
    }
    final username = '${decoded['sip_username'] ?? ''}'.trim();
    final password = '${decoded['sip_password'] ?? ''}';
    if (username.isEmpty || password.isEmpty) {
      throw const VobizCredentialsException(
          'Your backend\'s reply has no sip_username or sip_password');
    }
    return CredentialConfig(username: username, password: password);
  }

  /// The `reason` value sent for [request].
  static String reasonValue(VobizCredentialsRequest request) => switch (request) {
        VobizCredentialsRequest.signIn => 'sign_in',
        VobizCredentialsRequest.rejected => 'rejected',
        VobizCredentialsRequest.refresh => 'refresh',
      };

  /// Closes the HTTP client if this provider created it.
  void close() {
    if (_ownsHttp) _http.close();
  }
}
