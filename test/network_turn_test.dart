// Issue #20 (transport part): TURN with UDP, TCP and TLS-443 fallbacks.
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

void main() {
  test('one TURN server reachable over UDP, TCP and TLS on 443', () {
    final servers = TurnServers.withFallbacks(
        host: 'turn.example.com', username: 'u', credential: 'p');
    expect(servers, hasLength(1));
    expect(servers.single.urls, <String>[
      'turn:turn.example.com:3478?transport=udp',
      'turn:turn.example.com:3478?transport=tcp',
      'turns:turn.example.com:443?transport=tcp',
    ]);
    final json = servers.single.toJson();
    expect(json['username'], 'u');
    expect(json['credential'], 'p');

    final config = IceConfig(servers: <IceServerConfig>[
      const IceServerConfig(urls: <String>['stun:stun.l.google.com:19302']),
      ...servers,
    ]);
    expect(TurnServers.hasRelay(config), isTrue);
    expect(TurnServers.hasTls443Fallback(config), isTrue);
    final rtc = config.toRtcConfiguration()['iceServers'] as List<dynamic>;
    expect(rtc, hasLength(2));
  });

  test('the default ICE config has no relay and no TLS-443 path', () {
    expect(TurnServers.hasRelay(const IceConfig()), isFalse);
    expect(TurnServers.hasTls443Fallback(const IceConfig()), isFalse);
  });

  test('separate TLS host and paths can be left out', () {
    final s = TurnServers.withFallbacks(
      host: 'turn.example.com',
      tlsHost: 'turns.example.com',
      username: 'u',
      credential: 'p',
      udp: false,
    ).single;
    expect(s.urls, <String>[
      'turn:turn.example.com:3478?transport=tcp',
      'turns:turns.example.com:443?transport=tcp',
    ]);
  });

  test('rejects a host with a port, empty credentials, or no paths', () {
    expect(() => TurnServers.withFallbacks(host: 'turn.example.com:3478', username: 'u', credential: 'p'),
        throwsArgumentError);
    expect(() => TurnServers.withFallbacks(host: 'turn.example.com', username: '', credential: 'p'),
        throwsArgumentError);
    expect(
        () => TurnServers.withFallbacks(
            host: 'h', username: 'u', credential: 'p', udp: false, tcp: false, tls: false),
        throwsArgumentError);
  });

  test('connectivity_plus results map onto NetworkStatus', () {
    // Exercised without the plugin: the mapping is pure.
    expect(NetworkStatus.offline().isOnline, isFalse);
    expect(NetworkStatus(const <NetworkType>[NetworkType.none]).isOnline, isFalse);
    final both = NetworkStatus(const <NetworkType>[NetworkType.mobile, NetworkType.wifi]);
    expect(both.primary, NetworkType.wifi);
    expect(both, NetworkStatus(const <NetworkType>[NetworkType.wifi, NetworkType.mobile]));
    expect(
        PlatformConnectivityMonitor.fromResults(
            <ConnectivityResult>[ConnectivityResult.mobile, ConnectivityResult.vpn]).primary,
        NetworkType.mobile);
    expect(
        PlatformConnectivityMonitor.fromResults(
            <ConnectivityResult>[ConnectivityResult.none]).isOnline,
        isFalse);
  });
}
