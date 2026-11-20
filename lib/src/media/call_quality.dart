import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// How the call sounds, from [CallQualitySample.mos].
enum CallQualityLevel {
  /// MOS 3.6 or better: toll quality.
  good,

  /// MOS 3.1 to 3.6: noticeable but usable.
  fair,

  /// Below MOS 3.1: many users will complain. Show a network warning.
  poor,
}

/// One quality measurement over the interval since the previous one.
class CallQualitySample {
  const CallQualitySample({
    this.rttMs,
    this.jitterMs,
    this.packetLossPercent,
    this.codec,
    required this.mos,
    required this.level,
  });

  /// Round-trip time to the media server.
  final double? rttMs;

  /// Inbound jitter.
  final double? jitterMs;

  /// Inbound packet loss in this interval, not since the call began, so a
  /// burst shows up at once.
  final double? packetLossPercent;

  /// The audio codec in use, such as `PCMU` or `opus`, when reported.
  final String? codec;

  /// Estimated mean opinion score, 1 (bad) to 4.5 (excellent), from a
  /// simplified ITU-T G.107 E-model. An estimate, not a measurement.
  final double mos;

  final CallQualityLevel level;

  @override
  String toString() => 'CallQualitySample(mos: ${mos.toStringAsFixed(2)}, '
      'level: $level, rtt: $rttMs, jitter: $jitterMs, loss: $packetLossPercent, '
      'codec: $codec)';
}

/// Turns successive `getStats` reports into [CallQualitySample]s. Packet
/// loss is taken from the change in the lifetime counters between reports.
class CallQualityAnalyzer {
  double? _lastLost;
  double? _lastReceived;

  /// Reads one stats report. Returns null when it has no inbound audio yet.
  ///
  /// The round-trip time is the candidate pair's that carries the audio, as
  /// the `transport` report names it (`selectedCandidatePairId`). Without
  /// that name, a nominated or succeeded pair's; and the RTCP measure of the
  /// audio stream (`remote-inbound-rtp`) when no pair has one.
  CallQualitySample? add(List<StatsReport> reports) {
    double? jitterMs;
    double? lost;
    double? received;
    String? codecId;
    final codecs = <String, String>{};
    String? selectedPairId;
    final pairRttMs = <String, double>{};
    double? workingPairRttMs;
    double? streamRttMs;

    for (final StatsReport report in reports) {
      final Map<dynamic, dynamic> v = report.values;
      switch (report.type) {
        case 'transport':
          final Object? id = v['selectedCandidatePairId'];
          if (id != null && '$id'.isNotEmpty) selectedPairId = '$id';
          break;
        case 'candidate-pair':
          final double? rtt = _asDouble(v['currentRoundTripTime']);
          if (rtt == null || rtt <= 0) break;
          pairRttMs[report.id] = rtt * 1000;
          if (v['nominated'] == true || '${v['state']}' == 'succeeded') {
            workingPairRttMs = rtt * 1000;
          }
          break;
        case 'remote-inbound-rtp':
          final double? rtt = _asDouble(v['roundTripTime']);
          if (rtt != null && rtt > 0) streamRttMs ??= rtt * 1000;
          break;
        case 'inbound-rtp':
          if ('${v['kind'] ?? v['mediaType']}' != 'audio') break;
          final double? jitter = _asDouble(v['jitter']);
          if (jitter != null) jitterMs = jitter * 1000;
          lost = _asDouble(v['packetsLost']);
          received = _asDouble(v['packetsReceived']);
          codecId = v['codecId']?.toString();
          break;
        case 'codec':
          final mime = v['mimeType']?.toString();
          if (mime != null) codecs[report.id] = mime.split('/').last;
          break;
      }
    }
    // Another pair (a backup path, say) can also be nominated or succeeded:
    // its time says nothing about the audio's.
    final double? rttMs = selectedPairId != null
        ? pairRttMs[selectedPairId] ?? streamRttMs
        : workingPairRttMs ?? streamRttMs;
    if (received == null && jitterMs == null && rttMs == null) return null;

    double? lossPercent;
    if (lost != null && received != null) {
      final prevLost = _lastLost;
      final prevReceived = _lastReceived;
      final double dLost;
      final double dReceived;
      // The first report, or counters that went backwards because the stream
      // was renegotiated: use the totals so far.
      if (prevLost == null || prevReceived == null ||
          lost < prevLost || received < prevReceived) {
        dLost = lost;
        dReceived = received;
      } else {
        dLost = lost - prevLost;
        dReceived = received - prevReceived;
      }
      // Nothing arrived (far end on hold, or silent): no basis for a figure.
      if (dLost + dReceived > 0) lossPercent = dLost / (dLost + dReceived) * 100;
      _lastLost = lost;
      _lastReceived = received;
    }

    final codec = codecId == null ? null : codecs[codecId];
    final mos = estimateMos(
      rttMs: rttMs,
      jitterMs: jitterMs,
      packetLossPercent: lossPercent,
      codec: codec,
    );
    return CallQualitySample(
      rttMs: rttMs,
      jitterMs: jitterMs,
      packetLossPercent: lossPercent,
      codec: codec,
      mos: mos,
      level: levelFor(mos),
    );
  }

  /// Simplified E-model (ITU-T G.107): the one-way delay impairment from
  /// RTT/2 plus a jitter buffer of twice the jitter, and the loss impairment
  /// for the codec (G.711 with packet-loss concealment: Ie 0, Bpl 25.1;
  /// Opus is treated as Ie 0, Bpl 30).
  static double estimateMos({
    double? rttMs,
    double? jitterMs,
    double? packetLossPercent,
    String? codec,
  }) {
    final delay = (rttMs ?? 0) / 2 + 2 * (jitterMs ?? 0) + 10;
    final id = delay < 177.3
        ? 0.024 * delay
        : 0.024 * delay + 0.11 * (delay - 177.3);
    final bpl = (codec ?? '').toLowerCase() == 'opus' ? 30.0 : 25.1;
    final ppl = (packetLossPercent ?? 0).clamp(0, 100).toDouble();
    final ieEff = 0 + (95 - 0) * ppl / (ppl + bpl);
    final r = 93.2 - id - ieEff;
    if (r <= 0) return 1;
    if (r >= 100) return 4.5;
    final mos = 1 + 0.035 * r + 7e-6 * r * (r - 60) * (100 - r);
    return math.min(4.5, math.max(1, mos));
  }

  static CallQualityLevel levelFor(double mos) {
    if (mos >= 3.6) return CallQualityLevel.good;
    if (mos >= 3.1) return CallQualityLevel.fair;
    return CallQualityLevel.poor;
  }

  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
}

/// Reports a level change only after it holds for [confirmSamples] samples
/// in a row, so one bad second does not flash a warning.
class CallQualityLevelTracker {
  CallQualityLevelTracker({this.confirmSamples = 2});

  final int confirmSamples;
  CallQualityLevel _level = CallQualityLevel.good;
  CallQualityLevel? _candidate;
  int _count = 0;

  /// Returns true when [next] changes the reported level.
  bool add(CallQualityLevel next) {
    if (next == _level) {
      _candidate = null;
      _count = 0;
      return false;
    }
    if (next != _candidate) {
      _candidate = next;
      _count = 0;
    }
    _count++;
    if (_count < confirmSamples) return false;
    _level = next;
    _candidate = null;
    _count = 0;
    return true;
  }
}
