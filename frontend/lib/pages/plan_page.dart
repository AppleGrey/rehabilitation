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

/// 「康复方案」首页：从后端拉全部疗程列表。
class PlanPage extends StatefulWidget {
  /// 切到本 Tab 时递增，触发重新拉取。
  final int refreshTick;

  const PlanPage({super.key, this.refreshTick = 0});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  List<Map<String, dynamic>> _programs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PlanPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final views = await ProgramApi.listAll();
      // 同步本地历史，便于离线/其它入口
      for (final v in views.reversed) {
        final pid = v['program_id']?.toString();
        if (pid == null || pid.isEmpty) continue;
        final sid = v['session_id']?.toString();
        await ProgramStore.addToHistory(pid, sid);
      }
      if (!mounted) return;
      setState(() {
        _programs = views;
        _loading = false;
      });
    } catch (_) {
      // 后端失败时回退本地历史
      final history = await ProgramStore.loadHistory();
      final views = <Map<String, dynamic>>[];
      for (final item in history) {
        try {
          final v = await ProgramApi.get(item.id);
          views.add({
            ...v,
            '_session_id': item.session ?? v['session_id'],
          });
        } catch (_) {
          await ProgramStore.removeFromHistory(item.id);
        }
      }
      if (!mounted) return;
      setState(() {
        _programs = views;
        _loading = false;
      });
    }
  }

  void _open(Map<String, dynamic> v) {
    final pid = v['program_id']?.toString();
    if (pid == null) return;
    final sid = v['_session_id']?.toString() ?? v['session_id']?.toString();
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => ProgramPage(programId: pid, sessionId: sid),
        ))
        .then((_) => _load());
  }

  Future<void> _delete(Map<String, dynamic> v) async {
    final pid = v['program_id']?.toString();
    if (pid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除方案'),
        content: Text('确定删除「${v['condition'] ?? '该方案'}」？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ProgramApi.delete(pid);
      await ProgramStore.removeFromHistory(pid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  String _statusLabel(Map<String, dynamic> v) {
    final status = v['status']?.toString() ?? '';
    final current = v['current'] as Map<String, dynamic>?;
    final hasPlan = current != null && current['plan'] != null;
    if (status == 'generating') return '生成中';
    if (status == 'active' || hasPlan) return '进行中';
    if (status == 'refer') return '已转诊';
    if (status == 'discharged') return '已结业';
    return status.isEmpty ? '—' : status;
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
              else if (_programs.isEmpty)
                _empty()
              else
                ..._programs.map(_programCard),
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
    final label = _statusLabel(v);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppTheme.bgPrimary, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(v['condition'] as String? ?? '康复方案',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(6)),
              child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textTertiary),
              onPressed: () => _delete(v),
            ),
          ]),
          const SizedBox(height: 12),
          Text(
            status == 'generating'
                ? '方案生成中，稍候刷新即可查看训练动作。'
                : hasPlan
                    ? '当前处于第 ${v['current_stage_no'] ?? 1} 阶段（${_stageLabels[stageType] ?? stageType}），共 ${items.length} 个训练动作。'
                    : '方案尚未就绪。',
            style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.5),
          ),
          if (goals.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: goals.take(3).map((g) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
                    ),
                    child: Text(g, style: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary)),
                  )).toList(),
            ),
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
              onPressed: () => _open(v),
              icon: const Icon(Icons.play_circle_fill, size: 20),
              label: Text(hasPlan ? '查看方案 & 开始训练' : '查看方案',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}
