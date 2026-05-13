import 'package:flutter/material.dart';

/// Tibane cat logo - painted as a custom widget matching the SVG from tibane.net
class CatLogo extends StatelessWidget {
  final double size;
  final bool glow;

  const CatLogo({super.key, this.size = 64, this.glow = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CatLogoPainter(glow: glow),
      ),
    );
  }
}

class _CatLogoPainter extends CustomPainter {
  final bool glow;

  _CatLogoPainter({this.glow = false});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 64;
    canvas.save();
    canvas.scale(scale);

    // Gradient for face and ears
    const gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFFF6B2C), Color(0xFFFFA845), Color(0xFFFFCC00)],
    );

    final facePaint = Paint()
      ..shader = gradient.createShader(const Rect.fromLTWH(10, 14, 44, 44));

    final earPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [Color(0xFFFF6B2C), Color(0xFFFFA845)],
      ).createShader(const Rect.fromLTWH(8, 8, 48, 20));

    final innerEarPaint = Paint()
      ..color = const Color(0xFFFF8F5C).withValues(alpha: 0.7);

    final darkPaint = Paint()..color = const Color(0xFF050508);
    final whitePaint = Paint()..color = Colors.white.withValues(alpha: 0.9);

    // Glow effect
    if (glow) {
      final glowPaint = Paint()
        ..color = const Color(0xFFFF6B2C).withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(const Offset(32, 36), 24, glowPaint);
    }

    // Left ear
    final leftEar = Path()
      ..moveTo(12, 28)
      ..lineTo(8, 8)
      ..lineTo(24, 20)
      ..close();
    canvas.drawPath(leftEar, earPaint);

    // Right ear
    final rightEar = Path()
      ..moveTo(52, 28)
      ..lineTo(56, 8)
      ..lineTo(40, 20)
      ..close();
    canvas.drawPath(rightEar, earPaint);

    // Face
    canvas.drawCircle(const Offset(32, 36), 22, facePaint);

    // Inner ears
    final innerLeftEar = Path()
      ..moveTo(14, 24)
      ..lineTo(12, 12)
      ..lineTo(22, 20)
      ..close();
    canvas.drawPath(innerLeftEar, innerEarPaint);

    final innerRightEar = Path()
      ..moveTo(50, 24)
      ..lineTo(52, 12)
      ..lineTo(42, 20)
      ..close();
    canvas.drawPath(innerRightEar, innerEarPaint);

    // Eyes
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(24, 34), width: 10, height: 12),
      darkPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(40, 34), width: 10, height: 12),
      darkPaint,
    );

    // Eye shine
    canvas.drawCircle(const Offset(22, 32), 2, whitePaint);
    canvas.drawCircle(const Offset(38, 32), 2, whitePaint);

    // Nose
    final nose = Path()
      ..moveTo(32, 40)
      ..lineTo(29, 44)
      ..lineTo(35, 44)
      ..close();
    canvas.drawPath(nose, darkPaint);

    // Mouth
    final mouth = Path()
      ..moveTo(27, 46)
      ..quadraticBezierTo(32, 50, 37, 46);
    canvas.drawPath(
      mouth,
      Paint()
        ..color = const Color(0xFF050508)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    // Whiskers
    final whiskerPaint = Paint()
      ..color = const Color(0xFF050508).withValues(alpha: 0.7)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    // Left
    canvas.drawLine(const Offset(10, 36), const Offset(20, 38), whiskerPaint);
    canvas.drawLine(const Offset(10, 42), const Offset(20, 42), whiskerPaint);
    canvas.drawLine(const Offset(10, 48), const Offset(20, 46), whiskerPaint);

    // Right
    canvas.drawLine(const Offset(54, 36), const Offset(44, 38), whiskerPaint);
    canvas.drawLine(const Offset(54, 42), const Offset(44, 42), whiskerPaint);
    canvas.drawLine(const Offset(54, 48), const Offset(44, 46), whiskerPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
