import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../utils/logger.dart';
import '../utils/stream_extensions.dart';

/// Where call audio is played.
enum AudioRoute {
  /// The phone's receiver, held to the ear.
  earpiece,

  /// The loudspeaker.
  speaker,

  /// A Bluetooth headset or car kit (SCO / LE audio).
  bluetooth,

  /// A wired headset or USB headphones.
  wiredHeadset,
}

/// One audio output the platform reports, mapped to an [AudioRoute].
class AudioRouteDevice {
  const AudioRouteDevice({
    required this.route,
    required this.deviceId,
    required this.label,
  });

  final AudioRoute route;

  /// The platform's id for the output, as `Helper.enumerateDevices` gives it.
  final String deviceId;

  /// A name to show, such as the headset's Bluetooth name.
  final String label;

  @override
  String toString() => 'AudioRouteDevice($route, $deviceId, $label)';
}

/// Asks the platform for the runtime permission Android 12+ needs before an
/// app can see a Bluetooth headset (`BLUETOOTH_CONNECT`). Return true when it
/// is granted (or not needed on this platform).
///
/// The SDK has no platform code of its own, so the app supplies this, for
/// example with `permission_handler`:
///
/// ```dart
/// client.audioRoutes.bluetoothPermissionRequester = () async =>
///     !Platform.isAndroid ||
///     (await Permission.bluetoothConnect.request()).isGranted;
/// ```
///
/// The SDK asks once, before the first call's audio starts, because
/// flutter_webrtc's Android audio switch only looks for headsets when a call's
/// audio starts. Without it, a Bluetooth headset is never offered on
/// Android 12+ even though the manifest declares the permission.
typedef BluetoothPermissionRequester = Future<bool> Function();

/// The platform calls [AudioRouteController] makes. The default talks to
/// flutter_webrtc; tests substitute a fake.
abstract class AudioDeviceBackend {
  Future<List<MediaDeviceInfo>> audioOutputs();
  Future<void> selectAudioOutput(String deviceId);
  Future<void> setSpeakerphoneOn(bool enabled);

  /// Calls [onChange] whenever an output appears or disappears, until the
  /// returned function is called.
  void Function() listenForDeviceChanges(void Function() onChange);
}

class FlutterWebRtcAudioBackend implements AudioDeviceBackend {
  const FlutterWebRtcAudioBackend();

  @override
  Future<List<MediaDeviceInfo>> audioOutputs() =>
      Helper.enumerateDevices('audiooutput');

  @override
  Future<void> selectAudioOutput(String deviceId) =>
      Helper.selectAudioOutput(deviceId);

  @override
  Future<void> setSpeakerphoneOn(bool enabled) =>
      Helper.setSpeakerphoneOn(enabled);

  /// flutter_webrtc has one device-change handler for the whole app: the
  /// one already there (the app's own, say) keeps being called, and gets
  /// its place back when this one stops, unless another took it since.
  @override
  void Function() listenForDeviceChanges(void Function() onChange) {
    final devices = navigator.mediaDevices;
    final previous = devices.ondevicechange;
    final handler = (dynamic event) {
      previous?.call(event);
      onChange();
    };
    devices.ondevicechange = handler;
    return () {
      if (identical(devices.ondevicechange, handler)) {
        devices.ondevicechange = previous;
      }
    };
  }
}

/// Lists and selects call audio outputs, and puts the route back to the
/// default (earpiece, or a connected headset) between calls.
///
/// The route the SDK reports is the one it last selected, or the default
/// after speaker-off and between calls. When the output in use goes away (a
/// headset disconnects), [routeChanges] reports the default the platform
/// falls back to. A headset that connects while another output is in use is
/// listed by [availableDevices] but not reported as the route.
class AudioRouteController {
  AudioRouteController({
    AudioDeviceBackend backend = const FlutterWebRtcAudioBackend(),
    Logger? logger,
  })  : _backend = backend,
        _logger = logger ?? Logger();

  final AudioDeviceBackend _backend;
  final Logger _logger;

  final StreamController<AudioRoute> _routeChanges =
      StreamController<AudioRoute>.broadcast();

  AudioRoute _route = AudioRoute.earpiece;
  bool _listening = false;
  bool _disposed = false;
  void Function()? _stopListening;
  bool? _bluetoothPermitted;

  /// See [BluetoothPermissionRequester].
  BluetoothPermissionRequester? bluetoothPermissionRequester;

  /// The route the SDK last selected.
  AudioRoute get currentRoute => _route;

  /// Whether audio is on the loudspeaker.
  bool get isSpeakerOn => _route == AudioRoute.speaker;

  /// Emits the route each time it changes.
  Stream<AudioRoute> get routeChanges => _routeChanges.stream;

  /// Asks [bluetoothPermissionRequester] once per process. Returns whether
  /// Bluetooth may be used (true when no requester is set: the app may have
  /// asked already).
  Future<bool> ensureBluetoothPermission() async {
    final cached = _bluetoothPermitted;
    if (cached != null) return cached;
    final requester = bluetoothPermissionRequester;
    if (requester == null) return true;
    try {
      final granted = await requester();
      _bluetoothPermitted = granted;
      if (!granted) {
        _logger.warn('Bluetooth permission refused: headsets will not be offered');
      }
      return granted;
    } catch (e) {
      _logger.warn('Bluetooth permission request failed: $e');
      return false;
    }
  }

