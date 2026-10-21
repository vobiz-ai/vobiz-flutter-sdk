/// How `VobizClient.sendDtmf` sends keypad tones.
enum DtmfTransport {
  /// RFC 4733 telephone-events in the audio stream when the media server
  /// offered `telephone-event`, otherwise SIP INFO.
  auto,

  /// RFC 4733 telephone-events (`RTCDTMFSender`) only. Throws when the call
  /// did not negotiate `telephone-event`.
  rfc4733,

  /// SIP INFO (`application/dtmf-relay`), the way the Vobiz web SDK sends
  /// them.
  sipInfo,
}
