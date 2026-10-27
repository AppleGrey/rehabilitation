import 'dart:math' as math;

import 'follow_models.dart';

const landmarkIndex = <String, int>{
  'nose': 0,
  'left_shoulder': 11,
  'right_shoulder': 12,
  'left_elbow': 13,
  'right_elbow': 14,
  'left_wrist': 15,
  'right_wrist': 16,
  'left_hip': 23,
  'right_hip': 24,
  'left_knee': 25,
  'right_knee': 26,
  'left_ankle': 27,
  'right_ankle': 28,
};

OffsetLandmark? _pt(List<OffsetLandmark> lms, String name) {
  if (name == 'mid_shoulder' || name == 'mid_hip') {
    final side = name == 'mid_shoulder' ? 'shoulder' : 'hip';
    final a = _pt(lms, 'left_$side');
    final b = _pt(lms, 'right_$side');
    if (a == null || b == null) return null;
    return OffsetLandmark(
      x: (a.x + b.x) / 2,
      y: (a.y + b.y) / 2,
      v: math.min(a.v, b.v),
    );
  }
  if (name == 'mid_hip') {
    final a = _pt(lms, 'left_hip');
    final b = _pt(lms, 'right_hip');
    if (a == null || b == null) return null;
    return OffsetLandmark(
      x: (a.x + b.x) / 2,
      y: (a.y + b.y) / 2,
      v: math.min(a.v, b.v),
    );
  }
  final i = landmarkIndex[name];
  if (i == null || i >= lms.length) return null;
  return lms[i];
}

bool _visible(OffsetLandmark? p, double minV) => p != null && p.v >= minV;

double _angleFromVertical(OffsetLandmark from, OffsetLandmark to) {
  final dx = to.x - from.x;
  final dy = to.y - from.y;
  var ang = (math.atan2(dx, dy) * 180 / math.pi).abs();
  if (ang > 90) ang = 180 - ang;
  return ang;
}

/// 相对「竖直向下」的开角。站立约 0°，水平约 90°，超过水平继续增大，不再折回。
double _angleFromDown(OffsetLandmark from, OffsetLandmark to) {
  final dx = to.x - from.x;
  final dy = to.y - from.y;
  final hyp = math.sqrt(dx * dx + dy * dy);
  if (hyp < 1e-6) return 0;
  final cos = (dy / hyp).clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}

double _interior(OffsetLandmark a, OffsetLandmark b, OffsetLandmark c) {
  final bax = a.x - b.x;
  final bay = a.y - b.y;
  final bcx = c.x - b.x;
  final bcy = c.y - b.y;
  final na = math.sqrt(bax * bax + bay * bay);
  final nc = math.sqrt(bcx * bcx + bcy * bcy);
  if (na < 1e-6 || nc < 1e-6) return 0;
  var cos = (bax * bcx + bay * bcy) / (na * nc);
  cos = cos.clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}

double? computeMetricValue(
  List<OffsetLandmark> lms,
  FollowMetric metric,
  double minV,
) {
  if (metric.kind == 'segment_to_axis') {
    final a = _pt(lms, metric.fromName ?? '');
    final b = _pt(lms, metric.toName ?? '');
    if (!_visible(a, minV) || !_visible(b, minV)) return null;
    if (metric.output == 'degrees_from_down') {
      return _angleFromDown(a!, b!);
    }
    return _angleFromVertical(a!, b!);
  }
  if (metric.kind == 'angle_3point' && metric.points.length == 3) {
    final a = _pt(lms, metric.points[0]);
    final b = _pt(lms, metric.points[1]);
    final c = _pt(lms, metric.points[2]);
    if (!_visible(a, minV) || !_visible(b, minV) || !_visible(c, minV)) {
      return null;
    }
    return _interior(a!, b!, c!);
  }
  return null;
}

double _metricScore(double value, FollowMetric metric) {
  final op = metric.pass.op;
  final passV = metric.pass.value;
  final resetV = metric.reset.value;
  final excellentV = metric.excellent.value;
  if (op == 'gte') {
    final span = math.max(1e-3, passV - resetV);
    var score = (value - resetV) / span * 100;
    if (value >= excellentV) {
      final extra = math.min(20.0, (value - excellentV) / math.max(1.0, excellentV * 0.2) * 20);
      score = math.min(100.0, 90 + extra);
    }
    return score.clamp(0.0, 100.0);
  }
  final bad = resetV > passV ? resetV : passV * 2;
  var score = (bad - value) / math.max(1e-3, bad - passV) * 100;
  if (value <= excellentV) {
    score = math.min(100.0, math.max(score, 90.0));
  }
  return score.clamp(0.0, 100.0);
}

