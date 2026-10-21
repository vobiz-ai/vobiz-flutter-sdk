/// **Not token authentication.** [token] is sent as the SIP digest password
/// of the user [displayName] (or `token-user`), exactly like
/// [CredentialConfig]; there is no JWT or access-token sign-in.
///
/// Vobiz SIP registration authenticates with an endpoint's username and
/// password only (docs.vobiz.ai: "SIP endpoints do not require a separate
/// token or JWT"). Access-token sign-in needs platform support that does not
/// exist yet; when it does, the SDK will add it next to
/// `connectWithCredentialsProvider`, whose provider callback already gives a
/// refreshable place to fetch short-lived secrets.
@Deprecated('TokenConfig is a SIP password under another name. Use '
    'CredentialConfig, or connectWithCredentialsProvider with credentials '
    'from your own backend.')
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
