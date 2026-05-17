import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';
import 'pose_detection_page.dart' show PosePainter;

// ── 评估阶段 ─────────────────────────────────────────────────────────────────

enum _Phase { loading, watching, assessing, result }

// ── 页面 ─────────────────────────────────────────────────────────────────────

class RehabVideoPage extends StatefulWidget {
  final VoidCallback onBack;
  final String? videoUrl;
  final String? videoTitle;

  const RehabVideoPage({
    super.key,
    required this.onBack,
    this.videoUrl,
    this.videoTitle,
  });

  @override
  State<RehabVideoPage> createState() => _RehabVideoPageState();
}

class _RehabVideoPageState extends State<RehabVideoPage> {
  // ── 视频 ────────────────────────────────────────────────────────────────
  VideoPlayerController? _videoCtrl;
  bool _videoReady = false;

  // ── 摄像头 & 姿态 ────────────────────────────────────────────────────────
  CameraController? _camCtrl;
  PoseDetector? _detector;
  bool _processingFrame = false;
  int _frameIdx = 0;
  bool _pageDisposed = false;

  final ValueNotifier<({
    List<Pose> poses,
    Size imageSize,
    InputImageRotation rotation,
    CameraLensDirection lensDir,
  })?> _poseVisual = ValueNotifier(null);

  // ── 评估 ─────────────────────────────────────────────────────────────────
  _Phase _phase = _Phase.loading;
  final List<double> _matchScores = [];
  double _finalScore = 0;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  // ── 初始化 ────────────────────────────────────────────────────────────────

  Future<void> _initVideo() async {
    final url = widget.videoUrl;
    if (url == null) {
      setState(() => _phase = _Phase.watching);
      return;
    }

    try {
      _videoCtrl = VideoPlayerController.networkUrl(Uri.parse(url));
      await _videoCtrl!.initialize();
      _videoCtrl!.addListener(_onVideoProgress);
      setState(() {
        _videoReady = true;
        _phase = _Phase.watching;
      });
      _videoCtrl!.play();
    } catch (e) {
      setState(() => _phase = _Phase.watching);
    }
  }

