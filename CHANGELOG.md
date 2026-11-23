# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## 0.2.0 - 2026-11-23

Compared with 0.1.0, the SDK signs users in with
credentials from the app's own backend (an access token or a per-user SIP endpoint),
receives calls on a closed Android app through Vobiz push, keeps calls up through
network drops, and adds call options, hold, DTMF, audio routes, call quality,
conference and recordings. The account Auth Token never leaves the device outside an
explicit demo mode. Entries marked **Breaking** need code changes when upgrading from
0.1.0.

### Added

**Sign-in**

- Access-token (JWT) sign-in, as the web SDK's `loginWithAccessToken` and
  `loginWithAccessTokenGenerator`: `connectWithAccessToken`,
  `connectWithAccessTokenProvider` (with `VobizAccessTokenSession`),
  `updateAccessToken`, `VobizBackendAccessTokenProvider`, `VobizAccessToken`,
  `VobizAuthMode.accessToken`, and `VobizAccessTokenException` with the registrar's
  10001 to 10010 reasons. The client registers as `<sub>_<iss>`, sends the token as
  `X-Vobiz-Jwt` on REGISTER and outbound INVITEs, and refuses outbound calls the token
  does not grant. The provider session renews the token 60 s before it expires, timed
  by the registrar's own count once it has accepted a token
  (`VobizClient.accessTokenTimeLeft`); retries a failed renewal after
  `firstRetryDelay` (5 s), doubling up to `maximumRetryDelay` (60 s), and reports each
  failure; and asks for a new token when the registrar refuses one.
- `connectWithCredentialsProvider` and `VobizBackendCredentialsProvider`: per-user SIP
  credentials from your own backend, fetched again when the registrar refuses them.
  A refusal during a call is answered once the call has ended.
- Both providers return their session when the socket cannot be opened and the client
  retries the connection by itself (`SdkConfig.autoReconnect`).
- SIP Direct as `connectWithCredentials`, and Zero-Config Setup (demo only, see
  Security) as `connectWithAuthToken`, which provisions the Playground application and
  endpoint through `<backendUrl>/api/setup`. `authMode`, `sipUsername` and
  `ZeroConfigSession` say how the client signed in.

**Calls**

- `makeCall(destination, callerId:, headers:, record:, dialUser:)`: `X-VH-Caller-ID`,
  custom `X-VH-` headers, `X-VH-Record` and `X-VH-DialUser`, checked before dialling.
  The header rules are public as `VobizSipHeaders`; `VobizClient.buildCallHeaders`
  checks a form.
- `CallEvent` reports `direction`, `remoteIdentity`, Vobiz's `callUuid`, the custom
  `headers` sent or received, `sipCallId`, and on failure `sipCode` and `reason` (with
  the Q.850 cause). The client has `callState`, `callUuid`, `lastCallUuid`,
  `callDirection`, `callHeaders` and `isSpeakerOn`.
- `hold` and `resume` by SIP re-INVITE (the far end plays hold music), with
  `hold_failed` / `resume_failed` when refused; `audioInterruptionBegan` and
  `audioInterruptionEnded` hold and resume a call when another app takes the
  microphone.
- `sendDtmf(digits, transport:)`: RFC 4733 telephone-events in the audio when the call
  negotiated them, otherwise SIP INFO, one digit at a time (`DtmfTransport`).
- `setSpeakerphone`, `getCallStats`.
- `transferCall(number: | sipUser:, leg:, callerId:, sipHeaders:)` through the Redirect
  API (demo only, after Zero-Config). `TransferLeg.aLeg`, `bLeg` and `both`, named by
  who started the call.
- `fetchRecordings` and `waitForRecording(callUuid)` for the Playground server's
  recordings list. They send no credentials.

**Incoming calls to a closed app (Android, Vobiz push)**

- `VobizPushDevices` signs a phone up for Vobiz push for its SIP user (`register`) and
  removes it (`logout`); in production through your own backend (`baseUrl`,
  `pathPrefix`, `authHeaders`).
- `VobizIncomingPush.tryParse` reads Vobiz's incoming-call push, including its hold
  reference (`VobizPushHold`). `VobizClient.handleIncomingPush` claims the held call
  with the next REGISTER (`X-Index`, `X-Label`, `X-vobiz-Registrar-Info`);
  `reportCallScreenAccepted` and `reportCallScreenDeclined` answer or decline it as
  soon as its INVITE arrives; `pushCallUpdates`, `pushedCall` and `isPushedCall` follow
  it. The INVITE is matched to the push by its SIP Call-ID only.
