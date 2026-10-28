import 'dart:async';

import 'package:flutter/material.dart';

import '../services/program_api.dart';
import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';
import 'consult_report_page.dart';
import 'rehab_video_page.dart';

/// 「我的康复方案」——查看当前分期方案、逐项跟练与评估，做完一轮触发进阶决策。
class ProgramPage extends StatefulWidget {
  final String programId;
  final String? sessionId;

  const ProgramPage({super.key, required this.programId, this.sessionId});

  @override
  State<ProgramPage> createState() => _ProgramPageState();
}

class _ProgramPageState extends State<ProgramPage> {
  Map<String, dynamic>? _view;
  String? _error;
  bool _loading = true;
  bool _progressing = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_view == null) setState(() => _loading = true);
    try {
      final v = await ProgramApi.get(widget.programId);
      if (!mounted) return;
      setState(() {
        _view = v;
        _loading = false;
        _error = null;
      });
      _maybePoll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 方案生成中，或有训练项正在评估时，自动轮询刷新。
  void _maybePoll() {
    final v = _view;
    final generating =
        v?['status'] == 'generating' ||
        (v?['status'] == 'active' && (v?['current']?['plan'] == null));
    final items = (v?['current']?['items'] as List<dynamic>? ?? []);
    final assessing = items.any((it) {
      final s = (it as Map)['training']?['status'];
      return s == 'pending' || s == 'processing';
    });
    if (generating || assessing) {
      _poll ??= Timer.periodic(const Duration(seconds: 3), (_) => _load());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _train(Map<String, dynamic> item) {
    final vid = item['video_id'] as String?;
    if (vid == null || vid.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该动作暂时没有跟练视频，请按动作说明完成。')));
      return;
    }
    final stageNo = (_view?['current_stage_no'] as int?) ?? 1;
    final sid = (_view?['session_id'] as String?) ?? widget.sessionId;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (ctx) => RehabVideoPage(
              onBack: () => Navigator.of(ctx).pop(),
              videoId: vid,
              sessionId: sid,
              videoTitle: RehabOverview.itemTitle(item),
              uploadMode: 'training',
              programId: widget.programId,
              stageNo: stageNo,
            ),
          ),
        )
        .then((_) => _load());
  }

  void _openConsult() {
    final sid = (_view?['session_id'] as String?) ?? widget.sessionId;
    if (sid == null || sid.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConsultReportPage(sessionId: sid),
      ),
    );
  }

  Future<void> _viewResult(Map<String, dynamic> training) async {
    final taskId = training['task_id'] as String?;
    if (taskId == null) return;
    final task = await ProgramApi.assessStatus(taskId);
    final a = task?['assessment'];
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.bgSecondary,
      sheetAnimationStyle: AnimationStyle(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 420),
        ),
        reverseDuration: AppMotion.duration(context, AppMotion.standard),
        curve: AppMotion.curve,
        reverseCurve: AppMotion.emphasized,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _resultSheet(
        a is Map<String, dynamic> ? a : null,
        task?['summary'] as String?,
      ),
    );
  }

  Future<void> _finishRound() async {
    if (_progressing) return;
    setState(() => _progressing = true);
    try {
      final r = await ProgramApi.progress(widget.programId);
      if (!mounted) return;
      final decision = r['decision'] as String? ?? '';
      final rationale = r['rationale'] as String? ?? '';
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(_decisionTitle(decision)),
          content: Text(rationale.isEmpty ? '已根据本轮训练做出决定。' : rationale),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('进阶失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _progressing = false);
    }
  }

  String _decisionTitle(String d) =>
      {
        'advance': '很棒！进入下一阶段',
        'hold': '本阶段再巩固一轮',
        'regress': '调整为更轻松的训练',
        'refer': '建议先线下就医',
        'discharge': '恭喜，基本康复，可结业',
      }[d] ??
      '训练进阶';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        title: const Text('我的康复方案'),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.assignment_outlined,
              color: AppTheme.textSecondary,
            ),
            tooltip: '查看本次问诊',
            onPressed: _openConsult,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const AppLoading(label: '正在整理你的专属方案');
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 72),
          AppEmptyState(
            icon: Icons.cloud_off_outlined,
            title: '暂时没有连上康复方案',
            body: '请检查网络连接后重试，已完成的训练记录不会丢失。',
            actionLabel: '重新加载',
            onAction: _load,
          ),
        ],
      );
    }

    final v = _view!;
    final status = v['status'] as String? ?? '';
    final current = v['current'] as Map<String, dynamic>?;
    final plan = current?['plan'] as Map<String, dynamic>?;

    if (status == 'discharged') return _dischargeView();
    if (status == 'generating' || current == null || plan == null) {
      return _generatingView();
    }

    final stage = current['stage'] as Map<String, dynamic>?;
    final items = (current['items'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final goals = (stage?['goals'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final precautions = (plan['precautions'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final allDone =
        items.isNotEmpty &&
        items.every((it) => it['training']?['status'] == 'done');
    final done = items
        .where((it) => it['training']?['status'] == 'done')
        .length;

    final summary = plan['summary_text']?.toString().trim() ?? '';
    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          AppReveal(
            child: _hero(v, items, done: done, allDone: allDone, goals: goals),
          ),
          const SizedBox(height: 28),
          SectionHeader(
            title: '本期训练',
            subtitle: '左右滑动，按顺序完成',
            trailing: AppPill(
              label: allDone ? '本轮已完成' : '还剩 ${items.length - done} 个',
              icon: allDone ? Icons.check_rounded : Icons.route_rounded,
            ),
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const AppEmptyState(
              icon: Icons.playlist_add_rounded,
              title: '本期动作还在准备中',
              body: '下拉刷新查看最新内容，准备好后即可开始训练。',
            )
          else
            _trainingRail(items),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 22),
            _card(
              child: _infoBlock(
                icon: Icons.description_outlined,
                title: '方案详情',
                child: Text(
                  summary,
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.7,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 2),
          _card(
            child: _infoBlock(
              icon: Icons.health_and_safety_outlined,
              title: '注意事项',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...precautions.map(_precaution),
                  _precaution('训练中疼痛不超过 3 分为度，若明显加重请停止并咨询医生。'),
                ],
              ),
            ),
          ),
          if (allDone) ...[const SizedBox(height: 16), _roundButton()],
        ],
      ),
    );
  }

  Widget _hero(
    Map<String, dynamic> program,
    List<Map<String, dynamic>> items, {
    required int done,
    required bool allDone,
    required List<String> goals,
  }) {
    final ratio = items.isEmpty ? 0.0 : done / items.length;
    Map<String, dynamic>? next;
    for (final item in items) {
      if (item['training']?['status'] != 'done') {
        next = item;
        break;
      }
    }
    final assessing =
        next?['training']?['status'] == 'pending' ||
        next?['training']?['status'] == 'processing';
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.primaryDark,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryDark.withValues(alpha: 0.14),
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
            right: 16,
            top: 40,
            child: Icon(
              Icons.spa_outlined,
              size: 116,
              color: Colors.white.withValues(alpha: 0.055),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppPill(
                  label: RehabOverview.stageLabel(program),
                  icon: Icons.spa_outlined,
                  color: AppTheme.primaryLight,
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                ),
                const SizedBox(height: 20),
                Text(
                  RehabOverview.programTitle(program),
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    height: 1.25,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  items.isEmpty
                      ? '专属训练内容准备中'
                      : allDone
                      ? '本期动作全部完成，做得非常好'
                      : '下一个动作 · ${RehabOverview.itemTitle(next!)}',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Text(
                      '本期已完成 $done / ${items.length}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(ratio * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.mint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                AppProgressBar(
                  value: ratio,
                  color: AppTheme.mint,
                  backgroundColor: Colors.white.withValues(alpha: 0.14),
                ),
                if (goals.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: goals.take(3).map(_goalChip).toList(),
                  ),
                ],
                const SizedBox(height: 24),
                AppPressable(
                  enabled: !assessing && !_progressing,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryLight,
                      foregroundColor: AppTheme.primaryDark,
                      disabledBackgroundColor: AppTheme.primaryLight.withValues(
                        alpha: 0.55,
                      ),
                      minimumSize: const Size(double.infinity, 54),
                    ),
                    onPressed: assessing
                        ? null
                        : allDone && items.isNotEmpty
                        ? (_progressing ? null : _finishRound)
                        : next == null
                        ? null
                        : () => _train(next!),
                    icon: Icon(
                      allDone
                          ? Icons.flag_rounded
                          : assessing
                          ? Icons.timelapse_rounded
                          : Icons.play_arrow_rounded,
                      size: 21,
                    ),
                    label: Text(
                      allDone
                          ? (_progressing ? '正在制定下一步…' : '完成本轮 · 查看下一步')
                          : assessing
                          ? '动作评估中，请稍候'
                          : '继续我的训练',
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

  Widget _infoBlock({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AppIconBadge(icon: icon, size: 36),
            const SizedBox(width: 10),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    );
  }

  Widget _trainingRail(List<Map<String, dynamic>> items) {
    return SizedBox(
      height: 228,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final width = (MediaQuery.sizeOf(context).width * 0.74).clamp(
            230.0,
            300.0,
          );
          return SizedBox(
            width: width,
            child: _itemCard(index + 1, items[index]),
          );
        },
      ),
    );
  }

  Widget _itemCard(int no, Map<String, dynamic> it) {
    final roleLabel = switch (it['role']) {
      'warmup' => '热身',
      'cooldown' => '放松',
      _ => '主体训练',
    };
    final training = it['training'] as Map<String, dynamic>?;
    final status = training?['status']?.toString() ?? 'none';
    final done = status == 'done';
    final assessing = status == 'pending' || status == 'processing';
    final score = training?['overall_score'];
    final notes = it['notes']?.toString().trim() ?? '';
    final dosage = _dosage(it);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      onTap: done
          ? () => _viewResult(training!)
          : assessing
          ? null
          : () => _train(it),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconBadge(
                icon: done
                    ? Icons.check_rounded
                    : assessing
                    ? Icons.timelapse_rounded
                    : Icons.directions_walk_rounded,
                color: done ? AppTheme.success : AppTheme.primary,
                size: 34,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$roleLabel · 动作 $no',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            RehabOverview.itemTitle(it),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              height: 1.3,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            dosage.isEmpty ? '跟随视频指导完成' : dosage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              notes,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.45,
                color: AppTheme.textTertiary,
              ),
            ),
          ),
          if (done)
            Row(
              children: [
                if (score != null)
                  _badge(
                    '$score 分',
                    AppTheme.primaryLight,
                    AppTheme.primaryDark,
                  ),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _viewResult(training!),
                  child: const Text('查看评估'),
                ),
              ],
            )
          else if (assessing)
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '评估中',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            )
          else
            AppPressable(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _train(it),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('开始跟练'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _roundButton() => AppPressable(
    enabled: !_progressing,
    child: ElevatedButton.icon(
      onPressed: _progressing ? null : _finishRound,
      icon: _progressing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            )
          : const Icon(Icons.flag_rounded, size: 20),
      label: Text(_progressing ? '正在制定下一步…' : '完成本轮训练 · 查看下一步'),
    ),
  );

  Widget _precaution(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Icon(Icons.circle, size: 5, color: AppTheme.warning),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.6,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _circle(double size, Color color) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );

  Widget _generatingView() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        CircularProgressIndicator(),
        SizedBox(height: 18),
        Text(
          '方案生成中…',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        SizedBox(height: 8),
        Text(
          '正在结合你的问诊与基线表现制定方案，请稍候。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
      ],
    ),
  );

  Widget _dischargeView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.celebration, size: 56, color: AppTheme.primary),
          SizedBox(height: 16),
          Text(
            '恭喜，本疗程已结业',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          SizedBox(height: 10),
          Text(
            '你已基本恢复。建议继续保持训练习惯；如症状复发或加重，请及时复诊。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: AppTheme.textSecondary,
              height: 1.6,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _resultSheet(Map<String, dynamic>? a, String? summary) {
    if (a == null) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Text('暂无评估详情', textAlign: TextAlign.center),
      );
    }
    Widget row(String label, dynamic val) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          Text(
            '${val ?? '-'}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
    final findings = (a['key_findings'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final corrections = (a['corrections'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final comps = (a['compensations'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final romRatio = a['rom_target_ratio'];
    final pain = a['pain_reported'];
    final meets = a['meets_exit_criteria'];
    final grounded = (a['kg_sources'] as List<dynamic>? ?? []).isNotEmpty;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: AppTheme.bgTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const Text(
                  '动作评估',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                if (grounded) _chip('已对照知识图谱标准'),
              ],
            ),
            const SizedBox(height: 12),
            row('综合评分', a['overall_score']),
            row('姿势准确度', a['posture_score']),
            row('关节活动范围', a['range_of_motion']),
            row('动作节奏', a['rhythm_score']),
            if (romRatio != null)
              row('活动度达标度', '${((romRatio as num) * 100).round()}%（相对本阶段目标）'),
            if (pain != null) row('自评疼痛', '$pain / 10'),
            if (meets != null) row('本阶段达标', meets == true ? '已达标' : '未达标'),
            if (comps.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                '观察到的代偿',
                style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
              ),
              ...comps.map(
                (f) => Text(
                  '• $f',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.warning,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            if (findings.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                '关键发现',
                style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
              ),
              ...findings.map(
                (f) => Text(
                  '• $f',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            if (corrections.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                '纠正建议',
                style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
              ),
              ...corrections.map(
                (f) => Text(
                  '• $f',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            if ((summary ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                summary!,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                  height: 1.6,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _dosage(Map<String, dynamic> it) {
    final parts = <String>[];
    final sets = it['sets'], reps = it['reps'], hold = it['hold_seconds'];
    if (sets != null && reps != null) {
      parts.add('$sets 组 × $reps 次');
    } else if (hold != null) {
      parts.add('保持 $hold 秒');
    }
    if (it['frequency'] != null) parts.add('${it['frequency']}');
    if (it['load'] != null && '${it['load']}'.isNotEmpty) {
      parts.add('${it['load']}');
    }
    return parts.join(' · ');
  }

  Widget _card({required Widget child, VoidCallback? onTap}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: AppCard(
      padding: const EdgeInsets.all(18),
      onTap: onTap,
      child: child,
    ),
  );

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppTheme.primaryLight,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        color: AppTheme.primaryDark,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _badge(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w600),
    ),
  );

  Widget _goalChip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 11.5, color: AppTheme.primaryLight),
    ),
  );
}
