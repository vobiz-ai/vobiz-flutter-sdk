import 'package:meta/meta.dart';

/// Small, pure SDP helpers for the audio m-line.
@internal
class SdpUtils {
  SdpUtils._();

  static final RegExp _lineBreak = RegExp(r'\r?\n');

  /// Whether [sdp] offers RFC 4733 `telephone-event`, which in-band DTMF
  /// (`RTCDTMFSender`) needs.
  static bool hasTelephoneEvent(String? sdp) =>
      sdp != null && RegExp(r'a=rtpmap:\d+ telephone-event/', caseSensitive: false).hasMatch(sdp);

  /// The audio section's direction attribute (`sendrecv`, `sendonly`,
  /// `recvonly`, `inactive`); `sendrecv` when none is given.
  static String audioDirection(String sdp) {
    var inAudio = false;
    String? sessionLevel;
    String? audioLevel;
    for (final line in sdp.split(_lineBreak)) {
      if (line.startsWith('m=')) inAudio = line.startsWith('m=audio');
      final m = RegExp(r'^a=(sendrecv|sendonly|recvonly|inactive)\s*$').firstMatch(line);
      if (m == null) continue;
      if (inAudio) {
        audioLevel = m.group(1);
      } else if (!line.startsWith('m=')) {
        sessionLevel ??= m.group(1);
      }
    }
    return audioLevel ?? sessionLevel ?? 'sendrecv';
  }

  /// Sets the audio section's direction to [direction], adding the attribute
  /// when there is none. Used only when the platform cannot change a
  /// transceiver's direction.
  static String setAudioDirection(String sdp, String direction) {
    final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(_lineBreak);
    final out = <String>[];
    var inAudio = false;
    var wrote = false;
    for (final line in lines) {
      if (line.startsWith('m=')) {
        if (inAudio && !wrote) _insertBeforeTrailingBlank(out, 'a=$direction');
        inAudio = line.startsWith('m=audio');
        wrote = false;
      }
      if (inAudio && RegExp(r'^a=(sendrecv|sendonly|recvonly|inactive)\s*$').hasMatch(line)) {
        out.add('a=$direction');
        wrote = true;
        continue;
      }
      out.add(line);
    }
    if (inAudio && !wrote) _insertBeforeTrailingBlank(out, 'a=$direction');
    return out.join(eol);
  }

  static void _insertBeforeTrailingBlank(List<String> out, String line) {
    var i = out.length;
    while (i > 0 && out[i - 1].isEmpty) {
      i--;
    }
    out.insert(i, line);
  }

  /// Reorders the audio m-line's payload types so the codecs named in
  /// [preferred] (case-insensitive encoding names such as `opus`, `PCMU`)
  /// come first, in that order. Other codecs keep their order after them.
  /// Returns [sdp] unchanged when none of them is offered.
  static String preferAudioCodecs(String sdp, List<String> preferred) {
    if (preferred.isEmpty) return sdp;
    final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(_lineBreak);
    final mIndex = lines.indexWhere((l) => l.startsWith('m=audio'));
    if (mIndex < 0) return sdp;

    final names = <String, String>{};
    for (final line in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+) ([^/\s]+)').firstMatch(line);
      if (m != null) names[m.group(1)!] = m.group(2)!.toLowerCase();
    }
    final parts = lines[mIndex].split(' ');
    if (parts.length <= 3) return sdp;
    final header = parts.sublist(0, 3);
    final payloads = parts.sublist(3);
    final first = <String>[];
    for (final codec in preferred) {
      for (final pt in payloads) {
        if (names[pt] == codec.toLowerCase() && !first.contains(pt)) first.add(pt);
      }
    }
    if (first.isEmpty) return sdp;
    final rest = payloads.where((pt) => !first.contains(pt));
    lines[mIndex] = <String>[...header, ...first, ...rest].join(' ');
    return lines.join(eol);
  }
}
