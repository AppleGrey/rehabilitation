import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../config/api_config.dart';
import '../pose/follow_models.dart';
import '../pose/keypoint_counter.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/follow_live_stage.dart';

class FreeFollowPage extends StatefulWidget {
  final VoidCallback onBack;

  const FreeFollowPage({super.key, required this.onBack});

  @override
  State<FreeFollowPage> createState() => _FreeFollowPageState();
}

class _ActionItem {
  const _ActionItem({
    required this.videoId,
    required this.title,
    required this.detail,
    required this.hasRule,
  });

  final String videoId;
  final String title;
  final String detail;
  final bool hasRule;
}

class _FreeFollowPageState extends State<FreeFollowPage> {
  final _search = TextEditingController();
  List<_ActionItem> _actions = const [];
  bool _loading = true;
  String? _error;

  _ActionItem? _selected;
  VideoPlayerController? _video;
  CameraController? _camera;
  MotionStandard? _rule;
  KeypointCounter? _counter;
  int _count = 0;
  String? _followNote;
  bool _starting = false;
  List<_DemoCue> _cues = const [];
  int _cueIndex = 0;
  bool _waiting = false;
  bool _syncing = false;
  CyclePeak? _waitPeak;
  DateTime? _waitSince;
  DateTime? _holdSince;
  bool _attempted = false;
  DateTime? _resumeGuard;
  String? _banner;
  int _bannerSerial = 0;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _video?.removeListener(_onVideo);
    _search.dispose();
    _video?.dispose();
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final videosResponse = await http
          .get(Uri.parse(resolveBackendUrl('/api/videos?limit=500')))
          .timeout(const Duration(seconds: 20));
      if (videosResponse.statusCode != 200) {
        throw Exception('动作列表加载失败（${videosResponse.statusCode}）');
      }
      final listed = jsonDecode(videosResponse.body) as Map<String, dynamic>;
      final videos = (listed['videos'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      var ruled = <String>{};
      try {
        final rulesResponse = await http
            .get(Uri.parse('$kBackendBase/api/admin/motion-rules'))
            .timeout(const Duration(seconds: 8));
        if (rulesResponse.statusCode == 200) {
          final data = jsonDecode(rulesResponse.body) as Map<String, dynamic>;
          ruled = (data['video_ids'] as List<dynamic>? ?? const [])
              .map((item) => item.toString())
              .toSet();
        }
      } catch (_) {}
      final actions = [
        for (final video in videos)
          if ((video['url'] as String?)?.isNotEmpty ?? false)
            _ActionItem(
              videoId: video['video_id']?.toString() ?? '',
              title: _titleOf(video),
              detail: [video['target_joint'], video['description_cn']]
                  .whereType<String>()
                  .where((item) => item.isNotEmpty)
                  .join(' · '),
              hasRule: ruled.contains(video['video_id']?.toString()),
            ),
      ].where((item) => item.videoId.isNotEmpty).toList();
      actions.sort((a, b) {
        if (a.hasRule != b.hasRule) return a.hasRule ? -1 : 1;
        return a.title.compareTo(b.title);
      });
      if (!mounted) return;
      setState(() {
        _actions = actions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  String _titleOf(Map<String, dynamic> video) {
    final keywords = video['action_keywords'];
    if (keywords is List) {
      for (final item in keywords) {
        final text = item.toString().trim();
        if (text.isNotEmpty) return text;
      }
    }
    final description = video['description_cn']?.toString().trim() ?? '';
    if (description.isNotEmpty) return description;
    return video['video_id']?.toString() ?? '未命名动作';
  }

  List<_ActionItem> get _visible {
    final query = _search.text.trim();
    if (query.isEmpty) return _actions;
    return _actions
        .where(
          (item) =>
              '${item.title} ${item.detail} ${item.videoId}'.contains(query),
        )
        .toList();
  }

  Future<void> _open(_ActionItem action) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final rule = await _fetchRule(action.videoId);
      final video = VideoPlayerController.networkUrl(
        Uri.parse(resolveBackendUrl('/api/videos/${action.videoId}/play')),
      );
      CameraController? camera;
      try {
        await video.initialize();
        await video.setVolume(0);
        final cues = rule == null ? const <_DemoCue>[] : _cuesFor(rule);
        await video.setLooping(cues.isEmpty);
        if (cues.isNotEmpty && rule != null && rule.tStart > Duration.zero) {
          await video.seekTo(rule.tStart);
        }
        final cameras = await availableCameras();
        if (cameras.isEmpty) throw Exception('没有可用的摄像头');
        final front = cameras.firstWhere(
          (item) => item.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.first,
        );
        camera = CameraController(
          front,
          ResolutionPreset.medium,
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
          enableAudio: false,
        );
        await camera.initialize();
        _rule = rule;
        _cues = cues;
        _cueIndex = 0;
        _waiting = false;
        _waitPeak = null;
        _syncing = false;
        _resumeGuard = null;
        _count = 0;
        _video = video;
        video.addListener(_onVideo);
        await video.play();
      } catch (_) {
        video.removeListener(_onVideo);
        if (identical(_video, video)) _video = null;
        await video.dispose();
        await camera?.dispose();
        rethrow;
      }
      if (!mounted) {
        video.removeListener(_onVideo);
        _video = null;
        await video.dispose();
        await camera.dispose();
        return;
      }
      setState(() {
        _selected = action;
        _video = video;
        _camera = camera;
        _rule = rule;
        _counter = rule != null && _cues.isEmpty ? KeypointCounter(rule) : null;
        _followNote = rule == null ? '这个动作还没有评分规则，先跟着做' : null;
        _starting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _starting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<MotionStandard?> _fetchRule(String videoId) async {
    try {
      final response = await http
          .get(Uri.parse('$kBackendBase/api/motion-rules/$videoId'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final raw = data['rule'] as Map<String, dynamic>? ?? data;
      final rule = MotionStandard.fromJson(raw);
      if (!rule.metrics.any((metric) => metric.enabled)) return null;
      return rule;
    } catch (_) {
      return null;
    }
  }

  Future<void> _closeFollow() async {
    final video = _video;
    final camera = _camera;
    _bannerTimer?.cancel();
    video?.removeListener(_onVideo);
    setState(() {
      _selected = null;
      _video = null;
      _camera = null;
      _rule = null;
      _counter = null;
      _count = 0;
      _followNote = null;
      _cues = const [];
      _cueIndex = 0;
      _waiting = false;
      _waitPeak = null;
      _banner = null;
    });
    await video?.dispose();
    if (camera != null &&
        camera.value.isInitialized &&
        camera.value.isStreamingImages) {
      await camera.stopImageStream();
    }
    await camera?.dispose();
  }

  void _onFrame(PoseFrame frame, DateTime at) {
    if (_waiting) {
      _judgeWaiting(frame, at);
      return;
    }
    final counter = _counter;
    if (counter == null || _cues.isNotEmpty) return;
    final next = counter.update(frame, at);
    if (next != _count && mounted) setState(() => _count = next);
  }

  void _onVideo() {
    final video = _video;
    final rule = _rule;
    if (video == null ||
        rule == null ||
        _cues.isEmpty ||
        _syncing ||
        _waiting) {
      return;
    }
    if (!video.value.isInitialized) return;
    final guard = _resumeGuard;
    if (guard != null && DateTime.now().isBefore(guard)) return;
    if (video.value.isCompleted) {
      _restartCycle(video);
      return;
    }
    if (_cueIndex < 0 || _cueIndex >= _cues.length) return;
    final cue = _cues[_cueIndex];
    final pos = video.value.position;
    final tolerance = Duration(milliseconds: rule.pauseToleranceMs);
    if (pos + tolerance < cue.at) return;
    if (cue.peak == null) {
      _restartCycle(video);
      return;
    }
    _beginWait(video, cue);
  }

  void _beginWait(VideoPlayerController video, _DemoCue cue) {
    _syncing = true;
    _waiting = true;
    _waitPeak = cue.peak;
    _waitSince = DateTime.now();
    _holdSince = null;
    _attempted = false;
    if (mounted) setState(() {});
    video.pause();
    video.seekTo(cue.at).whenComplete(() {
      if (identical(_video, video)) _syncing = false;
    });
  }

  void _restartCycle(VideoPlayerController video) {
    _syncing = true;
    _cueIndex = 0;
    _resumeGuard = DateTime.now().add(const Duration(milliseconds: 400));
    final start = _rule?.tStart ?? Duration.zero;
    video.seekTo(start).then((_) {
      if (!identical(_video, video)) return;
      _syncing = false;
      if (!_waiting) unawaited(video.play());
    });
  }

  void _judgeWaiting(PoseFrame frame, DateTime at) {
    final rule = _rule;
    final peak = _waitPeak;
    final since = _waitSince;
    if (rule == null || peak == null || since == null || !_waiting) return;
    final metrics = _metricsFor(rule, peak);
    if (metrics.isEmpty) {
      _finishWait(standard: false);
      return;
    }
    final passed = metrics.every(
      (metric) => metric.pass.reached(frame.metrics[metric.id]),
    );
    if (passed) {
      _holdSince ??= at;
      if (at.difference(_holdSince!).inMilliseconds >= rule.holdMs) {
        _finishWait(standard: true);
      }
      return;
    }
    _holdSince = null;
    final lifts = metrics.where((metric) => metric.pass.op != 'lte').toList();
    if (lifts.isNotEmpty) {
      if (lifts.any(
        (metric) => metric.attempt.reached(frame.metrics[metric.id]),
      )) {
        _attempted = true;
      }
      final backDown = lifts.every(
        (metric) => metric.reset.reached(frame.metrics[metric.id]),
      );
      if (_attempted && backDown) {
        _finishWait(standard: false);
        return;
      }
    }
    final limit = _attempted ? rule.waitTimeoutMs : rule.idleGraceMs;
    if (at.difference(since).inMilliseconds >= limit) {
      _finishWait(standard: false);
    }
  }

  void _finishWait({required bool standard}) {
    if (!_waiting) return;
    final video = _video;
    final next = _cueIndex + 1;
    _waiting = false;
    _waitPeak = null;
    _holdSince = null;
    _bannerSerial += 1;
    _bannerTimer?.cancel();
    setState(() {
      if (standard) _count += 1;
      _banner = standard ? '规范' : '不规范';
    });
    _bannerTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) setState(() => _banner = null);
    });
    _resumeGuard = DateTime.now().add(const Duration(milliseconds: 250));
    if (video == null) return;
    if (next >= _cues.length) {
      _restartCycle(video);
      return;
    }
    _cueIndex = next;
    unawaited(video.play());
  }

  List<_DemoCue> _cuesFor(MotionStandard rule) {
    final enabled = {
      for (final metric in rule.metrics)
        if (metric.enabled) metric.id,
    };
    final peaks = [...rule.peaks]..sort((a, b) => a.time.compareTo(b.time));
    final cues = <_DemoCue>[
      for (final peak in peaks)
        if (peak.metricIds.any(enabled.contains))
          _DemoCue(at: peak.time, peak: peak),
    ];
    if (cues.isEmpty) return const [];
    if (rule.tEnd > cues.last.at) cues.add(_DemoCue(at: rule.tEnd));
    return cues;
  }

  List<FollowMetric> _metricsFor(MotionStandard rule, CyclePeak peak) {
    final byId = {for (final metric in rule.metrics) metric.id: metric};
    return [
      for (final id in peak.metricIds)
        if (byId[id]?.enabled ?? false) byId[id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final camera = _camera;
    if (selected != null && camera != null && camera.value.isInitialized) {
      return _followView(selected, camera);
    }
    return _listView();
  }

  Widget _listView() {
    final items = _visible;
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        leading: IconButton(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
        ),
        title: const Text('自由跟做'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(28),
          child: Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              '选择喜欢的动作，让运动成为习惯',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索动作',
                prefixIcon: Icon(Icons.search),
                filled: true,
                fillColor: AppTheme.bgPrimary,
                border: OutlineInputBorder(borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(child: _listBody(items)),
        ],
      ),
    );
  }

  Widget _listBody(List<_ActionItem> items) {
    if (_loading || _starting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(child: Text('没有可跟做的动作'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => _open(item),
              child: AppCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const AppIconBadge(
                      icon: Icons.directions_run_rounded,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (item.detail.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              item.detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppPill(
                      label: item.hasRule ? '可评分' : '仅跟做',
                      color: item.hasRule
                          ? AppTheme.primary
                          : AppTheme.textTertiary,
                      backgroundColor: item.hasRule
                          ? AppTheme.primaryLight
                          : AppTheme.bgSecondary,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _followView(_ActionItem action, CameraController camera) {
    final video = _video;
    final aspect =
        (video != null &&
            video.value.isInitialized &&
            video.value.aspectRatio > 0)
        ? video.value.aspectRatio
        : 0.75;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          onPressed: _closeFollow,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(action.title, overflow: TextOverflow.ellipsis),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          FollowLiveStage(
            camera: camera,
            rule: _rule,
            note: _followNote,
            demoAspect: aspect,
            onScoredFrame: _onFrame,
            focusPeakId: _waiting ? _waitPeak?.id : null,
            demoWaiting: _waiting,
            repCount: _rule == null ? null : _count,
            demo: video != null && video.value.isInitialized
                ? VideoPlayer(video)
                : null,
          ),
          if (_banner != null)
            Center(
              child: _VerdictFlash(
                key: ValueKey('$_bannerSerial'),
                text: _banner!,
              ),
            ),
        ],
      ),
    );
  }
}

class _DemoCue {
  const _DemoCue({required this.at, this.peak});

  final Duration at;
  final CyclePeak? peak;
}

class _VerdictFlash extends StatelessWidget {
  const _VerdictFlash({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ok = text == '规范';
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.55, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: Text(
          text,
          style: TextStyle(
            color: ok ? const Color(0xFF00E676) : const Color(0xFFFF5252),
            fontSize: 72,
            fontWeight: FontWeight.w800,
            shadows: const [Shadow(blurRadius: 18, color: Colors.black)],
          ),
        ),
      ),
    );
  }
}
