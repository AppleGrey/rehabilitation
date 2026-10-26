import 'dart:math' as math;

import 'follow_models.dart';

/// One-Euro + 跳变抑制，减轻 ML Kit 关节点抖动。
class LandmarkSmoother {
  LandmarkSmoother({
    this.minCutoff = 0.85,
    this.beta = 0.35,
    this.maxJump = 0.18,
    this.holdMisses = 8,
  });

  final double minCutoff;
  final double beta;
  final double maxJump;
  final int holdMisses;

  final Map<int, _OneEuro> _fx = {};
  final Map<int, _OneEuro> _fy = {};
  final Map<int, int> _outliers = {};
  List<OffsetLandmark>? _last;
  int _misses = 0;

  List<OffsetLandmark> push(List<OffsetLandmark> raw, DateTime now) {
    if (raw.length < 29) {
      _misses += 1;
      if (_misses > holdMisses) {
        reset();
        return const [];
      }
      return _last ?? const [];
    }
    _misses = 0;
    final prev = _last;
    final out = List<OffsetLandmark>.generate(raw.length, (i) {
      final p = raw[i];
      if (p.v < 0.12) {
        if (prev != null && i < prev.length && prev[i].v >= 0.12) {
          return prev[i];
        }
        return p;
      }
      var x = p.x;
      var y = p.y;
      if (prev != null && i < prev.length && prev[i].v >= 0.12) {
        final dx = x - prev[i].x;
        final dy = y - prev[i].y;
        final jump = math.sqrt(dx * dx + dy * dy);
        if (jump > maxJump) {
          final streak = (_outliers[i] ?? 0) + 1;
          _outliers[i] = streak;
          if (streak < 2) {
            x = prev[i].x;
            y = prev[i].y;
          } else {
            _outliers[i] = 0;
          }
        } else {
          _outliers[i] = 0;
        }
      }
      final sx = _fx.putIfAbsent(i, _OneEuro.new).filter(x, now, minCutoff, beta);
      final sy = _fy.putIfAbsent(i, _OneEuro.new).filter(y, now, minCutoff, beta);
      final pv = prev != null && i < prev.length ? prev[i].v : p.v;
      final v = pv * 0.55 + p.v * 0.45;
      return OffsetLandmark(x: sx, y: sy, v: v);
    });
    _last = out;
    return out;
  }

  void reset() {
    _fx.clear();
    _fy.clear();
    _outliers.clear();
    _last = null;
    _misses = 0;
  }
}

class _OneEuro {
  double? _x;
  double? _dx;
  DateTime? _t;

  double filter(double x, DateTime t, double minCutoff, double beta) {
    if (_x == null || _t == null) {
      _x = x;
      _dx = 0;
      _t = t;
      return x;
    }
    final dt = t.difference(_t!).inMicroseconds / 1e6;
    if (dt <= 1e-4) return _x!;
    final dx = (x - _x!) / dt;
    _dx = _lp(dx, _dx!, _alpha(dt, 1.0));
    final cutoff = minCutoff + beta * _dx!.abs();
    _x = _lp(x, _x!, _alpha(dt, cutoff));
    _t = t;
    return _x!;
  }

  double _alpha(double dt, double cutoff) {
    final tau = 1.0 / (2 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }

  double _lp(double x, double prev, double a) => a * x + (1 - a) * prev;
}

/// Low-latency smoothing for a skeleton drawn over its matching camera frame.
///
/// Unlike [LandmarkSmoother], this never holds missing landmarks or rejects a
/// moving joint as an outlier. Small, stationary noise is filtered, while motion
/// raises the cutoff and larger movements are shown immediately. Each visible
/// result stays within [maxDeviation] of that same frame's raw point, measured
/// as Euclidean distance in normalized preview coordinates. The corresponding
/// pixel displacement is at most maxDeviation times the preview's longer side.
/// Keep the scoring filter separate so visual tuning cannot change rep counts.
class PreviewLandmarkSmoother {
  PreviewLandmarkSmoother({
    this.maxDeviation = 0.006,
    this.minVisibility = 0.35,
    this.resetAfter = const Duration(milliseconds: 200),
  }) : assert(maxDeviation > 0 && maxDeviation.isFinite),
       assert(minVisibility >= 0 && minVisibility <= 1),
       assert(resetAfter > Duration.zero);

