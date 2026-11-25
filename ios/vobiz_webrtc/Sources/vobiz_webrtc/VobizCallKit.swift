import AVFoundation
import CallKit
import CryptoKit
import Flutter
import PushKit
import UIKit

/// Vobiz push-to-wake on iOS: PushKit VoIP pushes, the CallKit call screen,
/// and WebRTC's audio around CallKit (VobizCallAudio).
///
/// Dart turns it on with `VobizIosPush.start()`, which is remembered: on the
/// next launches `launch()` (from VobizAppDelegate) registers for PushKit
/// before Flutter runs, because a VoIP push can launch a closed app and must
/// be reported to CallKit before PushKit's completion runs. iOS ends an app
/// that takes a VoIP push without reporting a call, and stops sending it VoIP
/// pushes after a few, so every push is reported: one that is not a live
/// Vobiz call is reported and ended at once.
///
/// Calls are known to Dart by a key: the pushed call's SIP Call-ID, or the
/// key Dart picks for a call that rings over SIP. CallKit wants UUIDs, so
/// each key maps to a name-based UUID (screenUUID).
@objc(VobizCallKit)
public final class VobizCallKit: NSObject {
  @objc public static let shared = VobizCallKit()

  static let enabledKey = "ai.vobiz.webrtc.iosPush.enabled"
  static let settingsKey = "ai.vobiz.webrtc.iosPush.settings"

  private var registry: PKPushRegistry?
  private var provider: CXProvider?
  private let controller = CXCallController()
  let audio = VobizCallAudio()

  private var channel: FlutterMethodChannel?
  private var dartReady = false
  /// Events for Dart that came before it listened (the push that launched
  /// the app, typically).
  private var pending: [[String: Any]] = []
  private(set) var voipToken: String?

  private struct Call {
    let key: String
    var answered = false
  }
  private var calls: [UUID: Call] = [:]

  // MARK: - Launch and settings

  /// Registers for PushKit and creates the CallKit provider when the app
  /// turned iOS push on before. Call it early in
  /// `application(_:didFinishLaunchingWithOptions:)`; VobizAppDelegate does.
  @objc public func launch() {
    guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
    enable()
  }

