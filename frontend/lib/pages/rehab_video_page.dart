import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';
import '../config/api_config.dart';
import '../pose/follow_models.dart';
import '../widgets/follow_live_stage.dart';

// ── 阶段 ─────────────────────────────────────────────────────────────────────
//  loading  →  watching  →  preview  →  countdown  →  recording
//                                                          ↓
//                                                       uploading
//                                                          ↓
//                                                       polling
//                                                          ↓
//                                                        result

enum _Phase { loading, watching, preview, countdown, recording, uploading, polling, result }

// ── 评估结果 ──────────────────────────────────────────────────────────────────

class _AssessResult {
  final int overallScore;
  final int postureScore;
  final int rangeScore;
  final int rhythmScore;
  final List<String> keyFindings;
  final List<String> corrections;
  final List<String> safetyNotes;
  final String encouragement;
  final String summary;

  const _AssessResult({
    required this.overallScore,
    required this.postureScore,
    required this.rangeScore,
    required this.rhythmScore,
    required this.keyFindings,
    required this.corrections,
    required this.safetyNotes,
    required this.encouragement,
    required this.summary,
  });

  factory _AssessResult.fromJson(Map<String, dynamic> a, String summary) =>
      _AssessResult(
        overallScore: (a['overall_score'] as num?)?.toInt() ?? 0,
        postureScore: (a['posture_score'] as num?)?.toInt() ?? 0,
        rangeScore: (a['range_of_motion'] as num?)?.toInt() ?? 0,
        rhythmScore: (a['rhythm_score'] as num?)?.toInt() ?? 0,
        keyFindings: _strList(a['key_findings']),
        corrections: _strList(a['corrections']),
        safetyNotes: _strList(a['safety_notes']),
        encouragement: a['encouragement'] as String? ?? '',
        summary: summary,
      );

  static List<String> _strList(dynamic v) =>
      (v as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
}

// ── 页面 ─────────────────────────────────────────────────────────────────────

class RehabVideoPage extends StatefulWidget {
  final VoidCallback onBack;
  final String? videoUrl;
  final String? videoId;
  final String? sessionId;
  final String? videoTitle;

  const RehabVideoPage({
    super.key,
    required this.onBack,
    this.videoUrl,
    this.videoId,
    this.sessionId,
    this.videoTitle,
  });

  @override
  State<RehabVideoPage> createState() => _RehabVideoPageState();
}

class _RehabVideoPageState extends State<RehabVideoPage> {
  // ── 演示视频 ─────────────────────────────────────────────────────────────
  VideoPlayerController? _videoCtrl;
  bool _videoReady = false;
  String? _videoLoadError;

  // ── 摄像头与实时规则 ─────────────────────────────────────────────────────
  CameraController? _camCtrl;
  final _liveKey = GlobalKey<FollowLiveStageState>();
  MotionStandard? _rule;
  String? _ruleNote;
  bool _pageDisposed = false;

  // ── 倒计时 ───────────────────────────────────────────────────────────────
  int _countdownValue = 3;
  Timer? _countdownTimer;

  // ── 阶段 & 结果 ──────────────────────────────────────────────────────────
  _Phase _phase = _Phase.loading;
  _AssessResult? _result;
  String? _uploadError;

  // ── 异步任务轮询 ─────────────────────────────────────────────────────────
  Timer? _pollTimer;
  String _pollingMessage = '视觉 AI 正在对比标准动作与您的训练视频…';

  // SharedPreferences key
  String get _taskPrefKey =>
      'assess_task_${widget.sessionId ?? ''}_${widget.videoId ?? ''}';

  @override
  void initState() {
    super.initState();
    _checkExistingTask();
  }

  // ── 检查是否有未完成 / 已完成的历史任务 ──────────────────────────────────

  Future<void> _checkExistingTask() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTaskId = prefs.getString(_taskPrefKey);

