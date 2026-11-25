# Platform setup

What an app needs on Android and iOS to make and receive Vobiz calls with this SDK.
Everything here is taken from the [example app](example), which builds with it.

**Platforms:** Android and iOS. Web, desktop and macOS are not supported: the SDK uses
`dart:io` for its WebSocket.

| | Android | iOS |
|---|---|---|
| Outbound calls | yes | yes |
| Incoming calls, app in the foreground | yes | yes |
| Incoming calls, app in the background or closed | yes, woken by Vobiz push; the app shows the call screen (the example shows how) | **not yet**: no PushKit/CallKit (see below) |

## Dependency

```yaml
dependencies:
  vobiz_webrtc: ^0.2.0
```

The SDK brings `flutter_webrtc ^1.0.0` and `connectivity_plus ^7.0.0` with it; do not
add an older `flutter_webrtc` yourself. No permission plugin is needed: the microphone
permission is requested by WebRTC when the first call starts. (If you want to ask
earlier, any permission plugin works; it is not required.)

## Android

### SDK levels

Use Flutter's defaults (`flutter.minSdkVersion`, `flutter.targetSdkVersion`,
`flutter.compileSdkVersion`) as the example does, or at least:

| Setting | Value | Why |
|---|---|---|
| `minSdk` | 24 | Flutter's default minimum (`flutter_webrtc` and `connectivity_plus` need 21) |
| `targetSdk` / `compileSdk` | 36 | Flutter's default, and Google Play's target API requirement rises every year |

### Build tools

`connectivity_plus` 7, which the SDK depends on, states in its changelog that its
Android side needs Android Gradle Plugin 8.12.1 or newer, Gradle 8.13 or newer and
Kotlin 2.2.0. The example builds with Gradle 8.14, Android Gradle Plugin 8.11.1 and
Kotlin 2.2.20 (`example/android/settings.gradle.kts`,
`example/android/gradle/wrapper/gradle-wrapper.properties`).

### Permissions for calling

`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<!-- Bluetooth headsets: BLUETOOTH up to Android 11, BLUETOOTH_CONNECT from 12. -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

`BLUETOOTH_CONNECT` is a runtime permission on Android 12+. Ask for it with
`client.audioRoutes.bluetoothPermissionRequester` (see
[API_REFERENCE.md](API_REFERENCE.md#audio-and-media)); without it a Bluetooth headset is
not offered.

### Keep a call alive in the background

Android silences the microphone of an app that is not in the foreground, so a call
needs a foreground service for its whole length: from the moment it is placed or
answered until it ends, inbound or outbound, with an ongoing-call notification. The SDK
has no platform code; the app runs the service. The example's is `CallService.kt`
(`example/android/app/src/main/kotlin/ai/vobiz/vobiz_webrtc_example/`), started and
stopped from Dart, and declared like this:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<!-- The phoneCall service type needs it. -->
<uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<application …>
    <service
        android:name=".CallService"
        android:exported="false"
        android:foregroundServiceType="phoneCall|microphone" />
</application>
```

The service calls `startForeground` with both types, and with `phoneCall` alone if the
system refuses the microphone type.

### Incoming calls in the background: push and a call screen