  func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    // A new engine (hot restart): its Dart side asks again with `start`.
    dartReady = false
  }

  private func enable() {
    if provider == nil {
      let provider = CXProvider(configuration: makeConfiguration())
      provider.setDelegate(self, queue: nil)
      self.provider = provider
      audio.useManualAudio()
    }
    if registry == nil {
      let registry = PKPushRegistry(queue: .main)
      registry.delegate = self
      registry.desiredPushTypes = [.voIP]
      self.registry = registry
    }
  }

  private var settings: [String: Any] {
    UserDefaults.standard.dictionary(forKey: Self.settingsKey) ?? [:]
  }

  private func makeConfiguration() -> CXProviderConfiguration {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = false
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic, .phoneNumber]
    configuration.includesCallsInRecents = settings["includesCallsInRecents"] as? Bool ?? true
    if let name = settings["iconTemplateImageName"] as? String, let image = UIImage(named: name) {
      configuration.iconTemplateImageData = image.pngData()
    }
    if let sound = settings["ringtoneSound"] as? String, !sound.isEmpty {
      configuration.ringtoneSound = sound
    }
    return configuration
  }

  // MARK: - Dart

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      var saved = settings
      for key in ["includesCallsInRecents", "iconTemplateImageName", "ringtoneSound"] {
        saved[key] = args[key] ?? NSNull()
      }
      UserDefaults.standard.set(saved.filter { !($0.value is NSNull) }, forKey: Self.settingsKey)
      UserDefaults.standard.set(true, forKey: Self.enabledKey)
      enable()
      provider?.configuration = makeConfiguration()
      dartReady = true
      result(["voipToken": voipToken as Any, "events": pending])
      pending.removeAll()
    case "stop":
      UserDefaults.standard.set(false, forKey: Self.enabledKey)
      registry?.desiredPushTypes = []
      registry = nil
      voipToken = nil
      result(nil)
    case "reportIncoming":
      guard let key = args["key"] as? String, let provider = provider else {
        result(false)
        return
      }
      let uuid = Self.screenUUID(for: key)
      if calls[uuid] != nil {
        result(true)
        return
      }
      provider.reportNewIncomingCall(
        with: uuid, update: Self.update(caller: args["caller"] as? String, handle: args["handle"] as? String)
      ) { error in
        DispatchQueue.main.async {
          if error == nil { self.calls[uuid] = Call(key: key) }
          result(error == nil)
        }
      }
    case "answered":
      // Answered in the app: CallKit takes the call over, and activates the
      // audio session for it.
      if let key = args["key"] as? String, let call = calls[Self.screenUUID(for: key)], !call.answered {
        request(CXAnswerCallAction(call: Self.screenUUID(for: key)))
      }
      result(nil)
    case "end":
      if let key = args["key"] as? String {
        end(key: key, reason: Self.endReason(args["reason"] as? String))
      }
      result(nil)
    case "setMuted":
      if let key = args["key"] as? String, calls[Self.screenUUID(for: key)] != nil {
        request(CXSetMutedCallAction(call: Self.screenUUID(for: key), muted: args["muted"] as? Bool ?? false))
      }
      result(nil)
    case "bundleId":
      result(Bundle.main.bundleIdentifier)
    case "microphone":
      result([
        "permission": Self.microphonePermission,
        "appActive": UIApplication.shared.applicationState == .active,
      ])
    case "requestMicrophone":
      // iOS shows the prompt only over the app itself, not over CallKit or
      // the lock screen: asked any other time, the answer is what it is now.
      guard Self.microphonePermission == "undetermined",
            UIApplication.shared.applicationState == .active else {
        result(Self.microphonePermission)
        return
      }
      Self.requestMicrophone { _ in
        DispatchQueue.main.async { result(Self.microphonePermission) }
      }
    case "audioStart":
      audio.appCallStarted()
      result(nil)
    case "audioStop":
      audio.appCallEnded()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Microphone

  /// "granted", "denied" or "undetermined" (never asked).
  static var microphonePermission: String {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return "granted"
      case .denied: return "denied"
      default: return "undetermined"
      }
    }
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return "granted"
    case .denied: return "denied"
    default: return "undetermined"
    }
  }

  private static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: done)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(done)
    }
  }

  private func send(_ event: [String: Any]) {
    if dartReady, let channel = channel {
      channel.invokeMethod("event", arguments: event)
    } else {
      pending.append(event)
    }
  }

  private func request(_ action: CXCallAction) {
    controller.request(CXTransaction(action: action)) { error in
      if let error = error { NSLog("VobizCallKit: \(type(of: action)) refused: \(error)") }
    }
  }

  /// Ends a call Dart says is over (the caller hung up, the call failed, the
  /// push expired). Reported, not requested: the user did not end it.
  private func end(key: String, reason: CXCallEndedReason) {
    let uuid = Self.screenUUID(for: key)
    guard calls.removeValue(forKey: uuid) != nil else { return }
    provider?.reportCall(with: uuid, endedAt: nil, reason: reason)
  }

  private static func endReason(_ reason: String?) -> CXCallEndedReason {
    switch reason {
    case "unanswered": return .unanswered
    case "failed": return .failed
    case "answeredElsewhere": return .answeredElsewhere
    case "declinedElsewhere": return .declinedElsewhere
    default: return .remoteEnded
    }
  }

  // MARK: - Helpers

  static func update(caller: String?, handle: String?) -> CXCallUpdate {
    let update = CXCallUpdate()
    let name = nonEmpty(caller) ?? nonEmpty(handle) ?? "Unknown caller"
    update.remoteHandle = CXHandle(type: .generic, value: nonEmpty(handle) ?? name)
    update.localizedCallerName = name
    update.hasVideo = false
    update.supportsDTMF = false
    update.supportsHolding = true
    update.supportsGrouping = false
    update.supportsUngrouping = false
    return update
  }

  static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  /// A call Vobiz's registrar holds for this phone, not yet expired: what
  /// VobizIncomingPush.tryParse in Dart needs.
  static func isLiveCall(_ push: [String: String]) -> Bool {
    guard push["type"] == "incoming_call",
      ["call_id", "index", "label", "registrar"].allSatisfy({ nonEmpty(push[$0]) != nil })
    else { return false }
    guard let raw = push["expires_at"], let at = Double(raw) else { return true }
    // Seconds, or milliseconds when too large to be seconds (as in Dart).
    let seconds = at < 100_000_000_000 ? at : at / 1000
    return Date(timeIntervalSince1970: seconds) > Date()
  }

  /// The CallKit UUID for a call key: name-based (version 5, URL namespace),
  /// so the same key always gives the same call.
  static func screenUUID(for key: String) -> UUID {
    let namespace: [UInt8] = [
      0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
      0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
    ]
    var h = Array(Insecure.SHA1.hash(data: Data(namespace + Array(key.utf8))))
    h[6] = (h[6] & 0x0F) | 0x50
    h[8] = (h[8] & 0x3F) | 0x80
    return UUID(uuid: (
      h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
      h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
  }
}

// MARK: - PushKit

extension VobizCallKit: PKPushRegistryDelegate {
  public func pushRegistry(
    _ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = token
    send(["type": "token", "token": token])
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    voipToken = nil
    send(["type": "token", "token": ""])
  }

  public func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType, completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    enable()
    guard let provider = provider else {
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
    let key = Self.nonEmpty(push["call_id"]) ?? UUID().uuidString
    let uuid = Self.screenUUID(for: key)
    let update = Self.update(
      caller: Self.nonEmpty(push["caller"]) ?? push["caller_number"], handle: push["caller_number"])

    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      // CallKit answers on its own queue; the channel is main-thread only.
      DispatchQueue.main.async {
        if error == nil {
          if live {
            self.calls[uuid] = Call(key: key)
            // After the report, so the call screen is up before Dart claims.
            self.send(["type": "push", "data": push])
          } else {
            NSLog("VobizCallKit: not a live Vobiz call push; reported to CallKit and ended")
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
          }
        } else {
          // Do Not Disturb, a blocked caller, or this call is up already.
          NSLog("VobizCallKit: CallKit refused the call: \(error!)")
        }
        completion()
      }
    }
  }
}

// MARK: - CallKit

extension VobizCallKit: CXProviderDelegate {
  public func providerDidReset(_ provider: CXProvider) {
    calls.removeAll()
    audio.callKitReset()
    send(["type": "action", "action": "reset"])
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard var call = calls[action.callUUID] else {
      action.fail()
      return
    }
    call.answered = true
    calls[action.callUUID] = call
    audio.callKitAnswered()
    send(["type": "action", "action": "accept", "key": call.key])
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    guard let call = calls.removeValue(forKey: action.callUUID) else {
      action.fulfill()
      return
    }
    send(["type": "action", "action": call.answered ? "end" : "decline", "key": call.key])
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let call = calls[action.callUUID] {
      send(["type": "action", "action": "mute", "key": call.key, "muted": action.isMuted])
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    if let call = calls[action.callUUID] {
      send(["type": "action", "action": "hold", "key": call.key, "held": action.isOnHold])
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    audio.callKitActivated(audioSession)
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    audio.callKitDeactivated(audioSession)
  }
}