/// 当前关键点的分数：它的几条标准要同时做到，取其中最低的一条。
double scoreForPeak(PoseFrame frame, MotionStandard rule, String peakId) {
  CyclePeak? peak;
  for (final item in rule.peaks) {
    if (item.id == peakId) peak = item;
  }
  if (peak == null) return frame.instantScore.toDouble();
  final byId = {for (final metric in rule.metrics) metric.id: metric};
  final metrics = [
    for (final id in peak.metricIds)
      if (byId[id]?.enabled ?? false) byId[id]!,
  ];
  if (metrics.isEmpty) return 0;
  final scores = <double>[];
  for (final metric in metrics) {
    final value = frame.metrics[metric.id];
    if (value == null) return 0;
    scores.add(_metricScore(value, metric));
  }
  return scores.reduce(math.min);
}

/// 只有配置了至少一条启用的指标，跟做才显示实时分数。
bool motionRuleEnablesLiveScore(MotionStandard? rule) {
  if (rule == null) return false;
  return rule.metrics.any((metric) => metric.enabled);
}

/// 抬腿没到合格线时也给出能看见的分数。刚抬起来是低分，接近合格是「差一点」。
double shortLiftScore(double? angle, double passAngle) {
  if (angle == null || !angle.isFinite || angle < 12 || passAngle <= 12) {
    return 0;
  }
  if (angle >= passAngle) return 0;
  final ratio = ((angle - 12) / (passAngle - 12)).clamp(0.0, 1.0);
  return 40 + ratio * 38;
}

/// 实时分数取完整评分和「差一点」分数中更高的那个。人还在、腿也抬了，就不显示 0。
double displayedFollowScore({
  required bool detected,
  required int instantScore,
  required int rawScore,
  required double? angle,
  required double passAngle,
}) {
  if (!detected) return 0;
  return math.max(
    math.max(instantScore, rawScore).toDouble(),
    shortLiftScore(angle, passAngle),
  );
}

PoseFrame evaluateLocal(List<OffsetLandmark> lms, MotionStandard standard) {
  if (lms.length < 29) {
    return const PoseFrame(
      detected: false,
      visibilityOk: false,
      instantScore: 0,
      metrics: {},
      landmarks: [],
    );
  }
  final metrics = <String, double?>{};
  final scores = <String, double>{};
  var visOk = true;
  final required = standard.requiredIds.toSet();
  if (required.isEmpty && standard.metrics.isNotEmpty) {
    required.add(standard.metrics.first.id);
  }

  for (final m in standard.metrics) {
    if (!m.enabled) continue;
    final value = computeMetricValue(lms, m, standard.minVisibility);
    metrics[m.id] = _round1(value);
    if (value == null) {
      if (required.contains(m.id)) visOk = false;
      continue;
    }
    scores[m.id] = _metricScore(value, m);
  }
  final claimed = <String>{};
  final groups = <List<String>>[];
  for (final peak in standard.peaks) {
    final ids = peak.metricIds.where((id) => standard.metrics.any((metric) => metric.enabled && metric.id == id)).toList();
    if (ids.isEmpty) continue;
    groups.add(ids);
    claimed.addAll(ids);
  }
  for (final metric in standard.metrics) {
    if (metric.enabled && !claimed.contains(metric.id)) groups.add([metric.id]);
  }
  var instant = 0.0;
  var complete = false;
  for (final group in groups) {
    final values = <double>[];
    var missing = false;
    for (final id in group) {
      final score = scores[id];
      if (score == null) {
        missing = true;
        break;
      }
      values.add(score);
    }
    if (missing || values.isEmpty) continue;
    complete = true;
    final groupScore = values.reduce(math.min);
    if (groupScore > instant) instant = groupScore;
  }
  if (!complete) visOk = false;
  return PoseFrame(
    detected: true,
    visibilityOk: visOk,
    instantScore: instant.round(),
    metrics: metrics,
    landmarks: lms,
  );
}

double? _hipAbd(List<OffsetLandmark> lms, String side, double minV) {
  final hip = _pt(lms, '${side}_hip');
  final knee = _pt(lms, '${side}_knee');
  final ankle = _pt(lms, '${side}_ankle');
  if (!_visible(hip, minV)) return null;
  final thigh = _visible(knee, minV) ? _angleFromDown(hip!, knee!) : null;
  final whole = _visible(ankle, minV) ? _angleFromDown(hip!, ankle!) : null;
  // 人眼感受的是整条腿抬多高；膝、踝都可见时取更大的那个，避免只看大腿被低估。
  return _maxOf(thigh, whole);
}

/// 关节点置信度偏低时仍估计抬腿角度，避免动作不标准就完全没有分数。
double? forgivingSwingAngle(List<OffsetLandmark> landmarks) {
  return _maxOf(
    _hipAbd(landmarks, 'left', 0.2),
    _hipAbd(landmarks, 'right', 0.2),
  );
}

double? _maxOf(double? a, double? b) {
  if (a == null) return b;
  if (b == null) return a;
  return math.max(a, b);
}

double? _round1(double? v) => v == null ? null : double.parse(v.toStringAsFixed(1));
