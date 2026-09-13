import 'package:flutter/material.dart';

/// Zero-dependency per-download speed sparkline.
///
/// Renders a single stroked path over the smoothed speed history carried by
/// [DownloadItem.speedHistory] (60-sample ring, 1 sample/sec). Pure
/// [CustomPainter] — no axes, labels, or touch handlers; it is a transient
/// visual signal, not a chart. No animation timers: it repaints only when the
/// sample list changes.
class DownloadSparkline extends StatelessWidget {
  const DownloadSparkline({
    super.key,
    required this.samples,
    this.height = 28,
    this.color,
    this.fill = true,
  });

  final List<double> samples;
  final double height;
  final Color? color;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparklinePainter(
            samples: samples,
            color: color ?? Theme.of(context).colorScheme.primary,
            fill: fill,
          ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.samples,
    required this.color,
    required this.fill,
  });

  final List<double> samples;
  final Color color;
  final bool fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) {
      // Empty or single-sample state: render nothing rather than a point.
      return;
    }
    // Normalize by rolling max with a floor so a stall renders as a flat
    // zero-baseline line instead of NaN/division-by-zero artifacts.
    double max = 0;
    for (final s in samples) {
      if (s > max) max = s;
    }
    if (max <= 0) max = 1;

    final n = samples.length;
    final dx = size.width / (n - 1);
    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = i * dx;
      final y = size.height - (samples[i] / max) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (fill) {
      final fillPath = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      final fillPaint = Paint()
        ..color = color.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);
    }
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.samples.length != samples.length ||
      old.samples.last != samples.last;
}