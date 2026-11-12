# Vobiz WebRTC SDK for Flutter

Make and receive Vobiz voice calls from a Flutter app on Android and iOS: SIP over
WebSocket for signalling, WebRTC for the audio.

> **Never put the account Auth Token on a device.** In production each user signs in
> as their own SIP endpoint, with credentials your backend issues
> ([CREDENTIALS.md](CREDENTIALS.md)). The Playground-style Zero-Config sign-in, which
> sends the Auth Token from the device, is a demo and is off unless you set
> `SdkConfig(unsafeDemoZeroConfig: true)`.

- **Sign in** with per-user SIP credentials from your backend, refreshed when the
  registrar refuses them; or with an endpoint's username and password; or, for demos
  only, the Playground's Zero-Config Setup
- **Outbound calls** to phone numbers, with a caller ID, custom `X-VH-` SIP headers,
  call recording and Dial-User (ring a SIP endpoint)
- **Inbound calls**, with the caller's custom headers
- **In call:** mute, speaker, DTMF keypad, transfer, live latency
- **Auto-reconnect** when the network drops

The [`example/`](example) app is a full Playground for Flutter that uses all of it.

---

## Sign in

| | **Access token** (production) | **Credentials provider** (production) | **SIP Direct** | **Zero-Config Setup** (demo only) |
|---|---|---|---|---|
| Call | `connectWithAccessTokenProvider(provider)` (or `connectWithAccessToken(jwt)`) | `connectWithCredentialsProvider(provider)` | `connectWithCredentials(CredentialConfig(...))` | `connectWithAuthToken(...)` with `SdkConfig(unsafeDemoZeroConfig: true)` |
| Where credentials come from | Your backend mints a short-lived JWT with `POST /Account/{auth_id}/JWT/Token/` | Your backend creates one endpoint per user and returns its username and password | You already hold an endpoint's username and password | The webhook server provisions the account's single shared Playground endpoint |
| On the device | A token that expires (default 1 hour); no endpoint needed | That user's endpoint password | The endpoint password | **The account Auth ID and Auth Token** |
| Registers as | `<sub>_<auth_id>` | The endpoint | The endpoint | The shared Playground endpoint |
| Several devices / users | Each user gets their own `sub` | Each has its own endpoint | One endpoint each | One shared endpoint, password rotated on every sign-in: devices log each other out |
| Expiry and refusals | Renewed 60 s before expiry; a refused token asks the provider again | The provider is asked again and the client re-registers | Registration fails | Registration fails |