  void _onVideoProgress() {
    if (_videoCtrl == null) return;
    if (_videoCtrl!.value.position >= _videoCtrl!.value.duration &&
        _videoCtrl!.value.duration > Duration.zero &&
        _phase == _Phase.watching) {
      _startAssessment();
    }
  }

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
      imageFormatGroup: ImageFormatGroup.nv21,
      enableAudio: false,
    );
    await _camCtrl!.initialize();

    _detector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );

    _camCtrl!.startImageStream(_onCameraImage);
  }

  void _onCameraImage(CameraImage image) {
    if (_pageDisposed || _processingFrame) return;
    _frameIdx++;
    if (_frameIdx % 2 != 0) return;

    _processingFrame = true;

    final inputData = _buildInput(image);
    if (inputData == null) {
      _processingFrame = false;
      return;
    }

    _detector!.processImage(inputData.$1).then((poses) {
      if (_pageDisposed) return;

      if (poses.isNotEmpty && _phase == _Phase.assessing) {
        final score = _calcMatchScore(poses.first);
        _matchScores.add(score);
      }

      _poseVisual.value = (
        poses: poses,
        imageSize: inputData.$2,
        rotation: inputData.$3,
        lensDir: _camCtrl!.description.lensDirection,
      );
      _processingFrame = false;
    }).catchError((_) {
      _processingFrame = false;
    });
  }

  /// 计算单帧匹配得分（0~100）
  /// 核心思路：检测人体关键关节角度是否在合理范围内
  double _calcMatchScore(Pose pose) {
    double score = 0;
    int checks = 0;

    // 检查 1：躯干是否直立（左右肩与左右髋高度差对比）
    final lShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final lHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rHip = pose.landmarks[PoseLandmarkType.rightHip];

    if (lShoulder != null && rShoulder != null &&
        lHip != null && rHip != null) {
      final shoulderMidY = (lShoulder.y + rShoulder.y) / 2;
      final hipMidY = (lHip.y + rHip.y) / 2;
      final trunkHeight = (hipMidY - shoulderMidY).abs();

      // 肩部水平度（左右高度差占躯干高度的比例）
      final shoulderTilt = (lShoulder.y - rShoulder.y).abs() / trunkHeight;
      score += shoulderTilt < 0.1 ? 25 : shoulderTilt < 0.2 ? 15 : 5;
      checks++;
    }

    // 检查 2：膝关节角度（下蹲类动作）
    final lKnee = pose.landmarks[PoseLandmarkType.leftKnee];
    final lAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
    if (lHip != null && lKnee != null && lAnkle != null) {
      final angle = _angleDeg(
        lHip.x, lHip.y,
        lKnee.x, lKnee.y,
        lAnkle.x, lAnkle.y,
      );
      // 膝关节 150°~180° 视为站立正常
      score += angle >= 150 ? 25 : angle >= 120 ? 15 : 8;
      checks++;
    }

    // 检查 3：肘关节（上肢类动作）
    final lElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final lWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    if (lShoulder != null && lElbow != null && lWrist != null) {
      final angle = _angleDeg(
        lShoulder.x, lShoulder.y,
        lElbow.x, lElbow.y,
        lWrist.x, lWrist.y,
      );
      score += angle >= 160 ? 25 : angle >= 130 ? 15 : 8;
      checks++;
    }

    // 检查 4：人体是否在画面中（置信度）
    final nose = pose.landmarks[PoseLandmarkType.nose];
    if (nose != null && nose.likelihood > 0.6) {
      score += 25;
      checks++;
    }

    return checks > 0 ? (score / (checks * 25)) * 100 : 50;
  }

  double _angleDeg(
    double ax, double ay,
    double bx, double by,
    double cx, double cy,
  ) {
    final abx = ax - bx, aby = ay - by;
    final cbx = cx - bx, cby = cy - by;
    final dot = abx * cbx + aby * cby;
    final cross = abx * cby - aby * cbx;
    return math.atan2(cross.abs(), dot) * 180 / math.pi;
  }

  (InputImage, Size, InputImageRotation)? _buildInput(CameraImage image) {
    if (_camCtrl == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(
          _camCtrl!.description.sensorOrientation,
        ) ??
        InputImageRotation.rotation0deg;

    Uint8List? bytes;
    int bytesPerRow = image.planes.first.bytesPerRow;

    if (image.planes.length == 1) {
      bytes = image.planes.first.bytes;
    } else if (image.planes.length == 3) {
      final nv21 = _toNv21(image);
      if (nv21 == null) return null;
      bytes = nv21;
      bytesPerRow = image.width;
    }

    if (bytes == null) return null;

    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: bytesPerRow,
      ),
    );

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    return (inputImage, imageSize, rotation);
  }

  Uint8List? _toNv21(CameraImage image) {
    final w = image.width, h = image.height;
    final y = image.planes[0];
    final u = image.planes[1];
    final v = image.planes[2];
    final ySize = w * h;
    final out = Uint8List(ySize + (w * h ~/ 2));
    var idx = 0;
    for (var row = 0; row < h; row++) {
      for (var col = 0; col < w; col++) {
        out[idx++] = y.bytes[row * y.bytesPerRow + col * (y.bytesPerPixel ?? 1)];
      }
    }
    for (var row = 0; row < h ~/ 2; row++) {
      for (var col = 0; col < w ~/ 2; col++) {
        out[idx++] =
            v.bytes[row * v.bytesPerRow + col * (v.bytesPerPixel ?? 1)];
        out[idx++] =
            u.bytes[row * u.bytesPerRow + col * (u.bytesPerPixel ?? 1)];
      }
    }
    return out;
  }

  // ── 阶段控制 ──────────────────────────────────────────────────────────────

  Future<void> _startAssessment() async {
    _videoCtrl?.pause();
    _matchScores.clear();
    setState(() => _phase = _Phase.assessing);
    await _initCamera();
  }

  Future<void> _finishAssessment() async {
    _pageDisposed = true;
    await _camCtrl?.stopImageStream();
    await _camCtrl?.dispose();
    _camCtrl = null;
    _detector?.close();

    final avg = _matchScores.isEmpty
        ? 0.0
        : _matchScores.reduce((a, b) => a + b) / _matchScores.length;

    setState(() {
      _finalScore = avg;
      _phase = _Phase.result;
    });
  }

  @override
  void dispose() {
    _pageDisposed = true;
    _videoCtrl?.removeListener(_onVideoProgress);
    _videoCtrl?.dispose();
    _camCtrl?.stopImageStream();
    _camCtrl?.dispose();
    _detector?.close();
    _poseVisual.dispose();
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
        _Phase.loading => const Center(
            child: CircularProgressIndicator(color: AppTheme.primary)),
        _Phase.watching => _buildWatching(),
        _Phase.assessing => _buildAssessing(),
        _Phase.result => _buildResult(),
      },
    );
  }

  // ── 观看视频阶段 ──────────────────────────────────────────────────────────

  Widget _buildWatching() {
    return Column(
      children: [
        Expanded(
          child: _videoReady && _videoCtrl != null
              ? AspectRatio(
                  aspectRatio: _videoCtrl!.value.aspectRatio,
                  child: VideoPlayer(_videoCtrl!),
                )
              : const Center(
                  child: Text(
                    '视频加载中...\n（请确认视频文件已放入 backend/assets/）',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
        ),
        _buildVideoControls(),
      ],
    );
  }

  Widget _buildVideoControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.black,
      child: Column(
        children: [
          if (_videoReady && _videoCtrl != null)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _videoCtrl!,
              builder: (_, val, __) {
                final pos = val.position.inSeconds.toDouble();
                final dur = val.duration.inSeconds.toDouble();
                return Column(
                  children: [
                    Slider(
                      value: pos.clamp(0, dur > 0 ? dur : 1),
                      min: 0,
                      max: dur > 0 ? dur : 1,
                      activeColor: AppTheme.primary,
                      onChanged: (v) {
                        _videoCtrl!.seekTo(Duration(seconds: v.toInt()));
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _fmtDuration(val.position),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                        Text(
                          _fmtDuration(val.duration),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
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
                          onPressed: () {
                            val.isPlaying
                                ? _videoCtrl!.pause()
                                : _videoCtrl!.play();
                          },
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _startAssessment,
              icon: const Icon(Icons.fitness_center, size: 20),
              label: const Text(
                '我已看完，开始跟做评估',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 动作评估阶段 ──────────────────────────────────────────────────────────

  Widget _buildAssessing() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_camCtrl != null && _camCtrl!.value.isInitialized)
                CameraPreview(_camCtrl!),
              ValueListenableBuilder(
                valueListenable: _poseVisual,
                builder: (_, val, __) {
                  if (val == null) return const SizedBox();
                  return RepaintBoundary(
                  child: CustomPaint(
                    painter: PosePainter(
                      poses: val.poses,
                      imageSize: val.imageSize,
                      rotation: val.rotation,
                      cameraLensDirection: val.lensDir,
                      drawSkeleton: true,
                    ),
                  ),
                  );
                },
              ),
              // 实时得分
              Positioned(
                top: 16,
                left: 0,
                right: 0,
                child: ValueListenableBuilder(
                  valueListenable: _poseVisual,
                  builder: (_, val, __) {
                    final score = _matchScores.isEmpty
                        ? 0
                        : (_matchScores.last).round();
                    return Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '实时匹配度：$score%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          color: Colors.black,
          child: Column(
            children: [
              const Text(
                '请跟随视频中的动作进行练习\n保持匀速，如有不适请立即停止',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _finishAssessment,
                  icon: const Icon(Icons.check_circle, size: 20),
                  label: const Text(
                    '完成练习，查看评估结果',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── 结果阶段 ─────────────────────────────────────────────────────────────

  Widget _buildResult() {
    final score = _finalScore.round();
    final (grade, color, tip) = switch (score) {
      >= 85 => ('优秀', const Color(0xFF4CAF50), '动作标准，继续保持！'),
      >= 70 => ('良好', const Color(0xFF8BC34A), '整体不错，细节还可提升'),
      >= 55 => ('一般', const Color(0xFFFF9800), '建议加强练习，注意动作要领'),
      _ => ('需改进', const Color(0xFFF44336), '请仔细参照视频，循序渐进'),
    };

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 24),
            // 得分环
            SizedBox(
              width: 160,
              height: 160,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: _finalScore / 100,
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
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        '综合得分',
                        style: TextStyle(color: Colors.white60, fontSize: 13),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              grade,
              style: TextStyle(
                color: color,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tip,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            // 分项说明
            _ResultCard(
              icon: Icons.bar_chart,
              title: '评估帧数',
              value: '${_matchScores.length} 帧',
            ),
            const SizedBox(height: 12),
            _ResultCard(
              icon: Icons.accessibility_new,
              title: '平均匹配度',
              value: '$score%',
            ),
            const SizedBox(height: 12),
            _ResultCard(
              icon: Icons.tips_and_updates,
              title: '建议',
              value: tip,
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      _pageDisposed = false;
                      _matchScores.clear();
                      _poseVisual.value = null;
                      _initVideo();
                      setState(() => _phase = _Phase.loading);
                    },
                    icon: const Icon(Icons.replay, size: 18),
                    label: const Text('重新练习'),
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
                        borderRadius: BorderRadius.circular(12),
                      ),
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

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ── 结果卡片 ──────────────────────────────────────────────────────────────────

class _ResultCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _ResultCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
