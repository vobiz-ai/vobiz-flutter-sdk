import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// The kind of network the device is on.
enum NetworkType { none, wifi, mobile, ethernet, vpn, other }

/// What the operating system reports about the device's network.
///
/// [types] is a set because a device can be on more than one at a time (a
/// VPN over Wi-Fi, say). An empty set or `{NetworkType.none}` means offline.
/// Being on a network does not prove the internet is reachable: a captive
/// portal still counts as Wi-Fi.
class NetworkStatus {
  NetworkStatus(Iterable<NetworkType> types)
      : types = Set<NetworkType>.unmodifiable(
            types.where((NetworkType t) => t != NetworkType.none));

  /// No network at all.
  NetworkStatus.offline() : types = const <NetworkType>{};

  final Set<NetworkType> types;

  bool get isOnline => types.isNotEmpty;

  /// The network new connections will most likely use.
  NetworkType get primary {
    for (final t in const <NetworkType>[
      NetworkType.wifi,
      NetworkType.ethernet,
      NetworkType.mobile,
      NetworkType.vpn,
      NetworkType.other,
    ]) {
      if (types.contains(t)) return t;
    }
    return NetworkType.none;
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkStatus &&
      other.types.length == types.length &&
      other.types.containsAll(types);

  @override
  int get hashCode => Object.hashAllUnordered(types);

  @override
  String toString() =>
      isOnline ? 'NetworkStatus(${types.map((t) => t.name).join('+')})' : 'NetworkStatus(offline)';
}

/// Tells the client when the device's network changes.
///
/// The default, [PlatformConnectivityMonitor], uses the `connectivity_plus`
/// plugin. Supply your own to [VobizClient] to drive it from another source,
/// or in tests.
abstract class ConnectivityMonitor {
  /// The network right now.
  Future<NetworkStatus> current();

  /// Every change of network.
  Stream<NetworkStatus> get changes;
}

/// [ConnectivityMonitor] backed by `connectivity_plus` (Android
/// ConnectivityManager, iOS NWPathMonitor).
///
/// Never throws: where the plugin is unavailable (unit tests, unsupported
/// platforms) it reports online and no changes, which is how the SDK behaved
/// before it watched the network.
class PlatformConnectivityMonitor implements ConnectivityMonitor {
  PlatformConnectivityMonitor([Connectivity? connectivity])
      : _connectivity = connectivity;

  Connectivity? _connectivity;
  Connectivity get _plugin => _connectivity ??= Connectivity();

  @override
  Future<NetworkStatus> current() async {
    try {
      return fromResults(await _plugin.checkConnectivity());
    } catch (_) {
      return NetworkStatus(const <NetworkType>[NetworkType.other]);
    }
  }

  @override
  Stream<NetworkStatus> get changes {
    try {
      return _plugin.onConnectivityChanged
          .map(fromResults)
          // A missing plugin surfaces as a stream error; swallow it so the
          // client keeps working without network awareness.
          .handleError((Object _) {});
    } catch (_) {
      return const Stream<NetworkStatus>.empty();
    }
  }

  /// Maps the plugin's results onto [NetworkStatus].
  static NetworkStatus fromResults(List<ConnectivityResult> results) =>
      NetworkStatus(results.map(_map));

  static NetworkType _map(ConnectivityResult r) {
    switch (r) {
      case ConnectivityResult.wifi:
        return NetworkType.wifi;
      case ConnectivityResult.mobile:
        return NetworkType.mobile;
      case ConnectivityResult.ethernet:
        return NetworkType.ethernet;
      case ConnectivityResult.vpn:
        return NetworkType.vpn;
      case ConnectivityResult.none:
        return NetworkType.none;
      default:
        return NetworkType.other;
    }
  }
}
