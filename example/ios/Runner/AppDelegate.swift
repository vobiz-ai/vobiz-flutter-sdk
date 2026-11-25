import vobiz_webrtc

/// The SDK's VobizAppDelegate starts the app's one Flutter engine at launch,
/// registers the plugins with it, and registers for PushKit first, so a
/// Vobiz push can launch the closed app and ring CallKit. VobizIosPush (Dart)
/// does the rest.
@main
@objc class AppDelegate: VobizAppDelegate {}
