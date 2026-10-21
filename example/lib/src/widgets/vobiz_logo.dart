import 'package:flutter/material.dart';

/// The Vobiz brand mark, drawn from the source SVG's paths (42 × 30).
class VobizLogo extends StatelessWidget {
  const VobizLogo({super.key, this.width = 28});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width * 30 / 42,
      child: CustomPaint(painter: _VobizLogoPainter()),
    );
  }
}

class _VobizLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 42;
    final sy = size.height / 30;

    canvas.drawPath(
      Path()
        ..moveTo(42 * sx, 14.7458 * sy)
        ..lineTo(42 * sx, 0)
        ..cubicTo(24.5641 * sx, 0, 12 * sx, 13.7288 * sy, 12 * sx, 30 * sy)
        ..lineTo(27.1282 * sx, 30 * sy)
        ..cubicTo(27.1282 * sx, 21.3559 * sy, 33.5385 * sx, 14.7458 * sy,
            42 * sx, 14.7458 * sy)
        ..close(),
      Paint()..color = const Color(0xFFE83C00),
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, 15 * sy)
        ..lineTo(0, 0)
        ..cubicTo(9.28572 * sx, 0, 15 * sx, 6.42857 * sy, 15 * sx, 15 * sy)
        ..lineTo(0, 15 * sy)
        ..close(),
      Paint()..color = const Color(0xFFE86A00),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Logo, wordmark and the "Playground v2.0" line, as the web Playground shows.
class VobizBrand extends StatelessWidget {
  const VobizBrand({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const VobizLogo(width: 30),
            const SizedBox(width: 8),
            Text('vobiz',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: Theme.of(context).colorScheme.onSurface,
                )),
          ],
        ),
        const SizedBox(height: 4),
        Text('PLAYGROUND V2.0',
            style: TextStyle(fontSize: 10, letterSpacing: 2.2, color: muted)),
      ],
    );
  }
}
