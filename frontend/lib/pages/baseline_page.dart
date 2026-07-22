import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/program_api.dart';
import '../services/program_store.dart';
import '../theme/app_theme.dart';
import 'program_page.dart';
import 'rehab_video_page.dart';

/// 问诊后先出几个基线动作让用户试跟做，再据表现 + 问诊生成正式方案。
class BaselinePage extends StatefulWidget {
  final String sessionId;

  const BaselinePage({super.key, required this.sessionId});

  @override
  State<BaselinePage> createState() => _BaselinePageState();
}

class _BaselinePageState extends State<BaselinePage> {
  String? _programId;
  String _message = '';
  List<Map<String, dynamic>> _videos = [];
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
      setState(() {
        _programId = r['program_id'] as String?;
        _message = r['message'] as String? ?? '请先跟做以下动作，我会据此为你生成方案。';
        _videos = (r['baseline_videos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
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

  void _tryVideo(Map<String, dynamic> v) {
    final vid = v['video_id'] as String?;
    if (vid == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => RehabVideoPage(
        onBack: () => Navigator.of(ctx).pop(),
        videoId: vid,
        sessionId: widget.sessionId,
        videoTitle: '基线试跟做',
      ),
    ));
  }

  Future<void> _generate() async {
    final pid = _programId;
    if (pid == null || _generating) return;
    setState(() => _generating = true);
    try {
      final baseline = await _collectBaselineResults();
      await ProgramApi.generatePlan(pid, baseline: baseline.isEmpty ? null : baseline);
      await ProgramStore.saveCurrent(pid, widget.sessionId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => ProgramPage(programId: pid, sessionId: widget.sessionId),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('生成方案失败：$e')));
    }
  }

  /// 从本地记录的评估任务里，收集已完成的基线跟做表现，回喂给方案生成。
  Future<List<Map<String, dynamic>>> _collectBaselineResults() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <Map<String, dynamic>>[];
    for (final v in _videos) {
      final vid = v['video_id'] as String?;
      if (vid == null) continue;
      final taskId = prefs.getString('assess_task_${widget.sessionId}_$vid');
      if (taskId == null) continue;
      final task = await ProgramApi.assessStatus(taskId);
      if (task == null || task['status'] != 'done') continue;
      final a = task['assessment'];
      if (a is! Map) continue;
      final findings = (a['key_findings'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
      out.add({
        'video_id': vid,
        'overall_score': a['overall_score'],
        'range_of_motion': a['range_of_motion'],
        'notes': findings.isNotEmpty ? findings.join('；') : (task['summary'] ?? ''),
      });
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text('基线评估',
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
                  onPressed: _programId == null || _generating ? null : _generate,
                  child: _generating
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                        )
                      : const Text('根据我的情况生成康复方案',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.primaryLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Icon(Icons.tips_and_updates, color: AppTheme.primaryDark, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(_message, style: const TextStyle(fontSize: 13.5, color: AppTheme.primaryDark, height: 1.5))),
          ]),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
          child: Text('先试着跟做（可选）',
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
      ],
    );
  }

  Widget _videoCard(Map<String, dynamic> v) {
    final title = v['title'] as String? ?? v['video_id'] as String? ?? '动作';
    final diff = v['difficulty'];
    final dur = v['duration_seconds'];
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
          decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.self_improvement, color: AppTheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const SizedBox(height: 4),
            Text([
              if (diff != null) '难度 $diff',
              if (dur != null) '${dur}s',
            ].join(' · '), style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
          ]),
        ),
        TextButton.icon(
          onPressed: () => _tryVideo(v),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('试跟做'),
          style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
        ),
      ]),
    );
  }
}
