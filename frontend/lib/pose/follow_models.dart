class Threshold {
  final String op;
  final double value;

  const Threshold({required this.op, required this.value});

  factory Threshold.fromJson(Map<String, dynamic>? j, {String fallbackOp = 'gte'}) {
    if (j == null) {
      return Threshold(op: fallbackOp, value: 0);
    }
    return Threshold(
      op: j['op'] as String? ?? fallbackOp,
      value: (j['value'] as num?)?.toDouble() ?? 0,
    );
  }

  bool reached(double? v) {
    if (v == null) return false;
    return op == 'lte' ? v <= value : v >= value;
  }
}

class FollowMetric {
  final String id;
  final String nameCn;
  final String failHint;
  final double weight;
  final bool enabled;
  final Threshold pass;
  final Threshold excellent;
  final Threshold attempt;
  final Threshold reset;
  final String kind;
  final String output;
  final String? fromName;
  final String? toName;
  final List<String> points;

  const FollowMetric({
    required this.id,
    required this.nameCn,
    required this.failHint,
    required this.weight,
    required this.enabled,
    required this.pass,
    required this.excellent,
    required this.attempt,
    required this.reset,
    required this.kind,
    this.output = '',
    this.fromName,
    this.toName,
    this.points = const [],
  });

  factory FollowMetric.fromJson(Map<String, dynamic> j) {
    final def = j['definition'] as Map<String, dynamic>? ?? {};
    return FollowMetric(
      id: j['id'] as String,
      nameCn: j['name_cn'] as String? ?? j['id'] as String,
      failHint: j['fail_hint'] as String? ?? '',
      weight: (j['weight'] as num?)?.toDouble() ?? 1,
      enabled: j['enabled'] as bool? ?? true,
      pass: Threshold.fromJson(j['pass'] as Map<String, dynamic>?),
      excellent: Threshold.fromJson(j['excellent'] as Map<String, dynamic>?),
      attempt: Threshold.fromJson(j['attempt'] as Map<String, dynamic>?),
      reset: Threshold.fromJson(j['reset'] as Map<String, dynamic>?),
      kind: def['kind'] as String? ?? '',
      output: def['output'] as String? ?? '',
      fromName: def['from'] as String?,
      toName: def['to'] as String?,
      points: (def['points'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
    );
  }
}

class CyclePeak {
  final String id;
  final String nameCn;
  final List<String> metricIds;
  final Duration time;

  const CyclePeak({
    required this.id,
    required this.metricIds,
    required this.time,
    this.nameCn = '',
  });
}

class MotionStandard {
  final String videoId;
  final String titleCn;
  final Duration tStart;
  final Duration tPeak;
  final Duration tEnd;
  final List<CyclePeak> peaks;
  final int pauseToleranceMs;
  final int holdMs;
  final int waitTimeoutMs;
  final int idleGraceMs;
  final bool idleCounts;
  final int barSegments;
  final List<FollowMetric> metrics;
  final List<String> requiredIds;
  final String failHint;
  final double minVisibility;

  const MotionStandard({
    required this.videoId,
    required this.titleCn,
    required this.tStart,
    required this.tPeak,
    required this.tEnd,
    this.peaks = const [],
    required this.pauseToleranceMs,
    required this.holdMs,
    required this.waitTimeoutMs,
    required this.idleGraceMs,
    required this.idleCounts,
    required this.barSegments,
    required this.metrics,
    required this.requiredIds,
    required this.failHint,
    this.minVisibility = 0.35,
  });

  factory MotionStandard.fromJson(Map<String, dynamic> j) {
    final kf = j['keyframes'] as Map<String, dynamic>?;
    final points = (kf?['points'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    Duration pt(String role, double fallback) {
      for (final p in points) {
        if (p['role'] == role) {
          return Duration(milliseconds: ((p['t'] as num).toDouble() * 1000).round());
        }
      }
      return Duration(milliseconds: (fallback * 1000).round());
    }

    final peaks = <CyclePeak>[];
    for (final p in points) {
      final role = p['role'];
      if (role != 'peak' && role != 'wait_peak') continue;
      final listed = (p['metric_ids'] as List<dynamic>? ?? []).map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
      final metricIds = listed.isNotEmpty
          ? listed
          : [(p['metric_id'] ?? p['id'] ?? 'primary').toString()];
      final id = (p['id'] ?? metricIds.first).toString();
      peaks.add(
        CyclePeak(
          id: id,
          nameCn: p['name_cn'] as String? ?? '',
          metricIds: metricIds,
          time: Duration(milliseconds: ((p['t'] as num).toDouble() * 1000).round()),
        ),
      );
    }

    final metrics = (j['metrics'] as List<dynamic>? ?? [])
        .map((e) => FollowMetric.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final logic = j['rep_logic'] as Map<String, dynamic>? ?? {};
    final playback = j['playback'] as Map<String, dynamic>? ?? {};
    final requiredIds = (logic['required_metric_ids'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    FollowMetric? primary;
    if (metrics.isNotEmpty) {
      if (requiredIds.isNotEmpty) {
        for (final m in metrics) {
          if (m.id == requiredIds.first) {
            primary = m;
            break;
          }
        }
      }
      primary ??= metrics.first;
    }

    return MotionStandard(
      videoId: j['video_id'] as String? ?? '',
      titleCn: j['title_cn'] as String? ?? '跟做训练',
      tStart: pt('cycle_start', 0),
      tPeak: peaks.isEmpty ? pt('wait_peak', 0) : peaks.first.time,
      tEnd: pt('cycle_end', 0),
      peaks: peaks,
      pauseToleranceMs: (playback['pause_seek_tolerance_ms'] as num?)?.toInt() ?? 80,
      holdMs: (logic['hold_ms'] as num?)?.toInt() ?? 300,
      waitTimeoutMs: (logic['wait_timeout_ms'] as num?)?.toInt() ?? 8000,
      idleGraceMs: (logic['idle_grace_ms'] as num?)?.toInt() ?? 12000,
      idleCounts: logic['idle_timeout_counts_as_nonstandard'] as bool? ?? true,
      barSegments: ((j['scoring'] as Map<String, dynamic>?)?['bar_segments'] as num?)
              ?.toInt() ??
          10,
      metrics: metrics,
      requiredIds: requiredIds,
      failHint: primary?.failHint ?? '请对齐小窗中的姿势',
      minVisibility: (j['min_visibility'] as num?)?.toDouble() ?? 0.35,
    );
  }

  FollowMetric? get requiredMetric {
    if (requiredIds.isEmpty) return metrics.isEmpty ? null : metrics.first;
    for (final m in metrics) {
      if (m.id == requiredIds.first) return m;
    }
    return metrics.isEmpty ? null : metrics.first;
  }
}

class PoseFrame {
  final bool detected;
  final bool visibilityOk;
  final int instantScore;
  final Map<String, double?> metrics;
  final List<OffsetLandmark> landmarks;

  const PoseFrame({
    required this.detected,
    required this.visibilityOk,
    required this.instantScore,
    required this.metrics,
    required this.landmarks,
  });

  factory PoseFrame.fromJson(Map<String, dynamic> j) {
    final rawMetrics = j['metrics'] as Map<String, dynamic>? ?? {};
    final metrics = <String, double?>{};
    rawMetrics.forEach((k, v) {
      metrics[k] = (v as num?)?.toDouble();
    });
    final lms = (j['landmarks'] as List<dynamic>? ?? [])
        .map((e) => OffsetLandmark.fromJson(e as Map<String, dynamic>))
        .toList();
    return PoseFrame(
      detected: j['detected'] as bool? ?? false,
      visibilityOk: j['visibility_ok'] as bool? ?? false,
      instantScore: (j['instant_score'] as num?)?.toInt() ?? 0,
      metrics: metrics,
      landmarks: lms,
    );
  }
}

class OffsetLandmark {
  final double x;
  final double y;
  final double v;

  const OffsetLandmark({required this.x, required this.y, required this.v});

  factory OffsetLandmark.fromJson(Map<String, dynamic> j) => OffsetLandmark(
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        v: (j['v'] as num?)?.toDouble() ?? 0,
      );
}

class RepEvent {
  final String grade;
  final String reason;
  final double? bestValue;
  final int peakScore;

  const RepEvent({
    required this.grade,
    required this.reason,
    required this.bestValue,
    required this.peakScore,
  });
}
