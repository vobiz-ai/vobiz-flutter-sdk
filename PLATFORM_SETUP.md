# Platform setup

What an app needs on Android and iOS to make and receive Vobiz calls with this SDK.
Everything here is taken from the [example app](example), which builds with it.

**Platforms:** Android and iOS. Web, desktop and macOS are not supported: the SDK uses
`dart:io` for its WebSocket.

| | Android | iOS |
|---|---|---|
| Outbound calls | yes | yes |
| Incoming calls, app in the foreground | yes | yes |
| Incoming calls, app in the background or closed | yes, with a push (example app) | **not yet**: no PushKit/CallKit (see below) |

## Dependency

```yaml
dependencies:
  vobiz_webrtc:
    git:
      url: https://github.com/vobiz-ai/vobiz-flutter-sdk.git
```

The SDK brings `flutter_webrtc ^1.0.0` with it; do not add an older `flutter_webrtc`
yourself. No permission plugin is needed: the microphone permission is requested by
WebRTC when the first call starts. (If you want to ask earlier, any permission plugin
works; it is not required.)

## Android

### SDK levels

Use Flutter's defaults (`flutter.minSdkVersion`, `flutter.targetSdkVersion`,
`flutter.compileSdkVersion`) as the example does, or at least:

| Setting | Value | Why |
|---|---|---|
| `minSdk` | 24 | Flutter's current minimum (`flutter_webrtc` itself needs 21) |
| `targetSdk` / `compileSdk` | 36 | Google Play requires target API 36 for new apps and updates from 31 Aug 2026 |

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

`BLUETOOTH_CONNECT` is a runtime permission on Android 12+; ask for it before routing
audio to a headset.

### If you use a call-screen plugin (incoming calls in the background)

The example app rings when it is in the background or closed by using
`firebase_messaging` and `flutter_callkit_incoming`. That plugin merges these into your
manifest, whether you use them or not:

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

Play Console declarations you will still be asked for:

- **Foreground service types** `phoneCall` and `microphone`: describe the in-call
  notification.
- **Full-screen intent** (`USE_FULL_SCREEN_INTENT`): allowed for calling apps. On
  Android 14+ the user must grant it (*Settings → Apps → Special app access → Full
  screen notifications*); without it the call shows as a heads-up notification only.
  Ask for it when the user signs in, not on the first ring.
- **Notifications** (`POST_NOTIFICATIONS`) is a runtime permission on Android 13+.

Firebase needs `android/app/google-services.json` from your own Firebase project (the
example applies the Google services plugin only when that file exists).

## iOS

### Deployment target

**iOS 15.0**. `flutter_webrtc` alone needs 13.0, but `firebase_core`,
`firebase_messaging` and `flutter_callkit_incoming` need 15.0, so an app that uses push
must be on 15. Set it in both places:

- `ios/Podfile`: `platform :ios, '15.0'`
- Xcode → Runner → *Build Settings* → `IPHONEOS_DEPLOYMENT_TARGET = 15.0` (all
  configurations)

The example commits both ([`example/ios/Podfile`](example/ios/Podfile)). Run
`pod install` in `ios/` after changing them.

### Info.plist

```xml
<key>NSMicrophoneUsageDescription</key>
<string>The microphone carries your voice on calls.</string>
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

`audio` keeps a call that is already up running when the app goes to the background.

### Incoming calls on iOS: foreground only for now

The SDK and the example ring on iOS only while the app is open. Receiving calls in
the background or after the app is closed needs PushKit VoIP pushes reported to CallKit,
which are not implemented yet.

**Do not add the `voip` background mode** until they are: iOS terminates an app that
receives a VoIP push without reporting a call to CallKit, and App Review rejects apps
that declare `voip` without that. See [doc/PUSH_DESIGN.md](doc/PUSH_DESIGN.md) for the
plan.

## Checklist

- [ ] Android: `minSdk` ≥ 24, `targetSdk` 36
- [ ] Android: `INTERNET`, `ACCESS_NETWORK_STATE`, `RECORD_AUDIO`,
      `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH` (max 30), `BLUETOOTH_CONNECT`
- [ ] Android with a call-screen plugin: camera permissions removed, Play declarations
      filled in, full-screen intent asked for at sign-in
- [ ] iOS: deployment target 15.0 in the Podfile and the Xcode project
- [ ] iOS: `NSMicrophoneUsageDescription`, `UIBackgroundModes` = `audio` (no `voip`)
- [ ] Sign-in uses credentials from your backend ([CREDENTIALS.md](CREDENTIALS.md)),
      not the account Auth Token

## Troubleshooting

| Problem | Fix |
|---|---|
| Version solving fails on `flutter_webrtc` | Remove your own `flutter_webrtc` pin; the SDK needs `^1.0.0` |
| `pod install`: "requires a higher minimum iOS deployment version" | Set iOS 15.0 in the Podfile and the Xcode project, as above |
| No audio on an Android emulator | Use a real device, or enable the emulator's host microphone |
| Headset not used on Android 12+ | `BLUETOOTH_CONNECT` was not granted |
| Play Console asks about a camera foreground service | Remove the plugin's camera permissions and service type, as above |

Turn on SDK logging with `SdkConfig(debug: true)`, or pass your own
`Logger(writer: …)` to `VobizClient`.
