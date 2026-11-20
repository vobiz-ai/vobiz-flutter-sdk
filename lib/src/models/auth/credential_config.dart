/// An existing Vobiz SIP endpoint's username and password.
///
/// In production these come from your own backend, one endpoint per user
/// (see [VobizCredentialsProvider] and CREDENTIALS.md).
class CredentialConfig {
  const CredentialConfig({
    required this.username,
    required this.password,
    this.displayName,
  });

  final String username;
  final String password;

  /// A name for the app's own use, such as the one a backend returns with
  /// the credentials. The SDK does not send it.
  final String? displayName;
}