  final double maxDeviation;
  final double minVisibility;
  final Duration resetAfter;

  List<_PreviewPointFilter?> _filters = [];
  DateTime? _lastFrameAt;

  /// [capturedAt] is the time the camera frame was accepted, before inference.
  /// It must describe the same frame as [raw], not the time decoding completed.
  List<OffsetLandmark> push(List<OffsetLandmark> raw, DateTime capturedAt) {
    if (raw.isEmpty) {
      reset();
      return const [];
    }
    final elapsed = _lastFrameAt == null
        ? Duration.zero
        : capturedAt.difference(_lastFrameAt!);
    if (_filters.length != raw.length ||
        elapsed <= Duration.zero ||
        elapsed > resetAfter) {
      _filters = List<_PreviewPointFilter?>.filled(raw.length, null);
    }
    _lastFrameAt = capturedAt;
    final dt = elapsed.inMicroseconds / Duration.microsecondsPerSecond;

    return List<OffsetLandmark>.generate(raw.length, (i) {
      final point = raw[i];
      if (!point.x.isFinite ||
          !point.y.isFinite ||
          !point.v.isFinite ||
          point.v < minVisibility) {
        _filters[i] = null;
        return const OffsetLandmark(x: 0, y: 0, v: 0);
      }
      final filter = _filters[i];
      if (filter == null) {
        _filters[i] = _PreviewPointFilter(point.x, point.y);
        return OffsetLandmark(
          x: point.x,
          y: point.y,
          v: point.v.clamp(0.0, 1.0),
        );
      }
      return filter.push(point, dt, maxDeviation);
    }, growable: false);
  }

  void reset() {
    _filters = [];
    _lastFrameAt = null;
  }
}

class _PreviewPointFilter {
  _PreviewPointFilter(double x, double y)
    : _x = x,
      _y = y,
      _rawX = x,
      _rawY = y;

  double _x;
  double _y;
  double _rawX;
  double _rawY;
  double _vx = 0;
  double _vy = 0;

  OffsetLandmark push(OffsetLandmark raw, double dt, double maxDeviation) {
    final dx = raw.x - _x;
    final dy = raw.y - _y;
    final distanceSquared = dx * dx + dy * dy;
    // Large motion must follow the current frame, even on a slow device.
    final snapDistance = maxDeviation * 3;
    if (!distanceSquared.isFinite ||
        distanceSquared >= snapDistance * snapDistance) {
      _x = raw.x;
      _y = raw.y;
      _vx = 0;
      _vy = 0;
    } else {
      final velocityAlpha = _alpha(dt, 1.0);
      _vx += velocityAlpha * ((raw.x - _rawX) / dt - _vx);
      _vy += velocityAlpha * ((raw.y - _rawY) / dt - _vy);
      final speed = math.sqrt(_vx * _vx + _vy * _vy);
      final alpha = _alpha(dt, 1.7 + 10 * speed);
      _x += alpha * dx;
      _y += alpha * dy;

      // A visual stability filter may move a joint only a few source pixels;
      // it must never accumulate a trail behind the currently displayed body.
      final lagX = _x - raw.x;
      final lagY = _y - raw.y;
      final lagSquared = lagX * lagX + lagY * lagY;
      if (lagSquared > maxDeviation * maxDeviation) {
        final scale = maxDeviation / math.sqrt(lagSquared);
        _x = raw.x + lagX * scale;
        _y = raw.y + lagY * scale;
      }
    }
    _rawX = raw.x;
    _rawY = raw.y;
    return OffsetLandmark(x: _x, y: _y, v: raw.v.clamp(0.0, 1.0));
  }

  double _alpha(double dt, double cutoff) =>
      dt / (dt + 1 / (2 * math.pi * cutoff));
}
