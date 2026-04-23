class CallActions {
  const CallActions({
    this.canAnswer = false,
    this.canReject = false,
    this.canHangup = false,
    this.canMute = false,
    this.canHold = false,
    this.canResume = false,
    this.canSendDtmf = false,
  });

  final bool canAnswer;
  final bool canReject;
  final bool canHangup;
  final bool canMute;
  final bool canHold;
  final bool canResume;
  final bool canSendDtmf;
}
