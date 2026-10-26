# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

Fixes from the end-to-end review of 0.2.0 (tracking issue #56). Verified with unit
tests (SDK, example app and push bridge) only: no device, emulator or live Vobiz
call was used. #58 lists what still needs a device.

### Security

- The account Auth Token no longer leaves the device unless
  `SdkConfig.unsafeDemoZeroConfig` is set. Zero-Config, the Playground transfer and the
  shared demo recordings list are demo-only and throw
  `VobizDemoModeRequiredException` otherwise (#2).
- Push bridge: refuses to start without an `https` `PUBLIC_URL` and the Auth Token,
  checks Vobiz V3/V2 signatures as documented, rejects replayed nonces, and signs the
  call id into Dial callback paths (#12). Each phone pairs once and then uses its own
  device token; calls ring only the endpoints `ROUTES` maps the number to; the state
  file is 0600 (#13).
- Calls are matched to pushes by `PushRef` only, never by phone number (#46).
- Sign-out unregisters (REGISTER `Expires: 0`) and the example wipes stored
  credentials and the bridge device token (#27).

### Added

- `connectWithCredentialsProvider` and `VobizBackendCredentialsProvider`: per-user SIP
  credentials from your own backend, fetched again when the registrar refuses them
  (#14, #29). Typed errors: `VobizErrorCode` (including `auth_failed`),
  `VobizDemoModeRequiredException`, `VobizCredentialsException`,
  `VobizRegistrationException` (#33).
- Network: `networkEvents`, `reconnect()`, capped backoff (`SdkConfig.reconnectPolicy`),
  immediate reconnect when the network returns or switches, fast failure while offline,
  and a 12 s grace period that keeps a connected call through a short drop (#3, #18).
  `TurnServers.withFallbacks()` for TURN over UDP, TCP and TLS 443 (#20). New dependency:
  `connectivity_plus`.
- Media: real hold and resume by re-INVITE, RFC 4733 DTMF with SIP INFO fallback,
  183 early media, `CallQualityEvent` (interval loss, jitter, RTT, estimated MOS),
  an audio-route API, and Bluetooth-permission, proximity and audio-interruption hooks
  (#17, #20, #23, #30, #41, #44).
- `VobizIncomingPush` for reading call pushes (`ttl_ms` expiry, `lineBusy`) (#11, #50).
- CI: analyze and test for the SDK and example, and `node --test` for the bridge (#34).
- Re-registers by itself whenever the app returns to the foreground, so Vobiz has the
  device's current IP address: one REGISTER on a live connection (calls untouched), an
  immediate reconnect otherwise. `SdkConfig.reregisterOnForeground` (default true),
  `AppLifecycleMonitor` / `PlatformAppLifecycleMonitor` (#18).
- A REGISTER refresh (periodic or on returning to the foreground) that gets no answer
  now means a dead socket: it is closed and the client reconnects at once, keeping a
  call's dialog, instead of failing the registration and giving up. The foreground
  refresh waits 5 s, not 32 s. Refusals still fail the registration (#18).
- A call keeps its audio through a network drop. Before, the SIP connection came back
  but the media never did (Android deletes the ICE candidates of a lost network), and
  the call ended 12 s later. Now the client restarts ICE once it has registered again
  and offers the new candidates in an in-dialog re-INVITE on the new connection; the
  12 s grace period starts again with the restart. Verified live on Android against
  Vobiz, for calls placed and received: audio back about 1.4 s after the network
  returns, and through a Wi-Fi to mobile data switch and back. See API_REFERENCE.md,
  "When the network drops during a call".

### Fixed

- SIP: CANCEL when hanging up a ringing outbound call, with a crossing 200 ACKed and
  ended (#4); in-dialog re-INVITE and UPDATE answered, unsupported requests get 405/501,
  no `Supported: timer` (#6); one digest retry (two with `stale=true`), `opaque` echoed
  (#16); every non-2xx final response ACKed and a 32 s Timer B (#21); REGISTER lifetime
  600 s, refreshed at 80% of what is granted, 423 handled, failures reported (#22);
  responses matched by branch and CSeq, challenged BYE retried (#24); an INVITE during
  outbound setup gets 486 (#25); a ringing inbound call is declined with 486, not BYE
  (#26); DTMF digits sent one at a time (#49); a failed registration closes the socket
  (#53); every message uses CRLF line endings.
- Calls: no zombie call after sign-out, `dispose()` or a lost connection (#3); ringing
  calls are no longer cut off at 30 s (#5); no ghost "active" call after a CANCEL during
  answer (#7); a failed answer sends 480/488/500 and says why (#38); an unusable 200 OK
  is ACKed and ended (#39); `rejectCall()` on an answered call sends BYE (#52); setup
  timeout ends as `setup_timeout` (#54).
- Media: the PeerConnection and streams are disposed on every end path (#28, #37);
  the speaker setting no longer leaks into the next call (#42); mute is one state that
  survives hold and applies before the mic opens (#43).
- Keep-alive: the OPTIONS the registrar rejected is gone; a WebSocket ping every 15 s
  notices a dead connection within 30 s (#35).
- Network loss: a BYE or CANCEL that could not reach Vobiz because the connection was
  down is sent again as soon as the client has registered on a new connection. Before,
  it was lost: a call that ended during an outage longer than the 12 s grace period
  stayed up on the other side, silent and billed, until Vobiz timed the leg out about
  5 minutes later, and a call given up while ringing kept ringing. Sent again at most
  3 times, within 5 minutes, and only for the same SIP user; any final response ends it,
  481 included. Verified live on Android (#3, #18).
- Network loss: back from no network at all during a call (airplane mode, or Wi-Fi and
  mobile data both off), the client replaces its connection at once. It used to keep a
  socket that Android had left looking open, and reconnected only when that socket's
  ping timed out, after the 12 s grace period had ended the call. Verified live: audio
  back about 1 s after the network returned (#18).

### Changed

- `TokenConfig` is deprecated: it is a SIP password. Vobiz has no JWT SIP auth (#29).
- `hold()`/`resume()` throw when there is no call or Vobiz refuses; legacy
  call-control routes throw `UnsupportedError` instead of failing silently (#30).
- `CallSession`, `CallActions`, `SdkEvent` and `Logger` are exported (#33).
- Docs: PLATFORM_SETUP rewritten (target 36, iOS 15, iOS rings in the foreground only,
  no `voip` mode, camera permissions removed), CREDENTIALS rewritten around one endpoint
  per user (#10, #32). Example iOS target 15 with a Podfile.

### Example app and push bridge

- Calls woken by push sign in while the phone is still ringing and tell the bridge,
  which dials at once (`POST /push/registered`) (#8). One cached Flutter engine hosts
  SIP and UI (#51).
- Every call runs under the app's own foreground service (`phoneCall|microphone`) with
  a Hang up action (#15, #47).
- Answered-elsewhere and caller-hung-up pushes stop ringing; missed-call notifications
  only for real misses; a local "Recent calls" log (#9, #19). Call waiting instead of a
  second ringing screen (#45). Incoming calls ring and vibrate with the app open (#40).
- Decline sends the caller a busy tone and busy hangup at once (#31).
- Push bridge: inbound calls hold the caller on ringback for up to `PUSH_WAIT_SECONDS`
  (default 5, 3–9) and dial as soon as the pushed phones report they are registered,
  then ring every target at once in one `<Dial>`: app endpoints, `ALWAYS_RING`
  endpoints and, new, PSTN numbers listed in `ROUTES` (`+91…=alice,+9198…`). The
  re-dial loop is gone, so a ringing leg is never restarted; a late register gets
  `redial: "too_late"` (#8).
- Transfer picks `aleg`/`bleg` by call direction and offers `both` (#48).
- Connect errors show on the Identity tab (#57); the app root no longer rebuilds every
  second during a call (#55); no duplicate connect after Accept (#35).
- Connection watch: during a call the app reports "alive" to the bridge every second
  (`POST /call/alive`). When the reports stop for 3 s the bridge has Vobiz play a short
  beep to the other party every 2.5 s, and stops it when the app is back. After 15 s it
  ends the call through the Vobiz API: an offline phone's BYE cannot reach Vobiz, which
  otherwise keeps the call up and billed for about 5 minutes. `LOST_BEEP_SECONDS`,
  `LOST_HANGUP_SECONDS`. Calls through the bridge are reported by their PushRef.
- The example shows "Reconnecting..." while the SDK recovers a dropped call (it used to
  log a second "Call answered!"), and leaves the call screen when a call ends while
  the SDK is reconnecting (it used to stay on IN CALL).
- Push bridge: `POST /dtmf-test`, an answer URL that asks for four digits and reads
  back what Vobiz received, to check that keypad presses reach Vobiz.
- An outgoing call still ringing when the network drops leaves the Ringing screen and
  shows "Reconnecting..."; the app used to stay on Ringing after it had registered
  again, with nothing left to hang up.
- Push bridge: Vobiz returns at most 20 items a page whatever `limit` asks for, and the
  bridge stepped through its lists by 100, so it read only the first page. It refused
  endpoints past the 20th as not on the account, and created a second application when
  its own was not on the first page. It now steps by what each page returned.

### Not done here

- iOS PushKit/CallKit (needs Xcode) and Telecom/ConnectionService integration (#10,
  #11, #17, #18). ICE restart is done for a connection that drops; a handover that
  leaves the old connection up does not move the call until that network goes away.
- Platform work: Opus instead of PCMU, Vobiz-hosted TURN on 443, JWT SIP auth (#20, #29).
- #36 needs the app's Trace; #58 is the device test plan.

---

## [0.2.0] - 2026-10-09

The SDK now signs in and calls the way the Vobiz WebRTC Playground
(rtc-demo.vobiz.ai) does, against the same hosted webhook server, so an app needs no
backend of its own and no credentials compiled in.

### Added

- **Zero-Config Setup**: `connectWithAuthToken(authId:, authToken:)` provisions (or
  reuses) the Playground application and endpoint on the caller's account through
  `<backendUrl>/api/setup`, then registers as it. SIP Direct remains
  `connectWithCredentials`. `authMode` and `sipUsername` say how the client signed in.
- **Call options**: `makeCall(destination, callerId:, headers:, record:, dialUser:)`
  sends `X-VH-Caller-ID`, custom `X-VH-` headers, `X-VH-Record` and `X-VH-DialUser`,
  and refuses invalid headers before dialling. The rules are public as
  `VobizSipHeaders` and match the web SDK.
- **Call details**: `CallEvent` reports `direction`, `remoteIdentity`, Vobiz's
  `callUuid`, the custom `headers` sent or received, and on failure the `sipCode` and
  `reason` (with the Q.850 cause). `callState`, `callUuid`, `lastCallUuid`,
  `callDirection` and `callHeaders` on the client.
- `sendDtmf` (SIP INFO, as the web SDK sends it), `setSpeakerphone`, `getCallStats`.
- **Example: inbound calls in the background and after the app is swiped away.**
  `example/push_bridge` (Node, no dependencies) answers a Vobiz number, wakes the app
  with a Firebase push and rings its endpoint until it is back online. The example app
  shows the system call screen (flutter_callkit_incoming), signs itself in on *Accept*,
  answers the call when it arrives, and tells the bridge about *Decline*. Firebase is
  optional at build time: without `google-services.json` the app still rings while open.
- `transferCall(number: | sipUser:, leg:, sipHeaders:)` through the Redirect API
  (Zero-Config only).
- `fetchRecordings` and `waitForRecording(callUuid)`.
- `SdkConfig.voiceApiUrl`, `SdkConfig.defaultWebhookUrl`, `SdkConfig.defaultVoiceApiUrl`;
  `VobizException`, `VobizAuthMode`, `ZeroConfigSession`, `VobizRecording`,
  `TransferLeg`, `CallDirection`.
- `example/`: the Vobiz Playground for Flutter, with the web Playground's options.
- 26 unit tests for the new behaviour, widget tests and a live sign-in test for the
  example.

### Changed

- `backendUrl` defaults to `https://rtc-demo.vobiz.ai` and can be changed at sign-in.
- The SIP connect waits for the WebSocket handshake (20 s), so a timeout is caught,
  and a socket failure is reported once.
- A new sign-in closes the previous connection instead of opening a second one.
- README and API reference rewritten to match the code; they described methods the
  SDK never had (`login`, `answer`, `setMuted`, `state`).

### Fixed

- A local hangup reported the call as ended twice.
- A replaced socket's late close was taken for the new connection dropping and
  scheduled a reconnect over a healthy session.
- Mid-call INFO from the far end is acknowledged.
- `sip_service.dart` contained a literal NUL byte, which made git treat it as binary.

### Removed

- Tracked build caches (`.dart_tool/`, `.DS_Store`); a `.gitignore` now covers them.
- Real account values from the documentation.

---

## [0.1.0] - 2026-04-29

### Added

- Initial release of Vobiz WebRTC SDK for Flutter
- **SIP Features:**
  - WebSocket-based SIP registration with digest authentication
  - Automatic SIP keep-alive (OPTIONS every 60 seconds)
  - Support for REGISTER, INVITE, ACK, BYE, CANCEL, OPTIONS methods
  - CSeq tracking and dialog state management
  - INVITE retransmit handling

- **Call Features:**
  - Outbound calling to PSTN numbers
  - Inbound call detection and routing
  - Call state machine (idle → calling → ringing → inCall → ended)
  - Answer/Reject call handling
  - Mute/Unmute microphone control

- **WebRTC Features:**
  - Automatic peer connection management
  - Audio-only media streams
  - ICE candidate collection and management
  - SDP offer/answer negotiation
  - Automatic ICE gathering

- **Network Robustness:**
  - Auto-reconnect on WebSocket drop
  - SIP registration refresh every 55 minutes
  - ICE gathering with 8-second timeout
  - Connection state tracking

- **Platform Support:**
  - Android 5.0+ (API 21+)
  - iOS 11.0+

- **Documentation:**
  - Quick-start guide
  - Platform setup instructions (Android & iOS)
  - API reference
  - Answer URL contract specification
  - Troubleshooting guide

### Known Limitations

- Push notifications for background call wake-up not implemented yet
- No conference bridge (1:1 calls only)
- TURN server configuration optional (Google STUN only by default)

---

## Upcoming

### [0.2.0] - Planned

- Push notification support (APNs & FCM)
- Conference bridge
- Call recording
- Better reconnection logic

### [0.3.0] - Planned

- Advanced call features (blind transfer, hold/resume)
- Multiple concurrent calls
- Analytics

---

## Support

- [GitHub Issues](https://github.com/vobiz-ai/vobiz-flutter-sdk/issues)
- [Email Support](mailto:support@vobiz.ai)
