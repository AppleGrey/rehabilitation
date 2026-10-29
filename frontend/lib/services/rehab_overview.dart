import 'program_api.dart';

/// 一个训练动作的最近一次记录。进度页和首页都从这里读，避免再写死示例数据。
class TrainingHit {
  final String title;
  final String programTitle;
  final String programId;
  final String status;
  final double? score;
  final DateTime? at;
  final String taskId;
  final int? pain;

  const TrainingHit({
    required this.title,
    required this.programTitle,
    required this.programId,
    required this.status,
    this.score,
    this.at,
    this.taskId = '',
    this.pain,
  });

  bool get done => status == 'done';
}

class RehabOverview {
  final List<Map<String, dynamic>> programs;

  /// 已完成训练的全量时间线（跨疗程、含历史轮次），来自 /api/ai/assess/timeline。
  /// 「最近训练、得分趋势、本周节奏、连续天数」优先用它，取不到时回落到当前一轮。
  final List<Map<String, dynamic>> timeline;

  const RehabOverview(this.programs, {this.timeline = const []});

  static Future<RehabOverview> load() async {
    final views = await ProgramApi.listAll();
    List<Map<String, dynamic>> timeline = const [];
    try {
      timeline = await ProgramApi.timeline(limit: 60);
    } catch (_) {}
    return RehabOverview(views, timeline: timeline);
  }

  /// 还没结束的方案：生成中、进行中，或已经有分期内容但还没结业/转诊。
  Map<String, dynamic>? get focus {
    for (final p in programs) {
      if (_isOpen(p)) return p;
    }
    return null;
  }

  Map<String, dynamic>? get latest => programs.isEmpty ? null : programs.first;

  List<Map<String, dynamic>> itemsOf(Map<String, dynamic>? program) {
    final current = program?['current'];
    if (current is! Map) return const [];
    return (current['items'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<TrainingHit> get hits {
    final out = <TrainingHit>[];
    for (final p in programs) {
      final pid = p['program_id']?.toString() ?? '';
      final title = programTitle(p);
      for (final item in itemsOf(p)) {
        final training = item['training'];
        final t = training is Map
            ? Map<String, dynamic>.from(training)
            : const <String, dynamic>{};
        out.add(
          TrainingHit(
            title: itemTitle(item),
            programTitle: title,
            programId: pid,
            status: t['status']?.toString() ?? 'none',
            score: _asDouble(t['overall_score']),
            at: DateTime.tryParse(t['created_at']?.toString() ?? ''),
            taskId: t['task_id']?.toString() ?? '',
            pain: t['pain_reported'] is num
                ? (t['pain_reported'] as num).toInt()
                : null,
          ),
        );
      }
    }
    out.sort((a, b) {
      final at = a.at;
      final bt = b.at;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return out;
  }

  int doneOf(Map<String, dynamic>? program) =>
      itemsOf(program).where((it) => _status(it) == 'done').length;

  /// 全部疗程累计完成的训练次数（含历史轮次，不受当前方案版本影响）。
  int get totalTrainings {
    var total = 0;
    for (final p in programs) {
      final stats = p['stats'];
      final n = stats is Map ? stats['trainings_done'] : null;
      if (n is num) total += n.toInt();
    }
    return total;
  }

  /// 连续有训练记录的天数，从今天或昨天往前数。没有记录就是 0。
  int get streak {
    final days = _activeDays().toSet();
    if (days.isEmpty) return 0;
    var cursor = _day(DateTime.now());
    if (!days.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!days.contains(cursor)) return 0;
    }
    var n = 0;
    while (days.contains(cursor)) {
      n++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return n;
  }

  double? get averageScore {
    final scores = timeline
        .map((e) => e['score'])
        .whereType<num>()
        .map((v) => v.toDouble())
        .toList();
    if (scores.isNotEmpty) {
      return scores.reduce((a, b) => a + b) / scores.length;
    }
    // 时间线拿不到时退回当前一轮已评分的动作
    final fallback = hits
        .where((h) => h.done && h.score != null)
        .map((h) => h.score!)
        .toList();
    if (fallback.isEmpty) return null;
    return fallback.reduce((a, b) => a + b) / fallback.length;
  }

  /// 本周每天完成的训练组数，下标 0 是周一。
  List<int> get weekCounts {
    final now = DateTime.now();
    final monday = _day(now).subtract(Duration(days: now.weekday - 1));
    final counts = List<int>.filled(7, 0);
    for (final day in _activeDays()) {
      final delta = day.difference(monday).inDays;
      if (delta >= 0 && delta < 7) counts[delta]++;
    }
    return counts;
  }

  /// 有训练记录的那些天（本地日）。优先用全量时间线，没有时回落到当前一轮。
  List<DateTime> _activeDays() {
    final fromTimeline = timeline
        .map((e) => DateTime.tryParse(e['created_at']?.toString() ?? ''))
        .whereType<DateTime>()
        .map((at) => _day(at.toLocal()))
        .toList();
    if (fromTimeline.isNotEmpty) return fromTimeline;
    return hits
        .where((h) => h.done && h.at != null)
        .map((h) => _day(h.at!.toLocal()))
        .toList();
  }

  static bool _isOpen(Map<String, dynamic> p) {
    final status = p['status']?.toString() ?? '';
    if (status == 'discharged' || status == 'refer') return false;
    if (status == 'generating' || status == 'active') return true;
    final current = p['current'];
    return current is Map && current['plan'] != null;
  }

  static String programTitle(Map<String, dynamic> p) {
    final condition = p['condition']?.toString().trim() ?? '';
    final part = p['body_part']?.toString().trim() ?? '';
    if (condition.isNotEmpty) return condition;
    if (part.isNotEmpty) return '$part康复';
    return '康复方案';
  }

  static String itemTitle(Map<String, dynamic> item) {
    final title = item['title']?.toString().trim() ?? '';
    if (title.isNotEmpty) return title;
    final description = item['description_cn']?.toString().trim() ?? '';
    if (description.isNotEmpty) return description;
    final notes = item['notes']?.toString().trim() ?? '';
    if (notes.isNotEmpty) return notes;
    final order = item['order'];
    return order == null ? '训练动作' : '动作 $order';
  }

  static String stageLabel(Map<String, dynamic>? program) {
    const labels = {
      'acute': '保护期',
      'sub_acute': '恢复期',
      'strengthen': '强化期',
      'return': '回归期',
    };
    final current = program?['current'];
    final stage = current is Map ? current['stage'] : null;
    final type = stage is Map ? stage['stage_type']?.toString() ?? '' : '';
    final no = program?['current_stage_no'] ?? 1;
    final name = labels[type] ?? (type.isEmpty ? '当前阶段' : type);
    return '第 $no 阶段 · $name';
  }

  static String _status(Map<String, dynamic> item) {
    final training = item['training'];
    if (training is! Map) return 'none';
    return training['status']?.toString() ?? 'none';
  }

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '');
  }

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);
}
