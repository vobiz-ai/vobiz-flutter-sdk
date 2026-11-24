import Flutter
import UIKit

/// Shows the app's one Flutter engine (AppDelegate.flutterEngine) in the
/// window. The scene must not make its own: a VoIP push can start the app
/// with no scene, and the engine AppDelegate starts then is the one that
/// signs in and takes the call.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let windowScene = scene as? UIWindowScene,
      let appDelegate = UIApplication.shared.delegate as? AppDelegate
    {
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = FlutterViewController(
        engine: appDelegate.flutterEngine, nibName: nil, bundle: nil)
      self.window = window
      window.makeKeyAndVisible()
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
