import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/rehab_overview.dart';
import '../theme/app_theme.dart';
import 'program_page.dart';

/// 跟练式首页：今天做什么、做到哪一步，没有方案就去问诊。
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
        .push(MaterialPageRoute<void>(
          builder: (_) => ProgramPage(
            programId: pid,
            sessionId: program['session_id']?.toString(),
          ),
        ))
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final name = AuthStore.user?.displayName ?? '你好';
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6F5),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: AppTheme.primary,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              _greeting(name),
              const SizedBox(height: 18),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                _messageCard(
                  title: _error!,
                  body: '下拉可以重试。网络恢复后，首页会显示你的真实训练进度。',
                  action: '重试',
                  onTap: _load,
                )
              else
                ..._body(_overview!),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(RehabOverview overview) {
    final focus = overview.focus;
    if (focus == null) {
      return [
        _messageCard(
          title: '先做一次问诊',
          body: overview.programs.isEmpty
              ? '还没有康复方案。问诊之后，这里会变成你的今日训练。'
              : '上一份方案已经结束。想继续练，可以再问诊一次，生成新的方案。',
          action: '去问诊',
          onTap: widget.onConsult,
          accent: true,
        ),
      ];
    }
    final items = overview.itemsOf(focus);
    final done = overview.doneOf(focus);
    final total = items.length;
    final generating = focus['status']?.toString() == 'generating';
    final remaining = (total - done).clamp(0, total);
    return [
      _hero(focus, done: done, total: total, generating: generating, remaining: remaining),
      const SizedBox(height: 22),
      const Text(
        '本期动作',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
      ),
      const SizedBox(height: 10),
      if (generating || items.isEmpty)
        _messageCard(
          title: generating ? '方案正在生成' : '这一期还没有动作',
          body: '生成完成后，动作会出现在这里。你可以先去方案页看进度。',
          action: '查看方案',
          onTap: () => _openProgram(focus),
        )
      else
        ...items.map((item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _actionTile(item, () => _openProgram(focus)),
            )),
    ];
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
                '你好，$name',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppTheme.textPrimary, height: 1.15),
              ),
              const SizedBox(height: 4),
              Text(
                '${now.month}月${now.day}日 星期${weeks[now.weekday - 1]}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppTheme.primaryLight,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.self_improvement, color: AppTheme.primary),
        ),
      ],
    );
  }

  Widget _hero(
    Map<String, dynamic> program, {
    required int done,
    required int total,
    required bool generating,
    required int remaining,
  }) {
    final ratio = total == 0 ? 0.0 : done / total;
    final title = RehabOverview.programTitle(program);
    final cta = generating
        ? '查看方案'
        : remaining == 0 && total > 0
            ? '去确认进阶'
            : '继续训练';
    final hint = generating
        ? '正在根据问诊结果安排这一期动作'
        : total == 0
            ? RehabOverview.stageLabel(program)
            : remaining == 0
                ? '本期动作都练过了'
                : '还剩 $remaining 个动作';
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF14B89A), Color(0xFF067A64)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: AppTheme.primary.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 12)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint, style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 13)),
          const SizedBox(height: 6),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, height: 1.2)),
          const SizedBox(height: 4),
          Text(RehabOverview.stageLabel(program), style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                total == 0 ? '—' : '$done / $total',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: total == 0 ? null : ratio,
                    minHeight: 8,
                    backgroundColor: Colors.white.withValues(alpha: 0.25),
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF067A64),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () => _openProgram(program),
              child: Text(cta, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile(Map<String, dynamic> item, VoidCallback onTap) {
    final training = item['training'];
    final status = training is Map ? training['status']?.toString() ?? 'none' : 'none';
    final done = status == 'done';
    final score = training is Map ? training['overall_score'] : null;
    final dose = _dose(item);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: done ? const Color(0xFFE8F8EF) : AppTheme.primaryLight,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  done ? Icons.check_rounded : Icons.play_arrow_rounded,
                  color: done ? AppTheme.success : AppTheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      RehabOverview.itemTitle(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      done && score != null ? '已完成 · $score 分' : (done ? '已完成' : dose),
                      style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  String _dose(Map<String, dynamic> item) {
    final sets = item['sets'];
    final reps = item['reps'];
    if (sets != null && reps != null) return '$sets 组 × $reps 次';
    final freq = item['frequency']?.toString() ?? '';
    return freq.isEmpty ? '待完成' : freq;
  }

  Widget _messageCard({
    required String title,
    required String body,
    required String action,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
      decoration: BoxDecoration(
        color: accent ? null : Colors.white,
        gradient: accent
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF14B89A), Color(0xFF067A64)],
              )
            : null,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(accent ? Icons.forum_outlined : Icons.hourglass_top_rounded, color: accent ? Colors.white : AppTheme.primary, size: 28),
          const SizedBox(height: 14),
          Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: accent ? Colors.white : AppTheme.textPrimary)),
          const SizedBox(height: 8),
          Text(body, style: TextStyle(fontSize: 14, height: 1.5, color: accent ? Colors.white.withValues(alpha: 0.9) : AppTheme.textSecondary)),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accent ? Colors.white : AppTheme.primary,
                foregroundColor: accent ? const Color(0xFF067A64) : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: onTap,
              child: Text(action, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
