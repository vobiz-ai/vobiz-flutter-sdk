# Vobiz WebRTC SDK for Flutter

Make and receive Vobiz voice calls from a Flutter app on Android and iOS: SIP over
WebSocket for signalling, WebRTC for the audio.

> **Never put the account Auth Token on a device.** In production each user signs in
> with credentials your backend issues: their own SIP endpoint, or a short-lived access
> token ([CREDENTIALS.md](CREDENTIALS.md)). Push sign-up for closed-app calls goes
> through your backend too. The Playground-style Zero-Config sign-in, which sends the
> Auth Token from the device, is a demo and is off unless you set
> `SdkConfig(unsafeDemoZeroConfig: true)`.

- **Sign in** with an access token or per-user SIP credentials from your backend, both
  renewed by the SDK; with an endpoint's username and password; or, for demos only, the
  Playground's Zero-Config Setup
- **Outbound calls** to phone numbers, with a caller ID, custom `X-VH-` SIP headers,
  call recording and Dial-User (ring a SIP endpoint)
- **Inbound calls**, with the caller's custom headers, and on Android also while the app
  is closed, woken by Vobiz push
- **In call:** mute, speaker and audio routes, DTMF, hold and resume, live call
  quality, conference through your server, and (demo) transfer
- **Network recovery:** reconnects by itself, and a call survives a short network drop

The [`example/`](example) app is a full Playground for Flutter that uses all of it.

---

## Sign in

| | **Access token** (production) | **Credentials provider** (production) | **SIP Direct** | **Zero-Config Setup** (demo only) |
|---|---|---|---|---|
| Call | `connectWithAccessTokenProvider(provider)` (or `connectWithAccessToken(jwt)`) | `connectWithCredentialsProvider(provider)` | `connectWithCredentials(CredentialConfig(...))` | `connectWithAuthToken(...)` with `SdkConfig(unsafeDemoZeroConfig: true)` |
| Where credentials come from | Your backend mints a short-lived JWT with `POST /api/v1/Account/{auth_id}/JWT/Token/` | Your backend creates one endpoint per user and returns its username and password | You already hold an endpoint's username and password | The webhook server provisions the account's single shared Playground endpoint |
| On the device | A token that expires; no endpoint needed | That user's endpoint password | The endpoint password | **The account Auth ID and Auth Token** |
| Registers as | `<sub>_<auth_id>` | The endpoint | The endpoint | The shared Playground endpoint |
| Several devices / users | Each user gets their own `sub` | Each has its own endpoint | One endpoint each | One shared endpoint, password rotated on every sign-in: devices log each other out |
| Expiry and refusals | Renewed 60 s before expiry; a failed renewal is retried (5 s, doubling to 60 s); a refused token asks the provider again | A refusal asks the provider again and the client re-registers | Registration fails | Registration fails |

