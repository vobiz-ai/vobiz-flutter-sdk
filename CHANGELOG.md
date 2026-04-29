# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

- [GitHub Issues](https://github.com/devlume-in/vobiz-flutter-sdk/issues)
- [Email Support](mailto:support@vobiz.ai)