- A push is acted on until 30 s past its `expires_at` by the phone's clock, and its call
  is awaited at most 60 s (30 s for a push without `expires_at`).
- `VobizClient.sdkVersion`, sent with the device sign-up.
- `disconnect(unregister: false)` closes the connection without unregistering, as when
  Android kills the app, to test the push path.

**Conference**

- `VobizConference` turns the current call into a Vobiz conference room and manages it
  through your server, which holds the Auth Token: `add` (a number or SIP user; the
  first one moves both sides of the call into a new room), `mute`, `unmute`, `hold`,
  `resume`, `remove`, `end`, `refresh`, and a polled `state` with
  `VobizConferenceParticipant`s. When the conference ends the call is hung up from the
  phone too (`endCallWithConference`). A reply that arrives after its call ended never
  acts on the next call, and `refresh()` takes over a conference another object started
  for the same call. The four server routes are in API_REFERENCE.md.

**Network**

- `networkEvents` (`NetworkEvent`, `NetworkStatus`, `SignalingQuality`), `network`,
  `signalingQuality` and `reconnect()`.
- Reconnects with a capped, jittered backoff (`SdkConfig.reconnectPolicy`: 1 s doubling
  to 30 s, giving up after 10 attempts with `reconnect_failed`), at once when the
  network returns or changes, and makes no attempts while offline, where calls fail
  fast (`SdkConfig.watchNetwork`, `ConnectivityMonitor`). New dependency:
  `connectivity_plus`.
- A REGISTER the registrar could not take for now (no answer, 408, 480, 5xx) is retried
  with that backoff; during a call, once the call has ended.
- A connected call survives a short network drop: a 12 s grace period, an ICE restart
  in a re-INVITE once the client has registered on a new connection, and one ICE
  restart when only the audio is lost while signalling stays up. A call that ended on
  Vobiz during the outage (481 to that re-INVITE) ends at once as
  `ended_while_offline`. A BYE or CANCEL that could not leave the phone is sent again
  once the client has registered (at most 3 times, within 5 minutes, same user only).
- Re-registers each time the app returns to the foreground
  (`SdkConfig.reregisterOnForeground`, `AppLifecycleMonitor`), and reconnects at once
  when a REGISTER refresh gets no answer.
- Keep-alive by WebSocket ping every 15 s (`SdkConfig.keepAlive`, `KeepAliveConfig`).
- `VobizClient.updateIceConfig` replaces the STUN and TURN servers from the next call;
  `TurnServers.withFallbacks()` builds a TURN entry reachable over UDP, TCP and TLS 443.

**Audio and media**

- `callMediaEvents`: `MuteChangedEvent`, `HoldChangedEvent`, `EarlyMediaEvent` (183
  with audio is played), `AudioRouteChangedEvent` and `CallQualityEvent` (interval
  loss, jitter, RTT, estimated MOS, `CallQualityLevel`).
- `audioRoutes` (`AudioRouteController`): list and select earpiece, speaker, Bluetooth
  and wired headsets, with `bluetoothPermissionRequester` for Android 12+.
- `proximity` (`ProximityController`), and `MediaConstraints.preferredAudioCodecs`.

**Errors and other API**

- `VobizException` and its subclasses `VobizDemoModeRequiredException`,
  `VobizCredentialsException`, `VobizRegistrationException` and
  `VobizAccessTokenException`; `VobizErrorCode` constants for every code, including
  `auth_failed`, `reconnect_failed`, `network_lost`, `hold_failed`, `resume_failed`,
  `conference_failed` and `push_device_failed`.
- `VobizRecording`, `CallDirection`, `CallActions`, `SdkEvent`, and the `Logger` /
  `LogWriter` pair are exported. `SdkConfig.voiceApiUrl`, `defaultWebhookUrl` and
  `defaultVoiceApiUrl`.

### Changed

- **Breaking.** `SdkConfig.backendUrl` defaults to `https://rtc-demo.vobiz.ai`, the
  shared Playground server (was `http://10.0.2.2:3000`). The SDK uses it only for the
  demo features.
- **Breaking.** `hold` and `resume` are SIP re-INVITEs instead of calls to backend
  routes, and throw when there is no call or the far end refuses.
- **Breaking.** `acceptCall`, `mute` and `unmute` do nothing for another call's id.
  `rejectCall` on an answered call hangs it up with a BYE.
- **Breaking.** `CallSession` (`currentCall`) is a snapshot: `state`, `muted` and
  `speakerEnabled` are final constructor fields.
- REGISTER asks for an hour (`Expires: 3600`), refreshed at 80 % of what is granted,
  with 423 handled. A closed app stays reachable by push while that registration lasts.
