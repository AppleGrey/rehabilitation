import 'package:flutter/material.dart';

import '../services/error_text.dart';
import '../services/program_api.dart';
import '../services/program_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'program_page.dart';
import 'rehab_video_page.dart';

/// 问诊后先出几个基线动作让用户试跟做（录完只存档），再点「生成方案」才建库并异步出方案。
class BaselinePage extends StatefulWidget {
  final String sessionId;

  const BaselinePage({super.key, required this.sessionId});

  @override
  State<BaselinePage> createState() => _BaselinePageState();
}

class _BaselinePageState extends State<BaselinePage> {
  String _message = '';
  List<Map<String, dynamic>> _videos = [];
  Set<String> _recorded = {};
  String? _error;
  bool _loading = true;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ProgramApi.start(widget.sessionId);
      if (!mounted) return;
      final rec = ((r['baseline'] as Map<String, dynamic>?)?['recorded'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toSet();
      setState(() {
        _message = r['message'] as String? ?? '请先跟做以下动作（可选），再点下方生成方案。';
        _videos = (r['baseline_videos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _recorded = rec;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, fallback: '基线动作没加载出来，请重试');
        _loading = false;
      });
    }
  }

  Future<void> _refreshRecorded() async {
    try {
      final r = await ProgramApi.start(widget.sessionId);
      final rec = ((r['baseline'] as Map<String, dynamic>?)?['recorded'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toSet();
      if (mounted) setState(() => _recorded = rec);
    } catch (_) {}
  }

  void _tryVideo(Map<String, dynamic> v) {
    final vid = v['video_id'] as String?;
    if (vid == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (ctx) => RehabVideoPage(
            onBack: () => Navigator.of(ctx).pop(),
            videoId: vid,
            sessionId: widget.sessionId,
            videoTitle: '基线试跟做',
            uploadMode: 'baseline',
            programId: null, // 预览阶段尚未建方案，按 session 存草稿
          ),
        ))
        .then((_) => _refreshRecorded());
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() => _generating = true);
    try {
      final r = await ProgramApi.createAndGenerate(widget.sessionId);
      final pid = r['program_id'] as String?;
      if (pid == null || pid.isEmpty) throw Exception('未返回 program_id');
      await ProgramStore.saveCurrent(pid, widget.sessionId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => ProgramPage(programId: pid, sessionId: widget.sessionId),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e, fallback: '生成方案失败，请稍后重试'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        leading: const AppBackButton(),
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text('试做基线动作',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
      ),
      body: _buildBody(),
      bottomNavigationBar: (_loading || _error != null)
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  onPressed: _generating ? null : _generate,
                  child: _generating
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                        )
                      : Text(_recorded.isEmpty ? '直接生成康复方案' : '根据我的情况生成康复方案',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
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
            ElevatedButton(onPressed: _start, child: const Text('重试')),
          ]),
        ),
      );
    }

    final recordedCount = _videos.where((v) => _recorded.contains(v['video_id'])).length;
    final total = _videos.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        _stepsHeader(total: total, recorded: recordedCount),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.tips_and_updates, color: AppTheme.primaryDark, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '试做 1–2 个动作，AI 会按你实际能做到的程度来定动作和剂量，方案会更贴合你；'
                '不想做也可以跳过后直接生成。'
                '${total > 0 ? '（已试做 $recordedCount/$total）' : ''}',
                style: const TextStyle(fontSize: 13.5, color: AppTheme.primaryDark, height: 1.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
          child: Text('① 先试着跟做（可选）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        ),
        if (_videos.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('暂无匹配的基线动作，可直接生成方案。',
                textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textTertiary)),
          )
        else
          ..._videos.map(_videoCard),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: const Row(children: [
            Icon(Icons.auto_awesome, color: AppTheme.primary, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text('② 点底部按钮生成方案：AI 会结合问诊和试做结果，按阶段排好训练动作。',
                  style: TextStyle(fontSize: 13.5, color: AppTheme.textSecondary, height: 1.5)),
            ),
          ]),
        ),
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text(_message, style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary, height: 1.5)),
          ),
        ],
      ],
    );
  }

  Widget _stepsHeader({required int total, required int recorded}) {
    Widget step(int no, String label, bool active, bool done) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: done ? AppTheme.success : (active ? AppTheme.primary : AppTheme.bgTertiary),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: done
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : Text('$no',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : AppTheme.textTertiary,
                  )),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? AppTheme.textPrimary : AppTheme.textTertiary,
            )),
      ]);
    }

    final baselineDone = total > 0 && recorded >= total;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        step(1, baselineDone ? '试做基线（已完成）' : '试做基线（可选）', !baselineDone, baselineDone),
        const Expanded(child: Divider(indent: 8, endIndent: 8)),
        step(2, '生成方案', baselineDone, false),
      ]),
    );
  }

  Widget _videoCard(Map<String, dynamic> v) {
    final vid = v['video_id'] as String? ?? '';
    final title = v['title'] as String? ?? vid;
    final done = _recorded.contains(vid);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: done ? const Color(0xFFE8F6F1) : AppTheme.primaryLight,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(done ? Icons.check_circle : Icons.self_improvement,
              color: done ? AppTheme.success : AppTheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const SizedBox(height: 4),
            Text(done ? '已录入 ✓ 将用于方案' : (v['difficulty'] != null ? '未试做 · 难度 ${v['difficulty']}' : '未试做（可选）'),
                style: TextStyle(fontSize: 12, color: done ? AppTheme.success : AppTheme.textTertiary)),
          ]),
        ),
        TextButton.icon(
          onPressed: () => _tryVideo(v),
          icon: Icon(done ? Icons.replay : Icons.play_arrow, size: 18),
          label: Text(done ? '重做' : '试跟做'),
          style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
        ),
      ]),
    );
  }
}
