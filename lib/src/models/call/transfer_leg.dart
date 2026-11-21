/// Which leg of a live call a transfer moves, named the way Vobiz names a
/// call's legs: by who started the call, not by who is transferring.
enum TransferLeg {
  /// Moves the side that started the call onto the transfer target, and
  /// drops the other side. On a call this client placed that is this
  /// client; on a call that rang this client it is the caller.
  aLeg('aleg'),

  /// Moves the side the call's `<Dial>` reached onto the transfer target,
  /// and drops the other side. On a call that rang this client that is this
  /// client; on a call this client placed it is the party called.
  bLeg('bleg'),

  /// Moves both legs: each runs the transfer XML on its own (for example,
  /// both join a conference).
  both('both');

  const TransferLeg(this.apiValue);

  /// The value the Vobiz Redirect API expects in `legs`.
  final String apiValue;
}
