import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../config/api_config.dart';
import '../services/auth_store.dart';
import '../services/error_text.dart';
import '../services/program_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// 某个训练项的历史评估列表（多组训练按组逐条列出）。
class AssessHistoryPage extends StatefulWidget {
  final String programId;
  final String videoId;
  final String title;

  const AssessHistoryPage({
    super.key,
    required this.programId,
    required this.videoId,
    required this.title,
  });

  @override
  State<AssessHistoryPage> createState() => _AssessHistoryPageState();
}

class _AssessHistoryPageState extends State<AssessHistoryPage> {
  List<Map<String, dynamic>> _items = const [];
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
      final list = await ProgramApi.assessHistory(
        widget.programId,
        widget.videoId,
      );
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, fallback: '历史记录没加载出来，请重试');
        _loading = false;
      });
    }
  }

  String _when(String? iso) {
    final at = DateTime.tryParse(iso ?? '');
    if (at == null) return '';
    final local = at.toLocal();
    final now = DateTime.now();
    final hm =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '今天 $hm';
    }
    return '${local.month}月${local.day}日 $hm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(
          '${widget.title} · 历史记录',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const AppLoading(label: '正在读取历史记录');
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
    if (_items.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          SizedBox(height: 40),
          AppEmptyState(
            icon: Icons.history_rounded,
            title: '还没有历史记录',
            body: '完成一次跟练评估后，每一次的结果和视频都会出现在这里。',
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        itemCount: _items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _tile(_items[index]),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> t) {
    final status = t['status']?.toString() ?? '';
    final done = status == 'done';
    final score = t['overall_score'];
    final pain = t['pain_reported'];
    final setNo = (t['set_no'] as num?)?.toInt();
    final setTotal = (t['set_total'] as num?)?.toInt();
    final taskId = t['task_id']?.toString() ?? '';
    final parts = <String>[
      if (_when(t['created_at']?.toString()).isNotEmpty)
        _when(t['created_at']?.toString()),
      if (score is num) '${score.round()} 分',
      if (pain != null) '疼痛 $pain/10',
      if (!done) (status == 'error' ? '评估失败' : '评估中'),
    ];
    return AppCard(
      padding: const EdgeInsets.all(15),
      onTap: (done && taskId.isNotEmpty)
          ? () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AssessReplayPage(
                  taskId: taskId,
                  title: widget.title,
                  setNo: setNo,
                ),
              ),
            )
          : null,
      child: Row(
        children: [
          AppIconBadge(
            icon: done ? Icons.check_rounded : Icons.timelapse_rounded,
            color: done ? AppTheme.success : AppTheme.primary,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (setTotal != null && setTotal > 1 && setNo != null)
                      ? '第 $setNo / $setTotal 组'
                      : widget.title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  parts.join(' · '),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (done)
            const Icon(
              Icons.play_circle_outline_rounded,
              color: AppTheme.primary,
              size: 26,
            ),
        ],
      ),
    );
  }
}

/// 评估结果 + 录像回放：看到「哪一下没做好」。
class AssessReplayPage extends StatefulWidget {
  final String taskId;
  final String title;
  final int? setNo;

  const AssessReplayPage({
    super.key,
    required this.taskId,
    required this.title,
    this.setNo,
  });

  @override
  State<AssessReplayPage> createState() => _AssessReplayPageState();
}

class _AssessReplayPageState extends State<AssessReplayPage> {
  VideoPlayerController? _video;
  Map<String, dynamic>? _task;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final task = await ProgramApi.assessStatus(widget.taskId);
      final video = VideoPlayerController.networkUrl(
        Uri.parse(resolveBackendUrl('/api/uploads/${widget.taskId}/play')),
        httpHeaders: AuthStore.headers(),
      );
      await video.initialize();
      await video.setLooping(true);
      video.addListener(_onVideoTick);
      if (!mounted) {
        await video.dispose();
        return;
      }
      setState(() {
        _task = task;
        _video = video;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, fallback: '视频没有加载出来，请重试');
        _loading = false;
      });
    }
  }

  void _onVideoTick() {
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(
          widget.setNo != null ? '${widget.title} · 第 ${widget.setNo} 组' : widget.title,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const AppLoading(label: '正在加载本次录像');
    final video = _video;
    if (_error != null || video == null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 40),
          AppEmptyState(
            icon: Icons.videocam_off_outlined,
            title: _error ?? '录像暂时打不开',
            body: '上传的录像有时会被清理，评估结果仍然保留。',
            actionLabel: '重试',
            onAction: _load,
          ),
        ],
      );
    }
    final a = _task?['assessment'] is Map
        ? Map<String, dynamic>.from(_task!['assessment'] as Map)
        : <String, dynamic>{};
    final summary = _task?['summary']?.toString() ?? '';
    final findings = (a['key_findings'] as List? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    final corrections = (a['corrections'] as List? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: video.value.aspectRatio == 0
                ? 3 / 4
                : video.value.aspectRatio,
            child: VideoPlayer(video),
          ),
        ),
        const SizedBox(height: 6),
        VideoProgressIndicator(
          video,
          allowScrubbing: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          colors: const VideoProgressColors(playedColor: AppTheme.primary),
        ),
        Row(
          children: [
            IconButton(
              onPressed: () {
                if (video.value.isPlaying) {
                  video.pause();
                } else {
                  video.play();
                }
              },
              icon: Icon(
                video.value.isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
                color: AppTheme.primary,
                size: 34,
              ),
            ),
            Text(
              '${_fmt(video.value.position)} / ${_fmt(video.value.duration)}',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (a['overall_score'] != null)
                    AppPill(
                      label: '本次 ${(a['overall_score'] as num).round()} 分',
                      icon: Icons.insights_rounded,
                    ),
                  if (a['pain_reported'] != null) ...[
                    const SizedBox(width: 8),
                    AppPill(
                      label: '疼痛 ${a['pain_reported']}/10',
                      icon: Icons.favorite_border_rounded,
                      color: AppTheme.secondary,
                      backgroundColor: AppTheme.secondaryLight,
                    ),
                  ],
                ],
              ),
              if (summary.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  summary,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
              if (findings.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  '当时的发现',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textTertiary,
                  ),
                ),
                const SizedBox(height: 6),
                ...findings.map(
                  (f) => Text(
                    '• $f',
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
              if (corrections.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  '当时的纠正建议',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textTertiary,
                  ),
                ),
                const SizedBox(height: 6),
                ...corrections.map(
                  (f) => Text(
                    '• $f',
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