    if (savedTaskId != null) {
      final task = await _fetchTaskStatus(savedTaskId);
      if (task != null) {
        final status = task['status'] as String? ?? '';
        if (status == 'done') {
          // 历史结果直接展示
          _applyTaskResult(task);
          return;
        } else if (status == 'processing' || status == 'pending') {
          // 仍在处理中，恢复轮询
          setState(() => _phase = _Phase.polling);
          _startPolling(savedTaskId);
          return;
        }
        // error 或不存在：清掉缓存，正常初始化
        await prefs.remove(_taskPrefKey);
      }
    }

    // 正常流程：初始化演示视频
    _initVideo();
  }

  // ── 初始化演示视频 ────────────────────────────────────────────────────────

  Future<void> _initVideo() async {
    var url = widget.videoUrl;
    if (url == null && widget.videoId != null) {
      url = '$kBackendBase/api/videos/${widget.videoId}/play';
    }
    if (url == null) {
      setState(() {
        _phase = _Phase.watching;
        _videoLoadError = '未获取到演示视频地址';
      });
      return;
    }
    try {
      _videoCtrl?.dispose();
      _videoCtrl = VideoPlayerController.networkUrl(Uri.parse(url));
      await _videoCtrl!.initialize();
      if (!mounted) return;
      setState(() {
        _videoReady = true;
        _videoLoadError = null;
        _phase = _Phase.watching;
      });
      await _videoCtrl!.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _videoReady = false;
        _videoLoadError = '视频加载失败：$e\n地址：$url';
        _phase = _Phase.watching;
      });
    }
  }

  // ── 进入摄像头预览（点击"准备好了"后） ──────────────────────────────────

  Future<void> _enterPreview() async {
    _videoCtrl?.pause();
    await _initCamera();
    if (!mounted) return;
    await _loadMotionRule();
    if (!mounted) return;
    _startDemoLoop();
    setState(() => _phase = _Phase.preview);
  }

  Future<void> _loadMotionRule() async {
    final videoId = widget.videoId;
    if (videoId == null || videoId.isEmpty) {
      _rule = null;
      _ruleNote = '该动作尚未配置实时评分';
      return;
    }
    try {
      final response = await http
          .get(Uri.parse('$kBackendBase/api/motion-rules/$videoId'))
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final raw = data['rule'] as Map<String, dynamic>? ?? data;
        final rule = MotionStandard.fromJson(raw);
        final enabled = rule.metrics.any((metric) => metric.enabled);
        _rule = enabled ? rule : null;
        _ruleNote = enabled ? null : '该动作尚未配置实时评分';
      } else {
        _rule = null;
        _ruleNote = '该动作尚未配置实时评分';
      }
    } catch (_) {
      _rule = null;
      _ruleNote = '实时评分规则未加载，本次只显示骨架';
    }
  }

  void _startDemoLoop() {
    final video = _videoCtrl;
    if (video == null || !_videoReady) return;
    video.setVolume(0);
    video.setLooping(true);
    video.seekTo(Duration.zero);
    video.play();
  }

  // ── 初始化摄像头 ─────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _camCtrl = CameraController(
      front,
      ResolutionPreset.medium,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
      enableAudio: true,
    );
    await _camCtrl!.initialize();
  }

  // ── 开始倒计时（点击"开始录制"后，摄像头已就绪） ────────────────────────

  void _startCountdown() {
    setState(() {
      _countdownValue = 3;
      _phase = _Phase.countdown;
    });

    _startDemoLoop();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (_countdownValue > 1) {
        setState(() => _countdownValue--);
      } else {
        t.cancel();
        await _startRecording();
      }
    });
  }

  // ── 开始录制 ─────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    try {
      await _liveKey.currentState?.releaseStreamForRecording();
      await _camCtrl!.startVideoRecording(
        onAvailable: (image) => _liveKey.currentState?.handleFrame(image),
      );
      setState(() => _phase = _Phase.recording);
    } catch (e) {
      setState(() {
        _uploadError = '录制启动失败：$e';
        _phase = _Phase.result;
      });
    }
  }

  // ── 停止录制并上传 ────────────────────────────────────────────────────────

  Future<void> _stopAndUpload() async {
    if (_camCtrl == null) return;
    setState(() => _phase = _Phase.uploading);

    try {
      final xfile = await _camCtrl!.stopVideoRecording();
      await _camCtrl!.dispose();
      _camCtrl = null;
      _videoCtrl?.pause(); // 停止后台演示小窗播放

      await _uploadVideo(xfile.path);
    } catch (e) {
      setState(() {
        _uploadError = '停止录制失败：$e';
        _phase = _Phase.result;
      });
    }
  }

  // ── 上传视频，拿到 task_id 后立刻进入轮询 ─────────────────────────────────

  Future<void> _uploadVideo(String videoPath) async {
    final sid = widget.sessionId;
    final vid = widget.videoId;
    if (sid == null || vid == null) {
      setState(() {
        _uploadError = '缺少会话或视频ID，无法评估';
        _phase = _Phase.result;
      });
      return;
    }

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$kBackendBase/api/assess/motion'),
      )
        ..fields['session_id'] = sid
        ..fields['standard_video_id'] = vid
        ..files.add(await http.MultipartFile.fromPath(
          'user_video',
          videoPath,
          filename: 'user_training.mp4',
        ));

      final streamed = await request.send().timeout(const Duration(minutes: 2));
      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final taskId = data['task_id'] as String;

        // 持久化 task_id 到本地，退出重进可继续查看结果
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_taskPrefKey, taskId);

        setState(() => _phase = _Phase.polling);
        _startPolling(taskId);
      } else {
        setState(() {
          _uploadError = '上传失败（${streamed.statusCode}）：$body';
          _phase = _Phase.result;
        });
      }
    } on TimeoutException catch (_) {
      setState(() {
        _uploadError = '上传超时，请检查网络连接后重试';
        _phase = _Phase.result;
      });
    } catch (e) {
      setState(() {
        _uploadError = '上传失败：$e';
        _phase = _Phase.result;
      });
    }
  }

  // ── 轮询任务状态 ─────────────────────────────────────────────────────────

  void _startPolling(String taskId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final task = await _fetchTaskStatus(taskId);
      if (task == null || _pageDisposed) return;

      final status = task['status'] as String? ?? '';
      if (status == 'done') {
        _pollTimer?.cancel();
        _applyTaskResult(task);
      } else if (status == 'error') {
        _pollTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _uploadError = '评估失败：${task['error'] ?? '未知错误'}';
          _phase = _Phase.result;
        });
      } else if (status == 'processing') {
        if (mounted) {
          setState(() => _pollingMessage = '视觉 AI 正在对比标准动作与您的训练视频…');
        }
      }
    });
  }

  Future<Map<String, dynamic>?> _fetchTaskStatus(String taskId) async {
    try {
      final resp = await http
          .get(Uri.parse('$kBackendBase/api/assess/status/$taskId'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {
      // 网络临时失败，下次轮询重试
    }
    return null;
  }

  void _applyTaskResult(Map<String, dynamic> task) {
    if (!mounted) return;
    final assessment = task['assessment'];
    final summary = task['summary'] as String? ?? '';

    if (assessment is Map<String, dynamic>) {
      setState(() {
        _result = _AssessResult.fromJson(assessment, summary);
        _phase = _Phase.result;
      });
    } else {
      setState(() {
        _uploadError = '评估结果格式异常';
        _phase = _Phase.result;
      });
    }
  }

  @override
  void dispose() {
    _pageDisposed = true;
    _countdownTimer?.cancel();
    _pollTimer?.cancel();
    _videoCtrl?.dispose();
    _camCtrl?.dispose();
    super.dispose();
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: widget.onBack,
        ),
        title: Text(
          widget.videoTitle ?? '康复训练',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
      body: switch (_phase) {
        _Phase.loading   => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        _Phase.watching  => _buildWatching(),
        _Phase.preview || _Phase.countdown || _Phase.recording => _buildLiveSession(),
        _Phase.uploading => _buildUploading(),
        _Phase.polling   => _buildPolling(),
        _Phase.result    => _buildResult(),
      },
    );
  }

  // ── 观看演示视频 ──────────────────────────────────────────────────────────

  Widget _buildWatching() {
    return Column(
      children: [
        Expanded(
          child: _videoReady && _videoCtrl != null
              ? AspectRatio(
                  aspectRatio: _videoCtrl!.value.aspectRatio,
                  child: VideoPlayer(_videoCtrl!),
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _videoLoadError ?? '视频加载中…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.black,
          child: Column(
            children: [
              if (_videoReady && _videoCtrl != null)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: _videoCtrl!,
                  builder: (context2, val, child2) {
                    final pos = val.position.inSeconds.toDouble();
                    final dur = val.duration.inSeconds.toDouble();
                    return Column(
                      children: [
                        Slider(
                          value: pos.clamp(0, dur > 0 ? dur : 1),
                          min: 0,
                          max: dur > 0 ? dur : 1,
                          activeColor: AppTheme.primary,
                          onChanged: (v) =>
                              _videoCtrl!.seekTo(Duration(seconds: v.toInt())),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_fmt(val.position),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            Text(_fmt(val.duration),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: Icon(
                                val.isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 32,
                              ),
                              onPressed: () => val.isPlaying
                                  ? _videoCtrl!.pause()
                                  : _videoCtrl!.play(),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              const SizedBox(height: 8),
              const Text(
                '请先完整观看标准动作演示，了解动作要领后再开始训练',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              if (_videoLoadError != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _phase = _Phase.loading;
                        _videoLoadError = null;
                      });
                      _initVideo();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                    ),
                    child: const Text('重新加载视频'),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _enterPreview,
                  icon: const Icon(Icons.fitness_center, size: 20),
                  label: const Text(
                    '准备好了，开始训练',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLiveSession() {
    final camera = _camCtrl;
    final video = _videoCtrl;
    final aspect = video != null && video.value.aspectRatio > 0
        ? video.value.aspectRatio
        : 0.75;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (camera != null && camera.value.isInitialized)
          FollowLiveStage(
            key: _liveKey,
            camera: camera,
            rule: _rule,
            note: _ruleNote,
            demoAspect: aspect,
            demo: video != null && _videoReady ? VideoPlayer(video) : null,
          )
        else
          const Center(
            child: Text('正在连接摄像头…', style: TextStyle(color: Colors.white70)),
          ),
        if (_phase == _Phase.countdown)
          Center(
            child: Text(
              '$_countdownValue',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 120,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(blurRadius: 8, color: Colors.black)],
              ),
            ),
          ),
        if (_phase == _Phase.recording)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fiber_manual_record, color: Colors.white, size: 14),
                    SizedBox(width: 6),
                    Text('录制中', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: SafeArea(
            top: false,
            child: _phase == _Phase.recording
                ? SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _stopAndUpload,
                      icon: const Icon(Icons.check_circle, size: 20),
                      label: const Text('训练完成', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  )
                : _phase == _Phase.preview
                ? SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _startCountdown,
                      icon: const Icon(Icons.videocam, size: 20),
                      label: const Text('开始录制', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  // ── 上传中 ────────────────────────────────────────────────────────────────

  Widget _buildUploading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppTheme.primary),
          SizedBox(height: 20),
          Text(
            '正在上传训练视频…',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            '上传完成后将在后台分析，无需等待',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── 轮询中（后台处理） ────────────────────────────────────────────────────

  Widget _buildPolling() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 64,
              height: 64,
              child: CircularProgressIndicator(
                color: AppTheme.primary,
                strokeWidth: 5,
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              '处理中',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _pollingMessage,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              '可以先退出此页面，结果完成后重新进入即可查看',
              style: TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white54,
                side: const BorderSide(color: Colors.white24),
              ),
              onPressed: widget.onBack,
              icon: const Icon(Icons.home, size: 18),
              label: const Text('返回首页（结果将保留）'),
            ),
          ],
        ),
      ),
    );
  }

  // ── 结果展示 ──────────────────────────────────────────────────────────────

  Widget _buildResult() {
    if (_uploadError != null) {
      return _buildErrorResult();
    }
    final r = _result;
    if (r == null) return _buildErrorResult();

    final score = r.overallScore;
    final (grade, color) = switch (score) {
      >= 85 => ('优秀', const Color(0xFF4CAF50)),
      >= 70 => ('良好', const Color(0xFF8BC34A)),
      >= 55 => ('一般', const Color(0xFFFF9800)),
      _ => ('需改进', const Color(0xFFF44336)),
    };

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: score / 100,
                        strokeWidth: 10,
                        backgroundColor: Colors.white12,
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$score',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 44,
                              fontWeight: FontWeight.bold),
                        ),
                        const Text('综合评分',
                            style: TextStyle(color: Colors.white60, fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(grade,
                  style: TextStyle(
                      color: color,
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 20),
            _ScoreRow(label: '姿势准确度', score: r.postureScore),
            const SizedBox(height: 8),
            _ScoreRow(label: '关节活动范围', score: r.rangeScore),
            const SizedBox(height: 8),
            _ScoreRow(label: '动作节奏', score: r.rhythmScore),
            const SizedBox(height: 20),
            if (r.keyFindings.isNotEmpty) ...[
              _SectionTitle(title: '关键发现', icon: Icons.search),
              const SizedBox(height: 8),
              ...r.keyFindings.map((s) => _BulletItem(text: s)),
              const SizedBox(height: 16),
            ],
            if (r.corrections.isNotEmpty) ...[
              _SectionTitle(title: '纠正建议', icon: Icons.tips_and_updates),
              const SizedBox(height: 8),
              ...r.corrections.map(
                  (s) => _BulletItem(text: s, color: const Color(0xFFFF9800))),
              const SizedBox(height: 16),
            ],
            if (r.safetyNotes.isNotEmpty) ...[
              _SectionTitle(title: '安全提醒', icon: Icons.warning_amber_rounded),
              const SizedBox(height: 8),
              ...r.safetyNotes.map(
                  (s) => _BulletItem(text: s, color: const Color(0xFFF44336))),
              const SizedBox(height: 16),
            ],
            if (r.encouragement.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
                ),
                child: Text(
                  r.encouragement,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, fontStyle: FontStyle.italic),
                  textAlign: TextAlign.center,
                ),
              ),
            if (r.summary.isNotEmpty) ...[
              const SizedBox(height: 16),
              _SectionTitle(title: '康复总结', icon: Icons.summarize),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  r.summary,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.87),
                      fontSize: 14,
                      height: 1.6),
                ),
              ),
            ],
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () async {
                      // 清除本次任务缓存，允许重新训练
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.remove(_taskPrefKey);
                      if (!mounted) return;
                      _pageDisposed = false;
                      _result = null;
                      _uploadError = null;
                      setState(() => _phase = _Phase.loading);
                      _initVideo();
                    },
                    icon: const Icon(Icons.replay, size: 18),
                    label: const Text('重新训练'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.home, size: 18),
                    label: const Text('返回首页'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorResult() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 56),
            const SizedBox(height: 16),
            Text(
              _uploadError ?? '评估失败，请重试',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white54,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove(_taskPrefKey);
                    if (!mounted) return;
                    _uploadError = null;
                    setState(() => _phase = _Phase.loading);
                    _initVideo();
                  },
                  icon: const Icon(Icons.replay, size: 18),
                  label: const Text('重新训练'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.home),
                  label: const Text('返回首页'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ── 辅助组件 ──────────────────────────────────────────────────────────────────

class _ScoreRow extends StatelessWidget {
  final String label;
  final int score;
  const _ScoreRow({required this.label, required this.score});

  @override
  Widget build(BuildContext context) {
    final color = score >= 80
        ? const Color(0xFF4CAF50)
        : score >= 60
            ? const Color(0xFFFF9800)
            : const Color(0xFFF44336);
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label,
              style: const TextStyle(color: Colors.white60, fontSize: 13)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: score / 100,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 8,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 36,
          child: Text(
            '$score',
            style: TextStyle(
                color: color, fontSize: 14, fontWeight: FontWeight.bold),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  const _SectionTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.primary, size: 18),
        const SizedBox(width: 6),
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _BulletItem extends StatelessWidget {
  final String text;
  final Color color;
  const _BulletItem({required this.text, this.color = Colors.white70});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: TextStyle(color: color, fontSize: 14, height: 1.5)),
          Expanded(
            child: Text(text,
                style: TextStyle(color: color, fontSize: 13, height: 1.5)),
          ),
        ],
      ),
    );
  }
}
