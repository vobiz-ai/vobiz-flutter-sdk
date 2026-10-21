class IceServerConfig {
  const IceServerConfig({
    required this.urls,
    this.username,
    this.credential,
  });

  final List<String> urls;
  final String? username;
  final String? credential;

  /// Whether any of [urls] is a TURN server (`turn:` or `turns:`).
  bool get isTurn => urls.any((String u) {
        final lower = u.toLowerCase();
        return lower.startsWith('turn:') || lower.startsWith('turns:');
      });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'urls': urls,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      };
}

/// Which ICE candidates a call may use.
enum IceTransportPolicy {
  /// Any path: direct, STUN-reflexive or TURN relay.
  all,

  /// TURN relay only. Use on networks that block UDP, with a TURN server
  /// reachable over TLS on port 443 (`turns:host:443?transport=tcp`).
  relay,
}

class IceConfig {
  const IceConfig({
    this.servers = const <IceServerConfig>[
      IceServerConfig(urls: <String>['stun:stun.l.google.com:19302']),
    ],
    this.iceTransportPolicy = IceTransportPolicy.all,
  });

  final List<IceServerConfig> servers;

  /// See [IceTransportPolicy]. Defaults to [IceTransportPolicy.all].
  final IceTransportPolicy iceTransportPolicy;

  /// Whether a TURN server is configured, so the SDK waits for a relay
  /// candidate before sending the offer or answer.
  bool get hasTurnServer => servers.any((IceServerConfig s) => s.isTurn);

  Map<String, dynamic> toRtcConfiguration() => <String, dynamic>{
        'iceServers': servers.map((IceServerConfig e) => e.toJson()).toList(),
        if (iceTransportPolicy == IceTransportPolicy.relay)
          'iceTransportPolicy': 'relay',
      };
}
