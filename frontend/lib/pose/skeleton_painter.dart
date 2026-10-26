import 'package:flutter/material.dart';

import 'follow_models.dart';

const _connections = <List<int>>[
  [11, 12],
  [11, 13],
  [13, 15],
  [12, 14],
  [14, 16],
  [11, 23],
  [12, 24],
  [23, 24],
  [23, 25],
  [25, 27],
  [24, 26],
  [26, 28],
];

/// 红 → 黄 → 绿，随标准程度连续变化。
Color skeletonColorForScore(double score, {bool detected = true}) {
  if (!detected) return const Color(0x66FFFFFF);
  final t = score.clamp(0.0, 100.0);
  if (t < 50) {
    return Color.lerp(
      const Color(0xFFFF5252),
      const Color(0xFFFFC107),
      t / 50,
    )!;
  }
  return Color.lerp(
    const Color(0xFFFFC107),
    const Color(0xFF00E676),
    ((t - 50) / 50).clamp(0.0, 1.0),
  )!;
}

class SkeletonPainter extends CustomPainter {
  SkeletonPainter({
    required this.landmarks,
    required this.mirrorX,
    this.score = 0,
    this.detected = false,
    this.focusJoints = const [24, 26, 28],
    this.minVisibility = 0.35,
    this.color,
  });

  final List<OffsetLandmark> landmarks;
  final bool mirrorX;
  final double score;
  final bool detected;
  final Color? color;
  final List<int> focusJoints;
  final double minVisibility;

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.length < 29) return;
    final color = this.color ?? skeletonColorForScore(score, detected: detected);
    final glow = Paint()
      ..color = color.withValues(alpha: 0.28)
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final paintLine = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final paintFocus = Paint()
      ..color = color
      ..strokeWidth = 5.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final paintDot = Paint()
      ..color = Colors.white.withValues(alpha: detected ? 0.95 : 0.4)
      ..style = PaintingStyle.fill;
    final focus = focusJoints.toSet();

    Offset? pt(int i) {
      if (i >= landmarks.length) return null;
      final lm = landmarks[i];
      if (!lm.x.isFinite ||
          !lm.y.isFinite ||
          !lm.v.isFinite ||
          lm.v < minVisibility) {
        return null;
      }
      final x = (mirrorX ? 1 - lm.x : lm.x) * size.width;
      final y = lm.y * size.height;
      return Offset(x, y);
    }

    for (final pair in _connections) {
      final a = pt(pair[0]);
      final b = pt(pair[1]);
      if (a == null || b == null) continue;
      final isFocus = focus.contains(pair[0]) && focus.contains(pair[1]);
      canvas.drawLine(a, b, glow);
      canvas.drawLine(a, b, isFocus ? paintFocus : paintLine);
    }
    for (final i in const [11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28]) {
      final p = pt(i);
      if (p == null) continue;
      final r = focus.contains(i) ? 6.5 : 4.5;
      canvas.drawCircle(p, r + 2, glow);
      canvas.drawCircle(p, r, paintDot);
      canvas.drawCircle(p, r, paintLine);
    }
  }

  @override
  bool shouldRepaint(covariant SkeletonPainter oldDelegate) {
    return oldDelegate.landmarks != landmarks ||
        oldDelegate.mirrorX != mirrorX ||
        oldDelegate.score != score ||
        oldDelegate.detected != detected ||
        oldDelegate.focusJoints != focusJoints ||
        oldDelegate.minVisibility != minVisibility ||
        oldDelegate.color != color;
  }
}
