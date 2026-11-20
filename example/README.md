# Vobiz Playground for Flutter

The example app for `vobiz_webrtc`. It offers the same options as the
[Vobiz WebRTC Playground](https://rtc-demo.vobiz.ai) on the web, using the same hosted
webhook server, so it runs against any Vobiz account with nothing to deploy and no
credentials in the code.

## Run it

```bash
cd example
flutter pub get
flutter run            # pick an emulator or a connected phone
```

It needs Flutter 3.27 or newer (Dart 3.8), as its dependencies do.

On a phone (best for audio): enable **Developer options** (tap *Build number* seven
times in *About phone*), turn on **USB debugging**, connect the cable and accept the
prompt, then `flutter devices` and `flutter run -d <device id>`.

While it runs, `r` hot-reloads changes (to the app or to the SDK in `../lib`), `R`
restarts it and `q` quits.

## What is on each tab

**Identity**
- *Zero-Config Setup* (debug builds only, see [Release builds](#release-builds)): Auth
  ID and Auth Token. The production webhook callback (`https://rtc-demo.vobiz.ai`) is
  shown underneath; tap it to point at your own Playground server or an https tunnel to
  one. The Auth Token is sent to that webhook server at each sign-in and each transfer.
- *SIP Direct*: an endpoint's username and password.
- *Access token*: a short-lived JWT from a token server (your backend's route that
  returns `{"token": "<JWT>"}`), or, left empty, from the sample server's `/token`. The
  SDK fetches a new token before each one expires. Nothing secret is stored.
- *Remember me* keeps what you typed in the platform's secure storage (Keychain or
  Keystore). Unticking it removes what was saved at once.
- Once connected: the SIP username (copy), the sign-in mode, and *Disconnect*. Signing
  out signs out on the phone first, removes every saved secret (sign-in, push account,
  the sample server line), then takes the phone off Vobiz push.
- *Incoming calls*: Vobiz push, which rings this phone also when the app is closed.
  See below.
- *Sample server*: the line the server in [push_bridge/](push_bridge/README.md) prints,
  for access tokens, Conference, the connection watch and Vobiz push sign-up. See
  below.

**Dialer**
- *Caller ID Override* and *Destination Target*, each with a searchable country-code
  picker (231 countries). Pasting or typing a full `+44…` number picks the country for
  you.
- *SIP Headers*: add `X-VH-` headers, add a *Dial-User* header to ring a SIP endpoint
  instead, and *Record this call*. Rows are checked as you type, with the platform's
  own rules, and saved between launches.
- *Call headers*: the headers sent or received on recent calls, kept after they end.
- The keypad types digits before a call and sends DTMF during one.
- Incoming calls show the caller, their SIP headers, *Answer* and *Reject*.
- In a call: timer, live latency, the call's headers, *Mute*, *Keypad*, *Speaker*,
  *Transfer*, *Add* and *Hang up*.
- *Transfer* (Zero-Config only): to a number (blind) or a SIP user (carrying your
  headers), moving yourself, the other party, or both. The sheet shows the `legs` value
  it sends: on a call you placed you are the A-leg; on a call that rang you, the
  caller is.
- *Add* (through the sample server): the first person added turns the call into a
  conference; then *People* lists who is in, with mute, hold and remove for each, and
  *End for everyone*.
- *Recent calls*: the local call log, with missed calls marked.

**Trace**
Every step of sign-in and every call event, in the web Playground's wording, with copy
and clear. It follows new lines while you are at the bottom and stays put when you
scroll up.

The theme switch (light, dark, system) is on the Identity tab. On a wide screen the
three tabs sit side by side, as on the web.

## Incoming calls, also when the app is closed

A call to the SIP user the app signs in as rings the app over SIP while it is open.
When the app is in the background or has been swiped away, Vobiz push wakes it: Vobiz's
registrar holds the call (up to 30 s), its push service sends a Firebase push, and the
app shows the system call screen (flutter_callkit_incoming, full screen on a locked
phone) and signs in with the saved credentials at once; that sign-in claims the held
call. *Accept* answers it, *Decline* turns it away on this phone only (SIP 486; other
phones rung for the same call keep ringing). A call the caller gives up on
while it rings, or one that is answered on another phone, stops ringing here; a held
call whose INVITE never comes stops when its push expires. Every call ends up in
*Recent calls* on the Dialer. A call that arrives during a call is refused busy by the
SDK.

A closed phone is reachable only while the registration it left behind lasts (the SDK
asks for an hour), and only if it is signed up with Vobiz push. Signed out, or closed
for longer, the call fails at once for this phone.

To set it up (Android):

1. In a Firebase project, add an Android app with package name
   `ai.vobiz.vobiz_webrtc_example`, and save its `google-services.json` as
   `android/app/google-services.json` (git-ignored). Without it the app builds and
   rings while open, but cannot be woken.
2. In the Vobiz Console, under Push Notifications, save that Firebase project's key for
   the same package name.
3. Run the sample server behind an https tunnel, as [its README](push_bridge/README.md)
   describes. It rings the SIP users in `ROUTES` (or `ALWAYS_RING`) for calls to your
   Vobiz number; with neither set, nobody is rung.
4. In the app, on the Identity tab, paste the line the server printed under *Sample
   server*, sign in with *Remember me* ticked, switch on *Receive calls through Vobiz
   push* and allow notifications (and full-screen calls, which open Settings).

The phone then signs up for Vobiz push through the sample server, which adds the
account's credentials: the account's Auth Token never reaches the phone. Without a
server line, debug builds can sign up straight to Vobiz with the account's Auth ID and
Auth Token typed under *Incoming calls* (test only: it is the account's API key).

To try it without a second phone (debug builds): fill in the caller ID and answer URL
under *Incoming calls*, then *Call this phone through Vobiz*. The app drops its
connection without signing off, as when Android closes it, and places a real, billed
call to its own SIP user through Vobiz's Call API, which should wake it.

## The sample server

`example/push_bridge` answers your Vobiz number and rings the app with one `<Dial>`; it
does not wake a closed app (Vobiz push does). The app uses it for:

- **access tokens**: `POST /token`, when the Access token tab has no token server of its
  own. A user id the server does not mint for (`JWT_ALLOWED_SUBS`) is refused with the
  server's reason under *Connect*;
- **Conference**: `/conference/*`, with the account's Auth Token kept on the server;
- **Vobiz push sign-up**: `POST /push/devices/register` and `DELETE
  /push/devices/logout`, through the SDK's `VobizPushDevices`;
- **the connection watch**, when *Let the sample server watch my calls* is on (off by
  default): during a call the app reports to the server every second (`/call/alive`).
  When the reports stop because this phone lost its network, the server plays a tone to
  the other side and ends the call a few seconds later. The switch applies from the
  next call; a server that refuses a call (401, 403, 404) is not asked again for it.

Every request sends the server's key as `X-Bridge-Key`, and, while the app is signed
in, the SIP user it is signed in as as `X-Bridge-User`. The key is the server's whole
credential (it mints tokens, runs conferences, watches calls and signs phones up), so
the line is kept in secure storage and forgotten at sign-out.

## How the Android side fits together

In `android/app/src/main/kotlin/…`:

- **One Flutter engine.** `CallEngine` keeps the app's only engine in
  `FlutterEngineCache`; `MainActivity` runs on it (`provideFlutterEngine`) and never
  destroys it, whatever a launch intent asks. `CallPushReceiver` takes Vobiz's
  incoming-call pushes (`type: incoming_call`) and hands them to that engine, starting
  it headless when the app is closed. The Dart side registers no Firebase or
  call-screen background handlers, so no other engines start.
- **A foreground service for every call.** `CallService` (types
  `phoneCall|microphone`) runs from the moment a call is placed or answered, in the app
  or on the call screen, until it ends, with an ongoing-call notification and *Hang up*.
  Without it Android silences the microphone once the app is in the background.
- `MainActivity` uses `launchMode="singleInstance"`, so *Accept* re-opens the running
  activity from the call screen's own task. Opened by *Accept*, it shows over the lock
  screen until that call ends; opened any other way, it stays behind the lock screen.
- Nothing of the app is backed up or moved to a new phone (`allowBackup="false"` and
  data extraction rules): the saved sign-in, the call log and the push install id stay
  on this phone.

## Release builds

```bash
flutter build apk --release        # or appbundle
```

- **Demo and test-only tools are left out**: Zero-Config sign-in, the account Auth ID
  and Auth Token fields for push sign-up, and *Call this phone through Vobiz*. Vobiz
  push then signs up through the sample server only. To keep them in a release build
  for testing, add `--dart-define=VOBIZ_DEMO_TOOLS=true`.
- **https only**: a release build refuses an `http://` sample server line or token
  server (debug and profile builds accept them, for a server on your own network).
- **Signing**: put the upload keystore's details in `android/key.properties`
  (git-ignored, never commit it or the keystore):

  ```properties
  storeFile=upload-keystore.jks
  storePassword=…
  keyAlias=upload
  keyPassword=…
  ```

  `storeFile` is relative to `android/app`. Without the file the release build is
  signed with the debug key (so `flutter run --release` works) and Gradle warns: Play
  Console refuses such a build.
- The application id `ai.vobiz.vobiz_webrtc_example` is what the Firebase app and the
  Vobiz Console's push credential are registered for; the app reads it from Android
  when it signs up for push. Changing it needs a new `google-services.json` and a new
  push credential.

## Tests

```bash
flutter test test                # widget and controller tests: no network, no credentials
```

The live sign-in test signs in for real through the UI on a device or emulator:
Zero-Config Setup, *Disconnect*, then SIP Direct with the endpoint Zero-Config
provisioned. Put the credentials in a JSON file outside the repository:

```json
{ "VOBIZ_AUTH_ID": "MA_XXXXXXXX", "VOBIZ_AUTH_TOKEN": "your-auth-token" }
```

```bash
flutter test integration_test/sign_in_test.dart -d <device id> \
  --dart-define-from-file=/path/outside/the/repo/vobiz-test.json
```

Without the file the test is skipped. It runs on in-memory storage, so it neither reads
nor erases a sign-in saved on the device. Signing in rotates the password of the
account's Playground endpoint, as signing in on the web Playground does.

Calls are not part of the automated test: they ring real phones. Test them by hand,
calling only phones you own.
