import 'package:flutter/material.dart';

import '../services/program_api.dart';
import '../services/program_store.dart';
import '../theme/app_theme.dart';
import 'program_page.dart';

const _stageLabels = {
  'acute': '保护期',
  'sub_acute': '恢复期',
  'strengthen': '强化期',
  'return': '回归期',
};

/// 「康复方案」首页：展示用户当前疗程摘要，作为「我的方案」入口。
class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  Map<String, dynamic>? _view;
  String? _programId;
  String? _sessionId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final cur = await ProgramStore.loadCurrent();
    if (cur == null) {
      if (mounted) setState(() { _view = null; _programId = null; _loading = false; });
      return;
    }
    _programId = cur.id;
    _sessionId = cur.session;
    try {
      final v = await ProgramApi.get(cur.id);
      if (!mounted) return;
      setState(() { _view = v; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _view = null; _loading = false; });
    }
  }

  void _open() {
    final pid = _programId;
    if (pid == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => ProgramPage(programId: pid, sessionId: _sessionId),
        ))
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 90),
            children: [
              _header(),
              if (_loading)
                const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator()))
              else if (_view == null)
                _empty()
              else
                _programCard(_view!),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('康复方案',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
            IconButton(
              icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
              onPressed: _loading ? null : _load,
            ),
          ],
        ),
      );

  Widget _empty() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: AppTheme.bgPrimary, borderRadius: BorderRadius.circular(16)),
          child: Column(children: const [
            Icon(Icons.assignment_outlined, size: 48, color: AppTheme.textTertiary),
            SizedBox(height: 14),
            Text('还没有康复方案',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            SizedBox(height: 8),
            Text('先在「问诊」里完成一次 AI 问诊，即可生成属于你的分期康复方案。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: AppTheme.textSecondary, height: 1.6)),
          ]),
        ),
      );

  Widget _programCard(Map<String, dynamic> v) {
    final current = v['current'] as Map<String, dynamic>?;
    final stage = current?['stage'] as Map<String, dynamic>?;
    final items = (current?['items'] as List<dynamic>? ?? []);
    final goals = (stage?['goals'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final stageType = stage?['stage_type'] as String? ?? '';
    final status = v['status'] as String? ?? '';
    final hasPlan = current != null && current['plan'] != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppTheme.bgPrimary, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(
              child: Text(v['condition'] as String? ?? '康复方案',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(6)),
              child: Text(hasPlan ? '进行中' : '待生成',
                  style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
            ),
          ]),
          const SizedBox(height: 12),
          Text(
            hasPlan
                ? '当前处于第 ${v['current_stage_no'] ?? 1} 阶段（${_stageLabels[stageType] ?? stageType}），共 ${items.length} 个训练动作。'
                : '方案尚未生成，去「问诊」完成后即可生成。',
            style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.5),
          ),
          if (goals.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: goals.take(3).map((g) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
                  ),
                  child: Text(g, style: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary)),
                )).toList()),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              onPressed: _open,
              icon: const Icon(Icons.play_circle_fill, size: 20),
              label: Text(hasPlan ? '查看方案 & 开始训练' : '查看方案',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          if (status.isNotEmpty && !hasPlan) ...[
            const SizedBox(height: 6),
            const Text('（状态：待生成方案）', style: TextStyle(fontSize: 11, color: AppTheme.textTertiary)),
          ],
        ]),
      ),
    );
  }
}
