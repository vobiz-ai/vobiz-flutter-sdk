# vobiz_webrtc

A Flutter SDK for making and receiving calls over the Vobiz platform using SIP-over-WebSocket and WebRTC.

---

## Features

- SIP registration with digest authentication
- Outbound calling to any phone number or SIP address
- Inbound call detection via server polling
- Hold / Resume
- Blind transfer
- Add call (three-way conference)
- Mute / Unmute
- Android and iOS support

---

## Before You Begin

### Android

Add the following permissions to your `android/app/src/main/AndroidManifest.xml` inside the `<manifest>` tag, **above** `<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
```

Also add `android:usesCleartextTraffic="true"` to `<application>` if your backend runs over HTTP (non-HTTPS):

```xml
<application
    ...
    android:usesCleartextTraffic="true">
```

### iOS

Add the following entries to your `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to make and receive calls.</string>
```

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  vobiz_webrtc: ^0.1.0
```

---

## Quick Start

```dart
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

// 1. Create the client
final client = VobizClient(
  config: SdkConfig(
    wsUrl: 'wss://registrar.vobiz.ai:5063/',
    sipServer: 'registrar.vobiz.ai',
    backendUrl: 'https://your-server.example.com',
  ),
);

// 2. Listen for events
client.connectionEvents.listen((event) {
  print('Connection: ${event.connectionState} / ${event.registrationState}');
});

client.callEvents.listen((event) {
  print('Call ${event.callId}: ${event.state}');
  if (event.state == CallStateStatus.incoming) {
    client.acceptCall();
  }
});

client.errorEvents.listen((event) {
  print('Error: ${event.message}');
});

// 3. Connect with your Vobiz credentials
await client.connect(
  CredentialConfig(username: 'your-sip-username', password: 'your-sip-password'),
);

// 4. Make a call
await client.makeCall('+919876543210');

// 5. Hang up
await client.hangup();

// 6. Clean up
await client.dispose();
```

---

## Credentials

You receive your SIP `username` and `password` from the Vobiz dashboard after creating an endpoint. The `backendUrl` points to your own server that handles Vobiz webhooks — see the [demo server](../../Vobiz-RTC-demo/server.js) for a reference implementation.

---

## SdkConfig Reference

| Field | Default | Description |
|---|---|---|
| `wsUrl` | `wss://registrar.vobiz.ai:5063/` | WebSocket URL of the Vobiz SIP registrar |
| `sipServer` | `registrar.vobiz.ai` | SIP server domain used in SIP headers |
| `backendUrl` | `http://10.0.2.2:3000` | Base URL of your Vobiz webhook server |
| `autoReconnect` | `true` | Reconnect automatically on WebSocket drop |
| `debug` | `false` | Enable verbose logging |
| `iceConfig` | Google STUN | ICE/STUN/TURN server configuration |
| `mediaConstraints` | Audio only | WebRTC media constraints |

---

## Call Control

```dart
// Hold / Resume
await client.hold();
await client.resume();

// Mute / Unmute
await client.mute();
await client.unmute();

// Blind transfer
await client.transfer('+911234567890');

// Add a third party to the call
await client.addCall('+911234567890');

// Merge held + active into conference
await client.mergeCalls();
```

---

## Custom ICE / STUN / TURN

```dart
final client = VobizClient(
  config: SdkConfig(
    wsUrl: 'wss://registrar.vobiz.ai:5063/',
    sipServer: 'registrar.vobiz.ai',
    backendUrl: 'https://your-server.example.com',
    iceConfig: IceConfig(
      servers: [
        IceServerConfig(urls: ['stun:stun.l.google.com:19302']),
        IceServerConfig(
          urls: ['turn:turn.example.com:3478'],
          username: 'user',
          credential: 'pass',
        ),
      ],
    ),
  ),
);
```

---

## Event Reference

### ConnectionEvent

| Field | Type | Description |
|---|---|---|
| `connectionState` | `ConnectionStateStatus` | `connecting`, `connected`, `disconnected`, `failed` |
| `registrationState` | `RegistrationState` | `unregistered`, `registering`, `registered`, `failed` |
| `message` | `String?` | Human-readable status message |

### CallEvent

| Field | Type | Description |
|---|---|---|
| `callId` | `String` | Unique identifier for this call leg |
| `state` | `CallStateStatus` | `incoming`, `connecting`, `ringing`, `active`, `held`, `ended`, `failed` |
| `message` | `String?` | e.g. caller ID for inbound, error reason for failed |

### ErrorEvent

| Field | Type | Description |
|---|---|---|
| `code` | `String` | Machine-readable error code |
| `message` | `String` | Human-readable description |
| `cause` | `Object?` | Underlying exception if available |

---

## CHANGELOG

See [CHANGELOG.md](CHANGELOG.md).
