import 'dart:async';

import 'package:flutter/material.dart';

import '../services/program_api.dart';
import '../theme/app_theme.dart';
import 'consult_report_page.dart';
import 'rehab_video_page.dart';

const _stageLabels = {
  'acute': '保护期',
  'sub_acute': '恢复期',
  'strengthen': '强化期',
  'return': '回归期',
};

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
    final generating = v?['status'] == 'generating' ||
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
    if (vid == null || vid.isEmpty) return;
    final stageNo = (_view?['current_stage_no'] as int?) ?? 1;
    final sid = (_view?['session_id'] as String?) ?? widget.sessionId;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (ctx) => RehabVideoPage(
            onBack: () => Navigator.of(ctx).pop(),
            videoId: vid,
            sessionId: sid,
            videoTitle: '康复训练',
            uploadMode: 'training',
            programId: widget.programId,
            stageNo: stageNo,
          ),
        ))
        .then((_) => _load());
  }

  void _openConsult() {
    final sid = (_view?['session_id'] as String?) ?? widget.sessionId;
    if (sid == null || sid.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConsultReportPage(sessionId: sid),
    ));
  }

  Future<void> _viewResult(Map<String, dynamic> training) async {
    final taskId = training['task_id'] as String?;
    if (taskId == null) return;
    final task = await ProgramApi.assessStatus(taskId);
    final a = task?['assessment'];
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _resultSheet(a is Map<String, dynamic> ? a : null, task?['summary'] as String?),
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
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('好'))],
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('进阶失败：$e')));
    } finally {
      if (mounted) setState(() => _progressing = false);
    }
  }

  String _decisionTitle(String d) => {
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
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text('我的康复方案',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        actions: [
          IconButton(
            icon: const Icon(Icons.assignment_outlined, color: AppTheme.textSecondary),
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: const Text('重试')),
          ]),
        ),
      );
    }

    final v = _view!;
    final status = v['status'] as String? ?? '';
    final current = v['current'] as Map<String, dynamic>?;
    final plan = current?['plan'] as Map<String, dynamic>?;

    if (status == 'discharged') return _dischargeView();
    if (status == 'generating' || current == null || plan == null) return _generatingView();

    final stage = current['stage'] as Map<String, dynamic>?;
    final items = (current['items'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final goals = (stage?['goals'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final precautions = (plan['precautions'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final stageType = stage?['stage_type'] as String? ?? '';
    final allDone = items.isNotEmpty && items.every((it) => it['training']?['status'] == 'done');

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.assignment_turned_in, color: AppTheme.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(child: Text(v['condition'] as String? ?? '康复方案',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
              _chip('第 ${v['current_stage_no'] ?? 1} 阶段 · ${_stageLabels[stageType] ?? stageType}'),
            ]),
            if (goals.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('本阶段目标', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: goals.map(_goalChip).toList()),
            ],
          ])),
          if ((plan['summary_text'] as String? ?? '').isNotEmpty)
            _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('方案说明', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              Text(plan['summary_text'] as String, style: const TextStyle(fontSize: 13.5, color: AppTheme.textSecondary, height: 1.6)),
              if (precautions.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('注意事项', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
                const SizedBox(height: 6),
                ...precautions.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('• ', style: TextStyle(color: AppTheme.warning)),
                        Expanded(child: Text(p, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5))),
                      ]),
                    )),
              ],
            ])),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text('训练动作', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ),
          ...items.asMap().entries.map((e) => _itemCard(e.key + 1, e.value)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: allDone ? AppTheme.primary : AppTheme.bgTertiary,
                foregroundColor: allDone ? Colors.white : AppTheme.textTertiary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              onPressed: (allDone && !_progressing) ? _finishRound : null,
              icon: _progressing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                  : const Icon(Icons.flag, size: 18),
              label: Text(allDone ? '完成本轮训练 · 看下一步' : '完成全部动作后可进入下一步',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 8),
          const Text('温馨提示：训练中疼痛不超过 3 分为度，若明显加重请停止并咨询医生。',
              style: TextStyle(fontSize: 11.5, color: AppTheme.textTertiary, height: 1.5)),
        ],
      ),
    );
  }

  Widget _itemCard(int no, Map<String, dynamic> it) {
    final role = it['role'] as String?;
    final roleLabel = role == 'warmup' ? '热身' : role == 'cooldown' ? '放松' : '主体';
    final training = (it['training'] as Map<String, dynamic>?) ?? {'status': 'none'};
    final tstatus = training['status'] as String? ?? 'none';
    final score = training['overall_score'];

    Widget action;
    if (tstatus == 'done') {
      final rom = training['rom_target_ratio'];
      final comps = (training['compensations'] as List<dynamic>? ?? []);
      action = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (score != null) _badge('$score 分', const Color(0xFFE8F6F1), AppTheme.primaryDark),
          if (rom != null)
            _badge('活动度 ${((rom as num) * 100).round()}%', const Color(0xFFEFF4FF), AppTheme.primaryDark),
          if (comps.isNotEmpty)
            _badge('代偿 ${comps.length} 处', const Color(0xFFFFF3E0), AppTheme.warning),
        ]),
        Row(children: [
          const Spacer(),
          TextButton(onPressed: () => _viewResult(training), child: const Text('查看结果')),
          TextButton(onPressed: () => _train(it), child: const Text('重做')),
        ]),
      ]);
    } else if (tstatus == 'pending' || tstatus == 'processing') {
      action = Row(children: const [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('评估中…', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      ]);
    } else {
      action = SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), elevation: 0,
          ),
          onPressed: () => _train(it),
          icon: const Icon(Icons.play_circle_fill, size: 18),
          label: const Text('去跟练 & 动作评估', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      );
    }

    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 24, height: 24, alignment: Alignment.center,
          decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(12)),
          child: Text('$no', style: const TextStyle(fontSize: 12, color: AppTheme.primaryDark, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text('$roleLabel · ${it['video_id'] ?? ''}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
      ]),
      const SizedBox(height: 8),
      Text(_dosage(it), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      if ((it['notes'] as String? ?? '').isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(it['notes'] as String, style: const TextStyle(fontSize: 12.5, color: AppTheme.textTertiary)),
      ],
      const SizedBox(height: 12),
      action,
    ]));
  }

  Widget _generatingView() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: const [
          CircularProgressIndicator(),
          SizedBox(height: 18),
          Text('方案生成中…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          SizedBox(height: 8),
          Text('正在结合你的问诊与基线表现制定方案，请稍候。',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _dischargeView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: const [
            Icon(Icons.celebration, size: 56, color: AppTheme.primary),
            SizedBox(height: 16),
            Text('恭喜，本疗程已结业', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            SizedBox(height: 10),
            Text('你已基本恢复。建议继续保持训练习惯；如症状复发或加重，请及时复诊。',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: AppTheme.textSecondary, height: 1.6)),
          ]),
        ),
      );

  Widget _resultSheet(Map<String, dynamic>? a, String? summary) {
    if (a == null) {
      return const Padding(padding: EdgeInsets.all(28), child: Text('暂无评估详情', textAlign: TextAlign.center));
    }
    Widget row(String label, dynamic val) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            Text('${val ?? '-'}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ]),
        );
    final findings = (a['key_findings'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final corrections = (a['corrections'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final comps = (a['compensations'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final romRatio = a['rom_target_ratio'];
    final pain = a['pain_reported'];
    final meets = a['meets_exit_criteria'];
    final grounded = (a['kg_sources'] as List<dynamic>? ?? []).isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('动作评估', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(width: 8),
          if (grounded) _chip('已对照知识图谱标准'),
        ]),
        const SizedBox(height: 12),
        row('综合评分', a['overall_score']),
        row('姿势准确度', a['posture_score']),
        row('关节活动范围', a['range_of_motion']),
        row('动作节奏', a['rhythm_score']),
        if (romRatio != null)
          row('活动度达标度', '${(( romRatio as num) * 100).round()}%（相对本阶段目标）'),
        if (pain != null) row('自评疼痛', '$pain / 10'),
        if (meets != null) row('本阶段达标', meets == true ? '已达标' : '未达标'),
        if (comps.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('观察到的代偿', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
          ...comps.map((f) => Text('• $f', style: const TextStyle(fontSize: 13, color: AppTheme.warning, height: 1.5))),
        ],
        if (findings.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('关键发现', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
          ...findings.map((f) => Text('• $f', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5))),
        ],
        if (corrections.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('纠正建议', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
          ...corrections.map((f) => Text('• $f', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5))),
        ],
        if ((summary ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(summary!, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.6)),
        ],
      ]),
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
    if (it['load'] != null && '${it['load']}'.isNotEmpty) parts.add('${it['load']}');
    return parts.join(' · ');
  }

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: child,
      );

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(fontSize: 11, color: AppTheme.primaryDark, fontWeight: FontWeight.w600)),
      );

  Widget _badge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w600)),
      );

  Widget _goalChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.bgSecondary,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary)),
      );
}
