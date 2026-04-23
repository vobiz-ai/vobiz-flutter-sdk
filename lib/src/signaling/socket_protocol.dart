enum SocketCommand {
  login,
  tokenLogin,
  invite,
  incomingInvite,
  ringing,
  answer,
  reject,
  bye,
  candidate,
  keepAlive,
  hold,
  resume,
  merge,
}

class SocketEnvelope {
  const SocketEnvelope({
    required this.command,
    required this.payload,
  });

  final SocketCommand command;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'command': command.name,
        'payload': payload,
      };
}
