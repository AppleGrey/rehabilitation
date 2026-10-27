import 'follow_models.dart';

/// 一个关键点的动作标准都到了合格线，并保持一小段时间，就记 1 次。
/// 必须先回到复位，同一姿势才可以再记一次。
class KeypointCounter {
  KeypointCounter(this.rule);

  final MotionStandard rule;
  final Map<String, DateTime> _holdingSince = {};
  final Set<String> _latched = {};
  int count = 0;

  int update(PoseFrame frame, DateTime at) {
    final groups = _groups();
    for (final group in groups) {
      final passed = group.metrics.every(
        (metric) => metric.pass.reached(frame.metrics[metric.id]),
      );
      if (_latched.contains(group.id)) {
        final lifts = group.metrics.where((metric) => metric.pass.op != 'lte');
        final backDown = lifts.isEmpty || lifts.every((metric) => metric.reset.reached(frame.metrics[metric.id]));
        if (!passed && backDown) {
          _latched.remove(group.id);
          _holdingSince.remove(group.id);
        }
        continue;
      }
      if (!passed) {
        _holdingSince.remove(group.id);
        continue;
      }
      final since = _holdingSince.putIfAbsent(group.id, () => at);
      if (at.difference(since).inMilliseconds >= rule.holdMs) {
        count += 1;
        _latched.add(group.id);
        _holdingSince.remove(group.id);
      }
    }
    return count;
  }

  List<_Group> _groups() {
    final byId = {for (final metric in rule.metrics) metric.id: metric};
    final claimed = <String>{};
    final groups = <_Group>[];
    for (final peak in rule.peaks) {
      final metrics = [
        for (final id in peak.metricIds)
          if (byId[id]?.enabled ?? false) byId[id]!,
      ];
      claimed.addAll(peak.metricIds);
      if (metrics.isEmpty) continue;
      groups.add(_Group(peak.id, metrics));
    }
    final loose = [
      for (final metric in rule.metrics)
        if (metric.enabled && !claimed.contains(metric.id)) metric,
    ];
    if (loose.isNotEmpty && rule.peaks.isEmpty) {
      groups.add(_Group(loose.first.id, loose));
    }
    return groups;
  }
}

class _Group {
  const _Group(this.id, this.metrics);

  final String id;
  final List<FollowMetric> metrics;
}
