import AVFAudio
import CallKit
import CryptoKit
import Flutter
import PushKit
import UIKit
import UserNotifications
import flutter_callkit_incoming
#if canImport(WebRTC)
import WebRTC
#endif

/// The example's iOS side: Vobiz push over PushKit, the system call screen
/// (CallKit, through flutter_callkit_incoming), and the call's audio.
///
/// * One Flutter engine, started here and not by the window scene: a VoIP
///   push launches a closed app in the background, with no scene, and that
///   engine has to sign in and claim the call Vobiz is holding.
/// * Every VoIP push is reported to CallKit before PushKit's completion
///   runs. iOS ends an app that takes a VoIP push without reporting a call,
///   and stops sending it VoIP pushes after a few. A push that is not a live
///   Vobiz call is reported too, and ended at once.
/// * The channel `ai.vobiz.example/call` is the one CallPlatform (Dart) uses
///   on Android: `ready`, `packageName`, `startCallService`,
///   `stopCallService`, `showMissedCall`, `requestNotifications` (iOS only),
///   and `push` towards Dart.
@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CallkitIncomingAppDelegate {
  /// The engine that runs the whole app: UI, SIP connection and pushes.
  /// SceneDelegate shows it in the window.
  lazy var flutterEngine = FlutterEngine(name: "vobiz_playground")

  private var voipRegistry: PKPushRegistry?
  private var channel: FlutterMethodChannel?
  private let audio = CallAudio()

  /// Pushes that came before Dart listened (the push that launched the app).
  private var pendingPushes: [[String: String]] = []
  private var dartReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)

    let channel = FlutterMethodChannel(
      name: "ai.vobiz.example/call", binaryMessenger: flutterEngine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel

    audio.setUp()

    // After the plugins: an incoming push is reported through
    // flutter_callkit_incoming, which registration creates.
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ready":
      dartReady = true
      result(pendingPushes)
      pendingPushes.removeAll()
    case "packageName":
      // Vobiz pushes to iOS with the APNs key saved for this bundle id.
      result(Bundle.main.bundleIdentifier)
    case "startCallService":
      audio.appCallStarted()
      result(nil)
    case "stopCallService":
      audio.appCallEnded()
      result(nil)
    case "requestNotifications":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
        granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "showMissedCall":
      let args = call.arguments as? [String: Any]
      Self.postMissedCall(
        id: args?["id"] as? String ?? UUID().uuidString,
        caller: Self.nonEmpty(args?["caller"] as? String) ?? "Unknown caller")
      result(nil)
    case "leaveLockScreen":
      // Android only: CallKit handles the lock screen.
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func deliver(_ push: [String: String]) {
    if dartReady, let channel = channel {
      channel.invokeMethod("push", arguments: push)
    } else {
      pendingPushes.append(push)
    }
  }

  // MARK: - PushKit

  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    // Dart reads it with FlutterCallkitIncoming.getDevicePushTokenVoIP().
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType, completion: @escaping () -> Void
  ) {
    guard type == .voIP, let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance else {
      NSLog("Vobiz push: no call screen to report the push to")
      completion()
      return
    }
    // Vobiz's push service sends the call's fields as top-level strings
    // next to "aps".
    var push: [String: String] = [:]
    for (key, value) in payload.dictionaryPayload {
      guard let key = key as? String, key != "aps" else { continue }
      push[key] = "\(value)"
    }
    let live = Self.isLiveCall(push)
    let callId = push["call_id"] ?? ""
    let key = callId.isEmpty ? UUID().uuidString : callId

    let caller = Self.nonEmpty(push["caller"]) ?? Self.nonEmpty(push["caller_number"]) ?? "Unknown caller"
    let data = flutter_callkit_incoming.Data(
      id: Self.screenId(for: key),
      nameCaller: caller,
      handle: Self.nonEmpty(push["caller_number"]) ?? caller,
      type: 0)
    data.appName = "Vobiz Playground"
    data.handleType = "generic"
    // As long as the call screen rings on Android (CallScreen.ringFor).
    data.duration = 45000
    // WebRTC's audio waits for CallKit to activate the session (CallAudio).
    data.configureAudioSession = false
    // The app logs missed calls itself, from how the call really ended.
    data.isShowMissedCallNotification = false
    var extra = push
    extra["source"] = "push"
    extra["key"] = key
    data.extra = extra as NSDictionary

    plugin.showCallkitIncoming(data, fromPushKit: true) { [weak self] in
      // CallKit answers on its own queue; the channel is main-thread only.
      DispatchQueue.main.async {
        // After the report, so Dart finds the screen among the active calls
        // and does not show it a second time.
        if live {
          self?.deliver(push)
        } else {
          NSLog("Vobiz push: not a live Vobiz call; reported to CallKit and ended")
          plugin.endCall(data)
        }
        completion()
      }
    }
  }

  /// "Missed call" from [caller]; one per call [id], a second replaces the
  /// first. Posted only when notifications are allowed (requestNotifications).
  private static func postMissedCall(id: String, caller: String) {
    let content = UNMutableNotificationContent()
    content.title = "Missed call"
    content.body = caller
    content.sound = .default
    let request = UNNotificationRequest(identifier: "missed-\(id)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      if let error = error { NSLog("Missed call notification: \(error)") }
    }
  }

  /// A call Vobiz's registrar holds for this phone, not yet expired: the
  /// fields VobizIncomingPush.tryParse needs.
  static func isLiveCall(_ push: [String: String]) -> Bool {
    guard push["type"] == "incoming_call",
      ["call_id", "index", "label", "registrar"].allSatisfy({ nonEmpty(push[$0]) != nil })
    else { return false }
    guard let raw = push["expires_at"], let at = Double(raw) else { return true }
    // Seconds, or milliseconds when too large to be seconds (as in Dart).
    let seconds = at < 100_000_000_000 ? at : at / 1000
    return Date(timeIntervalSince1970: seconds) > Date()
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  /// CallKit wants a UUID for every call; a call's key (the SIP Call-ID of a
  /// pushed call) is not one. A name-based UUID (version 5, URL namespace):
  /// CallScreen.idFor in Dart makes the same one from the same key.
  static func screenId(for key: String) -> String {
    let namespace: [UInt8] = [
      0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
      0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
    ]
    var h = Array(Insecure.SHA1.hash(data: Foundation.Data(namespace + Array(key.utf8))))
    h[6] = (h[6] & 0x0F) | 0x50
    h[8] = (h[8] & 0x3F) | 0x80
    let uuid = UUID(uuid: (
      h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
      h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    return uuid.uuidString.lowercased()
  }

  // MARK: - CallKit (flutter_callkit_incoming)

  // Each action is fulfilled at once; Dart hears of it as a CallEvent and
  // answers, declines or hangs up the SIP call.
  func onAccept(_ call: flutter_callkit_incoming.Call, _ action: CXAnswerCallAction) {
    audio.callKitAnswered()
    action.fulfill()
  }

  func onDecline(_ call: flutter_callkit_incoming.Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  func onEnd(_ call: flutter_callkit_incoming.Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  func onTimeOut(_ call: flutter_callkit_incoming.Call) {}

  func didActivateAudioSession(_ audioSession: AVAudioSession) {
    audio.callKitActivated(audioSession)
  }

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    audio.callKitDeactivated(audioSession)
  }

  func providerDidReset() {
    audio.callKitReset()
  }
}

/// WebRTC's audio around CallKit.
///
/// A call answered on the CallKit screen gets its audio session from
/// CallKit, which activates it only after the answer (the app may not
/// activate it first, or the call is silent on a locked phone). So WebRTC
/// runs with manual audio: its audio unit starts when CallKit activates the
/// session. Calls CallKit does not carry (outgoing calls, and calls answered
/// in the app) activate the session themselves when Dart reports them
/// (`startCallService`).
final class CallAudio {
  /// Between Dart's startCallService and stopCallService.
  private var appCall = false
  /// CallKit has activated the session for a call.
  private var callKitActive = false
  /// Answered on the CallKit screen; CallKit has yet to activate the session.
  private var callKitPending = false

  func setUp() {
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.useManualAudio = true
      session.isAudioEnabled = false
    #else
      NSLog("CallAudio: WebRTC is not importable here; WebRTC manages its own audio session")
    #endif
  }

  func callKitAnswered() {
    callKitPending = true
  }

  func callKitActivated(_ audioSession: AVAudioSession) {
    callKitPending = false
    callKitActive = true
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.audioSessionDidActivate(audioSession)
      session.isAudioEnabled = true
    #endif
  }

  func callKitDeactivated(_ audioSession: AVAudioSession) {
    callKitActive = false
    #if canImport(WebRTC)
      RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    #endif
    // The CallKit call ended under a call that still runs: keep its audio.
    if appCall {
      activateOwnSession()
    } else {
      disable()
    }
  }

  func callKitReset() {
    callKitActive = false
    callKitPending = false
    if appCall {
      activateOwnSession()
    } else {
      disable()
    }
  }

  func appCallStarted() {
    appCall = true
    if !callKitActive && !callKitPending { activateOwnSession() }
  }

  func appCallEnded() {
    appCall = false
    callKitPending = false
    // A CallKit call's session is CallKit's to deactivate.
    if !callKitActive { disable(deactivate: true) }
  }

  private func activateOwnSession() {
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.lockForConfiguration()
      defer { session.unlockForConfiguration() }
      do {
        try session.setConfiguration(RTCAudioSessionConfiguration.webRTC(), active: true)
      } catch {
        NSLog("CallAudio: could not activate the audio session: \(error)")
      }
      session.isAudioEnabled = true
    #endif
  }

  private func disable(deactivate: Bool = false) {
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.isAudioEnabled = false
      guard deactivate else { return }
      session.lockForConfiguration()
      defer { session.unlockForConfiguration() }
      try? session.setActive(false)
    #endif
  }
}
