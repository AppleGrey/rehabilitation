import 'dart:async';

import 'package:flutter/material.dart';

import '../services/assess_notifications.dart';
import '../services/error_text.dart';
import '../services/program_api.dart';
import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';
import 'assess_history_page.dart';
import 'consult_report_page.dart';
import 'program_history_page.dart';
import 'rehab_video_page.dart';

/// 「我的康复方案」——查看当前分期方案、逐项跟练与评估，做完一轮触发进阶决策。
class ProgramPage extends StatefulWidget {
  final String programId;
  final String? sessionId;

  /// 打开后自动定位到「下一个要练的动作」（首页「继续我的训练」直达用）
  final bool focusNext;

  /// 结业/转诊收尾页的「再次问诊」入口（由外层切到问诊 Tab）
  final VoidCallback? onStartConsult;

  const ProgramPage({
    super.key,
    required this.programId,
    this.sessionId,
    this.focusNext = false,
    this.onStartConsult,
  });

  @override
  State<ProgramPage> createState() => _ProgramPageState();
}

class _ProgramPageState extends State<ProgramPage> {
  Map<String, dynamic>? _view;
  String? _error;
  bool _loading = true;
  bool _progressing = false;
  Timer? _poll;
  final ScrollController _railController = ScrollController();

  /// 上次加载时还在「评估中」的任务：由评估中 → 已完成时弹一条完成提醒（D3）
  Set<String> _assessingBefore = const {};

