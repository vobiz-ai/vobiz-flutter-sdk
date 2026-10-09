/// What Zero-Config Setup provisioned on the caller's Vobiz account.
///
/// Returned by `VobizClient.connectWithAuthToken`. The webhook server looks
/// for an application named "Vobiz WebRTC Playground" and an endpoint aliased
/// "Vobiz WebRTC Playground Endpoint" on the account, creates them if they are
/// missing, points the application at its own answer URL, and gives the
/// endpoint a fresh password on every setup.
class ZeroConfigSession {
  const ZeroConfigSession({
    required this.sipUsername,
    required this.sipPassword,
    required this.applicationId,
    this.message,
  });

  factory ZeroConfigSession.fromJson(Map<String, dynamic> json) {
    final username = '${json['sip_username'] ?? ''}'.trim();
    final password = '${json['sip_password'] ?? ''}'.trim();
    if (username.isEmpty || password.isEmpty) {
      throw const FormatException(
          'The setup response did not include SIP credentials');
    }
    return ZeroConfigSession(
      sipUsername: username,
      sipPassword: password,
      applicationId: '${json['application_id'] ?? ''}',
      message: json['message'] as String?,
    );
  }

  /// The endpoint username the client registers as.
  final String sipUsername;

  /// The endpoint password. It stops working at the next Zero-Config Setup on
  /// the same account, which rotates it.
  final String sipPassword;

  /// The Vobiz application the endpoint is attached to.
  final String applicationId;

  /// The server's summary, such as "Reused existing infrastructure".
  final String? message;

  /// True when the application and endpoint already existed and were reused.
  bool get reusedExisting => (message ?? '').toLowerCase().contains('reused');
}
