import '../webrtc/ice_config.dart';

/// Builds ICE server entries for a TURN server with the fallbacks a phone
/// needs on restrictive networks.
///
/// Many mobile carriers, hotel and corporate networks block UDP or every port
/// but 443. One TURN server reachable three ways covers them:
///
/// 1. `turn:<host>:<port>?transport=udp`: the normal path.
/// 2. `turn:<host>:<port>?transport=tcp`: UDP blocked.
/// 3. `turns:<tlsHost>:443?transport=tcp`: only HTTPS gets out (TLS on 443
///    looks like web traffic to a firewall).
///
/// ```dart
/// SdkConfig(
///   iceConfig: IceConfig(servers: [
///     const IceServerConfig(urls: ['stun:stun.l.google.com:19302']),
///     ...TurnServers.withFallbacks(
///       host: 'turn.example.com',
///       username: turnUser,
///       credential: turnPassword,
///     ),
///   ]),
/// );
/// ```
///
/// The SDK does not ship TURN credentials; they come from your TURN provider
/// (or a short-lived credential your backend issues).
class TurnServers {
  TurnServers._();

  /// One [IceServerConfig] holding the UDP, TCP and TLS-443 URLs of a TURN
  /// server, in that order of preference.
  ///
  /// [tlsHost] defaults to [host]; set it when the TLS listener has its own
  /// name (its certificate must match). Set [udp], [tcp] or [tls] to false to
  /// leave a path out.
  static List<IceServerConfig> withFallbacks({
    required String host,
    required String username,
    required String credential,
    int port = 3478,
    String? tlsHost,
    int tlsPort = 443,
    bool udp = true,
    bool tcp = true,
    bool tls = true,
  }) {
    final h = host.trim();
    if (h.isEmpty) throw ArgumentError.value(host, 'host', 'is empty');
    if (h.contains(':') && !h.startsWith('[')) {
      throw ArgumentError.value(
          host, 'host', 'must not include a port or scheme; use port/tlsPort');
    }
    if (username.isEmpty || credential.isEmpty) {
      throw ArgumentError('TURN needs a username and a credential');
    }
    if (!udp && !tcp && !tls) {
      throw ArgumentError('At least one of udp, tcp or tls is needed');
    }
    final urls = <String>[
      if (udp) 'turn:$h:$port?transport=udp',
      if (tcp) 'turn:$h:$port?transport=tcp',
      if (tls) 'turns:${(tlsHost ?? h).trim()}:$tlsPort?transport=tcp',
    ];
    return <IceServerConfig>[
      IceServerConfig(urls: urls, username: username, credential: credential),
    ];
  }

  /// Whether [config] has a TURN server reachable over TLS on port 443, the
  /// one path that works on networks that let only HTTPS out.
  static bool hasTls443Fallback(IceConfig config) => config.servers.any(
      (IceServerConfig s) => s.urls.any((String u) =>
          u.startsWith('turns:') && RegExp(r':443(\?|$)').hasMatch(u)));

  /// Whether [config] has any TURN (relay) server.
  static bool hasRelay(IceConfig config) => config.servers.any(
      (IceServerConfig s) => s.urls.any(
          (String u) => u.startsWith('turn:') || u.startsWith('turns:')));
}
