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