Access-token sign-in is the web SDK's `loginWithAccessToken` /
`loginWithAccessTokenGenerator`: the token travels as `X-Vobiz-Jwt` on REGISTER and on
outbound INVITEs, and its `app` claim picks the application whose Answer URL handles
your outbound calls. See [CREDENTIALS.md](CREDENTIALS.md#access-tokens-jwt).
`TokenConfig` is a deprecated alias for a SIP password, not a JWT.

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

final client = VobizClient();

// Production: your backend returns this user's own endpoint credentials.
final provider = VobizBackendCredentialsProvider(
  url: Uri.parse('https://api.example.com/voice/sip-credentials'),
  headers: () async => {'Authorization': 'Bearer ${await mySession.accessToken()}'},
);
final session = await client.connectWithCredentialsProvider(provider.call);

// …or SIP Direct with credentials you already hold
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

### Transfer (demo only)

`transferCall` posts the account Auth Token to the webhook server, so it needs
Zero-Config and `unsafeDemoZeroConfig`. In production, transfer from your backend with
the Vobiz API and `client.callUuid`.

```dart
await client.transferCall(number: '+919876543211');               // blind
await client.transferCall(sipUser: 'play123',                      // to an endpoint,
    sipHeaders: {'X-VH-OrderId': 'A1234'});                        // with context
await client.transferCall(number: '+919876543211', leg: TransferLeg.bLeg);
```

`TransferLeg.aLeg` (default) moves you onto the target and drops the other party;
`TransferLeg.bLeg` moves the other party and drops you. Transfers go through the Vobiz
Redirect API, never SIP REFER.

### Conference

`VobizConference` turns the current call into a conference and manages the people in it.
Vobiz mixes the voices in a conference room (VobizXML `<Conference>`); moving the call
into a room, dialling people and muting them need the Auth Token, so the SDK asks **your
server**, which makes the Vobiz calls. The first person added moves both sides of the call
into a new room, then dials them in; the phone's own call carries on unchanged.

```dart
final conference = VobizConference(
  client: client,
  serverUrl: Uri.parse('https://api.example.com'),
  headers: () async => {'Authorization': 'Bearer ${await session.token()}'},
);
await conference.add(number: '+919876543211', callerId: '+918000000000');
await conference.add(sipUser: 'play123');
conference.state.addListener(() {
  for (final p in conference.state.value?.present ?? const []) print('${p.label}: ${p.status}');
});
await conference.mute(id);   // unmute, hold (out of the room onto music), resume, remove
await conference.end();      // everyone, this call included
```

Your server implements four routes (`/conference/add`, `/state`, `/participant`, `/end`);
the example's push bridge is a working implementation, and its README has the protocol
and the Vobiz behaviour it relies on. The people added see `callerId`, one of your Vobiz
numbers. When the conference ends, the SDK hangs up the call itself
(`endCallWithConference`), so a hang-up lost on its way to the phone cannot leave it on a
dead call.

### Recordings

```dart
// After a call placed with record: true has ended:
final recording = await client.waitForRecording(client.lastCallUuid!);
print(recording?.url);
```

The hosted demo server's recordings list is shared by everyone who uses it, so the SDK
reads it only with `unsafeDemoZeroConfig`. In production point `backendUrl` at your own
server, scoped to the signed-in user.

---

## The webhook server

`SdkConfig.backendUrl` defaults to `https://rtc-demo.vobiz.ai`, the shared hosted
Playground server. It is for demos; production apps that use the routes below run
their own. It serves:

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
*Incoming calls* panel. The SDK provides `VobizIncomingPush` to read the push and match
the INVITE that follows (`CallEvent.headers` carries the server's `PushRef` header);
the call screen and the push server are still example code. **iOS rings only while the
app is in the foreground** for now (no PushKit/CallKit yet). See
[doc/PUSH_DESIGN.md](doc/PUSH_DESIGN.md).

**Vobiz's own push (Android, with Vobiz's server side, being deployed).** Vobiz's
registrar can hold a call for a SIP user with no live registration, push that user's
phones through Vobiz's push service, and send the call to the REGISTER that hands back
the push's hold reference. No push server of your own is needed:

1. After sign-in, and whenever Firebase replaces the token, register the phone with
   `VobizPushDevices.register` (`sipUsername`: the SIP user it signed in as). At
   sign-out, `VobizPushDevices.logout`.
2. When a push arrives, show your call screen and pass the push to
   `client.handleIncomingPush(VobizIncomingPush.tryParse(message.data)!)`, then sign
   in if the app was closed. The REGISTER carries `X-Index`, `X-Label` and
   `X-vobiz-Registrar-Info`, and the held INVITE follows with the push's `call_id` as
   its Call-ID (`CallEvent.sipCallId`).
3. Report the call screen's buttons with `reportCallScreenAccepted` and
   `reportCallScreenDeclined`; `pushCallUpdates` says when the call arrives or never
   came (`expired`: take the screen down).

The example app does all three in *Identity → Incoming calls → Vobiz push*. Device
registration takes the account's Auth ID and Auth Token for now: test only.

The older call-control methods (`transfer(String)`, `addCall`, `swapCalls`,
`mergeCalls`, `warmTransferStart`…) call routes such as `/add-call` that only the Node
reference server implements. They are unchanged; against the Playground server they
only log a warning. Use `transferCall` for transfers. `hold` and `resume` are SIP
re-INVITEs and work against Vobiz directly.

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

Do not add the `voip` background mode: without PushKit and CallKit it gets the app
rejected. The microphone permission is requested when the first call starts. More
detail, including the permissions a call-screen plugin merges in, in
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
| `VobizDemoModeRequiredException` | `connectWithAuthToken`, `transferCall` or the demo recordings list without `SdkConfig(unsafeDemoZeroConfig: true)`. Use your backend's credentials instead |
| "Vobiz did not accept that Auth ID and Auth Token" | Zero-Config was refused. Both values are on the Vobiz Console dashboard; the Auth Token is not your login password |
| "Wrong credentials (403 Forbidden)" / "Authentication failed" | SIP Direct: the endpoint username or password is wrong, or Zero-Config ran again elsewhere and rotated it |
| A call fails at once with no B leg | The caller ID is not a number your account owns |
| "Transfer needs Zero-Config Setup" | Not signed in with the (demo) Zero-Config Setup |
| No audio on an emulator | Use a real device, or enable the emulator's host microphone |

## Requirements

Flutter 3.19+, Dart 3.3+, Android API 24+ (Flutter's minimum), iOS 13+ for the SDK
alone and iOS 15+ with Firebase push, as in the example.

## Licence

MIT. See [LICENSE](LICENSE).

## Support

support@vobiz.ai