  /// 生成开始时间：用于「等太久」的兜底提示（B2）
  DateTime? _generatingSince;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _railController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_view == null) setState(() => _loading = true);
    try {
      final v = await ProgramApi.get(widget.programId);
      if (!mounted) return;
      final items = ((v['current']?['items'] as List<dynamic>?) ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      // D3：刚完成的评估给一次弹条提醒（只在正在看这一页时）
      final nowAssessing = <String>{};
      final justDone = <String>[];
      for (final it in items) {
        final t = it['training'];
        if (t is! Map) continue;
        final id = t['task_id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final s = t['status']?.toString() ?? '';
        if (s == 'pending' || s == 'processing') nowAssessing.add(id);
        if (s == 'done' && _assessingBefore.contains(id)) {
          justDone.add(RehabOverview.itemTitle(it));
        }
      }
      setState(() {
        _view = v;
        _loading = false;
        _error = null;
      });
      _assessingBefore = nowAssessing;
      if (justDone.isNotEmpty) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text('评估完成：${justDone.join('、')}，点开卡片看结果')),
          );
      }
      // 结果已在本页展示：把完成的任务标记为「已看过」，清掉底栏角标
      try {
        final doneIds = <String>[];
        for (final it in items) {
          final t = it['training'];
          if (t is Map && (t['status']?.toString() ?? '') == 'done') {
            final id = t['task_id']?.toString() ?? '';
            if (id.isNotEmpty) doneIds.add(id);
          }
        }
        await AssessNotifications.markSeen(doneIds);
      } catch (_) {}
      _maybePoll();
      // C6：自动定位到下一个要练的动作
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToNextItem(items),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, fallback: '暂时没有连上康复方案');
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
    if (generating) {
      _generatingSince ??= DateTime.now();
    } else {
      _generatingSince = null;
    }
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
    final training = item['training'] is Map
        ? Map<String, dynamic>.from(item['training'] as Map)
        : <String, dynamic>{};
    final setsTotal =
        (training['sets_total'] as num?)?.toInt() ??
        (item['sets'] as num?)?.toInt() ??
        1;
    final setNo = (training['next_set'] as num?)?.toInt() ?? 1;
    final restSeconds = (item['rest_seconds'] as num?)?.toInt() ?? 60;
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
              setNo: setNo,
              setTotal: setsTotal,
              restSeconds: restSeconds,
              dosageText: _dosage(item),
            ),
          ),
        )
        .then((_) => _load());
  }

  /// D4：评估卡住的兜底——让后端复位任务再跑一遍。
  Future<void> _retryAssess(Map<String, dynamic> training) async {
    final taskId = training['task_id'] as String?;
    if (taskId == null || taskId.isEmpty) return;
    try {
      await ProgramApi.retryAssess(taskId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已重新排队评估，稍候刷新查看结果')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(friendlyError(e, fallback: '重试失败，请稍后再试'))),
        );
    }
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

  /// 康复历程：按「轮」回看每轮训练录像与进阶决策。
  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProgramHistoryPage(programId: widget.programId),
      ),
    );
  }

  Future<void> _viewResult(Map<String, dynamic> item) async {
    final training = item['training'] is Map
        ? Map<String, dynamic>.from(item['training'] as Map)
        : <String, dynamic>{};
    final taskId = training['task_id']?.toString();
    if (taskId == null || taskId.isEmpty) return;
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
        item,
        training,
        a is Map<String, dynamic> ? a : null,
        task?['summary'] as String?,
      ),
    );
  }

  Future<void> _finishRound() async {
    if (_progressing) return;
    // E1：先给本轮小结（完成度/平均分/疼痛/代偿），再揭晓进阶结论
    final items = ((_view?['current']?['items'] as List<dynamic>?) ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final proceed = await _roundSummaryDialog(items);
    if (proceed != true || !mounted) return;
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
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(friendlyError(e, fallback: '这一步没成功，请稍后重试'))),
          );
      }
    } finally {
      if (mounted) setState(() => _progressing = false);
    }
  }

  /// 完成本轮前的小结：把表现摊开，用户知道「凭什么进阶/保持」。
  Future<bool?> _roundSummaryDialog(List<Map<String, dynamic>> items) {
    final done = items
        .where((it) => (it['training'] as Map?)?['status'] == 'done')
        .length;
    final scores = items
        .map((it) => (it['training'] as Map?)?['overall_score'])
        .whereType<num>()
        .map((e) => e.toDouble())
        .toList();
    final avg = scores.isEmpty
        ? '—'
        : (scores.reduce((a, b) => a + b) / scores.length).round().toString();
    final pains = items
        .map((it) => (it['training'] as Map?)?['pain_reported'])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList();
    final pain = pains.isEmpty ? '—' : '${pains.reduce((a, b) => a > b ? a : b)}';
    final comps = items
        .expand(
          (it) => ((it['training'] as Map?)?['compensations'] as List? ?? const []),
        )
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .toSet()
        .length;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('本轮小结'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summaryRow('完成动作', '$done / ${items.length}'),
            _summaryRow('平均得分', avg),
            _summaryRow('最高疼痛', pain == '—' ? '—' : '$pain / 10'),
            _summaryRow('观察到的代偿', comps == 0 ? '无明显代偿' : '$comps 项'),
            const SizedBox(height: 10),
            const Text(
              '接下来会结合这些表现，决定进阶到下一阶段、保持还是调整强度。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再练一会儿'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('查看下一步'),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
      ],
    ),
  );

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
        leading: const AppBackButton(),
        title: const Text('我的康复方案'),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.timeline_rounded,
              color: AppTheme.textSecondary,
            ),
            tooltip: '康复历程',
            onPressed: _openHistory,
          ),
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

    if (status == 'discharged') return _dischargeView(v);
    if (status == 'refer') return _referView();
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
          if (items.isNotEmpty) ...[
            const SizedBox(height: 18),
            _criteriaCard(items),
          ],
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
                Row(
                  children: [
                    AppPill(
                      label: RehabOverview.stageLabel(program),
                      icon: Icons.spa_outlined,
                      color: AppTheme.primaryLight,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                    ),
                    if (_expectedDays(program) != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '本阶段预计 ${_expectedDays(program)} 天',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                _stageRail(program),
                const SizedBox(height: 16),
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

  double _railCardWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * 0.74).clamp(230.0, 300.0);

  /// C6：自动滚动定位到「下一个要练的动作」。
  void _scrollToNextItem(List<Map<String, dynamic>> items) {
    if (!_railController.hasClients || items.isEmpty) return;
    final index = items.indexWhere(
      (it) => (it['training'] as Map?)?['status']?.toString() != 'done',
    );
    if (index <= 0) return;
    final width = _railCardWidth(context);
    final target = (index * (width + 12)).clamp(
      0.0,
      _railController.position.maxScrollExtent,
    );
    _railController.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _trainingRail(List<Map<String, dynamic>> items) {
    final nextIndex = items.indexWhere(
      (it) => (it['training'] as Map?)?['status']?.toString() != 'done',
    );
    return SizedBox(
      height: 252,
      child: ListView.separated(
        controller: _railController,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) => SizedBox(
          width: _railCardWidth(context),
          child: _itemCard(
            index + 1,
            items[index],
            isNext: index == nextIndex,
          ),
        ),
      ),
    );
  }

  Widget _itemCard(int no, Map<String, dynamic> it, {bool isNext = false}) {
    final roleLabel = switch (it['role']) {
      'warmup' => '热身',
      'cooldown' => '放松',
      _ => '主体训练',
    };
    final training = it['training'] is Map
        ? Map<String, dynamic>.from(it['training'] as Map)
        : <String, dynamic>{};
    final status = training['status']?.toString() ?? 'none';
    final done = status == 'done';
    final assessing = status == 'pending' || status == 'processing';
    final partial = status == 'partial';
    final failed = status == 'error';
    final score = training['overall_score'];
    final previous = training['previous_score'];
    final notes = it['notes']?.toString().trim() ?? '';
    final dosage = _dosage(it);
    final stale = assessing && _isStale(training);
    final doneSets = (training['sets_done'] as List?)?.length ?? 0;
    final totalSets = (training['sets_total'] as num?)?.toInt() ?? 1;
    final nextSet = (training['next_set'] as num?)?.toInt() ?? (doneSets + 1);

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      onTap: done
          ? () => _viewResult(it)
          : (assessing || failed)
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
                    : failed
                    ? Icons.error_outline_rounded
                    : Icons.directions_walk_rounded,
                color: done
                    ? AppTheme.success
                    : failed
                    ? AppTheme.warning
                    : AppTheme.primary,
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
              if (isNext && !done)
                _badge('下一步', AppTheme.primary, Colors.white),
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
          if (partial) ...[
            const SizedBox(height: 4),
            Text(
              '已录 $doneSets / $totalSets 组',
              style: const TextStyle(fontSize: 12, color: AppTheme.primary),
            ),
          ],
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
                if (previous is num && score is num) ...[
                  const SizedBox(width: 6),
                  Text(
                    _deltaText(previous.toDouble(), score.toDouble()),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: score >= previous
                          ? AppTheme.success
                          : AppTheme.warning,
                    ),
                  ),
                ],
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _viewResult(it),
                  child: const Text('查看评估'),
                ),
              ],
            )
          else if (assessing)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stale ? '评估耗时有点久，可以重试一次' : '评估中 · 通常 1 分钟内出结果',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
                if (stale)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => _retryAssess(training),
                    child: const Text('重试评估'),
                  ),
              ],
            )
          else if (failed)
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '上次评估没有成功，可以重试或重新录制',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _retryAssess(training),
                  child: const Text('重试评估'),
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
                label: Text(partial ? '继续第 $nextSet 组' : '开始跟练'),
              ),
            ),
        ],
      ),
    );
  }

  /// 评估超过约 12 分钟还没结果 → 视为卡住，给重试入口（D4）。
  bool _isStale(Map<String, dynamic> training) {
    final at = DateTime.tryParse(training['created_at']?.toString() ?? '');
    if (at == null) return false;
    return DateTime.now().difference(at.toLocal()).inMinutes >= 12;
  }

  String _deltaText(double previous, double score) {
    final delta = (score - previous).round();
    if (delta > 0) return '较上次 ↑$delta';
    if (delta < 0) return '较上次 ↓${delta.abs()}';
    return '与上次持平';
  }

  /// E1 进阶标准透明：把「本阶段达标条件」摊开，并给出当前完成情况。
  Widget _criteriaCard(List<Map<String, dynamic>> items) {
    final trainings = items
        .map((it) => (it['training'] as Map?) ?? const {})
        .toList();
    final doneScores = trainings
        .map((t) => t['overall_score'])
        .whereType<num>()
        .map((e) => e.toDouble())
        .toList();
    final avgScore = doneScores.isEmpty
        ? null
        : doneScores.reduce((a, b) => a + b) / doneScores.length;
    final roms = trainings
        .map((t) => t['rom_target_ratio'])
        .whereType<num>()
        .map((e) => e.toDouble())
        .toList();
    final romAvg = roms.isEmpty
        ? null
        : roms.reduce((a, b) => a + b) / roms.length;
    final pains = trainings
        .map((t) => t['pain_reported'])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList();
    final painMax = pains.isEmpty ? null : pains.reduce((a, b) => a > b ? a : b);
    final compCount = trainings
        .expand((t) => (t['compensations'] as List?) ?? const [])
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .length;

    Widget check(String label, String current, bool? pass) {
      final icon = pass == null
          ? Icons.remove_circle_outline_rounded
          : (pass ? Icons.check_circle_rounded : Icons.cancel_outlined);
      final color = pass == null
          ? AppTheme.textTertiary
          : (pass ? AppTheme.success : AppTheme.warning);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            Text(
              current,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      );
    }

    return _card(
      child: _infoBlock(
        icon: Icons.emoji_events_outlined,
        title: '本阶段达标条件',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            check(
              '动作评分均值 ≥ 80',
              avgScore == null ? '待评估' : avgScore.round().toString(),
              avgScore == null ? null : avgScore >= 80,
            ),
            check(
              '活动度达标度 ≥ 85%',
              romAvg == null ? '待评估' : '${(romAvg * 100).round()}%',
              romAvg == null ? null : romAvg >= 0.85,
            ),
            check(
              '自评疼痛 ≤ 3',
              painMax == null ? '待记录' : '$painMax / 10',
              painMax == null ? null : painMax <= 3,
            ),
            check(
              '无明显代偿',
              compCount == 0 ? '暂无代偿' : '$compCount 项',
              compCount == 0,
            ),
            const SizedBox(height: 6),
            const Text(
              '全部满足且动作完成质量稳定后，完成本轮更容易进阶到下一阶段。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: AppTheme.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int? _expectedDays(Map<String, dynamic> program) {
    final plan = program['current']?['plan'];
    if (plan is! Map) return null;
    final d = plan['expected_duration_days'];
    return d is num && d > 0 ? d.toInt() : null;
  }

  /// E2 阶段地图：保护 → 恢复 → 强化 → 回归，标出当前位置。
  Widget _stageRail(Map<String, dynamic> program) {
    const stages = [
      ('acute', '保护'),
      ('sub_acute', '恢复'),
      ('strengthen', '强化'),
      ('return', '回归'),
    ];
    final type = program['current']?['stage']?['stage_type']?.toString() ?? '';
    var currentIdx = stages.indexWhere((s) => s.$1 == type);
    if (currentIdx < 0) currentIdx = 0;
    return Row(
      children: [
        for (var i = 0; i < stages.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 1.5,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: i <= currentIdx
                    ? AppTheme.mint
                    : Colors.white.withValues(alpha: 0.18),
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: i == currentIdx ? 12 : 9,
                height: i == currentIdx ? 12 : 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < currentIdx
                      ? AppTheme.mint
                      : (i == currentIdx
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.25)),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                stages[i].$2,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: i == currentIdx
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: i == currentIdx
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ],
      ],
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

  /// 生成超过约 2.5 分钟还没完成 → 给出重试出口（B2 兜底）。
  bool get _generatingSlow =>
      _generatingSince != null &&
      DateTime.now().difference(_generatingSince!).inSeconds >= 150;

  Widget _generatingView() {
    final slow = _generatingSlow;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 20),
            const Text(
              '正在生成你的专属方案…',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 14),
            const _GeneratingSteps(),
            const SizedBox(height: 16),
            const Text(
              '可以先返回首页，生成完成后回来查看即可（不会丢）。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.6,
              ),
            ),
            if (slow) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await ProgramApi.generatePlan(widget.programId);
                    if (mounted) _load();
                  } catch (_) {}
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('等得有点久？点这里重新生成'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// E3 结业收尾页：疗程高光时刻——时长、训练次数、平均分 + 再次问诊入口。
  Widget _dischargeView(Map<String, dynamic> v) {
    final stats = v['stats'] is Map
        ? Map<String, dynamic>.from(v['stats'] as Map)
        : const <String, dynamic>{};
    final trainings = stats['trainings_done'];
    final avg = stats['avg_score'];
    var days = 0;
    final created = DateTime.tryParse(v['created_at']?.toString() ?? '');
    if (created != null) {
      days = DateTime.now().difference(created.toLocal()).inDays + 1;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        const SizedBox(height: 36),
        const Center(
          child: AppIconBadge(icon: Icons.celebration_rounded, size: 84),
        ),
        const SizedBox(height: 22),
        const Text(
          '恭喜，本疗程已结业 🎉',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '你已基本恢复。建议继续保持训练习惯；如症状复发或加重，请及时复诊。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13.5,
            color: AppTheme.textSecondary,
            height: 1.7,
          ),
        ),
        const SizedBox(height: 26),
        AppCard(
          child: Column(
            children: [
              _summaryRow('疗程天数', days > 0 ? '$days 天' : '—'),
              _summaryRow('累计完成训练', trainings == null ? '—' : '$trainings 次'),
              _summaryRow('平均得分', avg == null ? '—' : '$avg'),
            ],
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _openHistory,
          icon: const Icon(Icons.timeline_rounded, size: 19),
          label: const Text('回顾康复历程'),
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.of(context).maybePop();
            widget.onStartConsult?.call();
          },
          icon: const Icon(Icons.add_comment_outlined, size: 19),
          label: const Text('再次问诊，开启新疗程'),
        ),
        const SizedBox(height: 10),
        const Text(
          '新的不适或想继续强化，都可以重新问诊生成新方案。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
        ),
      ],
    );
  }

  /// E3 转诊收尾页：说清楚「为什么转、就医带什么、回来怎么办」。
  Widget _referView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        const SizedBox(height: 36),
        const Center(
          child: AppIconBadge(icon: Icons.local_hospital_outlined, size: 84),
        ),
        const SizedBox(height: 22),
        const Text(
          '已建议先线下就医',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '问诊或训练中出现了需要优先排除的情况，请先到医院相关科室检查。\n'
          '就医时可以带上「问诊过程与结果」页作为参考。\n'
          '检查后如果适合居家训练，回来重新问诊即可开启新疗程。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13.5,
            color: AppTheme.textSecondary,
            height: 1.8,
          ),
        ),
        const SizedBox(height: 26),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.of(context).maybePop();
            widget.onStartConsult?.call();
          },
          icon: const Icon(Icons.add_comment_outlined, size: 19),
          label: const Text('就医后重新问诊'),
        ),
      ],
    );
  }

  /// D1/D2/F3 + C7：结论先行 + 一条关键纠正 + 与上次对比 + 历史/回放 + 继续练下一个。
  Widget _resultSheet(
    Map<String, dynamic> item,
    Map<String, dynamic> training,
    Map<String, dynamic>? a,
    String? summary,
  ) {
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
    final score = a['overall_score'];
    final previous = training['previous_score'];
    final focusAdvice = corrections.isNotEmpty
        ? corrections.first
        : (comps.isNotEmpty
              ? comps.first
              : (findings.isNotEmpty ? findings.first : null));
    final next = _nextIncompleteItem(
      exceptVideoId: item['video_id']?.toString(),
    );
    final videoId = item['video_id']?.toString() ?? '';
    final itemTitle = RehabOverview.itemTitle(item);

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
                if (meets == true) ...[
                  const SizedBox(width: 6),
                  _chip('已达本阶段标准'),
                ],
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  score is num ? '${score.round()}' : '—',
                  style: const TextStyle(
                    fontSize: 44,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '综合评分',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _conclusionText(a),
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (previous is num && score is num) ...[
              const SizedBox(height: 8),
              Text(
                '上次 ${previous.round()} 分 → 本次 ${score.round()} 分'
                '（${(score - previous) >= 0 ? '+' : ''}${(score - previous).round()}）',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: score >= previous ? AppTheme.success : AppTheme.warning,
                ),
              ),
            ],
            if (focusAdvice != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: AppTheme.secondaryLight,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '接下来最先改这一点',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.secondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      focusAdvice,
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (romRatio != null || pain != null || meets != null) ...[
              const SizedBox(height: 12),
              if (romRatio is num)
                row('活动度达标度', '${(romRatio * 100).round()}%（相对本阶段目标）'),
              if (pain != null) row('自评疼痛', '$pain / 10'),
              if (meets != null) row('本阶段达标', meets == true ? '已达标' : '未达标'),
            ],
            const SizedBox(height: 6),
            AppDisclosure(
              icon: Icons.tune,
              title: '查看全部指标',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  row('姿势准确度', a['posture_score']),
                  row('关节活动范围', a['range_of_motion']),
                  row('动作节奏', a['rhythm_score']),
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
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AssessHistoryPage(
                          programId: widget.programId,
                          videoId: videoId,
                          title: itemTitle,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.history_rounded, size: 18),
                    label: const Text('历史记录'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AssessReplayPage(
                          taskId: training['task_id']?.toString() ?? '',
                          title: itemTitle,
                        ),
                      ),
                    ),
                    icon: const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 18,
                    ),
                    label: const Text('回看我的视频'),
                  ),
                ),
              ],
            ),
            if (next != null) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                  _train(next);
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: Text('继续练下一个 · ${RehabOverview.itemTitle(next)}'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 一句话人话结论（D1）。
  String _conclusionText(Map<String, dynamic> a) {
    final score = (a['overall_score'] as num?)?.toDouble();
    final meets = a['meets_exit_criteria'];
    final comps = (a['compensations'] as List? ?? const [])
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .toList();
    if (score == null) return '本次评估已完成，看看下面的建议。';
    if (meets == true || (score >= 85 && comps.isEmpty)) {
      return '本次表现很好，保持这个节奏！';
    }
    if (score >= 70) return '整体完成不错，还有小幅提升空间。';
    if (score >= 55) return '基本完成动作，建议放慢速度做稳每一组。';
    return '这次完成有点吃力，可以降低强度、以动作标准为先。';
  }

  /// 下一个还没完成的动作（C7「继续练下一个」）。
  Map<String, dynamic>? _nextIncompleteItem({String? exceptVideoId}) {
    final items = ((_view?['current']?['items'] as List<dynamic>?) ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    for (final it in items) {
      if (exceptVideoId != null &&
          it['video_id']?.toString() == exceptVideoId) {
        continue;
      }
      if (((it['training'] as Map?)?['status']?.toString() ?? 'none') !=
          'done') {
        return it;
      }
    }
    return null;
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

/// 生成等待的步骤提示：文案轮播，让等待有进度感而不是无限转圈（B2）。
class _GeneratingSteps extends StatefulWidget {
  const _GeneratingSteps();

  @override
  State<_GeneratingSteps> createState() => _GeneratingStepsState();
}

class _GeneratingStepsState extends State<_GeneratingSteps> {
  static const _steps = [
    '正在理解你的问诊信息…',
    '正在检索康复知识…',
    '正在编排训练动作和剂量…',
    '正在整理注意事项…',
  ];
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2400), (_) {
      if (mounted) setState(() => _index = (_index + 1) % _steps.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: Text(
        _steps[_index],
        key: ValueKey(_index),
        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
      ),
    );
  }
}
