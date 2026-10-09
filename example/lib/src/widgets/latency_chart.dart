import 'package:flutter/material.dart';

import '../theme.dart';

/// The round-trip time of the last 20 seconds, as the Playground draws it.
/// Gaps (no measurement yet) are drawn as nothing rather than as a guess.
class LatencyChart extends StatelessWidget {
  const LatencyChart({super.key, required this.samples});

  final List<double?> samples;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    final latest = samples.lastWhere((v) => v != null, orElse: () => null);
    return Container(
      width: 200,
      height: 56,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: pg.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: pg.border),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('LATENCY',
                  style: TextStyle(fontSize: 8, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
              const Spacer(),
              Text(latest == null ? '—' : '${latest.round()}ms',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: pg.accent)),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _LatencyPainter(samples, pg.accent, pg.border),
            ),
          ),
        ],
      ),
    );
  }
}

class _LatencyPainter extends CustomPainter {
  _LatencyPainter(this.samples, this.color, this.baseline);

  final List<double?> samples;
  final Color color;
  final Color baseline;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(Offset(0, size.height - 1), Offset(size.width, size.height - 1),
        Paint()..color = baseline);
    if (samples.length < 2) return;
    final step = size.width / (samples.length - 1);
    // Same scale as the Playground: 0-100 ms fills the height.
    double y(double v) => size.height - (v.clamp(0, 100) / 100) * (size.height - 2) - 1;

    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Path? path;
    for (var i = 0; i < samples.length; i++) {
      final v = samples[i];
      if (v == null) {
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final point = Offset(i * step, y(v));
      if (path == null) {
        path = Path()..moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    if (path != null) canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_LatencyPainter old) => true;
}
