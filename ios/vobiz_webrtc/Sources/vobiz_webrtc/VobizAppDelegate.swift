import Flutter
import UIKit

/// An AppDelegate for apps that ring through Vobiz push on iOS:
///
/// ```swift
/// import vobiz_webrtc
///
/// @main
/// @objc class AppDelegate: VobizAppDelegate {}
/// ```
///
/// A VoIP push can launch a closed app in the background, with no window
/// scene. The Flutter engine a scene would create never runs then, and that
/// engine has to sign in and claim the call. So this one starts the app's
/// engine at launch, registers the app's plugins with it, and registers for
/// PushKit first (when the app turned iOS push on before). With a window
/// scene, show the engine from the SceneDelegate:
///
/// ```swift
/// class SceneDelegate: FlutterSceneDelegate {
///   override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
///                       options connectionOptions: UIScene.ConnectionOptions) {
///     window = VobizAppDelegate.makeWindow(for: scene)
///     super.scene(scene, willConnectTo: session, options: connectionOptions)
///   }
/// }
/// ```
///
/// and take `UISceneStoryboardFile` out of Info.plist, so the scene does not
/// start a second engine from the storyboard.
open class VobizAppDelegate: FlutterAppDelegate {
  /// The app's one Flutter engine: UI, SIP connection and pushes.
  public lazy var flutterEngine = FlutterEngine(name: "vobiz_webrtc")

  open override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Before the engine: PushKit may deliver the push that launched the app.
    VobizCallKit.shared.launch()
    flutterEngine.run()
    Self.registerGeneratedPlugins(with: flutterEngine)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // Without window scenes, the app's own window shows the engine.
    if Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") == nil {
      let window = self.window ?? UIWindow(frame: UIScreen.main.bounds)
      window.rootViewController = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
      self.window = window
      window.makeKeyAndVisible()
    }
    return launched
  }

  /// A window for [scene] that shows the app's engine, for the
  /// SceneDelegate. Nil unless the app delegate is a VobizAppDelegate.
  public static func makeWindow(for scene: UIScene) -> UIWindow? {
    guard let windowScene = scene as? UIWindowScene,
      let delegate = UIApplication.shared.delegate as? VobizAppDelegate
    else { return nil }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = FlutterViewController(
      engine: delegate.flutterEngine, nibName: nil, bundle: nil)
    window.makeKeyAndVisible()
    return window
  }

  /// Registers the app's plugins (its GeneratedPluginRegistrant, which
  /// Flutter writes into the app) with [registry].
  public static func registerGeneratedPlugins(with registry: FlutterPluginRegistry) {
    guard let registrant = NSClassFromString("GeneratedPluginRegistrant") else {
      NSLog("VobizAppDelegate: GeneratedPluginRegistrant not found; no plugins registered")
      return
    }
    _ = (registrant as AnyObject).perform(NSSelectorFromString("registerWithRegistry:"), with: registry)
  }
}
