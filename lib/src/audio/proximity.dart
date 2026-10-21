/// Turns the screen off when the phone is held to the ear.
///
/// A call on the earpiece needs this, or the cheek presses Hang up, Mute or
/// the keypad. CallKit and a ConnectionService call do it for you; an app
/// that shows its own call screen has to. The SDK has no platform code, so
/// the app supplies the switch and the SDK flips it: on while a call is in
/// progress on the earpiece, off on speaker, headset, hold, or when the call
/// ends.
///
/// No maintained Flutter plugin toggles the proximity wake lock, so a few
/// lines of platform code do it:
///
/// - Android: `PowerManager.newWakeLock(PROXIMITY_SCREEN_OFF_WAKE_LOCK, tag)`;
///   `acquire()` to enable, `release(RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)` to
///   disable. No permission beyond `WAKE_LOCK`.
/// - iOS: `UIDevice.current.isProximityMonitoringEnabled = enabled`.
///
/// ```dart
/// const channel = MethodChannel('app/proximity');
/// client.proximity = ProximityController.fromCallback(
///     (enabled) => channel.invokeMethod('setEnabled', enabled));
/// ```
abstract class ProximityController {
  const ProximityController();

  factory ProximityController.fromCallback(
      Future<void> Function(bool enabled) callback) = _CallbackProximity;

  /// Enables or disables the proximity screen-off behaviour.
  Future<void> setEnabled(bool enabled);
}

/// The default: does nothing.
class NoProximityController extends ProximityController {
  const NoProximityController();

  @override
  Future<void> setEnabled(bool enabled) async {}
}

class _CallbackProximity extends ProximityController {
  const _CallbackProximity(this._callback);

  final Future<void> Function(bool enabled) _callback;

  @override
  Future<void> setEnabled(bool enabled) => _callback(enabled);
}
