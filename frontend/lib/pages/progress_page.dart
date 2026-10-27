import 'package:flutter/material.dart';

import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import '../widgets/progress_ring.dart';

/// 进度页只展示已经发生的训练：完成比例、得分、本周次数和最近记录。
class ProgressPage extends StatefulWidget {
  final int refreshTick;

  const ProgressPage({super.key, this.refreshTick = 0});

  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> {
  RehabOverview? _overview;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProgressPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await RehabOverview.load();
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '进度暂时没有加载出来';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6F5),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppTheme.primary,
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              const Text('康复进度', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
              const SizedBox(height: 4),
              const Text('按你实际完成的动作统计', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 18),
              if (_loading)
                const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                _empty(_error!, '下拉刷新后再看。')
              else
                ..._content(_overview!),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(RehabOverview overview) {
    final focus = overview.focus ?? overview.latest;
    final items = overview.itemsOf(focus);
    final done = overview.doneOf(focus);
    final total = items.length;
    final ratio = total == 0 ? 0.0 : done / total;
    final avg = overview.averageScore;
    final streak = overview.streak;
    final assessed = overview.hits.where((h) => h.done).length;
    final week = overview.weekCounts;
    final history = overview.hits.where((h) => h.done || h.at != null).take(8).toList();
    return [
      Center(
        child: Column(
          children: [
            ProgressRing(
              progress: ratio,
              centerText: total == 0 ? '—' : '${(ratio * 100).round()}%',
              subText: focus == null ? '还没有方案' : '本期完成',
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(999)),
              child: Text(
                streak > 0 ? '已连续训练 $streak 天' : '还没有连续训练记录',
                style: const TextStyle(fontSize: 13.5, color: AppTheme.primary, fontWeight: FontWeight.w600),
              ),
            ),
            if (focus != null) ...[
              const SizedBox(height: 8),
              Text(
                '${RehabOverview.programTitle(focus)} · ${RehabOverview.stageLabel(focus)}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(child: _stat('${overview.programs.length}', '方案数')),
          const SizedBox(width: 10),
          Expanded(child: _stat('$assessed', '已完成动作')),
          const SizedBox(width: 10),
          Expanded(child: _stat(avg == null ? '—' : avg.round().toString(), '平均得分')),
        ],
      ),
      const SizedBox(height: 16),
      _weekCard(week),
      const SizedBox(height: 18),
      const Text('训练记录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
      const SizedBox(height: 10),
      if (history.isEmpty)
        _empty('还没有训练记录', '完成方案里的动作后，得分和时间会出现在这里。')
      else
        ...history.map((h) => Padding(padding: const EdgeInsets.only(bottom: 10), child: _historyTile(h))),
    ];
  }

  Widget _stat(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _weekCard(List<int> counts) {
    final maxCount = counts.fold<int>(0, (a, b) => a > b ? a : b);
    const days = ['一', '二', '三', '四', '五', '六', '日'];
    final today = DateTime.now().weekday - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('本周完成', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          Text(
            maxCount == 0 ? '这周还没有完成动作' : '按每个动作最近一次完成的日期统计',
            style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final factor = maxCount == 0 ? 0.08 : (counts[i] / maxCount).clamp(0.08, 1.0);
                final active = counts[i] > 0;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (counts[i] > 0)
                        Text('${counts[i]}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const SizedBox(height: 4),
                      Container(
                        width: 18,
                        height: 78 * factor,
                        decoration: BoxDecoration(
                          color: active ? AppTheme.primary : const Color(0xFFE6EEEC),
                          borderRadius: BorderRadius.circular(9),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        days[i],
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: i == today ? FontWeight.w700 : FontWeight.w400,
                          color: i == today ? AppTheme.primary : AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyTile(TrainingHit hit) {
    final score = hit.score == null ? '评估中' : '${hit.score!.round()} 分';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: hit.done ? const Color(0xFFE8F8EF) : AppTheme.primaryLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(hit.done ? Icons.check_rounded : Icons.timelapse, color: hit.done ? AppTheme.success : AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text(
                  hit.done ? '${hit.programTitle} · $score' : hit.programTitle,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          Text(_when(hit.at), style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
        ],
      ),
    );
  }

  String _when(DateTime? at) {
    if (at == null) return '';
    final local = at.toLocal();
    final now = DateTime.now();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (day == today) return '今天 $hm';
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    return '${local.month}/${local.day} $hm';
  }

  Widget _empty(String title, String body) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(fontSize: 13.5, height: 1.5, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}
