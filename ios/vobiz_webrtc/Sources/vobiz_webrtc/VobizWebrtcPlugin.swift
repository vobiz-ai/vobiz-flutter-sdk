import Flutter
import UIKit

/// The plugin: one channel to Dart's VobizIosPush. The work is in
/// VobizCallKit, which exists before any Flutter engine does.
public class VobizWebrtcPlugin: NSObject, FlutterPlugin {
  static let channelName = "ai.vobiz.webrtc/ios_push"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    VobizCallKit.shared.attach(channel)
    channel.setMethodCallHandler { call, result in
      VobizCallKit.shared.handle(call, result: result)
    }
  }
}
