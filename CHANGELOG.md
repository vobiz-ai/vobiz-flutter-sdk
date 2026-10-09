# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
