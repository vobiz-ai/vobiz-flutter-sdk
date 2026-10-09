# Vobiz WebRTC SDK for Flutter

Make and receive Vobiz voice calls from a Flutter app on Android and iOS: SIP over
WebSocket for signalling, WebRTC for the audio.

It signs in and calls the same way as the [Vobiz WebRTC Playground](https://rtc-demo.vobiz.ai),
against the same hosted webhook server, so an app built on it needs **no backend of
its own and no credentials compiled in**. Whoever uses the app signs in with their
own account.

- **Two ways to sign in:** Zero-Config Setup (Auth ID + Auth Token) or SIP Direct
  (an endpoint's username and password)
- **Outbound calls** to phone numbers, with a caller ID, custom `X-VH-` SIP headers,
  call recording and Dial-User (ring a SIP endpoint)
- **Inbound calls**, with the caller's custom headers
- **In call:** mute, speaker, DTMF keypad, transfer, live latency
- **Auto-reconnect** when the network drops

The [`example/`](example) app is a full Playground for Flutter that uses all of it.

---

## Sign in: the two modes

| | **Zero-Config Setup** | **SIP Direct** |
|---|---|---|
| You enter | Auth ID and Auth Token (Vobiz Console dashboard) | An endpoint's SIP username and password (Console → Voice → Endpoints) |
| What happens | The webhook server finds or creates the application "Vobiz WebRTC Playground" and the endpoint "Vobiz WebRTC Playground Endpoint" on **your** account, points the application at its answer URL, gives the endpoint a fresh password, and the SDK registers as it | The SDK registers as that endpoint. Nothing is provisioned |
| Credentials on the device | Auth ID and Auth Token, in memory only until `disconnect()` | The endpoint's password only |
| Transfer | Yes | No (it needs the account credentials) |

Zero-Config Setup sends the Auth ID and Auth Token to the webhook server once, exactly
as the web Playground does. Signing in this way gives the shared Playground endpoint a
new password, so a web Playground session on the same account that signed in with the
old one stops working at its next refresh.

## Quick start

```yaml
# pubspec.yaml
dependencies:
  vobiz_webrtc:
    git:
      url: https://github.com/vobiz-ai/vobiz-flutter-sdk.git
```

```dart
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

final client = VobizClient(); // defaults to the hosted webhook server

// Zero-Config Setup
final session = await client.connectWithAuthToken(
  authId: authIdTheUserTyped,
  authToken: authTokenTheUserTyped,
);

// …or SIP Direct
await client.connectWithCredentials(
  CredentialConfig(username: sipUsername, password: sipPassword),
);

// Registration finishes asynchronously.
client.connectionEvents.listen((e) {
  if (e.registrationState == RegistrationState.registered) print('Ready');
});
```

### Place a call

```dart
await client.makeCall(
  '+919876543210',               // destination, E.164
  callerId: '+918000000000',     // a number your account owns → X-VH-Caller-ID
  headers: {'X-VH-Order-Id': 'A1234'},
  record: true,                  // → X-VH-Record: true
);
```

Invalid headers are refused **before** anything is dialled, with a reason for each
(`ArgumentError`). The rules match the Vobiz web SDK exactly and are public as
`VobizSipHeaders`, so a form can check them as the user types.

To ring a SIP endpoint instead of the number, add `dialUser: 'play123'`. A destination
number is still needed: it is what gets the call to the webhook.

### Answer, control and end calls

```dart
client.callEvents.listen((e) {
  switch (e.state) {
    case CallStateStatus.incoming:
      print('Call from ${e.remoteIdentity}, headers ${e.headers}');
    case CallStateStatus.active:
      print('Connected, CallUUID ${e.callUuid}');
    case CallStateStatus.failed:
      print('Failed: ${e.reason} (SIP ${e.sipCode})');
    case CallStateStatus.ended:
      print('Ended: ${e.reason}');
    default:
  }
});

await client.acceptCall();     // or rejectCall()
await client.mute();           // unmute()
await client.setSpeakerphone(true);
await client.sendDtmf('1');    // SIP INFO, as the web SDK sends it
final stats = await client.getCallStats(); // rttMs, jitterMs, packetLossPercent
await client.hangup();
```

### Transfer (Zero-Config only)

```dart
await client.transferCall(number: '+919876543211');               // blind
await client.transferCall(sipUser: 'play123',                      // to an endpoint,
    sipHeaders: {'X-VH-OrderId': 'A1234'});                        // with context
await client.transferCall(number: '+919876543211', leg: TransferLeg.bLeg);
```

`TransferLeg.aLeg` (default) moves you onto the target and drops the other party;
`TransferLeg.bLeg` moves the other party and drops you. Transfers go through the Vobiz
Redirect API, never SIP REFER.

### Recordings

```dart
// After a call placed with record: true has ended:
final recording = await client.waitForRecording(client.lastCallUuid!);
print(recording?.url);
```

The recordings list on the hosted server is shared by everyone who uses it, so match by
CallUUID, as `waitForRecording` does, rather than taking the newest entry.

---

## The webhook server

`SdkConfig.backendUrl` defaults to `https://rtc-demo.vobiz.ai`, the hosted Playground
server (the web Playground's "production webhook callback"). It serves:

| Route | Used for | Called by |
|---|---|---|
| `POST /api/setup` | Zero-Config Setup | the SDK |
| `GET/POST /api/answer` | what each call does: dial the number or user, apply caller ID, recording and headers | Vobiz |
| `POST /api/transfer`, `/api/transfer-xml` | transfer through the Redirect API | the SDK, then Vobiz |
| `GET /api/recording?list=1`, `POST /api/recording` | recording results | the SDK, Vobiz |
| `POST /api/dial-status` | the result of each `<Dial>` | Vobiz |

To use your own deployment of the Playground server, or an https tunnel to one while
developing, set `backendUrl`. It must be public HTTPS: Vobiz calls it.

```dart
final client = VobizClient(
  config: const SdkConfig(backendUrl: 'https://playground.example.com'),
);
```

### Receiving calls when the app is closed

The SDK registers over a WebSocket, and Vobiz drops that registration as soon as the
socket closes, so an app that Android has closed cannot be rung directly. The
example app shows the usual way round it: a small server answers your Vobiz number,
sends a Firebase push that wakes the app and shows the system call screen, and rings
the endpoint again until the app has signed back in. See
[example/push_bridge](example/push_bridge/README.md) and the example app's
*Incoming calls* panel. The SDK needs nothing extra: `CallEvent.headers` carries the
`X-VH-` headers the server puts on the INVITE, which the app uses to match the call to
its push.

The older call-control methods (`hold`, `resume`, `transfer(String)`, `addCall`,
`swapCalls`, `mergeCalls`, `warmTransferStart`…) call routes such as `/hold-start` that
only the Node reference server implements. They are unchanged; against the Playground
server they only log a warning. Use `transferCall` for transfers.

## Platform setup

Android (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

iOS (`ios/Runner/Info.plist`):

```xml
<key>NSMicrophoneUsageDescription</key>
<string>The microphone carries your voice on calls.</string>
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

The microphone permission is requested when the first call starts. More detail in
[PLATFORM_SETUP.md](PLATFORM_SETUP.md).

## Run the example

```bash
cd example
flutter run
```

Sign in on the **Identity** tab, dial on the **Dialer** tab, and watch every step on
the **Trace** tab. See [example/README.md](example/README.md).

## Troubleshooting

| What you see | What it means |
|---|---|
| "Vobiz did not accept that Auth ID and Auth Token" | Zero-Config was refused. Both values are on the Vobiz Console dashboard; the Auth Token is not your login password |
| "Wrong credentials (403 Forbidden)" / "Authentication failed" | SIP Direct: the endpoint username or password is wrong, or Zero-Config ran again elsewhere and rotated it |
| A call fails at once with no B leg | The caller ID is not a number your account owns |
| "Transfer needs Zero-Config Setup" | Signed in with SIP Direct |
| No audio on an emulator | Use a real device, or enable the emulator's host microphone |

## Requirements

Flutter 3.19+, Dart 3.3+, Android 5.0+ (API 21) or iOS 13+ (the minimums of
`flutter_webrtc`).

## Licence

MIT. See [LICENSE](LICENSE).

## Support

support@vobiz.ai
