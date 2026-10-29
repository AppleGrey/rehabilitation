import 'package:flutter/material.dart';

import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';
import 'assess_history_page.dart';
import 'program_history_page.dart';

/// 进度页展示：当前阶段与本轮进度、本阶段达标条件、全量训练记录、本周节奏与得分趋势。
/// 「本轮完成几项、离下一阶段还差什么」来自当前方案；「练过哪些、得分趋势」来自全量训练时间线，
/// 因此换轮/进阶后历史记录不会消失。
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
    final historyPane = _stack([
      SectionHeader(
        title: '最近训练',
        subtitle: _historyCount(overview) == 0
            ? null
            : '最近 ${_historyCount(overview)} 条记录',
      ),
      const SizedBox(height: 14),
      if (_historyCount(overview) == 0)
        const AppEmptyState(
          icon: Icons.directions_walk_rounded,
          title: '第一条记录，等你来完成',
          body: '完成方案里的动作后，得分和训练时间会出现在这里。',
        )
      else
        ..._historyTiles(overview),
    ]);
    return [
      _stageCard(overview, focus, items, done, total),
      const SizedBox(height: 16),
      _statsRow(overview),
      if (_criteriaCard(focus) != null) ...[
        const SizedBox(height: 16),
        _criteriaCard(focus)!,
      ],
      const SizedBox(height: 24),
      historyPane,
      const SizedBox(height: 24),
      _weekCard(overview.weekCounts),
      const SizedBox(height: 24),
      _trendCard(overview),
    ];
  }

  Widget _landscapeBody(RehabOverview overview) {
    final focus = overview.focus ?? overview.latest;
    final items = overview.itemsOf(focus);
    final done = overview.doneOf(focus);
    final total = items.length;
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
                  _stageCard(overview, focus, items, done, total),
                  const SizedBox(height: 12),
                  _statsRow(overview),
                  if (_criteriaCard(focus) != null) ...[
                    const SizedBox(height: 12),
                    _criteriaCard(focus)!,
                  ],
                  const SizedBox(height: 12),
                  _weekCard(overview.weekCounts),
                  const SizedBox(height: 12),
                  _trendCard(overview, compact: true),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: KeyedSubtree(
            key: const Key('landscape-history'),
            child: _historyPanel(overview),
          ),
        ),
      ],
    );
  }

  Widget _historyPanel(RehabOverview overview) {
    final count = _historyCount(overview);
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
          if (count > 0) ...[
            const SizedBox(height: 4),
            Text(
              '最近 $count 条记录',
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: count == 0
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
                : ListView(children: _historyTiles(overview)),
          ),
        ],
      ),
    );
  }

  int _historyCount(RehabOverview overview) {
    final pending = overview.hits
        .where((h) => !h.done && h.at != null)
        .length;
    return pending + overview.timeline.take(8).length;
  }

  List<Widget> _historyTiles(RehabOverview overview) {
    final tiles = <Widget>[];
    // 正在评估的（刚录完的那几组）排最前
    for (final hit in overview.hits) {
      if (!hit.done && hit.at != null) {
        tiles.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _pendingTile(hit),
          ),
        );
      }
    }
    for (final entry in overview.timeline.take(8)) {
      tiles.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _trainingTile(entry),
        ),
      );
    }
    return tiles;
  }

  /// 当前阶段卡片：阶段位置 + 本轮完成情况 + 为什么还没进下一阶段。
  Widget _stageCard(
    RehabOverview overview,
    Map<String, dynamic>? focus,
    List<Map<String, dynamic>> items,
    int done,
    int total,
  ) {
    final streak = overview.streak;
    final streakPill = AppPill(
      label: streak > 0 ? '已连续训练 $streak 天' : '从今天开始，每一步都算数',
      icon: streak > 0
          ? Icons.local_fire_department_rounded
          : Icons.spa_outlined,
      color: streak > 0 ? AppTheme.secondary : AppTheme.primary,
      backgroundColor: streak > 0
          ? AppTheme.secondaryLight
          : AppTheme.primaryLight,
    );
    if (focus == null) {
      return AppCard(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '当前阶段',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '还没有进行中的康复方案。完成问诊并生成方案后，这里会显示所处阶段和本轮进度。',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Align(alignment: Alignment.centerLeft, child: streakPill),
          ],
        ),
      );
    }
    final status = focus['status']?.toString() ?? '';
    final generating = status == 'generating';
    final current = focus['current'];
    final stage = current is Map ? current['stage'] : null;
    final plan = current is Map ? current['plan'] : null;
    final stageType = stage is Map ? stage['stage_type']?.toString() ?? '' : '';
    final stageNo = (focus['current_stage_no'] as num?)?.toInt() ?? 1;
    final version = plan is Map ? (plan['version'] as num?)?.toInt() : null;
    final programId = focus['program_id']?.toString() ?? '';
    var stageIndex = _stageOrder.indexOf(stageType);
    if (stageIndex < 0) {
      stageIndex = (stageNo - 1).clamp(0, _stageOrder.length - 1).toInt();
    }
    final remaining = (total - done).clamp(0, total);
    final hasPending = items.any((it) {
      final t = it['training'];
      return t is Map && t['status'] == 'processing';
    });

    final String caption;
    if (status == 'discharged') {
      caption = '恭喜结业，整个疗程已完成，可随时在康复历程里回看每一轮训练。';
    } else if (status == 'refer') {
      caption = '已转入线下就医，康复历程里可以回看之前每一轮的训练与决策记录。';
    } else if (generating) {
      caption = '正在为你生成接下来的训练安排，稍后回来看看。';
    } else if (total == 0) {
      caption = '本阶段训练安排马上就绪。';
    } else if (remaining > 0) {
      caption = '完成本轮剩余 $remaining 项训练后，系统将评估能否进入下一阶段。';
    } else {
      caption = '本轮训练已完成，评估结果出来后决定下一步安排。';
    }

    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '当前阶段',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const Spacer(),
              streakPill,
            ],
          ),
          const SizedBox(height: 16),
          _stageRail(stageIndex),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  version != null
                      ? '${RehabOverview.programTitle(focus)} · 第 $version 轮'
                      : RehabOverview.programTitle(focus),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (total > 0)
                Text(
                  '本轮完成 $done / $total 项',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 10),
            _roundSegments(done, total, hasPending),
          ],
          const SizedBox(height: 12),
          Text(
            caption,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: AppTheme.textSecondary,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: programId.isEmpty
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ProgramHistoryPage(programId: programId),
                      ),
                    ),
              icon: const Icon(Icons.timeline_rounded, size: 17),
              label: const Text('康复历程'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primary,
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const _stageOrder = ['acute', 'sub_acute', 'strengthen', 'return'];
  static const _stageLabels = {
    'acute': '保护期',
    'sub_acute': '恢复期',
    'strengthen': '强化期',
    'return': '回归期',
  };

  /// 四个分期小地图：走过的打勾，当前高亮，后面的留灰。
  Widget _stageRail(int current) {
    return Row(
      children: List.generate(_stageOrder.length, (i) {
        final passed = i < current;
        final active = i == current;
        final color = passed
            ? AppTheme.success
            : (active ? AppTheme.primary : AppTheme.bgTertiary);
        return Expanded(
          child: Column(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: passed
                    ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                    : (active
                          ? const Icon(
                              Icons.circle,
                              size: 8,
                              color: Colors.white,
                            )
                          : null),
              ),
              const SizedBox(height: 6),
              Text(
                _stageLabels[_stageOrder[i]] ?? '',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active
                      ? AppTheme.primary
                      : (passed
                            ? AppTheme.textSecondary
                            : AppTheme.textTertiary),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  /// 本轮逐项进度条：已完成实心，正在评估的浅色，其余留灰。
  Widget _roundSegments(int done, int total, bool hasPending) {
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Container(
              height: 7,
              decoration: BoxDecoration(
                color: i < done
                    ? AppTheme.primary
                    : (i == done && hasPending
                          ? AppTheme.primaryLight
                          : AppTheme.bgTertiary),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 本阶段达标条件：说明「怎样才算这一阶段练好了」。
  Widget? _criteriaCard(Map<String, dynamic>? focus) {
    final current = focus?['current'];
    final stage = current is Map ? current['stage'] : null;
    final raw = stage is Map ? stage['exit_criteria'] : null;
    final criteria = (raw as List<dynamic>? ?? const [])
        .map((e) => e?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    if (criteria.isEmpty) return null;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '本阶段达标条件',
            subtitle: '全部完成并达标后，才会进入下一阶段',
          ),
          const SizedBox(height: 14),
          for (final c in criteria)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.check_circle_outline_rounded,
                      size: 16,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.55,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statsRow(RehabOverview overview) {
    final avg = overview.averageScore;
    return Row(
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
            '${overview.totalTrainings}',
            '累计训练 / 次',
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

  Widget _weekCard(List<int> counts) {
    final maxCount = counts.fold<int>(0, (a, b) => a > b ? a : b);
    final weekTotal = counts.fold<int>(0, (a, b) => a + b);
    const days = ['一', '二', '三', '四', '五', '六', '日'];
    final today = DateTime.now().weekday - 1;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: '本周节奏', subtitle: '保持规律，比一次练很多更重要'),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              maxCount == 0 ? '还没有完成记录' : '本周完成 $weekTotal 组训练',
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

  /// F2 趋势：最近 10 次训练的得分与疼痛随时间变化（数据来自全量训练时间线）。
  Widget _trendCard(RehabOverview overview, {bool compact = false}) {
    final entries = overview.timeline
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

  /// 已完成的一组训练：可点开回放录像并查看当时的评估。
  Widget _trainingTile(Map<String, dynamic> entry) {
    final taskId = entry['task_id']?.toString() ?? '';
    final rawTitle = entry['title']?.toString().trim() ?? '';
    final title = rawTitle.isNotEmpty
        ? rawTitle
        : (entry['video_id']?.toString() ?? '训练动作');
    final score = entry['score'];
    final pain = entry['pain_reported'];
    final setNo = (entry['set_no'] as num?)?.toInt();
    final setTotal = (entry['set_total'] as num?)?.toInt();
    final at = DateTime.tryParse(entry['created_at']?.toString() ?? '');
    final parts = <String>[
      if (setTotal != null && setTotal > 1) '第 ${setNo ?? 1}/$setTotal 组',
      score is num ? '${score.round()} 分' : '已完成',
      if (pain != null) '疼痛 $pain/10',
    ];
    return AppCard(
      padding: const EdgeInsets.all(15),
      onTap: taskId.isEmpty
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AssessReplayPage(
                  taskId: taskId,
                  title: title,
                  setNo: setTotal != null && setTotal > 1 ? setNo : null,
                ),
              ),
            ),
      child: Row(
        children: [
          const AppIconBadge(
            icon: Icons.check_rounded,
            color: AppTheme.success,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  parts.join(' · '),
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _when(at),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textTertiary,
                ),
              ),
              const SizedBox(height: 4),
              const Icon(
                Icons.play_circle_outline_rounded,
                size: 19,
                color: AppTheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 刚录完、还在评估中的一组训练。
  Widget _pendingTile(TrainingHit hit) {
    final failed = hit.status == 'error';
    return AppCard(
      padding: const EdgeInsets.all(15),
      child: Row(
        children: [
          AppIconBadge(
            icon: failed ? Icons.error_outline_rounded : Icons.timelapse_rounded,
            color: failed ? AppTheme.warning : AppTheme.primary,
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
                  failed ? '评估失败，可到方案页重试' : '评估中，结果出来后会更新得分',
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
