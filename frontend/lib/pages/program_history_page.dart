import 'package:flutter/material.dart';

import '../services/error_text.dart';
import '../services/program_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'assess_history_page.dart';

const _stageLabels = {
  'acute': '保护期',
  'sub_acute': '恢复期',
  'strengthen': '强化期',
  'return': '回归期',
};

/// K2 康复历程：一个方案按「轮」回看——每轮练了什么、得多少分、为什么进阶/保持。
/// 一轮 = 一版阶段方案；点轮内训练可回放当次录像并看当时评测。
class ProgramHistoryPage extends StatefulWidget {
  final String programId;

  const ProgramHistoryPage({super.key, required this.programId});

  @override
  State<ProgramHistoryPage> createState() => _ProgramHistoryPageState();
}

class _ProgramHistoryPageState extends State<ProgramHistoryPage> {
  List<Map<String, dynamic>> _rounds = const [];
  bool _loading = true;
  String? _error;

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
      final rounds = await ProgramApi.rounds(widget.programId);
      if (!mounted) return;
      setState(() {
        _rounds = rounds.reversed.toList(); // 新的在前
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, fallback: '康复历程没加载出来，请重试');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: const AppBackButton(), title: const Text('康复历程')),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const AppLoading(label: '正在读取康复历程');
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 40),
          AppEmptyState(
            icon: Icons.cloud_off_outlined,
            title: _error!,
            body: '请检查网络后重试，训练记录不会丢失。',
            actionLabel: '重新加载',
            onAction: _load,
          ),
        ],
      );
    }
    if (_rounds.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          SizedBox(height: 40),
          AppEmptyState(
            icon: Icons.route_rounded,
            title: '还没有轮次记录',
            body: '方案生成并完成第一轮训练后，这里会按轮展示训练与进阶决策。',
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        itemCount: _rounds.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _roundCard(_rounds[index]),
      ),
    );
  }

  ({String label, Color color, Color bg}) _decisionStyle(String? d) {
    switch (d) {
      case 'advance':
        return (label: '进阶', color: AppTheme.success, bg: AppTheme.primaryLight);
      case 'hold':
        return (
          label: '本阶段再巩固',
          color: AppTheme.primaryDark,
          bg: AppTheme.primaryLight,
        );
      case 'regress':
        return (
          label: '强度回退',
          color: AppTheme.warning,
          bg: AppTheme.secondaryLight,
        );
      case 'refer':
        return (label: '已转诊', color: AppTheme.error, bg: const Color(0xFFFBE9E9));
      case 'discharge':
        return (
          label: '结业',
          color: AppTheme.secondary,
          bg: AppTheme.secondaryLight,
        );
      default:
        return (
          label: '进行中',
          color: AppTheme.textSecondary,
          bg: AppTheme.bgTertiary,
        );
    }
  }

  IconData _decisionIcon(String? d) {
    switch (d) {
      case 'advance':
        return Icons.trending_up_rounded;
      case 'hold':
        return Icons.refresh_rounded;
      case 'regress':
        return Icons.trending_down_rounded;
      case 'refer':
        return Icons.local_hospital_outlined;
      case 'discharge':
        return Icons.celebration_rounded;
      default:
        return Icons.timelapse_rounded;
    }
  }

  String _fmtDate(Object? iso, {bool withTime = false}) {
    final at = DateTime.tryParse(iso?.toString() ?? '');
    if (at == null) return '';
    final local = at.toLocal();
    if (!withTime) return '${local.month}月${local.day}日';
    final hm =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '${local.month}月${local.day}日 $hm';
  }

  List<String> _metricChips(Map<String, dynamic> m) {
    final chips = <String>[];
    final avg = m['avg_overall_score'];
    if (avg is num) chips.add('均分 ${avg.round()}');
    final pain = m['pain_max'];
    if (pain is num) chips.add('最高疼痛 ${pain.round()}/10');
    final rom = m['rom_ratio_avg'];
    if (rom is num) chips.add('活动度达标 ${(rom * 100).round()}%');
    final done = m['items_assessed'];
    final prescribed = m['items_prescribed'];
    if (done is num && prescribed is num && prescribed > 0) {
      chips.add('完成 ${done.round()}/${prescribed.round()} 项');
    }
    return chips;
  }

  Widget _roundCard(Map<String, dynamic> r) {
    final decision = r['decision']?.toString();
    final style = _decisionStyle(decision);
    final stageType = r['stage_type']?.toString() ?? '';
    final stageLabel =
        _stageLabels[stageType] ?? r['stage_label']?.toString() ?? '';
    final header = [
      '第 ${r['round_no'] ?? '-'} 轮',
      if (stageLabel.isNotEmpty) stageLabel,
    ].join(' · ');
    final started = _fmtDate(r['started_at'], withTime: true);
    final ended = _fmtDate(r['ended_at'], withTime: true);
    final inProgress = r['in_progress'] == true;
    final range = inProgress
        ? (started.isEmpty ? '进行中' : '$started 开始')
        : [started, ended].where((s) => s.isNotEmpty).join(' – ');
    final rationale = r['rationale']?.toString() ?? '';
    final metrics = r['metrics'] is Map
        ? Map<String, dynamic>.from(r['metrics'] as Map)
        : const <String, dynamic>{};
    final chips = _metricChips(metrics);
    final trainings = (r['trainings'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconBadge(
                icon: _decisionIcon(decision),
                color: style.color,
                backgroundColor: style.bg,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      header,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (range.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        range,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AppPill(
                label: style.label,
                color: style.color,
                backgroundColor: style.bg,
              ),
            ],
          ),
          if (rationale.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              rationale,
              style: const TextStyle(
                fontSize: 13,
                height: 1.55,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final c in chips) AppPill(label: c)],
            ),
          ],
          const Divider(height: 24),
          if (trainings.isEmpty)
            const Text(
              '这一轮还没有训练记录',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textTertiary),
            )
          else
            ...trainings.map(_trainingRow),
        ],
      ),
    );
  }

  Widget _trainingRow(Map<String, dynamic> t) {
    final status = t['status']?.toString() ?? '';
    final done = status == 'done';
    final taskId = t['task_id']?.toString() ?? '';
    final title = t['title']?.toString() ?? '训练动作';
    final setNo = (t['set_no'] as num?)?.toInt();
    final setTotal = (t['set_total'] as num?)?.toInt();
    final score = t['score'];
    final pain = t['pain_reported'];
    final parts = <String>[
      if (setTotal != null && setTotal > 1) '第 ${setNo ?? 1}/$setTotal 组',
      if (done && score is num) '${score.round()} 分',
      if (pain != null) '疼痛 $pain/10',
      if (!done) (status == 'error' ? '评估失败' : '评估中'),
      _fmtDate(t['created_at'], withTime: true),
    ].where((s) => s.isNotEmpty).toList();

    final canReplay = done && taskId.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canReplay
            ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AssessReplayPage(
                      taskId: taskId,
                      title: title,
                      setNo: setTotal != null && setTotal > 1 ? setNo : null,
                    ),
                  ),
                )
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              AppIconBadge(
                icon: done
                    ? Icons.check_rounded
                    : (status == 'error'
                          ? Icons.error_outline_rounded
                          : Icons.timelapse_rounded),
                color: done
                    ? AppTheme.success
                    : (status == 'error' ? AppTheme.error : AppTheme.primary),
                size: 32,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      parts.join(' · '),
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (canReplay)
                const Icon(
                  Icons.play_circle_outline_rounded,
                  color: AppTheme.primary,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
