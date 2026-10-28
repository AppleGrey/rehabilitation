import 'package:flutter/material.dart';

import '../services/program_api.dart';
import '../services/program_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';
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
  final _search = TextEditingController();
  List<Map<String, dynamic>> _programs = [];
  bool _loading = true;
  String _filter = 'all';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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
          views.add({...v, '_session_id': item.session ?? v['session_id']});
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
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ProgramPage(programId: pid, sessionId: sid),
          ),
        )
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已删除')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
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

  List<Map<String, dynamic>> get _visiblePrograms {
    final query = _search.text.trim().toLowerCase();
    return _programs.where((program) {
      final status = program['status']?.toString() ?? '';
      final matchesFilter = switch (_filter) {
        'active' => status == 'active' || status == 'generating',
        'finished' => status == 'discharged' || status == 'refer',
        _ => true,
      };
      if (!matchesFilter) return false;
      if (query.isEmpty) return true;
      final text = [
        program['condition'],
        program['body_part'],
        program['current']?['stage']?['stage_type'],
      ].map((value) => value?.toString() ?? '').join(' ').toLowerCase();
      return text.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visiblePrograms;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              AppPageHeader(
                eyebrow: 'MY REHAB PLAN',
                title: '康复方案',
                subtitle: _loading
                    ? '正在同步你的方案'
                    : '共 ${_programs.length} 个疗程，记录每一步恢复',
                actions: [
                  IconButton.filledTonal(
                    tooltip: '刷新方案',
                    style: IconButton.styleFrom(
                      backgroundColor: AppTheme.primaryLight,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    onPressed: _loading ? null : _load,
                  ),
                ],
              ),
              const SizedBox(height: 22),
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '搜索部位或方案名称',
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: AppTheme.textTertiary,
                  ),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          onPressed: () => setState(() => _search.clear()),
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                ),
              ),
              const SizedBox(height: 14),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('all', '全部方案', _programs.length),
                    _filterChip(
                      'active',
                      '进行中',
                      _programs
                          .where(
                            (p) =>
                                ['active', 'generating'].contains(p['status']),
                          )
                          .length,
                    ),
                    _filterChip(
                      'finished',
                      '已结束',
                      _programs
                          .where(
                            (p) =>
                                ['discharged', 'refer'].contains(p['status']),
                          )
                          .length,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_loading)
                const AppLoading()
              else if (_programs.isEmpty)
                const AppEmptyState(
                  icon: Icons.assignment_outlined,
                  title: '还没有康复方案',
                  body: '在「问诊」中描述你的情况，完成问诊后即可生成专属分期方案。',
                )
              else if (visible.isEmpty)
                AppEmptyState(
                  icon: Icons.manage_search_rounded,
                  title: '没有找到匹配的方案',
                  body: '换个关键词或筛选条件试试。',
                  actionLabel: '清除筛选',
                  onAction: () => setState(() {
                    _search.clear();
                    _filter = 'all';
                  }),
                )
              else
                ...visible.map(_programCard),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterChip(String value, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label  $count'),
        selected: _filter == value,
        showCheckmark: false,
        labelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: _filter == value ? Colors.white : AppTheme.textSecondary,
        ),
        onSelected: (_) => setState(() => _filter = value),
      ),
    );
  }

  Widget _programCard(Map<String, dynamic> v) {
    final current = v['current'] as Map<String, dynamic>?;
    final stage = current?['stage'] as Map<String, dynamic>?;
    final items = (current?['items'] as List<dynamic>? ?? []);
    final goals = (stage?['goals'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final stageType = stage?['stage_type'] as String? ?? '';
    final status = v['status'] as String? ?? '';
    final hasPlan = current != null && current['plan'] != null;
    final label = _statusLabel(v);

    final done = items.where((item) {
      final training = (item as Map)['training'];
      return training is Map && training['status'] == 'done';
    }).length;
    final progress = items.isEmpty ? 0.0 : done / items.length;
    final isOpen = status == 'active' || status == 'generating' || hasPlan;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _open(v),
          borderRadius: BorderRadius.circular(22),
          child: AppCard(
            padding: const EdgeInsets.fromLTRB(18, 18, 10, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppIconBadge(
                      icon: isOpen
                          ? Icons.spa_outlined
                          : Icons.emoji_events_outlined,
                      color: isOpen ? AppTheme.primary : AppTheme.secondary,
                      backgroundColor: isOpen
                          ? AppTheme.primaryLight
                          : AppTheme.secondaryLight,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            v['condition'] as String? ?? '康复方案',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 7),
                          AppPill(
                            label: label,
                            icon: status == 'generating'
                                ? Icons.auto_awesome_rounded
                                : null,
                            color: isOpen
                                ? AppTheme.primary
                                : AppTheme.textSecondary,
                            backgroundColor: isOpen
                                ? AppTheme.primaryLight
                                : AppTheme.bgSecondary,
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '方案操作',
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        color: AppTheme.textTertiary,
                      ),
                      onSelected: (value) {
                        if (value == 'open') _open(v);
                        if (value == 'delete') _delete(v);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'open', child: Text('查看方案')),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            '删除方案',
                            style: TextStyle(color: AppTheme.error),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  status == 'generating'
                      ? '正在结合问诊与基线情况，为你安排训练动作。'
                      : hasPlan
                      ? '第 ${v['current_stage_no'] ?? 1} 阶段 · ${_stageLabels[stageType] ?? stageType} · ${items.length} 个动作'
                      : '方案尚未就绪，请稍后刷新。',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.5,
                  ),
                ),
                if (hasPlan) ...[
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Expanded(
                        child: AppProgressBar(value: progress, height: 6),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '$done/${items.length}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primary,
                        ),
                      ),
                    ],
                  ),
                ],
                if (goals.isNotEmpty) ...[
                  const SizedBox(height: 15),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: goals
                        .take(2)
                        .map(
                          (goal) => AppPill(
                            label: goal,
                            color: AppTheme.textSecondary,
                            backgroundColor: AppTheme.bgSecondary,
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: [
                      Text(
                        hasPlan ? '查看详情，继续训练' : '查看方案详情',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryDark,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryDark,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          status == 'generating'
                              ? Icons.schedule_rounded
                              : Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
