import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../pose/camera_frame.dart';
import '../pose/follow_models.dart';
import '../pose/geometry.dart';
import '../pose/landmark_smoother.dart';
import '../pose/pose_service.dart';
import '../pose/skeleton_painter.dart';
import 'follow_demo_pip.dart';

/// 正式跟做画面：摄像头、骨架和可拖动的演示小窗。
/// 动作没有启用中的评分规则时只画骨架，不显示分数。
class FollowLiveStage extends StatefulWidget {
  const FollowLiveStage({
    super.key,
    required this.camera,
    required this.rule,
    this.demo,
    this.demoAspect = 0.75,
    this.note,
    this.onScoredFrame,
    this.focusPeakId,
    this.demoWaiting = false,
    this.repCount,
  });

  final CameraController camera;
  final MotionStandard? rule;
  final Widget? demo;
  final double demoAspect;
  final String? note;
  final void Function(PoseFrame frame, DateTime at)? onScoredFrame;
  final String? focusPeakId;
  final bool demoWaiting;
  final int? repCount;

  @override
  State<FollowLiveStage> createState() => FollowLiveStageState();
}

class FollowLiveStageState extends State<FollowLiveStage> {
  final _detector = LocalPoseDetector();
  final _decoder = CameraFrameDecoder();
  final _smoother = LandmarkSmoother();
  final _previewSmoother = PreviewLandmarkSmoother();

  ui.Image? _image;
  List<OffsetLandmark> _landmarks = const [];
  bool _detected = false;
  double _score = 0;
  Map<String, double?> _angles = const {};
  bool _inflight = false;
  bool _closed = false;
  InputImageRotation? _lastRotation;

  bool get _scored => motionRuleEnablesLiveScore(widget.rule);

  @override
  void initState() {
    super.initState();
    unawaited(ensureStreaming());
  }

  Future<void> ensureStreaming() async {
    final camera = widget.camera;
    if (_closed ||
        !camera.value.isInitialized ||
        camera.value.isRecordingVideo) {
      return;
    }
    if (camera.value.isStreamingImages) return;
    await camera.startImageStream(handleFrame);
  }

  /// 录像和图像流不能同时开。停掉预览流后，由录像回调继续送帧。
  Future<void> releaseStreamForRecording() async {
    final camera = widget.camera;
    if (camera.value.isStreamingImages) {
      await camera.stopImageStream();
    }
  }