A closed app is woken by Vobiz push, a Firebase Cloud Messaging data message (see
[README.md](README.md#receiving-calls-when-the-app-is-closed-android)). The app needs:

- **Firebase**: `android/app/google-services.json` from your own Firebase project, for
  your package name. The example applies the Google services plugin only when that file
  exists, and the file is git-ignored.
- **The Vobiz Console's push credential**: that Firebase project's key, saved under
  Push Notifications for the same package name.
- **A call screen** that rings while the app starts. The example uses
  `firebase_messaging` and `flutter_callkit_incoming`.

`flutter_callkit_incoming` merges these into your manifest, whether you use them or not:

`USE_FULL_SCREEN_INTENT`, `DISABLE_KEYGUARD`, `TURN_SCREEN_ON`, `VIBRATE`, `WAKE_LOCK`,
`ACCESS_NOTIFICATION_POLICY`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_PHONE_CALL`, `FOREGROUND_SERVICE_MICROPHONE`,
**`FOREGROUND_SERVICE_CAMERA`**, **`CAMERA`**, `MANAGE_OWN_CALLS`, and a service with
`foregroundServiceType="phoneCall|microphone|camera"`.

An audio-only app should remove the camera ones, as the example does; otherwise Play
Console asks you to justify a camera foreground service:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.CAMERA" tools:node="remove" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" tools:node="remove" />

    <application …>
        <service
            android:name="com.hiennv.flutter_callkit_incoming.CallkitNotificationService"
            android:foregroundServiceType="phoneCall|microphone"
            tools:replace="android:foregroundServiceType" />
    </application>
</manifest>
```

(`flutter_callkit_incoming` 3.1.6 only adds the camera foreground-service type for video
calls with `CAMERA` granted, so removing it does not affect audio calls.) Check the
merged manifest (Android Studio → *Merged Manifest*, or
`build/app/intermediates/merged_manifest/`) after upgrading the plugin.

**Over the lock screen.** Show the app over the lock screen only for the call answered
there, and only until that call ends. The example's `MainActivity` turns on
`setShowWhenLocked` and `setTurnScreenOn` when it is opened by the call screen's Accept,
and turns them off when the call ends; opened any other way, it stays behind the lock
screen.

Play Console declarations you will still be asked for:

- **Foreground service types** `phoneCall` and `microphone`: describe the in-call
  notification.
- **Full-screen intent** (`USE_FULL_SCREEN_INTENT`): allowed for calling apps. On
  Android 14+ the user must grant it (*Settings → Apps → Special app access → Full
  screen notifications*); without it the call shows as a heads-up notification only.
  Ask for it when the user signs in, not on the first ring.
- **Notifications** (`POST_NOTIFICATIONS`) is a runtime permission on Android 13+.

### Backups

A sign-in kept in `flutter_secure_storage` is encrypted with a Keystore key that is not
backed up, so a restored copy cannot be read; a call log holds phone numbers; and a push
install id copied to a new phone would take over the old phone's push sign-up. The
example turns backups off: `android:allowBackup="false"` and
`android:dataExtractionRules="@xml/data_extraction_rules"` on `<application>`, with every
domain excluded from cloud backup and device transfer
(`example/android/app/src/main/res/xml/data_extraction_rules.xml`).

## iOS

### Deployment target

**iOS 15.0**. `flutter_webrtc` alone needs 13.0, but `firebase_core` 4,
`firebase_messaging` 16 and `flutter_callkit_incoming` 3 need 15.0, so an app that uses
them must be on 15. Set it in both places:

- `ios/Podfile`: `platform :ios, '15.0'`
- Xcode → Runner → *Build Settings* → `IPHONEOS_DEPLOYMENT_TARGET = 15.0` (all
  configurations)

The example commits both ([`example/ios/Podfile`](example/ios/Podfile)). Run
`pod install` in `ios/` after changing them.

### Info.plist

```xml
<key>NSMicrophoneUsageDescription</key>
<string>The microphone carries your voice on calls.</string>
<key>NSCameraUsageDescription</key>
<string>Calls are audio only; this app does not use the camera.</string>
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <!-- Only with PushKit and CallKit, as below. -->
  <string>voip</string>
</array>
```

`audio` keeps a call that is already up running when the app goes to the background.
`voip` lets PushKit wake the app for a call: add it only together with the PushKit and
CallKit code below.
The camera string says the camera is not used: the WebRTC framework that
`flutter_webrtc` bundles contains camera code, and App Store Connect can refuse a build
whose binary refers to the camera without a purpose string. The SDK never opens the
camera.

### Incoming calls on iOS: PushKit and CallKit

A closed or suspended iOS app is woken for a call by a PushKit VoIP push, which Vobiz's
push service sends through APNs. The SDK stays free of native code, as on Android: the
app receives the push and shows the call. The example does it in
[`example/ios/Runner/AppDelegate.swift`](example/ios/Runner/AppDelegate.swift) with
`flutter_callkit_incoming`:

1. **Capabilities.** *Push Notifications* (the example's
   [`Runner.entitlements`](example/ios/Runner/Runner.entitlements), `aps-environment`)
   and the `voip` background mode.
2. **One Flutter engine, started in the AppDelegate.** A VoIP push launches a closed
   app in the background with no window scene, so an engine the scene makes would not
   run. The example's `SceneDelegate` shows the AppDelegate's engine instead, and
   `Info.plist` names no storyboard for the scene.
3. **PushKit.** `PKPushRegistry` for `.voIP`; hand its token to
   `SwiftFlutterCallkitIncomingPlugin.setDevicePushTokenVoIP`, and sign the phone up
   with `VobizPushDevice(platform: 'ios', pushToken: <that token>, …)`.
4. **Report every push to CallKit before PushKit's completion.** iOS ends an app that
   takes a VoIP push without reporting a call, and stops sending it VoIP pushes after a
   few. A push that is not a live Vobiz call (expired, or missing its hold reference)
   is reported and ended at once. Then hand the push's fields to
   `VobizClient.handleIncomingPush`, as on Android.
5. **CallKit takes UUIDs.** A SIP Call-ID is not one: the example makes a name-based
   UUID from it, the same in Swift and in Dart (`CallScreen.uuidFor`).
6. **Audio.** WebRTC runs with manual audio (`RTCAudioSession.useManualAudio`): a call
   answered on CallKit starts its audio when CallKit activates the session
   (`didActivate`), and calls CallKit does not carry (outgoing calls, calls answered in
   the app) activate it themselves. Without this, a call answered on a locked phone is
   often silent.

Vobiz pushes with the APNs key (`.p8`, with its key id and team id) saved for the app's
bundle id under Push Notifications in the Vobiz Console, to the topic
`<bundle id>.voip`. A debug build's token is a sandbox token: it needs the credential
saved as sandbox, and a TestFlight or App Store build's a production one. See
[doc/PUSH_DESIGN.md](doc/PUSH_DESIGN.md#ios).

**Test push with a profile or release build, not debug.** A Flutter debug build runs
its Dart code through the debugger, so on a device it starts only while Xcode or
`flutter run` is attached. Launched any other way, from the home screen or by a VoIP
push to a killed app, it crashes while registering plugins, and nothing rings. Build
with `flutter run --profile` (or `flutter build ios --profile` and install it), or set
Xcode's Run scheme to *Profile* (Product → Scheme → Edit Scheme → Run → Build
Configuration).

The example is signed for Vobiz's team with the bundle id `ai.vobiz.vobizWebrtc`, which
the APNs key in the Console is saved for. Outside that team, pick your own team and
bundle id in Xcode (Runner → Signing & Capabilities) and save your own APNs key for it.

## Checklist

- [ ] Android: `minSdk` ≥ 24, `targetSdk` 36
- [ ] Android: `INTERNET`, `ACCESS_NETWORK_STATE`, `RECORD_AUDIO`,
      `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH` (max 30), `BLUETOOTH_CONNECT`
- [ ] Android: a `phoneCall|microphone` foreground service for every call, with its
      permissions and `MANAGE_OWN_CALLS`
- [ ] Android with push: `google-services.json`, the Console push credential for your
      package name, a call screen; camera permissions removed, Play declarations filled
      in, full-screen intent asked for at sign-in
- [ ] Android: over the lock screen only for the call answered there; backups off if
      you keep a sign-in or a call log
- [ ] iOS: deployment target 15.0 in the Podfile and the Xcode project (13.0 without
      Firebase and the call-screen plugin)
- [ ] iOS: `NSMicrophoneUsageDescription`, `NSCameraUsageDescription`,
      `UIBackgroundModes` = `audio`
- [ ] iOS with push: Push Notifications capability, `voip` background mode, PushKit
      reported to CallKit for every push, the engine started in the AppDelegate,
      WebRTC manual audio, and the Console APNs key for your bundle id (sandbox for
      debug builds)
- [ ] Sign-in and push sign-up use your backend ([CREDENTIALS.md](CREDENTIALS.md)), not
      the account Auth Token

## Troubleshooting

| Problem | Fix |
|---|---|
| Version solving fails on `flutter_webrtc` | Remove your own `flutter_webrtc` pin; the SDK needs `^1.0.0` |
| `pod install`: "requires a higher minimum iOS deployment version" | Set iOS 15.0 in the Podfile and the Xcode project, as above |
| The other side stops hearing you when the app goes to the background | No foreground service is running for the call |
| iOS: the app is killed on a VoIP push, or VoIP pushes stop arriving | A push was not reported to CallKit before PushKit's completion |
| iOS: no VoIP push arrives | The Console's APNs credential is sandbox for a production token or the reverse, or it is for another bundle id |
| iOS: a killed app crashes on a VoIP push (`ConnectivityPlusPlugin.register`, or any plugin's `register`) | It is a debug build, which cannot start without Xcode attached: test with a profile or release build |
| iOS: a call answered on the lock screen has no audio | WebRTC activated the audio session before CallKit: use manual audio, as above |
| No audio on an Android emulator | Use a real device, or enable the emulator's host microphone |
| Headset not used on Android 12+ | `BLUETOOTH_CONNECT` was not granted |
| Play Console asks about a camera foreground service | Remove the plugin's camera permissions and service type, as above |

Turn on SDK logging with `SdkConfig(debug: true)`, or pass your own
`Logger(writer: …)` to `VobizClient`.
