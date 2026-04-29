# Vobiz WebRTC SDK for Flutter

Make and receive voice calls in your Flutter app using Vobiz — a SIP-based calling platform with WebRTC media.

- 📞 **Make outbound calls** to phone numbers (PSTN)
- 📲 **Receive inbound calls** automatically
- 🎙️ **Crystal clear audio** via WebRTC
- 🔌 **Auto-reconnect** on network issues
- 📱 **Works on Android & iOS**

---

## 🚀 Quick Start (5 Minutes)

### 1. Install the SDK

```bash
flutter pub add vobiz_webrtc
```

### 2. Get Your Vobiz Credentials

1. Log in to [Vobiz Console](https://app.vobiz.ai)
2. Go to **Voice** → **Endpoints**
3. Create or select an endpoint and copy:
   - **Username** (e.g., `dkvoice312279403969368799244`)
   - **Password** (from endpoint creation)

### 3. Wire Up the SDK

```dart
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

// Create client
final client = VobizClient(
  config: SdkConfig(
    wsUrl: 'wss://registrar.vobiz.ai:5063/',
    sipServer: 'registrar.vobiz.ai',
    backendUrl: 'https://your-backend.example.com',
  ),
);

// Connect
await client.connect();

// Login
await client.login(
  username: 'your-endpoint-username',
  password: 'your-endpoint-password',
);

// Listen for calls
client.state.listen((state) {
  print('Call: ${state.call}');
});

// Make a call
await client.makeCall('+1234567890');

// Answer incoming call
await client.answer();

// Hang up
await client.hangup();
```

---

## ⚙️ Platform Setup

### Android Setup

Add permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

Request microphone permission at runtime:

```dart
import 'package:permission_handler/permission_handler.dart';

await Permission.microphone.request();
```

### iOS Setup

Add to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>We need microphone access to make and receive calls</string>
<key>NSLocalNetworkUsageDescription</key>
<string>We need local network access for calling</string>
```

Request permissions:

```dart
import 'package:permission_handler/permission_handler.dart';

await Permission.microphone.request();
```

---

## 📖 Full Guide

### 1. Setup Backend

You need an Answer URL server. See [vobiz-rtc-demo](https://github.com/devlume-in/vobiz-rtc-demo) for Node.js reference.

### 2. Connect to SIP

```dart
final client = VobizClient(
  config: SdkConfig(
    wsUrl: 'wss://registrar.vobiz.ai:5063/',
    sipServer: 'registrar.vobiz.ai',
    backendUrl: 'https://your-backend.example.com',
  ),
);

await client.connect();
```

### 3. Login with Credentials

```dart
await client.login(
  username: 'dkvoice312279403969368799244',
  password: 'your-password-from-vobiz-console',
);
```

### 4. Make Outbound Calls

```dart
await client.makeCall('+1234567890');

// Listen for state changes
client.state.listen((state) {
  if (state.call == CallState.inCall) {
    print('Call connected!');
  }
});
```

### 5. Handle Inbound Calls

```dart
client.state.listen((state) {
  if (state.call == CallState.incoming) {
    print('Incoming from: ${state.callerId}');
    // Show accept/reject UI
  }
});

// Accept
await client.answer();

// Or reject
await client.reject();
```

### 6. Call Control

```dart
// Mute microphone
await client.setMuted(true);

// Unmute
await client.setMuted(false);

// End call
await client.hangup();
```

---

## 🔗 Answer URL Contract

Your backend must handle `/answer` endpoint:

**Outbound (SDK initiates):**
```xml
<?xml version="1.0"?>
<Response>
  <Dial callerId="+918046733542">
    <Number>+1234567890</Number>
  </Dial>
</Response>
```

**Inbound (PSTN calls your number):**
```xml
<?xml version="1.0"?>
<Response>
  <Dial>
    <User>sip:your-endpoint@registrar.vobiz.ai</User>
  </Dial>
</Response>
```

See [vobiz-rtc-demo/server.js](https://github.com/devlume-in/vobiz-rtc-demo/blob/main/server.js) for full implementation.

---

## 📚 API Reference

### VobizClient

```dart
// Connection
Future<void> connect()
Future<void> login(String username, String password)
Future<void> disconnect()

// Outbound
Future<void> makeCall(String destination)

// Inbound
Future<void> answer()
Future<void> reject()

// Control
Future<void> hangup()
Future<void> setMuted(bool muted)

// State
Stream<VobizState> get state
```

### VobizState

```dart
ClientConnectionState connection   // disconnected/connecting/connected
RegistrationState registration     // unregistered/registering/registered/failed
CallState call                     // idle/calling/incoming/inCall/ended
String? callerId                   // Incoming caller ID
String? errorMessage               // Error if any
bool isMuted                       // Microphone muted?
```

---

## 📄 Features

- ✅ SIP registration with digest auth
- ✅ Outbound calls to PSTN numbers
- ✅ Inbound call detection
- ✅ WebRTC audio
- ✅ Mute/Unmute
- ✅ Hold/Resume
- ✅ Blind transfer
- ✅ Three-way conference
- ✅ Auto-reconnect

---

## 🐛 Troubleshooting

| Issue | Solution |
|-------|----------|
| "SIP socket closed" | Check internet, verify credentials, endpoint must be Active |
| No audio | Use physical device, not emulator; grant microphone permissions |
| Inbound calls don't arrive | Verify app is registered; check Answer URL is correct in Vobiz Console |

---

## 📦 Requirements

- Flutter 3.19.0+
- Dart 3.3.0+
- Android 5.0+ or iOS 11.0+

---

## 📚 Resources

- [Vobiz Console](https://app.vobiz.ai)
- [Example App](https://github.com/devlume-in/vobiz-flutter-sdk/tree/main/example)
- [Demo Backend](https://github.com/devlume-in/vobiz-rtc-demo)
- [GitHub Issues](https://github.com/devlume-in/vobiz-flutter-sdk/issues)

---

## 📄 License

MIT License — See LICENSE file

---

## Support

- Email: support@vobiz.ai
- GitHub: [devlume-in/vobiz-flutter-sdk](https://github.com/devlume-in/vobiz-flutter-sdk)
