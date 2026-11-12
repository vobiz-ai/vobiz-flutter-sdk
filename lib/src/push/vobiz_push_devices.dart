import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../errors/vobiz_exception.dart';

/// One phone's registration with Vobiz's push service: where to push, and
/// for which SIP user.
///
/// Vobiz pushes a call only to the devices registered for the SIP user that
/// is called ([sipUsername]), so register again whenever the app signs in as
/// another user or Firebase replaces the token.
class VobizPushDevice {
  const VobizPushDevice({
    required this.deviceId,
    required this.pushToken,
    required this.sipUsername,
    required this.appBundleId,
    this.platform = 'android',
    this.pushType = 'voip',
    this.appVersion = '',
    this.sdkVersion = '',
  });

  /// A stable id for this install of the app: make one once and keep it.
  /// Registering again with the same id updates the same device.
  final String deviceId;

  /// The push token (Firebase Cloud Messaging on Android).
  final String pushToken;

  /// The SIP user the app is signed in as (`VobizClient.sipUsername`). Vobiz
  /// pushes a call only to the devices of the SIP user it is for.
  final String sipUsername;

  /// The app's package name (Android) or bundle id (iOS). Vobiz pushes with
  /// the Firebase credential saved for it in the Console (Push
  /// Notifications).
  final String appBundleId;

  /// `android` or `ios`.
  final String platform;

  /// `voip` for incoming calls: a data-only, high-priority push.
  final String pushType;

  final String appVersion;
  final String sdkVersion;

  Map<String, String> toJson() => <String, String>{
        'device_id': deviceId,
        'push_token': pushToken,
        'platform': platform,
        'push_type': pushType,
        'app_bundle_id': appBundleId,
        'app_version': appVersion,
        'sdk_version': sdkVersion,
        'sip_username': sipUsername,
      };

  @override
  String toString() => 'VobizPushDevice($deviceId as $sipUsername, $platform/$pushType, $appBundleId)';
}

/// Registers this phone with Vobiz's push service, so a call to its SIP user
/// wakes the app when it is closed, and removes it at sign-out.
///
/// ```dart
/// final devices = VobizPushDevices(
///   authHeaders: () => VobizPushDevices.accountHeaders(authId, authToken),
/// );
/// await devices.register(VobizPushDevice(
///   deviceId: installId,
///   pushToken: await FirebaseMessaging.instance.getToken() ?? '',
///   sipUsername: client.sipUsername!,
///   appBundleId: 'com.example.app',
///   sdkVersion: VobizClient.sdkVersion,
/// ));
/// // at sign-out:
/// await devices.logout(installId);
/// ```
///
/// **Authentication is not settled yet.** Vobiz's gateway takes the
/// account's `X-Auth-ID` and `X-Auth-Token` ([accountHeaders]), which is fine
/// for a test but must not ship in an app: the Auth Token is the account's
/// API key. A way for an app to register with credentials scoped to its own
/// endpoint is still to come from Vobiz; [authHeaders] lets you pass whatever
/// that turns out to be (or your backend can register the device instead).
class VobizPushDevices {
  VobizPushDevices({
    required this.authHeaders,
    Uri? baseUrl,
    this.pathPrefix = defaultPathPrefix,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  })  : baseUrl = baseUrl ?? defaultBaseUrl,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// Vobiz's API gateway.
  static final Uri defaultBaseUrl = Uri.parse('https://api.vobiz.ai');

  /// Where the gateway hands requests to the push service. Checked on
  /// 2026-11-12: `/api/v1/devices/*` reaches it, while `/v1/devices/*`
  /// (without `/api`) is answered 404 by the gateway.
  static const String defaultPathPrefix = '/api/v1/devices';

  /// The path in front of `register` and `logout`.
  final String pathPrefix;

  /// The account's own credentials, as headers. **For testing only**: never
  /// ship an account's Auth Token in an app.
  static Map<String, String> accountHeaders(String authId, String authToken) =>
      <String, String>{'X-Auth-ID': authId.trim(), 'X-Auth-Token': authToken.trim()};

  final Uri baseUrl;

  /// The headers that authenticate each request. Called for every request.
  final FutureOr<Map<String, String>> Function() authHeaders;

  /// How long to wait for Vobiz.
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttp;

  /// `POST <pathPrefix>/register`. Throws [VobizException]
  /// (`push_device_failed`) when Vobiz refuses it or cannot be reached.
  Future<void> register(VobizPushDevice device) async {
    if (device.deviceId.trim().isEmpty || device.pushToken.trim().isEmpty) {
      throw ArgumentError('A device id and a push token are required');
    }
    if (device.sipUsername.trim().isEmpty) {
      throw ArgumentError('sipUsername is required: Vobiz pushes a call only to the '
          'devices of the SIP user it is for');
    }
    await _send('POST', 'register', device.toJson());
  }

  /// `DELETE <pathPrefix>/logout`: stop pushing to [deviceId]. Throws
  /// [VobizException] (`push_device_failed`) when Vobiz refuses it or cannot
  /// be reached.
  Future<void> logout(String deviceId) async {
    if (deviceId.trim().isEmpty) throw ArgumentError('A device id is required');
    await _send('DELETE', 'logout', <String, String>{'device_id': deviceId});
  }

  Future<void> _send(String method, String path, Map<String, String> body) async {
    final prefix = pathPrefix.endsWith('/') ? pathPrefix.substring(0, pathPrefix.length - 1) : pathPrefix;
    final url = baseUrl.resolve('$prefix/$path');
    final request = http.Request(method, url)
      ..headers.addAll(<String, String>{
        ...await authHeaders(),
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      })
      ..body = jsonEncode(body);
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(timeout));
    } on TimeoutException catch (e) {
      throw VobizException('push_device_failed',
          'Vobiz did not answer $method $url within ${timeout.inSeconds} s',
          cause: e);
    } catch (e) {
      throw VobizException('push_device_failed', 'Could not reach Vobiz for $url: $e',
          cause: e);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw VobizException(
      'push_device_failed',
      'Vobiz refused $method $url (HTTP ${response.statusCode})'
          '${_reason(response.body)}',
      statusCode: response.statusCode,
    );
  }

  /// Vobiz's own reason (`message`, `error` or `detail`), when it gave one.
  static String _reason(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        for (final key in const <String>['message', 'error', 'detail']) {
          final value = json[key];
          if (value is String && value.trim().isNotEmpty) return ': ${value.trim()}';
        }
      }
    } catch (_) {}
    return '';
  }

  /// Closes the HTTP client, unless it was passed in.
  void close() {
    if (_ownsHttp) _http.close();
  }
}