  /// The outputs a call can use right now.
  Future<List<AudioRouteDevice>> availableDevices() async {
    _listen();
    final List<MediaDeviceInfo> outputs;
    try {
      outputs = await _backend.audioOutputs();
    } catch (e) {
      _logger.warn('Could not list audio outputs: $e');
      return const <AudioRouteDevice>[];
    }
    final seen = <AudioRoute>{};
    final devices = <AudioRouteDevice>[];
    for (final MediaDeviceInfo info in outputs) {
      if (info.kind != null && info.kind != 'audiooutput') continue;
      final route = routeFor(info.deviceId, info.label);
      if (route == null || !seen.add(route)) continue;
      devices.add(AudioRouteDevice(
          route: route, deviceId: info.deviceId, label: info.label));
    }
    return devices;
  }

  /// The distinct routes in [availableDevices].
  Future<List<AudioRoute>> availableRoutes() async => <AudioRoute>[
        for (final AudioRouteDevice d in await availableDevices()) d.route,
      ];

  /// Moves call audio to [route]. Throws [StateError] when that output is
  /// not connected, or when Bluetooth was chosen and the permission refused.
  Future<void> selectRoute(AudioRoute route) async {
    switch (route) {
      case AudioRoute.speaker:
        await _backend.setSpeakerphoneOn(true);
        break;
      case AudioRoute.earpiece:
        await _backend.setSpeakerphoneOn(false);
        // With a headset connected, speaker-off prefers the headset. Ask for
        // the earpiece explicitly when the platform lists it.
        final earpiece = await _deviceFor(AudioRoute.earpiece);
        if (earpiece != null) await _backend.selectAudioOutput(earpiece.deviceId);
        break;
      case AudioRoute.bluetooth:
      case AudioRoute.wiredHeadset:
        if (route == AudioRoute.bluetooth && !await ensureBluetoothPermission()) {
          throw StateError('Bluetooth permission was refused');
        }
        final device = await _deviceFor(route);
        if (device == null) {
          throw StateError('No ${route.name} audio output is connected');
        }
        await _backend.setSpeakerphoneOn(false);
        await _backend.selectAudioOutput(device.deviceId);
        break;
    }
    _setRoute(route);
  }

  /// Speaker on, or back to the default (earpiece or a connected headset).
  Future<void> setSpeakerOn(bool enabled) async {
    await _backend.setSpeakerphoneOn(enabled);
    _setRoute(enabled ? AudioRoute.speaker : await _defaultRoute());
  }

  /// Puts the route back to the default (earpiece, or a connected headset,
  /// which speaker-off prefers) so the next call does not start on the
  /// loudspeaker while the app shows the earpiece. Called when the last
  /// call ends.
  Future<void> reset() async {
    try {
      await _backend.setSpeakerphoneOn(false);
    } catch (e) {
      _logger.warn('Could not reset the audio route: $e');
    }
    _setRoute(await _defaultRoute());
  }

  /// Stops reporting route changes and hands flutter_webrtc's device-change
  /// handler back.
  Future<void> dispose() async {
    _disposed = true;
    _stopListening?.call();
    _stopListening = null;
    await _routeChanges.close();
  }

  /// Maps a flutter_webrtc output to a route. Android ids are the audio
  /// switch's kind names; iOS gives port names, so the label decides.
  static AudioRoute? routeFor(String deviceId, String label) {
    switch (deviceId) {
      case 'earpiece':
        return AudioRoute.earpiece;
      case 'speaker':
        return AudioRoute.speaker;
      case 'bluetooth':
        return AudioRoute.bluetooth;
      case 'wired-headset':
        return AudioRoute.wiredHeadset;
    }
    final text = '$deviceId $label'.toLowerCase();
    if (text.contains('bluetooth') || text.contains('airpods') ||
        text.contains('hfp') || text.contains('a2dp') || text.contains('ble')) {
      return AudioRoute.bluetooth;
    }
    if (text.contains('speaker')) return AudioRoute.speaker;
    if (text.contains('receiver') || text.contains('earpiece')) {
      return AudioRoute.earpiece;
    }
    if (text.contains('headphone') || text.contains('headset') ||
        text.contains('wired') || text.contains('usb')) {
      return AudioRoute.wiredHeadset;
    }
    return null;
  }

  Future<AudioRouteDevice?> _deviceFor(AudioRoute route) async {
    for (final AudioRouteDevice d in await availableDevices()) {
      if (d.route == route) return d;
    }
    return null;
  }

  /// What speaker-off falls back to: a headset when one is connected.
  Future<AudioRoute> _defaultRoute() async {
    final routes = await availableRoutes();
    if (routes.contains(AudioRoute.bluetooth)) return AudioRoute.bluetooth;
    if (routes.contains(AudioRoute.wiredHeadset)) return AudioRoute.wiredHeadset;
    return AudioRoute.earpiece;
  }

  void _setRoute(AudioRoute route) {
    if (route == _route) return;
    _route = route;
    _routeChanges.addIfOpen(route);
  }

  void _listen() {
    if (_listening || _disposed) return;
    _listening = true;
    try {
      _stopListening = _backend.listenForDeviceChanges(() async {
        if (_disposed) return;
        // A headset that vanished takes its route with it.
        final routes = await availableRoutes();
        if (!_disposed && !routes.contains(_route) && routes.isNotEmpty) {
          _setRoute(await _defaultRoute());
        }
      });
    } catch (e) {
      _logger.warn('Audio device changes unavailable: $e');
    }
  }
}
