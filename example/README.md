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

On a phone (best for audio): enable **Developer options** (tap *Build number* seven
times in *About phone*), turn on **USB debugging**, connect the cable and accept the
prompt, then `flutter devices` and `flutter run -d <device id>`.

While it runs, `r` hot-reloads changes (to the app or to the SDK in `../lib`), `R`
restarts it and `q` quits.

## What is on each tab

**Identity**
- *Zero-Config Setup*: Auth ID and Auth Token. The production webhook callback
  (`https://rtc-demo.vobiz.ai`) is shown underneath; tap it to point at your own
  Playground server or an https tunnel to one.
- *SIP Direct*: an endpoint's username and password.
- *Remember me* keeps what you typed in the platform's secure storage (Keychain or
  Keystore). Unticked, anything saved before is removed.
- Once connected: the SIP username (copy), the sign-in mode, and *Disconnect*.

**Dialer**
- *Caller ID Override* and *Destination Target*, each with a searchable country-code
  picker (231 countries). Pasting a full `+44…` number picks the country for you.
- *SIP Headers*: add `X-VH-` headers, add a *Dial-User* header to ring a SIP endpoint
  instead, and *Record this call*. Rows are checked as you type, with the platform's
  own rules, and saved between launches.
- *Call headers*: the headers sent or received on recent calls, kept after they end.
- The keypad types digits before a call and sends DTMF during one.
- Incoming calls show the caller, their SIP headers, *Answer* and *Reject*.
- In a call: timer, live latency, the call's headers, *Mute*, *Keypad*, *Speaker*,
  *Transfer* and *Hang up*.
- *Transfer* (Zero-Config only): to a number (blind) or a SIP user (carrying your
  headers), moving yourself or the other party.

**Trace**
Every step of sign-in and every call event, in the web Playground's wording, with copy
and clear. It follows new lines while you are at the bottom and stays put when you
scroll up.

The theme switch (light, dark, system) is on the Identity tab. On a wide screen the
three tabs sit side by side, as on the web.

## Tests

```bash
flutter test                     # widget tests: no network, no credentials
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

Without the file the test is skipped. It switches *Remember me* off, so nothing is
written to the device. Signing in rotates the password of the account's Playground
endpoint, as signing in on the web Playground does.

Calls are not part of the automated test: they ring real phones. Test them by hand,
calling only phones you own.
