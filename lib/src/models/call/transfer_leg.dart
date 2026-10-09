/// Which leg of a live call a transfer moves.
enum TransferLeg {
  /// Moves your own leg onto the transfer target. The other party is dropped.
  aLeg('aleg'),

  /// Moves the other party onto the transfer target. Your leg is dropped.
  bLeg('bleg');

  const TransferLeg(this.apiValue);

  /// The value the Vobiz Redirect API expects in `legs`.
  final String apiValue;
}
