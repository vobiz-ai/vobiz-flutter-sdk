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
/// Vobiz's gateway takes only the account's `X-Auth-ID` and `X-Auth-Token`,
/// and the Auth Token is the account's API key: it must not ship in an app.
/// So in production point [baseUrl] at your own backend, which checks the
/// signed-in user and forwards the request to Vobiz with the account
/// credentials it keeps; [authHeaders] then carries your app's session:
///
/// ```dart
/// final devices = VobizPushDevices(
///   baseUrl: Uri.parse('https://api.example.com'),
///   pathPrefix: '/vobiz/push-devices',
///   authHeaders: () async => {'Authorization': 'Bearer ${await mySession()}'},
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
/// Your backend must take `sip_username` from the signed-in user, not from
/// the request, and remove only devices that user registered: Vobiz scopes
/// devices to the account, not to the SIP user. For a demo or a test,
/// [accountHeaders] sends the account credentials from the device straight to
/// Vobiz, and only when asked to explicitly.
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

  /// The path in front of `register` and `logout`, after any path [baseUrl]
  /// has.
  final String pathPrefix;

  /// The account's own credentials, as headers, for a demo or a test: never
  /// ship an account's Auth Token in an app (see the class doc).
  ///
  /// Throws [VobizDemoModeRequiredException] unless [unsafeDemo] is true:
  /// the same deliberate opt-in as `SdkConfig.unsafeDemoZeroConfig`, so a
  /// build that must not send account credentials passes false (from a
  /// compile-time switch, say) and cannot send them by mistake.
  static Map<String, String> accountHeaders(String authId, String authToken, {required bool unsafeDemo}) {
    if (!unsafeDemo) {
      throw const VobizDemoModeRequiredException('Push sign-up with the account credentials');
    }
    return <String, String>{'X-Auth-ID': authId.trim(), 'X-Auth-Token': authToken.trim()};
  }

  /// Where requests go; its path, if any, is kept in front of [pathPrefix].
  final Uri baseUrl;

  /// The headers that authenticate each request. Called for every request.
  final FutureOr<Map<String, String>> Function() authHeaders;

  /// How long to wait for Vobiz.
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttp;

  /// `POST <pathPrefix>/register`. Throws [VobizException]
  /// ([VobizErrorCode.pushDeviceFailed]) when Vobiz refuses it, cannot be
  /// reached, or has not answered in full within [timeout].
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
  /// [VobizException] ([VobizErrorCode.pushDeviceFailed]) when Vobiz refuses
  /// it, cannot be reached, or has not answered in full within [timeout].
  Future<void> logout(String deviceId) async {
    if (deviceId.trim().isEmpty) throw ArgumentError('A device id is required');
    await _send('DELETE', 'logout', <String, String>{'device_id': deviceId});
  }

  Future<void> _send(String method, String path, Map<String, String> body) async {
    // Joined as text: Uri.resolve with a prefix that starts with '/' would
    // drop a path on baseUrl (https://api.example.com/vobiz).
    final base = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final prefix = pathPrefix.replaceAll(RegExp(r'^/+|/+$'), '');
    final url = Uri.parse(prefix.isEmpty ? '$base/$path' : '$base/$prefix/$path');
    final request = http.Request(method, url)
      ..headers.addAll(<String, String>{
        ...await authHeaders(),
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      })
      ..body = jsonEncode(body);
    final http.Response response;
    try {
      // The whole exchange, body included: a reply that stalls after its
      // headers is a timeout too.
      response = await _http.send(request).then(http.Response.fromStream).timeout(timeout);
    } on TimeoutException catch (e) {
      throw VobizException(VobizErrorCode.pushDeviceFailed,
          'Vobiz did not answer $method $url within ${timeout.inSeconds} s',
          cause: e);
    } catch (e) {
      throw VobizException(VobizErrorCode.pushDeviceFailed, 'Could not reach Vobiz for $url: $e',
          cause: e);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw VobizException(
      VobizErrorCode.pushDeviceFailed,
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
