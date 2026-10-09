/// A call recording reported by the webhook server.
///
/// Calls placed with `record: true` carry the `X-VH-Record` header, the
/// webhook server answers them with a session `<Record>`, and Vobiz posts the
/// result back to the server once the call ends.
class VobizRecording {
  const VobizRecording({
    required this.recordingId,
    required this.callUuid,
    required this.url,
    required this.receivedAt,
    this.durationSecs,
    this.endReason,
  });

  factory VobizRecording.fromJson(Map<String, dynamic> json) {
    final received = json['receivedAt'];
    final endReason = '${json['endReason'] ?? ''}'.trim();
    return VobizRecording(
      recordingId: '${json['recordingId'] ?? ''}',
      callUuid: '${json['callUUID'] ?? ''}',
      url: '${json['url'] ?? ''}',
      durationSecs: double.tryParse('${json['durationSecs'] ?? ''}')?.round(),
      endReason: endReason.isEmpty ? null : endReason,
      receivedAt: received is num
          ? DateTime.fromMillisecondsSinceEpoch(received.toInt())
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final String recordingId;

  /// The Vobiz CallUUID of the recorded leg (the leg this client placed).
  final String callUuid;

  /// Where the recording file can be fetched from.
  final String url;

  final int? durationSecs;
  final String? endReason;

  /// When the webhook server received the recording callback.
  final DateTime receivedAt;
}
