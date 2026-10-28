import 'package:flutter/material.dart';

import '../services/program_api.dart';
import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';
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
  List<Map<String, dynamic>> _timeline = const [];
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
      // 趋势数据单独取（跨疗程的完成历史）；失败退回空列表，不挡主数据
      List<Map<String, dynamic>> timeline = const [];
      try {
        timeline = await ProgramApi.timeline();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _timeline = timeline;
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
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final header = const AppPageHeader(
              eyebrow: 'EVERY STEP COUNTS',
              title: '康复进度',
              subtitle: '每一次坚持，都算数',
            );
            if (_landscape && constraints.maxHeight >= 680) {
              return RefreshIndicator(
                color: AppTheme.primary,
                onRefresh: _load,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                      child: Column(
                        children: [
                          header,
                          const SizedBox(height: 16),
                          Expanded(child: _landscapeSlot()),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
            return RefreshIndicator(
              color: AppTheme.primary,
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
                children: [
                  header,
                  const SizedBox(height: 24),
                  if (_loading)
                    const AppLoading()
                  else if (_error != null)
                    _errorCard()
                  else
                    ..._content(_overview!),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _landscapeSlot() {
    if (_loading) return const AppLoading();
    if (_error != null) return _errorCard();
    return _landscapeBody(_overview!);
  }

  Widget _errorCard() {
    return AppEmptyState(
      icon: Icons.cloud_off_outlined,
      title: _error!,
      body: '请检查网络后重新加载，训练记录会显示在这里。',
      actionLabel: '重新加载',
      onAction: _load,
    );
  }

  bool get _landscape {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  Widget _stack(List<Widget> children) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
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
    final history = overview.hits
        .where((h) => h.done || h.at != null)
        .take(8)
        .toList();
    final summary = _summaryCard(
      ratio: ratio,
      total: total,
      focus: focus,
      streak: streak,
      compact: _landscape,
    );
    final metrics = Row(
      children: [
        Expanded(
          child: _stat(
            '${overview.programs.length}',
            '康复疗程',
            Icons.assignment_outlined,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: _stat('$assessed', '完成动作', Icons.task_alt_rounded)),
        const SizedBox(width: 10),
        Expanded(
          child: _stat(
            avg == null ? '—' : avg.round().toString(),
            '平均得分',
            Icons.auto_graph_rounded,
          ),
        ),
      ],
    );
    final historyPane = _stack([
      SectionHeader(
        title: '最近训练',
        subtitle: history.isEmpty ? null : '展示最近 ${history.length} 条记录',
      ),
      const SizedBox(height: 14),
      if (history.isEmpty)
        const AppEmptyState(
          icon: Icons.directions_walk_rounded,
          title: '第一条记录，等你来完成',
          body: '完成方案里的动作后，得分和训练时间会出现在这里。',
        )
      else
        ...history.map(
          (hit) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _historyTile(hit),
          ),
        ),
    ]);
    if (_landscape) {
      return [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: _stack([
                summary,
                const SizedBox(height: 12),
                metrics,
                const SizedBox(height: 12),
                _weekCard(week),
              ]),
            ),
            const SizedBox(width: 16),
            Expanded(flex: 6, child: historyPane),
          ],
        ),
      ];
    }
    return [
      summary,
      const SizedBox(height: 16),
      metrics,
      const SizedBox(height: 20),
      _trendCard(),
      const SizedBox(height: 20),
      _weekCard(week),
      const SizedBox(height: 28),
      historyPane,
    ];
  }

  Widget _landscapeBody(RehabOverview overview) {
    final focus = overview.focus ?? overview.latest;
    final items = overview.itemsOf(focus);
    final done = overview.doneOf(focus);
    final total = items.length;
    final ratio = total == 0 ? 0.0 : done / total;
    final avg = overview.averageScore;
    final streak = overview.streak;
    final assessed = overview.hits.where((h) => h.done).length;
    final history = overview.hits
        .where((h) => h.done || h.at != null)
        .take(8)
        .toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: KeyedSubtree(
            key: const Key('landscape-progress-main'),
            // 横屏高度不足时整个左列可滚动，避免小高度平板溢出
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _summaryCard(
                    ratio: ratio,
                    total: total,
                    focus: focus,
                    streak: streak,
                    compact: true,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _stat(
                          '${overview.programs.length}',
                          '康复疗程',
                          Icons.assignment_outlined,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _stat(
                          '$assessed',
                          '完成动作',
                          Icons.task_alt_rounded,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _stat(
                          avg == null ? '—' : avg.round().toString(),
                          '平均得分',
                          Icons.auto_graph_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _trendCard(compact: true),
                  const SizedBox(height: 12),
                  _weekCard(overview.weekCounts),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: KeyedSubtree(
            key: const Key('landscape-history'),
            child: _historyPanel(history),
          ),
        ),
      ],
    );
  }

  Widget _historyPanel(List<TrainingHit> history) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '最近训练',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '展示最近 ${history.length} 条记录',
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: history.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIconBadge(
                          icon: Icons.directions_walk_rounded,
                          size: 60,
                        ),
                        SizedBox(height: 16),
                        Text(
                          '第一条记录，等你来完成',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          '完成方案里的动作后，得分和训练时间会出现在这里。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.6,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: history.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _historyTile(history[index]),
                  ),
          ),
        ],
      ),
    );
  }

  /// F2 趋势：最近 10 次训练的得分与疼痛随时间变化（数据来自完成历史）。
  Widget _trendCard({bool compact = false}) {
    final entries = _timeline
        .map(
          (e) => (
            at: DateTime.tryParse(
              e['created_at']?.toString() ?? '',
            )?.toLocal(),
            score: (e['score'] as num?)?.toDouble(),
            pain: (e['pain_reported'] as num?)?.toDouble(),
          ),
        )
        .where((e) => e.at != null)
        .toList()
      ..sort((a, b) => a.at!.compareTo(b.at!));
    final recent = entries.length > 10
        ? entries.sublist(entries.length - 10)
        : entries;
    final scores = recent
        .map((e) => e.score)
        .where((s) => s != null)
        .toList();
    final pains = recent.map((e) => e.pain).toList();
    final firstScore = scores.isEmpty ? null : scores.first;
    final lastScore = scores.isEmpty ? null : scores.last;
    final delta = (firstScore != null && lastScore != null && scores.length >= 2)
        ? (lastScore - firstScore).round()
        : null;
    return AppCard(
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 14, 16, 12)
          : const EdgeInsets.fromLTRB(18, 20, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '训练趋势',
            subtitle: '最近的得分与疼痛，看疗效最直观',
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              scores.length < 2
                  ? '完成 2 次以上训练后开始画趋势'
                  : '最近 ${recent.length} 次 · ${_shortDate(recent.first.at!)}–${_shortDate(recent.last.at!)}',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (scores.length < 2)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '再多练几次，这里会画出你的进步曲线。',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textTertiary),
              ),
            )
          else ...[
            _TrendRow(
              label: '得分',
              trailing: delta == null
                  ? null
                  : (delta >= 0 ? '较首次 +$delta' : '较首次 $delta'),
              trailingColor: (delta ?? 0) >= 0
                  ? AppTheme.success
                  : AppTheme.warning,
              values: recent.map((e) => e.score).toList(),
              color: AppTheme.primary,
              fixedMin: 0,
              fixedMax: 100,
              height: compact ? 52 : 62,
            ),
            const SizedBox(height: 8),
            if (pains.any((p) => p != null))
              _TrendRow(
                label: '疼痛',
                values: pains,
                color: AppTheme.secondary,
                fixedMin: 0,
                fixedMax: 10,
                height: compact ? 52 : 62,
              ),
          ],
        ],
      ),
    );
  }

  String _shortDate(DateTime at) {
    final local = at.toLocal();
    return '${local.month}/${local.day}';
  }

  Widget _summaryCard({
    required double ratio,
    required int total,
    required Map<String, dynamic>? focus,
    required int streak,
    required bool compact,
  }) {
    final ring = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: ratio),
      duration: AppMotion.duration(context, AppMotion.progress),
      curve: AppMotion.curve,
      builder: (_, value, child) => ProgressRing(
        progress: value,
        size: compact ? 132 : 180,
        centerText: total == 0 ? '—' : '${(value * 100).round()}%',
        subText: focus == null ? '还没有方案' : '本期完成',
      ),
    );
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        AppPill(
          label: streak > 0 ? '已连续训练 $streak 天' : '完成一次训练，开启你的记录',
          icon: streak > 0
              ? Icons.local_fire_department_rounded
              : Icons.spa_outlined,
          color: streak > 0 ? AppTheme.secondary : AppTheme.primary,
          backgroundColor: streak > 0
              ? AppTheme.secondaryLight
              : AppTheme.primaryLight,
        ),
        if (focus != null) ...[
          const SizedBox(height: 12),
          Text(
            '${RehabOverview.programTitle(focus)} · ${RehabOverview.stageLabel(focus)}',
            textAlign: compact ? TextAlign.start : TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ],
    );
    return AppCard(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 20,
        vertical: compact ? 16 : 24,
      ),
      child: compact
          ? Row(
              children: [
                ring,
                const SizedBox(width: 16),
                Expanded(child: details),
              ],
            )
          : Column(children: [ring, const SizedBox(height: 16), details]),
    );
  }

  Widget _stat(String value, String label, IconData icon) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 8),
      child: Column(
        children: [
          Icon(icon, size: 19, color: AppTheme.primary),
          const SizedBox(height: 7),
          Text(
            value,
            style: const TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _weekCard(List<int> counts, {bool fill = false}) {
    final maxCount = counts.fold<int>(0, (a, b) => a > b ? a : b);
    const days = ['一', '二', '三', '四', '五', '六', '日'];
    final today = DateTime.now().weekday - 1;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
      child: Column(
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: '本周节奏', subtitle: '保持规律，比一次练很多更重要'),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              maxCount == 0
                  ? '还没有完成记录'
                  : '本周完成 ${counts.reduce((a, b) => a + b)} 个动作',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final factor = maxCount == 0
                    ? 0.08
                    : (counts[i] / maxCount).clamp(0.08, 1.0);
                final active = counts[i] > 0;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (counts[i] > 0)
                        Text(
                          '${counts[i]}',
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => Align(
                            alignment: Alignment.bottomCenter,
                            child: AnimatedContainer(
                              duration: AppMotion.duration(
                                context,
                                AppMotion.progress,
                              ),
                              curve: AppMotion.curve,
                              width: 18,
                              height: constraints.maxHeight * factor,
                              decoration: BoxDecoration(
                                color: active
                                    ? AppTheme.primary
                                    : const Color(0xFFE6EEEC),
                                borderRadius: BorderRadius.circular(9),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        days[i],
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: i == today
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: i == today
                              ? AppTheme.primary
                              : AppTheme.textSecondary,
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
    return AppCard(
      padding: const EdgeInsets.all(15),
      child: Row(
        children: [
          AppIconBadge(
            icon: hit.done ? Icons.check_rounded : Icons.timelapse_rounded,
            color: hit.done ? AppTheme.success : AppTheme.primary,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hit.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  hit.done ? '${hit.programTitle} · $score' : hit.programTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _when(hit.at),
            style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
          ),
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
    final hm =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (day == today) return '今天 $hm';
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    return '${local.month}/${local.day} $hm';
  }
}

/// 带标签的迷你趋势行：一列值，缺口自动跳过。
class _TrendRow extends StatelessWidget {
  final String label;
  final List<double?> values;
  final Color color;
  final double height;
  final double? fixedMin;
  final double? fixedMax;
  final String? trailing;
  final Color trailingColor;

  const _TrendRow({
    required this.label,
    required this.values,
    required this.color,
    this.height = 60,
    this.fixedMin,
    this.fixedMax,
    this.trailing,
    this.trailingColor = AppTheme.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
            const Spacer(),
            if (trailing != null)
              Text(
                trailing!,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: trailingColor,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _TrendPainter(
              values: values,
              color: color,
              fixedMin: fixedMin,
              fixedMax: fixedMax,
            ),
          ),
        ),
      ],
    );
  }
}

/// 迷你折线：折线 + 淡色面积 + 首尾圆点，不画坐标轴，保持克制。
class _TrendPainter extends CustomPainter {
  final List<double?> values;
  final Color color;
  final double? fixedMin;
  final double? fixedMax;

  _TrendPainter({
    required this.values,
    required this.color,
    this.fixedMin,
    this.fixedMax,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final present = values.whereType<double>().toList();
    if (present.length < 2) return;
    var minV = fixedMin ?? present.reduce((a, b) => a < b ? a : b);
    var maxV = fixedMax ?? present.reduce((a, b) => a > b ? a : b);
    if (maxV - minV < 1e-6) maxV = minV + 1;
    const pad = 6.0;
    final dx = values.length <= 1
        ? 0.0
        : (size.width - pad * 2) / (values.length - 1);
    Offset point(int i, double v) => Offset(
      pad + dx * i,
      pad + (1 - (v - minV) / (maxV - minV)) * (size.height - pad * 2),
    );

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final areaPaint = Paint()..color = color.withValues(alpha: 0.10);
    final dotPaint = Paint()..color = color;

    final path = Path();
    final area = Path();
    var started = false;
    double? lastX;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) continue;
      final p = point(i, v);
      if (!started) {
        path.moveTo(p.dx, p.dy);
        area.moveTo(p.dx, size.height);
        area.lineTo(p.dx, p.dy);
        started = true;
      } else {
        path.lineTo(p.dx, p.dy);
        area.lineTo(p.dx, p.dy);
      }
      lastX = p.dx;
    }
    if (!started || lastX == null) return;
    area.lineTo(lastX, size.height);
    area.close();
    canvas.drawPath(area, areaPaint);
    canvas.drawPath(path, linePaint);

    for (final idx in [0, values.length - 1]) {
      final v = values[idx];
      if (v == null) continue;
      canvas.drawCircle(point(idx, v), 3.2, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.values != values || old.color != color;
}
