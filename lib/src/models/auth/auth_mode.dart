/// How a [VobizClient] signed in.
enum VobizAuthMode {
  /// Not signed in.
  none,

  /// Zero-Config Setup: the account's Auth ID and Auth Token were sent to the
  /// webhook server, which found or created the application and SIP endpoint
  /// on that account and returned the endpoint's credentials.
  ///
  /// The only mode that can transfer calls, because the transfer is made
  /// through the Vobiz API with those account credentials.
  zeroConfig,

  /// SIP Direct: an existing endpoint's SIP username and password. Nothing is
  /// provisioned and no account credentials reach the device.
  sipDirect,

  /// An access token (JWT) minted by the app's backend: the client registers
  /// as `<sub>_<iss>` with the token instead of a password. No endpoint is
  /// needed and no long-lived secret reaches the device.
  accessToken,
}
