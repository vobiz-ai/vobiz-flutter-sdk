/// An existing Vobiz SIP endpoint's username and password.
///
/// In production these come from your own backend, one endpoint per user
/// (see [VobizCredentialsProvider] and CREDENTIALS.md).
class CredentialConfig {
  const CredentialConfig({
    required this.username,
    required this.password,
    this.displayName,
    this.answerUrl,
  });

  final String username;
  final String password;
  final String? displayName;
  final String? answerUrl;
}
