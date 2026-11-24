import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AudioVisualizer extends StatelessWidget {
  final ValueListenable<Float32List> fftListenable;
  final Color primaryColor;
  final Color secondaryColor;
  final int barCount;
  final double height;

  const AudioVisualizer({
    super.key,
    required this.fftListenable,
    required this.primaryColor,
    this.secondaryColor = const Color(0xFF00E5FF),
    this.barCount = 40,
    this.height = 110,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _FftVisualizerPainter(
          fftListenable: fftListenable,
          barCount: barCount,
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
        ),
      ),
    );
  }
}

class _FftVisualizerPainter extends CustomPainter {
  final ValueListenable<Float32List> fftListenable;
  final int barCount;
  final Color primaryColor;
  final Color secondaryColor;

  // super(repaint: fftListenable) -> hanya kanvas ini yang digambar ulang di GPU!
  _FftVisualizerPainter({
    required this.fftListenable,
    required this.barCount,
    required this.primaryColor,
    required this.secondaryColor,
  }) : super(repaint: fftListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final fft = fftListenable.value;
    final baselineY =
        size.height * 0.78; // 78% atas untuk batang, 22% bawah untuk pantulan
    final maxBarHeight = baselineY - 6;

    final slotWidth = size.width / barCount;
    final barWidth = (slotWidth * 0.62).clamp(2.5, 9.0);

    // Garis horizon tipis di dasar spektrum
    final linePaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      linePaint,
    );

    final glowPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    final reflectPaint = Paint();

    final barPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [primaryColor, secondaryColor],
      ).createShader(Rect.fromLTWH(0, 0, size.width, baselineY));

    for (int i = 0; i < barCount; i++) {
      double amplitude = 0.0;

      if (fft.isNotEmpty) {
        // Skala Logaritmik: telinga manusia mendengar bass lebih lebar dari treble
        final t0 = i / barCount;
        final t1 = (i + 1) / barCount;
        const minBin = 1.0;
        final maxBin = (fft.length * 0.72).clamp(2.0, fft.length.toDouble());

        final startBin = (minBin * math.pow(maxBin / minBin, t0)).floor().clamp(
          0,
          fft.length - 1,
        );
        final endBin = (minBin * math.pow(maxBin / minBin, t1)).ceil().clamp(
          startBin + 1,
          fft.length,
        );

        // Ambil puncak frekuensi tertinggi di rentang band batang ini
        double peak = 0.0;
        for (int b = startBin; b < endBin; b++) {
          if (fft[b] > peak) peak = fft[b];
        }
        amplitude = peak.clamp(0.0, 1.0);
      }

      final barHeight = (4.0 + amplitude * maxBarHeight).clamp(
        4.0,
        maxBarHeight,
      );
      final x = i * slotWidth + (slotWidth - barWidth) / 2;
      final t = i / (barCount - 1);

      // Batang utama (tumbuh ke atas dari garis horizon)
      final mainRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baselineY - barHeight, barWidth, barHeight),
        Radius.circular(barWidth / 2),
      );

      // Efek Neon Glow (makin terang saat frekuensi tinggi)
      if (amplitude > 0.05) {
        glowPaint.color = Color.lerp(
          primaryColor,
          secondaryColor,
          t,
        )!.withValues(alpha: 0.4 * amplitude);
        canvas.drawRRect(mainRect, glowPaint);
      }

      canvas.drawRRect(mainRect, barPaint);

      // Efek Pantulan Kaca tipis di bawah garis horizon
      final reflectHeight = (barHeight * 0.25).clamp(
        2.0,
        size.height - baselineY,
      );
      reflectPaint.color = Color.lerp(
        primaryColor,
        secondaryColor,
        t,
      )!.withValues(alpha: 0.22);
      final reflectRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baselineY + 2, barWidth, reflectHeight),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(reflectRect, reflectPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FftVisualizerPainter oldDelegate) {
    return oldDelegate.primaryColor != primaryColor ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.barCount != barCount;
  }
}
