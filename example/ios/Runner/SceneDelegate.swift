import Flutter
import UIKit
import vobiz_webrtc

/// Shows the engine VobizAppDelegate started. Info.plist names no scene
/// storyboard, so the scene does not start a second engine.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    window = VobizAppDelegate.makeWindow(for: scene)
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
