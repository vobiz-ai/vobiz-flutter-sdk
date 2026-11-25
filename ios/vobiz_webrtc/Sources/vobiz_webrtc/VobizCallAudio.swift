import AVFoundation
import Foundation

/// WebRTC's audio around CallKit.
///
/// CallKit activates the audio session for a call only after the user
/// answers, and the app must not activate it first, or a call answered on a
/// locked phone can be silent. So WebRTC runs with manual audio: its audio
/// unit starts when CallKit activates the session. Calls CallKit does not
/// carry (outgoing calls, calls with no CallKit screen) activate the session
/// themselves when Dart says the call started (`audioStart`).
///
/// WebRTC's RTCAudioSession is reached through the Objective-C runtime, not
/// imported: flutter_webrtc brings WebRTC through CocoaPods or Swift Package
/// Manager depending on the app, and this plugin builds the same either way.
/// Where WebRTC is missing, every call here is a no-op.
final class VobizCallAudio {
  /// Between Dart's audioStart and audioStop.
  private var appCall = false
  /// CallKit has activated the session for a call.
  private var callKitActive = false
  /// Answered on CallKit; CallKit has yet to activate the session.
  private var callKitPending = false

  private var rtc: NSObject? {
    guard let cls = NSClassFromString("RTCAudioSession") else { return nil }
    return (cls as AnyObject).perform(NSSelectorFromString("sharedInstance"))?
      .takeUnretainedValue() as? NSObject
  }

  private func setRTC(_ key: String, _ value: Bool) {
    rtc?.setValue(value, forKey: key)
  }

  private func tellRTC(_ selector: String, _ session: AVAudioSession) {
    _ = rtc?.perform(NSSelectorFromString(selector), with: session)
  }

  func useManualAudio() {
    guard rtc != nil else {
      NSLog("VobizCallAudio: WebRTC's RTCAudioSession not found; WebRTC manages its own audio session")
      return
    }
    setRTC("useManualAudio", true)
    setRTC("isAudioEnabled", false)
  }

  func callKitAnswered() {
    callKitPending = true
  }

  func callKitActivated(_ session: AVAudioSession) {
    callKitPending = false
    callKitActive = true
    tellRTC("audioSessionDidActivate:", session)
    setRTC("isAudioEnabled", true)
  }

  func callKitDeactivated(_ session: AVAudioSession) {
    callKitActive = false
    tellRTC("audioSessionDidDeactivate:", session)
    // The CallKit call ended under a call that still runs: keep its audio.
    if appCall {
      activateOwnSession()
    } else {
      setRTC("isAudioEnabled", false)
    }
  }

  func callKitReset() {
    callKitActive = false
    callKitPending = false
    if appCall {
      activateOwnSession()
    } else {
      setRTC("isAudioEnabled", false)
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
    guard !callKitActive else { return }
    setRTC("isAudioEnabled", false)
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
    tellRTC("audioSessionDidDeactivate:", session)
  }

  private func activateOwnSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // 0x4: allowBluetooth (renamed allowBluetoothHFP in iOS 26), for headsets.
      try session.setCategory(
        .playAndRecord, mode: .voiceChat, options: AVAudioSession.CategoryOptions(rawValue: 0x4))
      try session.setActive(true)
    } catch {
      NSLog("VobizCallAudio: could not activate the audio session: \(error)")
    }
    tellRTC("audioSessionDidActivate:", session)
    setRTC("isAudioEnabled", true)
  }
}
