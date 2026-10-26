import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'follow_models.dart';

const _orientations = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

const _mlToIndex = <PoseLandmarkType, int>{
  PoseLandmarkType.nose: 0,
  PoseLandmarkType.leftShoulder: 11,
  PoseLandmarkType.rightShoulder: 12,
  PoseLandmarkType.leftElbow: 13,
  PoseLandmarkType.rightElbow: 14,
  PoseLandmarkType.leftWrist: 15,
  PoseLandmarkType.rightWrist: 16,
  PoseLandmarkType.leftHip: 23,
  PoseLandmarkType.rightHip: 24,
  PoseLandmarkType.leftKnee: 25,
  PoseLandmarkType.rightKnee: 26,
  PoseLandmarkType.leftAnkle: 27,
  PoseLandmarkType.rightAnkle: 28,
};

class DetectedPose {
  const DetectedPose({required this.preview, this.candidates = const []});

  /// 与直立预览对齐的 0–1 坐标，计次和叠骨骼共用同一套点。
  final List<OffsetLandmark> preview;

  /// 同一帧里检测到的全部人体，用于锁定体验者、忽略路人。
  final List<List<OffsetLandmark>> candidates;

  static const empty = DetectedPose(preview: []);
}

class LocalPoseDetector {
  LocalPoseDetector()
    : _detector = PoseDetector(
        options: PoseDetectorOptions(
          mode: PoseDetectionMode.stream,
          model: PoseDetectionModel.base,
        ),
      );

  final PoseDetector _detector;

  Future<void> close() => _detector.close();

  Future<DetectedPose> detect(
    CameraImage image,
    CameraController controller, {
    InputImageRotation? rotation,
    Uint8List? bytes,
    int? bytesPerRow,
  }) async {
    final input = inputImageFromCamera(
      image,
      controller,
      rotation: rotation,
      bytes: bytes,
      bytesPerRow: bytesPerRow,
    );
    if (input == null) return DetectedPose.empty;
    final poses = await _detector.processImage(input);
    if (poses.isEmpty) return DetectedPose.empty;
    final meta = input.metadata;
    if (meta == null) return DetectedPose.empty;
    final candidates = [
      for (final pose in poses)
        landmarksFromPose(
          pose,
          meta.size,
          meta.rotation,
          controller.description.lensDirection,
        ),
    ];
    return DetectedPose(
      preview: candidates.isEmpty ? const [] : candidates.first,
      candidates: candidates,
    );
  }
}

InputImageRotation? cameraInputRotation(CameraController controller) {
  final camera = controller.description;
  final sensorOrientation = camera.sensorOrientation;
  if (Platform.isIOS) {
    return InputImageRotationValue.fromRawValue(sensorOrientation);
  }
  final orientation =
      controller.value.lockedCaptureOrientation ??
      controller.value.deviceOrientation;
  var compensation =
      _orientations[orientation] ??
      _orientations[DeviceOrientation.portraitUp]!;
  compensation = camera.lensDirection == CameraLensDirection.front
      ? (sensorOrientation + compensation) % 360
      : (sensorOrientation - compensation + 360) % 360;
  return InputImageRotationValue.fromRawValue(compensation);
}

InputImage? inputImageFromCamera(
  CameraImage image,
  CameraController controller, {
  InputImageRotation? rotation,
  Uint8List? bytes,
  int? bytesPerRow,
}) {
  final inputRotation = rotation ?? cameraInputRotation(controller);
  if (inputRotation == null) return null;

  final format = InputImageFormatValue.fromRawValue(image.format.raw);
  if (format == null ||
      (Platform.isAndroid && format != InputImageFormat.nv21) ||
      (Platform.isIOS && format != InputImageFormat.bgra8888)) {
    return null;
  }
  if (image.planes.length != 1) return null;
  final plane = image.planes.first;

  return InputImage.fromBytes(
    bytes: bytes ?? plane.bytes,
    metadata: InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: inputRotation,
      format: format,
      bytesPerRow: bytesPerRow ?? plane.bytesPerRow,
    ),
  );
}

/// ML Kit 像素坐标 → 与直立预览对齐的 0–1 坐标。
List<OffsetLandmark> landmarksFromPose(
  Pose pose,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection lens,
) {
  // Android ML Kit 返回转正后的像素坐标；前置镜像只在显示时应用一次。
  // iOS 的 BGRA 已由 camera_avfoundation 转正、镜像，直接按原尺寸归一化。
  final swapAxes =
      !Platform.isIOS &&
      (rotation == InputImageRotation.rotation90deg ||
          rotation == InputImageRotation.rotation270deg);
  final width = swapAxes ? imageSize.height : imageSize.width;
  final height = swapAxes ? imageSize.width : imageSize.height;
  if (width <= 0 || height <= 0 || !width.isFinite || !height.isFinite) {
    return const [];
  }
  final mirror = !Platform.isIOS && lens == CameraLensDirection.front;
  final out = List<OffsetLandmark>.generate(
    33,
    (_) => const OffsetLandmark(x: 0, y: 0, v: 0),
  );
  for (final entry in _mlToIndex.entries) {
    final lm = pose.landmarks[entry.key];
    if (lm == null || !lm.x.isFinite || !lm.y.isFinite) continue;
    final x = lm.x / width;
    out[entry.value] = OffsetLandmark(
      x: mirror ? 1 - x : x,
      y: lm.y / height,
      v: lm.likelihood.isFinite ? lm.likelihood.clamp(0.0, 1.0) : 0,
    );
  }
  return out;
}
