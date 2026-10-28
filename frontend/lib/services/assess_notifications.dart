import 'package:shared_preferences/shared_preferences.dart';

import 'auth_store.dart';
import 'rehab_overview.dart';

/// 评估完成提醒：本地记录「已提醒过的 task」。
/// 各处加载方案数据时算一遍「最近完成但还没看过的评估」，用于角标与弹条。
class AssessNotifications {
  /// 最近完成但还没提醒过的评估（7 天内，最多 5 条，新→旧）。
  static Future<List<TrainingHit>> unseen(RehabOverview overview) async {
    final seen = await _seen();
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final out = <TrainingHit>[];
    for (final h in overview.hits) {
      if (!h.done || h.taskId.isEmpty) continue;
      if (seen.contains(h.taskId)) continue;
      if (h.at == null || h.at!.isBefore(cutoff)) continue;
      out.add(h);
      if (out.length >= 5) break;
    }
    return out;
  }

  /// 标记一批评估已提醒过。
  static Future<void> markSeen(Iterable<String> taskIds) async {
    final ids = taskIds.where((e) => e.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final merged = <String>{...(p.getStringList(_key()) ?? const []), ...ids}.toList();
    final trimmed = merged.length > 200 ? merged.sublist(merged.length - 200) : merged;
    await p.setStringList(_key(), trimmed);
  }

  static String _key() => 'assess_notified_tasks_v1_${AuthStore.user?.id ?? 'anon'}';

  static Future<Set<String>> _seen() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_key()) ?? const []).toSet();
  }
}
