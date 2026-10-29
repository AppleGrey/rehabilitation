import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';
import 'assess_history_page.dart';
import 'program_page.dart';

/// 进度页：最近几个方案的进度（分期 + 本轮完成环）、训练统计、本周节奏、
/// 得分趋势与最近训练记录。记录类数据全部来自全量训练时间线，换轮后不丢。
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
    final historyPane = _stack([
      SectionHeader(
        title: '最近训练',
        trailing: _historyCount(overview) == 0
            ? null
            : Text(
                '最近 ${_historyCount(overview)} 条',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textTertiary,
                ),
              ),
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
      ..._programsSection(overview),
      const SizedBox(height: 16),
      _statsStrip(overview),
      const SizedBox(height: 22),
      _weekCard(overview.weekCounts),
      const SizedBox(height: 20),
      _trendCard(overview),
      const SizedBox(height: 24),
      historyPane,
    ];
  }

  Widget _landscapeBody(RehabOverview overview) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: KeyedSubtree(
            key: const Key('landscape-progress-main'),
            // 横屏高度不足时整个左列可滚动，避免小高度平板溢出
            child: SingleChildScrollView(
              child: _stack([
                ..._programsSection(overview),
                const SizedBox(height: 12),
                _statsStrip(overview),
                const SizedBox(height: 12),
                _weekCard(overview.weekCounts),
                const SizedBox(height: 12),
                _trendCard(overview, compact: true),
              ]),
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

  // ── 方案进度（最近 3 个疗程）────────────────────────────────────────

  static const _stageNames = {
    'acute': '保护期',
    'sub_acute': '恢复期',
    'strengthen': '强化期',
    'return': '回归期',
  };

  List<Widget> _programsSection(RehabOverview overview) {
    final programs = overview.programs.take(3).toList();
    return [
      SectionHeader(
        title: '方案进度',
        subtitle: overview.programs.length > 3
            ? '共 ${overview.programs.length} 个疗程，展示最近 3 个'
            : null,
      ),
      const SizedBox(height: 14),
      if (programs.isEmpty)
        const AppEmptyState(
          icon: Icons.route_rounded,
          title: '还没有康复方案',
          body: '完成问诊并生成方案后，这里会显示每个疗程的进度。',
        )
      else
        for (final p in programs)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _programTile(p, overview),
          ),
    ];
  }

  Widget _programTile(Map<String, dynamic> p, RehabOverview overview) {
    final pid = p['program_id']?.toString() ?? '';
    final title = RehabOverview.programTitle(p);
    final status = p['status']?.toString() ?? '';
    final items = overview.itemsOf(p);
    final done = overview.doneOf(p);
    final total = items.length;
    final current = p['current'];
    final stage = current is Map ? current['stage'] : null;
    final plan = current is Map ? current['plan'] : null;
    final stageType = stage is Map ? stage['stage_type']?.toString() ?? '' : '';
    final stageNo = (p['current_stage_no'] as num?)?.toInt() ?? 1;
    final version = plan is Map ? (plan['version'] as num?)?.toInt() : null;
    final stageName = _stageNames[stageType] ?? '第 $stageNo 阶段';
    final roundDone = total > 0 && done >= total;

    final subtitle = [
      stageName,
      if (version != null) '第 $version 轮',
    ].join(' · ');

    final Widget trailing;
    switch (status) {
      case 'generating':
        trailing = const AppPill(
          label: '生成中',
          color: AppTheme.secondary,
          backgroundColor: AppTheme.secondaryLight,
        );
      case 'discharged':
        trailing = const AppPill(
          label: '已结业',
          color: AppTheme.success,
          backgroundColor: AppTheme.primaryLight,
        );
      case 'refer':
        trailing = const AppPill(
          label: '已转诊',
          color: AppTheme.warning,
          backgroundColor: AppTheme.secondaryLight,
        );
      default:
        trailing = const Icon(
          Icons.chevron_right_rounded,
          size: 22,
          color: AppTheme.textTertiary,
        );
    }

    final Widget leading = total == 0
        ? Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              color: AppTheme.bgSecondary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              status == 'generating'
                  ? Icons.auto_awesome_rounded
                  : Icons.hourglass_empty_rounded,
              size: 19,
              color: AppTheme.primary,
            ),
          )
        : _MiniRing(done: done, total: total, completed: roundDone);

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: pid.isEmpty
          ? null
          : () => Navigator.of(context)
                .push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProgramPage(
                      programId: pid,
                      sessionId: p['session_id']?.toString(),
                    ),
                  ),
                )
                .then((_) => _load()),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
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
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
  }

  // ── 训练统计（一条紧凑数据带）──────────────────────────────────────

  Widget _statsStrip(RehabOverview overview) {
    final avg = overview.averageScore;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          _miniStat('${overview.streak}', '连续训练 / 天'),
          Container(width: 1, height: 30, color: AppTheme.border),
          _miniStat('${overview.totalTrainings}', '累计训练 / 次'),
          Container(width: 1, height: 30, color: AppTheme.border),
          _miniStat(avg == null ? '—' : avg.round().toString(), '平均得分'),
        ],
      ),
    );
  }

  Widget _miniStat(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 21,
              height: 1.1,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 5),
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

  // ── 本周节奏 ──────────────────────────────────────────────────────

  Widget _weekCard(List<int> counts) {
    final maxCount = counts.fold<int>(0, (a, b) => a > b ? a : b);
    final weekTotal = counts.fold<int>(0, (a, b) => a + b);
    const days = ['一', '二', '三', '四', '五', '六', '日'];
    final today = DateTime.now().weekday - 1;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '本周节奏',
            trailing: Text(
              maxCount == 0 ? '还没有完成记录' : '本周 $weekTotal 组训练',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 96,
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
                            fontSize: 10.5,
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
                              width: 16,
                              height: constraints.maxHeight * factor,
                              decoration: BoxDecoration(
                                color: active
                                    ? AppTheme.primary
                                    : const Color(0xFFE6EEEC),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        days[i],
                        style: TextStyle(
                          fontSize: 11.5,
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

  // ── 训练趋势 ──────────────────────────────────────────────────────

  /// 最近 10 次训练的得分与疼痛随时间变化（数据来自全量训练时间线）。
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '训练趋势',
            trailing: Text(
              scores.length < 2
                  ? '完成 2 次后开始画趋势'
                  : '最近 ${recent.length} 次 · ${_shortDate(recent.first.at!)}–${_shortDate(recent.last.at!)}',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (scores.length < 2)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
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
              height: compact ? 48 : 56,
            ),
            const SizedBox(height: 8),
            if (pains.any((p) => p != null))
              _TrendRow(
                label: '疼痛',
                values: pains,
                color: AppTheme.secondary,
                fixedMin: 0,
                fixedMax: 10,
                height: compact ? 48 : 56,
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

  // ── 最近训练 ──────────────────────────────────────────────────────

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
    final pending = overview.hits.where((h) => !h.done && h.at != null).length;
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
      padding: const EdgeInsets.all(13),
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
            size: 40,
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
                const SizedBox(height: 4),
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
              const SizedBox(height: 3),
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
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          AppIconBadge(
            icon: failed
                ? Icons.error_outline_rounded
                : Icons.timelapse_rounded,
            color: failed ? AppTheme.warning : AppTheme.primary,
            size: 40,
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
                const SizedBox(height: 4),
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

/// 本轮完成度小圆环：中心直接写「已完成/总数」，不做百分比。
class _MiniRing extends StatelessWidget {
  final int done;
  final int total;
  final bool completed;

  const _MiniRing({
    required this.done,
    required this.total,
    required this.completed,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0
        ? 0.0
        : (done / total).clamp(0.0, 1.0).toDouble();
    final color = completed ? AppTheme.success : AppTheme.primary;
    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(46, 46),
            painter: _MiniRingPainter(progress: ratio, color: color),
          ),
          Text(
            '$done/$total',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniRingPainter extends CustomPainter {
  final double progress;
  final Color color;

  _MiniRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - stroke) / 2 - 1;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = AppTheme.bgTertiary
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniRingPainter old) =>
      old.progress != progress || old.color != color;
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
