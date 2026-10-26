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
  });

  final CameraController camera;
  final MotionStandard? rule;
  final Widget? demo;
  final double demoAspect;
  final String? note;

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
  double? _angle;
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
    if (_closed || !camera.value.isInitialized || camera.value.isRecordingVideo) {
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
      final front = camera.description.lensDirection == CameraLensDirection.front;
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
            rotation: Platform.isIOS ? InputImageRotation.rotation0deg : rotation,
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
      final metric = rule?.requiredMetric;
      final angle = frame == null || metric == null ? null : frame.metrics[metric.id];
      setState(() {
        final previous = _image;
        _image = frameImage;
        frameImage = null;
        _landmarks = drawLandmarks;
        _detected = tracked.isNotEmpty;
        _angle = angle;
        if (frame != null) {
          final target = frame.instantScore.toDouble();
          _score += (target - _score) * 0.4;
        }
        previous?.dispose();
      });
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
    final metric = rule?.requiredMetric;
    final scored = _scored;
    final tint = scored ? null : const Color(0xFF80DEEA);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image == null)
          CameraPreview(widget.camera)
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
        if (scored && metric != null)
          Positioned(
            left: 16,
            top: 12,
            child: Text(
              _angle == null
                  ? '请让全身入画'
                  : '${metric.nameCn} ${_angle!.toStringAsFixed(0)}° / 合格 ${metric.pass.value.round()}°',
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
            top: 48,
            child: Text(
              '${_score.round().clamp(0, 100)}',
              style: TextStyle(
                color: skeletonColorForScore(_score, detected: _detected),
                fontSize: 42,
                fontWeight: FontWeight.bold,
                height: 1,
              ),
            ),
          ),
        if (widget.demo != null)
          Positioned.fill(
            child: FollowDemoPip(
              aspectRatio: widget.demoAspect,
              waiting: false,
              child: widget.demo!,
            ),
          ),
      ],
    );
  }
}

List<int> focusJointsFor(MotionStandard rule) {
  final metric = rule.requiredMetric;
  if (metric == null) return const [];
  final names = <String>[
    if (metric.fromName != null) metric.fromName!,
    if (metric.toName != null) metric.toName!,
    ...metric.points,
  ];
  return [
    for (final name in names)
      if (landmarkIndex.containsKey(name)) landmarkIndex[name]!,
  ];
}
