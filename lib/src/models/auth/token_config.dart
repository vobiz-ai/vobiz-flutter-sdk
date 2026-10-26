/// **Not token authentication.** [token] is sent as the SIP digest password
/// of the user [displayName] (or `token-user`), exactly like
/// [CredentialConfig].
///
/// For access-token (JWT) sign-in use `VobizClient.connectWithAccessToken`
/// or `connectWithAccessTokenProvider`: they send the token as
/// `X-Vobiz-Jwt`, which the registrar validates in place of a password.
@Deprecated('TokenConfig is a SIP password under another name. For a JWT use '
    'connectWithAccessToken or connectWithAccessTokenProvider; for an '
    'endpoint use CredentialConfig or connectWithCredentialsProvider.')
class TokenConfig {
  const TokenConfig({
    required this.token,
    this.displayName,
    this.answerUrl,
  });

  /// Sent as the SIP digest password.
  final String token;

  /// Used as the SIP username (not a display name).
  final String? displayName;
  final String? answerUrl;
}