- A REGISTER refusal (401, 403, 404, 407, a token error) is final and reported once as
  `registration_failed`; reconnect attempts no longer report `failed` or
  `connect_failed` each time, only `reconnect_failed` when they give up.
- Overlapping sign-ins, and a sign-out during a sign-in, end quietly: the newer one
  owns the state. A new sign-in closes the previous connection.
- The SIP connect waits for the WebSocket handshake (20 s), and a socket failure is
  reported once.
- `TokenConfig` and `connect(Object)` are deprecated: `TokenConfig` is a SIP password,
  not an access token.
- `MediaConstraints.audio` and `.video` are deprecated and ignored: a call always opens
  the microphone and never the camera. Echo cancellation, noise suppression and
  automatic gain control now also reach Android and iOS.
- `AudioRouteController.reset()` reports the default route (a connected headset, or the
  earpiece).
- `VobizBackendCredentialsProvider` reads only `sip_username` and `sip_password`;
  `CredentialConfig.displayName` is for the app's own use and is not sent.
- The caller's number on an incoming call is taken from P-Asserted-Identity,
  Remote-Party-ID, From or Contact only when it is the whole user part of the URI or
  the whole quoted display name.
- Package: published for Android and iOS only, with topics; the Node sample server and
  the example's tests are left out of the published package.

### Fixed

- SIP: CANCEL when hanging up a ringing outbound call, with a crossing 200 ACKed and
  ended; in-dialog re-INVITE and UPDATE answered, unsupported requests get 405 or 501;
  one digest retry (two with `stale=true`), `opaque` echoed; every non-2xx final
  response ACKed and a 32 s transaction timeout; responses matched by branch and CSeq;
  a challenged BYE retried; an INVITE during outbound setup gets 486; a ringing
  incoming call is declined with 486, not BYE; a failed registration closes the socket;
  CRLF line endings throughout; mid-call INFO acknowledged; a message in a binary
  WebSocket frame (a Latin-1 caller name) is read.
- SIP: a late INVITE for a call that has ended gets 481 and does not ring; a 481 to a
  hold, resume or DTMF INFO ends the call; a re-INVITE that crosses the client's own
  gets 491.
- Calls: no zombie call after sign-out, `dispose()` or a lost connection; ringing
  calls are no longer cut off at 30 s; no "active" call after a CANCEL during answer; a
  failed answer sends 480, 488 or 500 and says why; an unusable 200 OK is ACKed and
  ended; a local hangup is reported once; an outbound INVITE with no response at all
  ends after 30 s as `setup_timeout`.
- Media: the PeerConnection and streams are released on every end path; the speaker
  setting no longer leaks into the next call; mute is one state that survives hold and
  applies before the microphone opens; a refused hold or resume puts the media back as
  it was; the SDK's audio-device handler chains to one the app set.
- Keep-alive: the SIP OPTIONS the registrar rejected is gone.
- A replaced socket's late close is no longer taken for the new connection dropping.

### Removed

Relative to 0.1.0:

- **Breaking.** `VobizClient.transfer(String)`, `warmTransferStart`,
  `warmTransferComplete`, `addCall`, `startSecondCall`, `swapCalls`, `mergeCalls`,
  `endSecondCall` and `removeAddedCall`, which called routes no Vobiz server provides.
  Use `transferCall` (demo) or your backend for transfers, and `VobizConference` for
  more than two people.
- **Breaking.** `VobizClient.calls` (there is one call at a time: `currentCall`),
  `CallEvent.session`, `CallStateStatus.outgoing`, and the models `IncomingCall`,
  `OutgoingCall` and `DtmfTone`.
- **Breaking.** `answerUrl` on `SdkConfig`, `CredentialConfig` and `TokenConfig`: the
  SDK never sent it. The application's answer URL is set on Vobiz.

### Security