Access-token sign-in is the web SDK's `loginWithAccessToken` /
`loginWithAccessTokenGenerator`: the token travels as `X-Vobiz-Jwt` on REGISTER and on
outbound INVITEs, and its `app` claim picks the application whose Answer URL handles
your outbound calls. See [CREDENTIALS.md](CREDENTIALS.md#access-tokens-jwt).
`TokenConfig` is a deprecated alias for a SIP password, not a JWT.

## Quick start

```yaml
# pubspec.yaml
dependencies:
  vobiz_webrtc: ^0.2.0
```

Or run `flutter pub add vobiz_webrtc`.

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

Invalid input is refused **before** anything is dialled, with an `ArgumentError` that
names every problem: a header that breaks the rules, a caller ID that is not a plus and
7 to 15 digits, or a destination with a space or a SIP delimiter. The header rules match
the Vobiz web SDK and are public as `VobizSipHeaders`, so a form can check them as the
user types.

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
await client.sendDtmf('1');    // RFC 4733 in the audio when negotiated, otherwise SIP INFO
await client.hold();           // resume(): re-INVITEs, the other side hears hold music
final stats = await client.getCallStats(); // rttMs, jitterMs, packetLossPercent
await client.hangup();
```

`client.audioRoutes` lists and selects earpiece, speaker, Bluetooth and wired headsets,
and `client.callMediaEvents` reports mute, hold, early media, route changes and call
quality. See [API_REFERENCE.md](API_REFERENCE.md#audio-and-media).

### Transfer (demo only)

`transferCall` posts the account Auth Token to the webhook server, so it works only after
a Zero-Config sign-in (which needs `unsafeDemoZeroConfig`); otherwise it throws
`StateError`. In production, transfer from your backend with the Vobiz API and
`client.callUuid`.

```dart
await client.transferCall(number: '+919876543211');               // blind
await client.transferCall(sipUser: 'play123',                      // to an endpoint,
    sipHeaders: {'X-VH-OrderId': 'A1234'});                        // with context
await client.transferCall(number: '+919876543211', leg: TransferLeg.bLeg);
```

`leg` names the call's legs the way Vobiz does, by who started the call:
`TransferLeg.aLeg` (the default) moves the side that started the call onto the target and
drops the other side, `TransferLeg.bLeg` moves the side the call's `<Dial>` reached, and
`TransferLeg.both` moves both. On a call you placed you are the A-leg; on a call that
rang you, the caller is. Transfers go through the Vobiz Redirect API, never SIP REFER.

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

Your server implements four routes (`/conference/add`, `/state`, `/participant`, `/end`,
listed in [API_REFERENCE.md](API_REFERENCE.md#vobizconference)); the example's sample
server ([example/push_bridge](example/push_bridge/README.md#conference)) is a working
implementation. The people added see `callerId`, one of your Vobiz numbers. When the
conference ends, the SDK hangs up the call itself (`endCallWithConference`), so a hang-up
lost on its way to the phone cannot leave it on a dead call.

### Recordings (demo only)

```dart
// After a call placed with record: true has ended:
final recording = await client.waitForRecording(client.lastCallUuid!);
print(recording?.url);
```

`fetchRecordings` and `waitForRecording` read `<backendUrl>/api/recording?list=1` and
**send no credentials**, so any server that answers them gives its list to whoever knows
the address. The hosted demo server's list is shared by everyone who uses it, and the
SDK reads it only with `unsafeDemoZeroConfig`. In production, list recordings through
your own authenticated API, scoped to the signed-in user.

---

## The webhook server

`SdkConfig.backendUrl` defaults to `https://rtc-demo.vobiz.ai`, the shared hosted
Playground server. The SDK uses it only for the demo features: Zero-Config Setup,
transfers and the recordings list. Its routes:

| Route | Used for | Called by |
|---|---|---|
| `POST /api/setup` | Zero-Config Setup | the SDK |
| `GET/POST /api/answer` | what each call does: dial the number or user, apply caller ID, recording and headers | Vobiz |
| `POST /api/transfer`, `/api/transfer-xml` | transfer through the Redirect API | the SDK, then Vobiz |
| `GET /api/recording?list=1`, `POST /api/recording` | recording results | the SDK, Vobiz |
| `POST /api/dial-status` | the result of each `<Dial>` | Vobiz |

To use your own deployment of the Playground server, or an https tunnel to one while
developing, set `backendUrl`. It must be public HTTPS, because Vobiz calls it and the
SDK sends it the account Auth Token (plain `http` only to `localhost` or the Android
emulator's host, `10.0.2.2`).

```dart
final client = VobizClient(
  config: const SdkConfig(backendUrl: 'https://playground.example.com'),
);
```

## Receiving calls when the app is closed (Android)

A call to the SIP user the app signs in as rings the app over SIP while it is open.
When the app is closed, Vobiz's push does the waking: Vobiz's registrar holds the call
(up to 30 seconds), its push service sends a Firebase push to the phones signed up for
that SIP user, and the app claims the held call when it signs in again. No push server
of your own is needed. A closed app is reachable this way while the registration it left
behind lasts (the SDK asks for an hour, and every REGISTER starts the hour again), and
only if the phone is signed up. Signed out, or closed for longer, the call fails at once
for that phone.

1. **Sign the phone up** after each sign-in, and whenever Firebase replaces the token,
   with `VobizPushDevices.register` (`sipUsername`: `client.sipUsername`); at sign-out,
   `VobizPushDevices.logout`. Vobiz's device API takes the account's Auth ID and Auth
   Token, so the app calls **your backend**, which adds them:

   ```dart
   final devices = VobizPushDevices(
     baseUrl: Uri.parse('https://api.example.com'),
     pathPrefix: '/voice/push-devices',
     authHeaders: () async => {'Authorization': 'Bearer ${await mySession.token()}'},
   );
   await devices.register(VobizPushDevice(
     deviceId: installId,                       // made once per install, then kept
     pushToken: await FirebaseMessaging.instance.getToken() ?? '',
     sipUsername: client.sipUsername!,
     appBundleId: 'com.example.app',            // your package name
     sdkVersion: VobizClient.sdkVersion,
   ));
   ```

   Your backend takes `sip_username` from the signed-in user, never from the request,
   and removes only devices that user registered: Vobiz scopes devices to the account,
   not to the SIP user. See
   [CREDENTIALS.md](CREDENTIALS.md#push-sign-up-through-your-backend).
2. **When a push arrives**, read it and hand it to the client, then sign in if the app
   was closed (the sign-in's REGISTER claims the call):

   ```dart
   final push = VobizIncomingPush.tryParse(message.data);
   if (push != null && client.handleIncomingPush(push)) {
     // show your call screen for push.caller
   }
   ```

   `tryParse` returns null for anything but Vobiz's incoming-call push, and
   `handleIncomingPush` returns false for one that expired more than 30 s ago. The held
   INVITE then arrives as a normal incoming call whose `CallEvent.sipCallId` is the
   push's `call_id` (`client.isPushedCall(e.callId)`).
3. **Report the call screen's buttons** with `reportCallScreenAccepted(push)` and
   `reportCallScreenDeclined(push)`: a call accepted or declined before its INVITE
   arrives is answered or declined as soon as it does. `pushCallUpdates` reports each
   step, and `expired` when the call never came: take the call screen down then.

The SDK has no Firebase or call-screen dependency: the app receives the push and shows
the call screen. The example app does all of this (Firebase, `flutter_callkit_incoming`,
a foreground service per call) and signs up through its sample server; turn it on under
*Identity → Incoming calls → Receive calls through Vobiz push*. **iOS rings only while
the app is in the foreground** for now (no PushKit/CallKit yet). The flow and its limits
are in [doc/PUSH_DESIGN.md](doc/PUSH_DESIGN.md); the API is in
[API_REFERENCE.md](API_REFERENCE.md#incoming-calls-to-a-closed-app-vobiz-push).

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

A call that should keep its microphone while the app is in the background also needs a
foreground service of type `phoneCall|microphone` for its whole length.

iOS (`ios/Runner/Info.plist`):

```xml
<key>NSMicrophoneUsageDescription</key>
<string>The microphone carries your voice on calls.</string>
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

Do not add the `voip` background mode: without PushKit and CallKit it gets the app
rejected. The microphone permission is requested when the first call starts. The
foreground service, the permissions a call-screen plugin merges in, Firebase, backups
and the iOS camera purpose string are in [PLATFORM_SETUP.md](PLATFORM_SETUP.md).

## Run the example

```bash
cd example
flutter run
```

Sign in on the **Identity** tab, dial on the **Dialer** tab, and watch every step on
the **Trace** tab. A release build of the example leaves out its demo tools (Zero-Config,
the account-credential fields, the test call) unless it is built with
`--dart-define=VOBIZ_DEMO_TOOLS=true`, refuses `http://` sample-server and token-server
addresses, and is signed with the upload key named in `android/key.properties` (without
that file, with the debug key, which Play Console refuses). See
[example/README.md](example/README.md#release-builds).

## Troubleshooting

| What you see | What it means |
|---|---|
| `VobizDemoModeRequiredException` | `connectWithAuthToken` without `SdkConfig(unsafeDemoZeroConfig: true)`, or `VobizPushDevices.accountHeaders` without `unsafeDemo: true`. Use your backend's credentials instead |
| `StateError`: "Transfer needs Zero-Config Setup" | `transferCall` after any sign-in other than the (demo) Zero-Config Setup |
| `VobizException` `recordings_failed` on the demo server | The shared demo server's recordings list is read only with `unsafeDemoZeroConfig` |
| "Vobiz did not accept that Auth ID and Auth Token" | Zero-Config was refused. Both values are on the Vobiz Console dashboard; the Auth Token is not your login password |
| `registration_failed`, "Wrong credentials (403 Forbidden)" / "Authentication failed" | The endpoint username or password is wrong, or Zero-Config ran again elsewhere and rotated it |
| `reconnect_failed` | Reconnecting gave up after 10 attempts. A network change or `client.reconnect()` tries again |
| `ArgumentError` from `makeCall` | An invalid header, a caller ID that is not a plus and 7 to 15 digits, or an unusable destination; the message names each |
| A call fails at once with no B leg | The caller ID is not a number your account owns |
| No audio on an emulator | Use a real device, or enable the emulator's host microphone |

## Requirements

Flutter 3.19+, Dart 3.3+, Android API 24+ (Flutter's default minimum; the SDK's own
dependencies need 21), iOS 13+ for the SDK alone and iOS 15+ with Firebase push, as in
the example. The example app itself needs Flutter 3.27+ (Dart 3.8).

## Licence

MIT. See [LICENSE](LICENSE).

## Support

support@vobiz.ai
