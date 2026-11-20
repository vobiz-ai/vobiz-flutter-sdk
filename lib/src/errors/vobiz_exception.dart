/// The error codes the SDK reports, on [VobizException.code] and on
/// `ErrorEvent.code`.
///
/// Compare against these constants instead of string literals.
abstract final class VobizErrorCode {
  /// Zero-Config Setup failed or the webhook server refused it.
  static const String setupFailed = 'setup_failed';

  /// A transfer through the webhook server failed.
  static const String transferFailed = 'transfer_failed';

  /// The webhook server's recordings list could not be read.
  static const String recordingsFailed = 'recordings_failed';

  /// An account-credential (demo) operation was attempted without
  /// [SdkConfig.unsafeDemoZeroConfig]. See [VobizDemoModeRequiredException].
  static const String demoModeRequired = 'demo_mode_required';

  /// The app's credentials provider threw or returned nothing usable.
  /// See [VobizCredentialsException].
  static const String credentialsFailed = 'credentials_failed';

  /// The WebSocket to the SIP registrar could not be opened.
  static const String connectFailed = 'connect_failed';

  /// The registrar refused the SIP credentials (401/403).
  static const String registrationFailed = 'registration_failed';

  /// The WebSocket dropped.
  static const String socketError = 'socket_error';

  /// An outbound call could not be started.
  static const String makeCallFailed = 'make_call_failed';

  /// An inbound call could not be answered.
  static const String answerFailed = 'answer_failed';

  /// A call failed after it was set up.
  static const String callFailed = 'call_failed';

  /// A call did not connect in time.
  static const String callTimeout = 'call_timeout';

  /// The server refused the call's credentials (401/407 after the SDK
  /// answered its digest challenge).
  static const String authFailed = 'auth_failed';

  /// An access token (JWT) could not be used: it is not a Vobiz token, the
  /// app's token provider failed, or the token does not allow what was
  /// asked. See [VobizAccessTokenException].
  static const String accessTokenFailed = 'access_token_failed';

  /// A conference request failed: your conference server could not be
  /// reached, or it refused (see [VobizException.statusCode]).
  static const String conferenceFailed = 'conference_failed';

  /// Registering or removing this phone for Vobiz push failed: the push
  /// service refused it or could not be reached (`VobizPushDevices`).
  static const String pushDeviceFailed = 'push_device_failed';
}

/// An SDK operation failed.
///
/// [code] says which operation failed (see [VobizErrorCode]) and [message]
/// carries the server's own explanation when it gave one. Subclasses narrow
/// the cause so apps can `catch` on type:
///
/// ```dart
/// try {
///   await client.connectWithCredentialsProvider(provider);
/// } on VobizCredentialsException catch (e) {
///   // your backend did not hand out SIP credentials
/// } on VobizException catch (e) {
///   // anything else the SDK reports
/// }
/// ```
class VobizException implements Exception {
  const VobizException(this.code, this.message, {this.statusCode, this.cause});

  final String code;
  final String message;

  /// The HTTP status the server answered with, when it answered at all.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType($code${statusCode != null ? ', HTTP $statusCode' : ''}): $message';
}

/// An operation that sends the account Auth ID and Auth Token off the device
/// (Zero-Config Setup, the Playground transfer, the shared Playground
/// recordings list) was called without [SdkConfig.unsafeDemoZeroConfig].
///
/// Production apps must not see this: they sign in with SIP credentials that
/// their own backend issues (see `VobizCredentialsProvider`).
class VobizDemoModeRequiredException extends VobizException {
  const VobizDemoModeRequiredException(String operation)
      : super(
          VobizErrorCode.demoModeRequired,
          '$operation sends the account Auth ID and Auth Token from the device '
          'to the webhook server. That is for demos only. Production apps sign '
          'in with per-user SIP credentials from their own backend '
          '(connectWithCredentialsProvider). To run the demo anyway, set '
          'SdkConfig(unsafeDemoZeroConfig: true).',
        );
}

/// The app's credentials provider failed or returned unusable credentials.
class VobizCredentialsException extends VobizException {
  const VobizCredentialsException(String message, {super.statusCode, super.cause})
      : super(VobizErrorCode.credentialsFailed, message);
}

/// The SIP registrar refused the credentials, even after the provider was
/// asked for fresh ones.
class VobizRegistrationException extends VobizException {
  const VobizRegistrationException(String message, {super.cause})
      : super(VobizErrorCode.registrationFailed, message);
}

/// An access token (JWT) could not be used.
///
/// [tokenError] is the registrar's reason when it gave one: the
/// `X-vobiz-Jwt-Error-Code` header on its refusal, 10001 to 10010, the same
/// numbers the web SDK reports in `onLoginFailed`. [tokenErrorName] names it.
/// The SDK also uses [invalidToken] when a token cannot be decoded and
/// [invalidGrants] when it does not allow outgoing calls.
///
/// On an `ErrorEvent` with code [VobizErrorCode.registrationFailed], this is
/// the `cause` when the registrar refused an access token.
class VobizAccessTokenException extends VobizException {
  const VobizAccessTokenException(String message,
      {this.tokenError, super.statusCode, super.cause})
      : super(VobizErrorCode.accessTokenFailed, message);

  /// The registrar's reason code (10001 to 10010), when there is one.
  final int? tokenError;

  /// [tokenError] by name, such as `ACCESS_TOKEN_EXPIRED`; null without one.
  String? get tokenErrorName => tokenError == null ? null : errorName(tokenError!);

  /// Not a JWT, or a claim is missing or has the wrong type.
  static const int invalidToken = 10001;

  /// The JWT header is not one Vobiz signs (`typ`, `alg` or `cty`).
  static const int invalidHeader = 10002;

  /// `iss` is not an Auth ID the platform knows.
  static const int invalidIssuer = 10003;

  /// `sub` names no identity on that account.
  static const int invalidSubject = 10004;

  /// `nbf` is still in the future.
  static const int notValidYet = 10005;

  /// `exp` has passed.
  static const int expired = 10006;

  /// The signature does not match the account's Auth Token.
  static const int invalidSignature = 10007;

  /// `per.voice` does not allow this: an outgoing call without
  /// `outgoing_allow`, for example.
  static const int invalidGrants = 10008;

  /// `exp - nbf` is outside 180 seconds to 24 hours.
  static const int lifetimeTooLong = 10009;

  /// Too many sign-ins for this identity.
  static const int maxLoginsReached = 10010;

  /// The name the web SDK's `getErrorStringByErrorCodes` gives [code].
  static String errorName(int code) => switch (code) {
        invalidToken => 'INVALID_ACCESS_TOKEN',
        invalidHeader => 'INVALID_ACCESS_TOKEN_HEADER',
        invalidIssuer => 'INVALID_ACCESS_TOKEN_ISSUER',
        invalidSubject => 'INVALID_ACCESS_TOKEN_SUBJECT',
        notValidYet => 'ACCESS_TOKEN_NOT_VALID_YET',
        expired => 'ACCESS_TOKEN_EXPIRED',
        invalidSignature => 'INVALID_ACCESS_TOKEN_SIGNATURE',
        invalidGrants => 'INVALID_ACCESS_TOKEN_GRANTS',
        lifetimeTooLong => 'EXPIRATION_EXCEEDS_MAX_ALLOWED_TIME',
        maxLoginsReached => 'MAX_ALLOWED_LOGIN_REACHED',
        _ => 'UNAUTHORISED',
      };

  @override
  String toString() => 'VobizAccessTokenException('
      '${tokenError != null ? '$tokenError ${tokenErrorName!}' : code}): $message';
}