- The account Auth ID and Auth Token leave the device only with
  `SdkConfig.unsafeDemoZeroConfig`: `connectWithAuthToken` throws
  `VobizDemoModeRequiredException` without it, which also leaves `transferCall` without
  a sign-in to use, and the shared demo server's recordings list is not read. With it,
  they go only to an `https` `backendUrl` (plain `http` only to this device or the
  Android emulator's host).
- `VobizPushDevices.accountHeaders(authId, authToken, unsafeDemo:)` throws
  `VobizDemoModeRequiredException` unless `unsafeDemo` is true; production apps sign up
  through their backend.
- A release build refuses a cleartext `ws:` registrar URL to anything but this device.
- Every value the SDK writes into a SIP message is checked first: the destination, the
  SIP username, caller IDs (a plus and 7 to 15 digits), the access token's text and a
  push's hold reference. `ArgumentError` (or `VobizAccessTokenException`) instead of a
  header injected into the message.
- SIP Call-IDs, tags, branches and the digest cnonce come from a secure random source.
- Sign-out unregisters (REGISTER `Expires: 0`) and drops every credential from memory.
  The SDK never logs an access token.
- No real account values in the documentation.

### Example app

The example is the Vobiz Playground for Flutter (`example/`), with the web Playground's
options:

- Sign-in tabs for Zero-Config Setup, SIP Direct and Access token (a token server of
  your own, or the sample server's `/token`), with *Remember me* in secure storage.
  Unticking it deletes what was saved at once; sign-out signs out on the phone first,
  then removes every saved secret (sign-in, push account, sample server line) and takes
  the phone off Vobiz push.
- Dialer with caller ID, destination, SIP headers, Dial-User and recording; the in-call
  screen with mute, keypad, speaker, transfer (moving you, the other party or both, by
  call direction) and **Add** for a conference; a local *Recent calls* log; and the
  Trace tab.
- Calls to a closed app through Vobiz push: a Firebase push wakes the app, which shows
  the system call screen (`flutter_callkit_incoming`) and signs in from saved
  credentials. Decline before the INVITE gives one Declined entry; Hang up before it
  turns the call away without opening the microphone; a caller who gives up stops the
  ringing. The phone signs up through the sample server when one is set.
- One cached Flutter engine hosts SIP and the UI; every call runs under the app's own
  foreground service (`phoneCall|microphone`) with a Hang up action. Opened by Accept,
  the app shows over the lock screen until that call ends, and otherwise stays behind
  it. Nothing of the app is backed up or moved to a new phone.
- The line the sample server prints (*Identity → Sample server*) is used for access
  tokens, conferences, push sign-up and, when *Let the sample server watch my calls* is
  on (off by default), the connection watch.
- Release builds leave out the demo and test tools (Zero-Config, the account-credential
  fields, *Call this phone through Vobiz*) unless built with
  `--dart-define=VOBIZ_DEMO_TOOLS=true`, refuse `http://` server and token addresses,
  and are signed with the upload key in `android/key.properties`.
- The app shows "Reconnecting..." while the SDK recovers a connection or a call, and
  "Connection lost" when reconnecting gave up; sheets stay above the keyboard; controls
  have TalkBack labels; permissions are checked again on resume.

### Sample server (`example/push_bridge`)

A small Node 22 server, with no npm dependencies, for the example app. It is not part
of the published package.

- Answers your Vobiz number and rings, in one `<Dial>` at once, the SIP users and phone
  numbers `ROUTES` (per number) and `ALWAYS_RING` name; with neither set it rings nobody
  and says so. The busy tone plays only when everyone rung is on a call this server
  connected; otherwise "Sorry, there was no answer".
- Signs phones up for Vobiz push (`POST /push/devices/register`,
  `DELETE /push/devices/logout`), adding the account credentials itself. It refuses a
  `sip_username` other than the caller's `X-Bridge-User`, or one that is not a SIP user
  of its account.
- Mints access tokens (`POST /token`, limited to `JWT_ALLOWED_SUBS` when set), runs
  conferences (`/conference/*`, two adds at once share one room), watches the app's
  connection during a call (`/call/alive`, `/call/ended`: a beep for the other party,
  then the call is ended), and offers a DTMF test (`/dtmf-test`).
- App requests carry `X-Bridge-Key` and, while signed in, `X-Bridge-User`; a malformed
  user header is a 400. Only the user who answered an inbound call may have it watched
  or conferenced.
- Webhooks need a valid Vobiz V3 or V2 signature; each nonce and signature is accepted
  once (remembered for 24 hours). It will not start without an `https` `PUBLIC_URL` and
  the Auth Token, a `BRIDGE_KEY` under 16 characters, or an unquoted `.env` value with a
  space. A request target that is not a URL gets 400; a state file that cannot be
  written does not fail a call.

### Known limitations

- iOS rings only while the app is in the foreground: PushKit and CallKit are not
  implemented. Android has no Telecom/ConnectionService integration.
- A closed Android app is reachable only while the registration it left behind lasts
  (an hour from its last REGISTER) and only if it is signed up for Vobiz push.

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

## Support

- [GitHub Issues](https://github.com/vobiz-ai/vobiz-flutter-sdk/issues)
- [Email Support](mailto:support@vobiz.ai)
