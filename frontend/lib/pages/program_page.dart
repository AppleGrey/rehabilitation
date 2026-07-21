import 'package:flutter/material.dart';

import '../services/program_api.dart';
import '../theme/app_theme.dart';
import 'rehab_video_page.dart';

const _stageLabels = {
  'acute': '保护期',
  'sub_acute': '恢复期',
  'strengthen': '强化期',
  'return': '回归期',
};

/// 「我的康复方案」——查看当前分期方案、训练项，并进入跟练。
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final v = await ProgramApi.get(widget.programId);
      if (!mounted) return;
      setState(() {
        _view = v;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _train(Map<String, dynamic> item) {
    final vid = item['video_id'] as String?;
    if (vid == null || vid.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => RehabVideoPage(
        onBack: () => Navigator.of(ctx).pop(),
        videoId: vid,
        sessionId: widget.sessionId,
        videoTitle: '康复训练',
      ),
    ));
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
    final current = v['current'] as Map<String, dynamic>?;
    final stage = current?['stage'] as Map<String, dynamic>?;
    final plan = current?['plan'] as Map<String, dynamic>?;
    final items = (current?['items'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    if (current == null || plan == null) {
      return _emptyPlan(v['status'] as String?);
    }

    final goals = (stage?['goals'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final precautions = (plan['precautions'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final stageType = stage?['stage_type'] as String? ?? '';

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          _card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.assignment_turned_in, color: AppTheme.primary, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(v['condition'] as String? ?? '康复方案',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                ),
                _chip('第 ${v['current_stage_no'] ?? 1} 阶段 · ${_stageLabels[stageType] ?? stageType}'),
              ]),
              if (goals.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('本阶段目标', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: goals.map((g) => _goalChip(g)).toList()),
              ],
            ]),
          ),
          if ((plan['summary_text'] as String? ?? '').isNotEmpty)
            _card(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('方案说明',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                Text(plan['summary_text'] as String,
                    style: const TextStyle(fontSize: 13.5, color: AppTheme.textSecondary, height: 1.6)),
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
              ]),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text('训练动作',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ),
          ...items.asMap().entries.map((e) => _itemCard(e.key + 1, e.value)),
          const SizedBox(height: 8),
          const Text(
            '温馨提示：训练中疼痛不超过 3 分为度，若明显加重请停止并咨询医生。',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textTertiary, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _emptyPlan(String? status) {
    final msg = status == 'baseline_pending'
        ? '还没有正式方案。请先完成基线动作试跟做，再生成方案。'
        : '暂无方案内容。';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary, height: 1.6)),
      ),
    );
  }

  Widget _itemCard(int no, Map<String, dynamic> it) {
    final title = (it['role'] as String?) == 'warmup'
        ? '热身'
        : (it['role'] as String?) == 'cooldown'
            ? '放松'
            : '主体';
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 24, height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(12)),
            child: Text('$no', style: const TextStyle(fontSize: 12, color: AppTheme.primaryDark, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('$title · ${it['video_id'] ?? ''}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(_dosage(it), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        if ((it['notes'] as String? ?? '').isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(it['notes'] as String, style: const TextStyle(fontSize: 12.5, color: AppTheme.textTertiary)),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            onPressed: () => _train(it),
            icon: const Icon(Icons.play_circle_fill, size: 18),
            label: const Text('去跟练 & 动作评估', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
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
