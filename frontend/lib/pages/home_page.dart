import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';
import 'program_page.dart';

/// 首页只回答三件事：今天练什么、做到哪一步、下一步点哪里。
class HomePage extends StatefulWidget {
  final VoidCallback onConsult;
  final int refreshTick;

  const HomePage({super.key, required this.onConsult, this.refreshTick = 0});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  RehabOverview? _overview;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
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
        _error = '暂时没有连上康复记录';
      });
    }
  }

  void _openProgram(Map<String, dynamic> program) {
    final pid = program['program_id']?.toString();
    if (pid == null || pid.isEmpty) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ProgramPage(
              programId: pid,
              sessionId: program['session_id']?.toString(),
            ),
          ),
        )
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (_landscape && constraints.maxHeight >= 680) {
              return _landscapeFill(constraints.maxHeight);
            }
            return _portraitList();
          },
        ),
      ),
    );
  }

  Widget _portraitList() {
    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primary,
      backgroundColor: AppTheme.bgPrimary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        children: [
          _greeting(AuthStore.user?.displayName ?? '你好'),
          const SizedBox(height: 24),
          if (_loading)
            const AppLoading()
          else if (_error != null)
            _errorCard()
          else
            ..._body(_overview!),
        ],
      ),
    );
  }

  Widget _landscapeFill(double height) {
    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primary,
      backgroundColor: AppTheme.bgPrimary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              children: [
                _greeting(AuthStore.user?.displayName ?? '你好'),
                const SizedBox(height: 16),
                Expanded(
                  child: _loading
                      ? const AppLoading()
                      : _error != null
                      ? _errorCard()
                      : _landscapeBody(_overview!),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorCard() {
    return AppEmptyState(
      icon: Icons.cloud_off_outlined,
      title: _error!,
      body: '请检查网络连接，恢复后下拉即可重新加载。',
      actionLabel: '重新加载',
      onAction: _load,
    );
  }

  bool get _landscape {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  Widget _columns(Widget primary, Widget secondary) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 5, child: primary),
        const SizedBox(width: 16),
        Expanded(flex: 6, child: secondary),
      ],
    );
  }

  Widget _stack(List<Widget> children) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  List<Widget> _body(RehabOverview overview) {
    final focus = overview.focus;
    if (focus == null) {
      final start = _startCard(overview.programs.isEmpty);
      if (!_landscape || overview.programs.isEmpty) {
        return [
          start,
          if (overview.programs.isNotEmpty) ...[
            const SizedBox(height: 24),
            _stats(overview),
          ],
        ];
      }
      return [_columns(start, _stats(overview))];
    }
    final items = overview.itemsOf(focus);
    final done = overview.doneOf(focus);
    final total = items.length;
    final generating = focus['status']?.toString() == 'generating';
    final remaining = (total - done).clamp(0, total);
    final hero = _hero(
      focus,
      done: done,
      total: total,
      generating: generating,
      remaining: remaining,
      fill: false,
    );
    final training = _stack([
      const SectionHeader(title: '本期训练', subtitle: '跟着你的专属方案，一步一步来'),
      const SizedBox(height: 14),
      if (generating || items.isEmpty)
        _pendingCard(focus, generating)
      else
        ...items.asMap().entries.map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _actionTile(
              entry.key + 1,
              entry.value,
              () => _openProgram(focus),
            ),
          ),
        ),
      const SizedBox(height: 8),
      _safetyNote(),
    ]);
    if (_landscape) {
      return [
        _columns(
          _stack([hero, const SizedBox(height: 12), _stats(overview)]),
          training,
        ),
      ];
    }
    return [
      hero,
      const SizedBox(height: 20),
      _stats(overview),
      const SizedBox(height: 28),
      training,
    ];
  }

  Widget _landscapeBody(RehabOverview overview) {
    final focus = overview.focus;
    if (focus == null) {
      return _columns(
        _startCard(overview.programs.isEmpty),
        overview.programs.isEmpty ? const SizedBox.shrink() : _stats(overview),
      );
    }
    final items = overview.itemsOf(focus);
    final done = overview.doneOf(focus);
    final total = items.length;
    final generating = focus['status']?.toString() == 'generating';
    final remaining = (total - done).clamp(0, total);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: const Key('landscape-hero'),
                  child: _hero(
                    focus,
                    done: done,
                    total: total,
                    generating: generating,
                    remaining: remaining,
                    fill: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              KeyedSubtree(
                key: const Key('landscape-stats'),
                child: _stats(overview),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: KeyedSubtree(
            key: const Key('landscape-training'),
            child: _trainingPanel(focus, items, generating),
          ),
        ),
      ],
    );
  }

  Widget _trainingPanel(
    Map<String, dynamic> focus,
    List<Map<String, dynamic>> items,
    bool generating,
  ) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '本期训练',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '跟着你的专属方案，一步一步来',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: generating || items.isEmpty
                ? _pendingCard(focus, generating)
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => _actionTile(
                      index + 1,
                      items[index],
                      () => _openProgram(focus),
                      plain: true,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          _safetyNote(),
        ],
      ),
    );
  }

  Widget _pendingCard(Map<String, dynamic> focus, bool generating) {
    return AppCard(
      child: Row(
        children: [
          const AppIconBadge(icon: Icons.auto_awesome_rounded),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              generating ? '专属方案生成中，稍后回来看看。' : '这一期还没有动作，请先查看方案详情。',
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          IconButton(
            tooltip: '查看方案',
            onPressed: () => _openProgram(focus),
            icon: const Icon(
              Icons.arrow_forward_rounded,
              color: AppTheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _greeting(String name) {
    final now = DateTime.now();
    const weeks = ['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${now.month}月${now.day}日 · 星期${weeks[now.weekday - 1]}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '你好，$name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '不着急，每次进步一点点。',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        const AppIconBadge(icon: Icons.self_improvement_rounded, size: 48),
      ],
    );
  }

  Widget _hero(
    Map<String, dynamic> program, {
    required int done,
    required int total,
    required bool generating,
    required int remaining,
    required bool fill,
  }) {
    final ratio = total == 0 ? 0.0 : done / total;
    final cta = generating
        ? '查看生成进度'
        : remaining == 0 && total > 0
        ? '完成本轮，查看下一步'
        : '继续我的训练';
    final compact = _landscape;
    final gap = compact ? 14.0 : 24.0;
    final next = generating || total == 0
        ? '为你安排合适的康复节奏'
        : remaining == 0
        ? '本期动作已全部完成，做得很好'
        : '下一个动作 · ${RehabOverview.itemTitle(overviewNext(program, done))}';
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.98, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppTheme.primaryDark,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primaryDark.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: -55,
              top: -70,
              child: _circle(190, Colors.white.withValues(alpha: 0.045)),
            ),
            Positioned(
              right: 22,
              top: 36,
              child: Icon(
                Icons.spa_outlined,
                size: 110,
                color: Colors.white.withValues(alpha: 0.055),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(compact ? 18 : 22),
              child: Column(
                mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppPill(
                    label: generating
                        ? '正在生成方案'
                        : RehabOverview.stageLabel(program),
                    icon: generating
                        ? Icons.auto_awesome_rounded
                        : Icons.spa_outlined,
                    color: AppTheme.primaryLight,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                  ),
                  SizedBox(height: compact ? 12 : 22),
                  Text(
                    RehabOverview.programTitle(program),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 22 : 26,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    next,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 12.5,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: gap),
                  Row(
                    children: [
                      Text(
                        total == 0 ? '准备中' : '$done / $total 个动作',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        total == 0 ? '' : '${(ratio * 100).round()}%',
                        style: const TextStyle(
                          color: AppTheme.mint,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  generating
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            minHeight: 7,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.13,
                            ),
                            color: AppTheme.mint,
                          ),
                        )
                      : AppProgressBar(
                          value: ratio,
                          backgroundColor: Colors.white.withValues(alpha: 0.13),
                          color: AppTheme.mint,
                        ),
                  if (fill) const Spacer(),
                  SizedBox(height: gap),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryLight,
                      foregroundColor: AppTheme.primaryDark,
                      minimumSize: const Size(double.infinity, 52),
                    ),
                    onPressed: () => _openProgram(program),
                    icon: Icon(
                      generating
                          ? Icons.schedule_rounded
                          : Icons.play_arrow_rounded,
                      size: 20,
                    ),
                    label: Text(cta),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> overviewNext(Map<String, dynamic> program, int done) {
    final items = RehabOverview([program]).itemsOf(program);
    if (items.isEmpty) return const {};
    for (final item in items) {
      final training = item['training'];
      if (training is! Map || training['status'] != 'done') return item;
    }
    return items[done.clamp(0, items.length - 1)];
  }

  Widget _stats(RehabOverview overview) {
    final avg = overview.averageScore;
    return Row(
      children: [
        Expanded(
          child: _stat(
            Icons.local_fire_department_outlined,
            '${overview.streak}',
            '连续训练 / 天',
            AppTheme.secondary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _stat(
            Icons.task_alt_rounded,
            '${overview.hits.where((h) => h.done).length}',
            '已完成动作',
            AppTheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _stat(
            Icons.insights_rounded,
            avg == null ? '—' : '${avg.round()}',
            '平均得分',
            AppTheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _stat(IconData icon, String value, String label, Color color) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Column(
        children: [
          Icon(icon, size: 20, color: color),
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

  Widget _actionTile(
    int number,
    Map<String, dynamic> item,
    VoidCallback onTap, {
    bool plain = false,
  }) {
    final training = item['training'];
    final status = training is Map
        ? training['status']?.toString() ?? 'none'
        : 'none';
    final done = status == 'done';
    final score = training is Map ? training['overall_score'] : null;
    final assessing = status == 'pending' || status == 'processing';
    final row = Row(
      children: [
        Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? AppTheme.primaryLight : AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(16),
          ),
          child: done
              ? const Icon(Icons.check_rounded, color: AppTheme.primary)
              : Text(
                  '$number'.padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primary,
                  ),
                ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                RehabOverview.itemTitle(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: done ? AppTheme.textSecondary : AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                assessing
                    ? '动作评估中'
                    : done && score != null
                    ? '已完成 · 本次 $score 分'
                    : (done ? '已完成 · 可再次跟练' : _dose(item)),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Icon(
          assessing ? Icons.schedule_rounded : Icons.arrow_forward_ios_rounded,
          size: 16,
          color: AppTheme.textTertiary,
        ),
      ],
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(plain ? 14 : 22),
        onTap: onTap,
        child: plain
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: row,
              )
            : AppCard(
                padding: const EdgeInsets.all(16),
                color: done ? const Color(0xFFFAFCF9) : Colors.white,
                child: row,
              ),
      ),
    );
  }

  String _dose(Map<String, dynamic> item) {
    final sets = item['sets'];
    final reps = item['reps'];
    if (sets != null && reps != null) return '$sets 组 × $reps 次';
    final hold = item['hold_seconds'];
    if (hold != null) return '保持 $hold 秒';
    final freq = item['frequency']?.toString() ?? '';
    return freq.isEmpty ? '待完成' : freq;
  }

  Widget _startCard(bool isFirst) {
    return AppCard(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppIconBadge(icon: Icons.forum_outlined, size: 58),
          const SizedBox(height: 22),
          Text(
            isFirst ? '从了解自己开始' : '为下一阶段做好准备',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isFirst
                ? '花几分钟完成 AI 问诊，我们会根据你的情况生成专属康复方案。'
                : '上一份方案已经结束。如果还需要继续训练，可以重新问诊并生成新的方案。',
            style: const TextStyle(
              fontSize: 14,
              height: 1.7,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: widget.onConsult,
            icon: const Icon(Icons.add_comment_outlined, size: 19),
            label: const Text('开始 AI 问诊'),
          ),
        ],
      ),
    );
  }

  Widget _circle(double size, Color color) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );

  Widget _safetyNote() {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.favorite_border_rounded,
          size: 17,
          color: AppTheme.textTertiary,
        ),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '以身体感受为准。若疼痛明显加重，请停止训练并咨询医生。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: AppTheme.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}