  void handleFrame(CameraImage image) {
    unawaited(_onFrame(image));
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_closed || _inflight) return;
    final camera = widget.camera;
    _inflight = true;
    ui.Image? frameImage;
    try {
      final capturedAt = DateTime.now();
      final rotation = cameraInputRotation(camera);
      final snap = CapturedCameraFrame.tryCapture(image);
      if (rotation == null || snap == null) return;
      final front =
          camera.description.lensDirection == CameraLensDirection.front;
      final detection = _detector.detect(
        image,
        camera,
        rotation: rotation,
        bytes: snap.bytes,
        bytesPerRow: snap.bytesPerRow,
      );
      final conversion = _decoder
          .decode(
            snap,
            rotation: Platform.isIOS
                ? InputImageRotation.rotation0deg
                : rotation,
            mirror: !Platform.isIOS && front,
          )
          .then((value) => frameImage = value);
      final (detected, _) = await (detection, conversion).wait;
      if (_closed || !mounted || frameImage == null) return;
      if (_lastRotation != rotation) {
        _smoother.reset();
        _previewSmoother.reset();
        _lastRotation = rotation;
      }
      final tracked = detected.preview;
      final scoredLandmarks = _smoother.push(tracked, capturedAt);
      final drawLandmarks = _previewSmoother.push(tracked, capturedAt);
      final rule = widget.rule;
      PoseFrame? frame;
      if (_scored && rule != null && scoredLandmarks.isNotEmpty) {
        frame = evaluateLocal(scoredLandmarks, rule);
      }
      final angles = <String, double?>{
        for (final metric in (rule?.metrics ?? const <FollowMetric>[]).where(
          (item) => item.enabled,
        ))
          metric.id: frame?.metrics[metric.id],
      };
      setState(() {
        final previous = _image;
        _image = frameImage;
        frameImage = null;
        _landmarks = drawLandmarks;
        _detected = tracked.isNotEmpty;
        _angles = angles;
        if (frame != null) {
          final focus = widget.focusPeakId;
          final target = focus != null && rule != null
              ? scoreForPeak(frame, rule, focus)
              : frame.instantScore.toDouble();
          _score += (target - _score) * 0.4;
        }
        previous?.dispose();
      });
      if (frame != null) widget.onScoredFrame?.call(frame, capturedAt);
    } catch (error) {
      debugPrint('follow pose failed: $error');
    } finally {
      frameImage?.dispose();
      _inflight = false;
    }
  }

  @override
  void dispose() {
    _closed = true;
    final camera = widget.camera;
    if (camera.value.isInitialized && camera.value.isStreamingImages) {
      unawaited(camera.stopImageStream());
    }
    _image?.dispose();
    _decoder.dispose();
    unawaited(_detector.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final rule = widget.rule;
    final scoredMetrics =
        rule?.metrics.where((item) => item.enabled).toList() ??
        const <FollowMetric>[];
    final scored = _scored;
    final tint = scored ? null : const Color(0xFF80DEEA);
    final segments = rule?.barSegments ?? 10;
    final filled = ((_score / 100) * segments)
        .round()
        .clamp(0, segments)
        .toInt();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image == null)
          widget.camera.value.isPreviewPaused
              ? const Center(
                  child: Text(
                    '正在连接摄像头…',
                    style: TextStyle(color: Colors.white70),
                  ),
                )
              : CameraPreview(widget.camera)
        else
          SyncedPosePreview(
            image: image,
            landmarks: _landmarks,
            score: scored ? _score : 0,
            detected: _detected,
            focusJoints: rule == null ? const [] : focusJointsFor(rule),
            color: tint,
          ),
        if (widget.note != null && !scored)
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Text(
              widget.note!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                shadows: [Shadow(blurRadius: 6, color: Colors.black)],
              ),
            ),
          ),
        if (scored && scoredMetrics.isNotEmpty)
          Positioned(
            left: 16,
            top: 12,
            right: 96,
            child: Text(
              followScoreLines(rule!, _angles),
              style: const TextStyle(
                color: Color(0xFF69F0AE),
                fontSize: 14,
                shadows: [Shadow(blurRadius: 6, color: Colors.black)],
              ),
            ),
          ),
        if (scored)
          Positioned(
            right: 16,
            top: 72,
            bottom: 72,
            child: Column(
              children: [
                Text(
                  '${_score.round().clamp(0, 100)}',
                  style: TextStyle(
                    color: skeletonColorForScore(_score, detected: _detected),
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _ScoreBar(
                    segments: segments,
                    filled: filled,
                    color: skeletonColorForScore(_score, detected: _detected),
                  ),
                ),
                if (widget.repCount != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${widget.repCount}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (widget.demo != null)
          Positioned.fill(
            child: FollowDemoPip(
              aspectRatio: widget.demoAspect,
              waiting: widget.demoWaiting,
              child: Transform.flip(flipX: true, child: widget.demo!),
            ),
          ),
      ],
    );
  }
}

class _ScoreBar extends StatelessWidget {
  final int segments;
  final int filled;
  final Color color;

  const _ScoreBar({
    required this.segments,
    required this.filled,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final count = segments < 1 ? 1 : segments;
    return Column(
      children: List.generate(count, (i) {
        final lit = (count - 1 - i) < filled;
        return Expanded(
          child: Container(
            width: 18,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: lit ? color : Colors.white24,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }),
    );
  }
}

String followScoreLines(MotionStandard rule, Map<String, double?> angles) {
  String line(FollowMetric metric) {
    final angle = angles[metric.id];
    if (angle == null) return '${metric.nameCn} 未入画';
    return '${metric.nameCn} ${angle.toStringAsFixed(0)}° / 合格 ${metric.pass.value.round()}°';
  }

  final byId = {for (final metric in rule.metrics) metric.id: metric};
  final claimed = <String>{};
  final lines = <String>[];
  final grouped =
      rule.peaks.length > 1 ||
      rule.peaks.any((peak) => peak.metricIds.length > 1);
  for (final peak in rule.peaks) {
    final metrics = [
      for (final id in peak.metricIds)
        if (byId[id]?.enabled ?? false) byId[id]!,
    ];
    if (metrics.isEmpty) continue;
    if (grouped && peak.nameCn.isNotEmpty) lines.add(peak.nameCn);
    for (final metric in metrics) {
      claimed.add(metric.id);
      lines.add(line(metric));
    }
  }
  for (final metric in rule.metrics) {
    if (!metric.enabled || claimed.contains(metric.id)) continue;
    lines.add(line(metric));
  }
  final measurements = lines.where(
    (item) => item.contains('°') || item.endsWith('未入画'),
  );
  if (measurements.isEmpty ||
      measurements.every((item) => item.endsWith('未入画'))) {
    return '请让全身入画';
  }
  return lines.join('\n');
}

List<int> focusJointsFor(MotionStandard rule) {
  final metrics = rule.metrics.where((metric) => metric.enabled);
  final names = <String>{
    for (final metric in metrics) ...[
      if (metric.fromName != null) metric.fromName!,
      if (metric.toName != null) metric.toName!,
      ...metric.points,
    ],
  };
  return [
    for (final name in names)
      if (landmarkIndex.containsKey(name)) landmarkIndex[name]!,
  ];
}
