/// Whether a call was placed by this client or rang it.
enum CallDirection {
  /// Someone called this client's endpoint.
  inbound,

  /// This client placed the call.
  outbound,
}
