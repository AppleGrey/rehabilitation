import 'dart:io' show Platform;
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import '../theme/app_theme.dart';

/// 与 flutter-ml/google_ml_kit_flutter 示例 `coordinates_translator.dart` 一致，
/// 将 ML Kit 返回的**图像像素坐标**映射到与 [CameraPreview] 对齐的画布坐标。
double _mlKitTranslateX(
  double x,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      return x *
          canvasSize.width /
          (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation270deg:
      return canvasSize.width -
          x *
              canvasSize.width /
              (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      switch (cameraLensDirection) {
        case CameraLensDirection.back:
          return x * canvasSize.width / imageSize.width;
        default:
          return canvasSize.width - x * canvasSize.width / imageSize.width;
      }
  }
}

double _mlKitTranslateY(
  double y,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection _,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y *
          canvasSize.height /
          (Platform.isIOS ? imageSize.height : imageSize.width);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      return y * canvasSize.height / imageSize.height;
  }
}

/// 骨骼叠加层一帧所需数据；用 [ValueNotifier] 更新，避免每次全页 [setState] 抢主线程。
class _PoseStreamVisual {
  const _PoseStreamVisual({
    required this.poses,
    required this.imageSize,
    required this.rotation,
    required this.lensDirection,
    required this.kneeStatus,
    required this.spineStatus,
  });

  final List<Pose> poses;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection lensDirection;
  final String kneeStatus;
  final String spineStatus;

  bool get hasPose => poses.isNotEmpty;
}

class PoseDetectionPage extends StatefulWidget {
  final VoidCallback onBack;

  const PoseDetectionPage({super.key, required this.onBack});

  @override
  State<PoseDetectionPage> createState() => _PoseDetectionPageState();
}

class _PoseDetectionPageState extends State<PoseDetectionPage> {
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  bool _isProcessing = false;
  bool _isInitialized = false;
  bool _pageDisposed = false;
  String _statusMessage = '正在初始化...';
  bool _isCameraFront = true;

  final ValueNotifier<_PoseStreamVisual?> _poseVisual = ValueNotifier(null);

  /// ML Kit 官方示例：用于 Android 上根据屏幕方向补偿 rotation
  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// 上一帧平滑后的关键点，用于 EMA 抑制抖动。
  final Map<PoseLandmarkType, PoseLandmark> _smoothedLandmarks = {};

  /// 新观测权重：越高骨架越跟手（体感延迟更低），越低越稳。
  static const double _poseSmoothAlpha = 0.52;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted && !_pageDisposed) {
          setState(() {
            _statusMessage = '未找到摄像头';
          });
        }
        return;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection ==
            (_isCameraFront ? CameraLensDirection.front : CameraLensDirection.back),
        orElse: () => cameras.first,
      );

      await _poseDetector?.close();
      _smoothedLandmarks.clear();
      _poseVisual.value = null;
      // 流式场景用 base 模型：官方推荐，比 accurate 延迟更低、时序更稳。
      _poseDetector = PoseDetector(
        options: PoseDetectorOptions(
          mode: PoseDetectionMode.stream,
          model: PoseDetectionModel.base,
        ),
      );

      _cameraController = CameraController(
        camera,
        // 比 low 高一档，细节更好；负载由隔帧推理抵消。
        ResolutionPreset.medium,
        enableAudio: false,
        // Android 必须为 NV21，否则 InputImageConverter 报 ImageFormat is not supported
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_processImage);

      if (mounted && !_pageDisposed) {
        setState(() {
          _isInitialized = true;
          _statusMessage = '';
        });
      }
    } catch (e) {
      if (mounted && !_pageDisposed) {
        setState(() {
          _statusMessage = '摄像头初始化失败: $e';
        });
      }
    }
  }

  Future<void> _processImage(CameraImage image) async {
    if (_pageDisposed || _isProcessing) return;

    _isProcessing = true;

    try {
      final built = _buildPoseInput(image);
      if (built == null) {
        _isProcessing = false;
        return;
      }

      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) {
        _isProcessing = false;
        return;
      }
      final lens = controller.description.lensDirection;

      final poses = await _poseDetector!.processImage(built.input);

      if (_pageDisposed || !mounted) {
        _isProcessing = false;
        return;
      }

      late final List<Pose> displayPoses;
      late final String knee;
      late final String spine;

      if (poses.isEmpty) {
        _smoothedLandmarks.clear();
        displayPoses = [];
        knee = '检测中...';
        spine = '检测中...';
      } else {
        final smoothed = _smoothPose(poses.first);
        displayPoses = [smoothed];
        final r = _evaluatePoseResults(smoothed);
        knee = r.knee;
        spine = r.spine;
      }

      _poseVisual.value = _PoseStreamVisual(
        poses: displayPoses,
        imageSize: built.imageSize,
        rotation: built.rotation,
        lensDirection: lens,
        kneeStatus: knee,
        spineStatus: spine,
      );
    } catch (e) {
      debugPrint('Pose detection error: $e');
    }

    _isProcessing = false;
  }

  /// 对关键点做指数滑动平均，减轻 ML Kit 帧间噪声导致的「线条乱跳」。
  Pose _smoothPose(Pose raw) {
    final merged = <PoseLandmarkType, PoseLandmark>{};
    for (final e in raw.landmarks.entries) {
      final type = e.key;
      final cur = e.value;
      final prev = _smoothedLandmarks[type];
      if (prev == null) {
        merged[type] = cur;
      } else {
        var a = _poseSmoothAlpha * cur.likelihood.clamp(0.35, 1.0);
        if (cur.likelihood < 0.42) {
          a *= 0.65;
        }
        final b = 1.0 - a;
        merged[type] = PoseLandmark(
          type: type,
          x: prev.x * b + cur.x * a,
          y: prev.y * b + cur.y * a,
          z: prev.z * b + cur.z * a,
          likelihood: cur.likelihood,
        );
      }
    }
    _smoothedLandmarks
      ..clear()
      ..addAll(merged);
    return Pose(landmarks: Map<PoseLandmarkType, PoseLandmark>.from(merged));
  }

  /// 构建本帧 [InputImage]，并返回与检测坐标系一致的尺寸与旋转。
  ({InputImage input, Size imageSize, InputImageRotation rotation})?
      _buildPoseInput(CameraImage image) {
    try {
      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) return null;

      final camera = controller.description;
      final sensorOrientation = camera.sensorOrientation;

      InputImageRotation? rotation;
      if (Platform.isIOS) {
        rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
      } else {
        var rotationCompensation =
            _orientations[controller.value.deviceOrientation] ?? 0;
        if (camera.lensDirection == CameraLensDirection.front) {
          rotationCompensation =
              (sensorOrientation + rotationCompensation) % 360;
        } else {
          rotationCompensation =
              (sensorOrientation - rotationCompensation + 360) % 360;
        }
        rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
      }
      if (rotation == null) return null;

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;

      final imageSize =
          Size(image.width.toDouble(), image.height.toDouble());

      if (Platform.isAndroid) {
        final nv21 = _androidCameraImageToNv21(image);
        if (nv21 == null) return null;
        return (
          input: InputImage.fromBytes(
            bytes: nv21.bytes,
            metadata: InputImageMetadata(
              size: imageSize,
              rotation: rotation,
              format: InputImageFormat.nv21,
              bytesPerRow: nv21.bytesPerRow,
            ),
          ),
          imageSize: imageSize,
          rotation: rotation,
        );
      }

      if (format != InputImageFormat.bgra8888 || image.planes.length != 1) {
        return null;
      }
      final plane = image.planes.first;
      return (
        input: InputImage.fromBytes(
          bytes: plane.bytes,
          metadata: InputImageMetadata(
            size: imageSize,
            rotation: rotation,
            format: InputImageFormat.bgra8888,
            bytesPerRow: plane.bytesPerRow,
          ),
        ),
        imageSize: imageSize,
        rotation: rotation,
      );
    } catch (e) {
      return null;
    }
  }

  /// Android：ML Kit `fromBytes` 仅接受 NV21/YV12 字节布局。
  /// 单 plane NV21 直接使用；YUV_420_888（常见为三 plane）合并为 NV21。
  ({Uint8List bytes, int bytesPerRow})? _androidCameraImageToNv21(
    CameraImage image,
  ) {
    final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
    final w = image.width;
    final h = image.height;

    if (image.planes.length == 1 && format == InputImageFormat.nv21) {
      final p = image.planes.first;
      return (bytes: p.bytes, bytesPerRow: p.bytesPerRow);
    }

    if (image.planes.length == 3 &&
        (format == InputImageFormat.yuv_420_888 ||
            format == InputImageFormat.nv21)) {
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];
      final yRowStride = yPlane.bytesPerRow;
      final yPixelStride = yPlane.bytesPerPixel ?? 1;
      final uRowStride = uPlane.bytesPerRow;
      final uPixelStride = uPlane.bytesPerPixel ?? 1;
      final vRowStride = vPlane.bytesPerRow;
      final vPixelStride = vPlane.bytesPerPixel ?? 1;

      final ySize = w * h;
      final uvRowCount = h ~/ 2;
      final uvColCount = w ~/ 2;
      final uvSize = uvRowCount * uvColCount;
      final out = Uint8List(ySize + uvSize * 2);

      var outIndex = 0;
      for (var row = 0; row < h; row++) {
        for (var col = 0; col < w; col++) {
          out[outIndex++] =
              yPlane.bytes[row * yRowStride + col * yPixelStride];
        }
      }
      for (var row = 0; row < uvRowCount; row++) {
        for (var col = 0; col < uvColCount; col++) {
          final vIndex = row * vRowStride + col * vPixelStride;
          final uIndex = row * uRowStride + col * uPixelStride;
          out[outIndex++] = vPlane.bytes[vIndex];
          out[outIndex++] = uPlane.bytes[uIndex];
        }
      }
      return (bytes: out, bytesPerRow: w);
    }

    return null;
  }

  /// 膝角、脊柱状态文案（与画骨骼共用同一帧平滑结果）。
  ({String knee, String spine}) _evaluatePoseResults(Pose pose) {
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final leftKnee = pose.landmarks[PoseLandmarkType.leftKnee];
    final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];

    String knee = '检测中...';
    if (leftHip != null && leftKnee != null && leftAnkle != null) {
      final kneeAngle = _calculateAngle(
        leftHip.x, leftHip.y,
        leftKnee.x, leftKnee.y,
        leftAnkle.x, leftAnkle.y,
      );
      knee = (kneeAngle >= 160 && kneeAngle <= 180) ? '正常' : '异常';
    }

    String spine = '检测中...';
    if (leftShoulder != null && leftHip != null && leftKnee != null) {
      final spineAngle = _calculateAngle(
        leftShoulder.x, leftShoulder.y,
        leftHip.x, leftHip.y,
        leftKnee.x, leftKnee.y,
      );
      spine = (spineAngle >= 160 && spineAngle <= 180) ? '正常' : '异常';
    }

    return (knee: knee, spine: spine);
  }

  double _calculateAngle(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    final radians =
        atan2(y3 - y2, x3 - x2) - atan2(y1 - y2, x1 - x2);
    var angle = radians * 180 / pi;
    if (angle < 0) angle += 360;
    if (angle > 180) angle = 360 - angle;
    return angle;
  }

  @override
  void dispose() {
    _pageDisposed = true;
    final c = _cameraController;
    _cameraController = null;
    if (c != null) {
      if (c.value.isInitialized && c.value.isStreamingImages) {
        c.stopImageStream().then((_) => c.dispose()).catchError((_) => c.dispose());
      } else {
        c.dispose();
      }
    }
    _poseDetector?.close();
    _poseVisual.dispose();
    super.dispose();
  }

  Future<void> _switchCamera() async {
    final old = _cameraController;
    if (old != null && old.value.isInitialized && old.value.isStreamingImages) {
      await old.stopImageStream();
    }
    await old?.dispose();
    if (!mounted) return;
    _poseVisual.value = null;
    setState(() {
      _cameraController = null;
      _isCameraFront = !_isCameraFront;
      _isInitialized = false;
      _smoothedLandmarks.clear();
    });
    await _initializeCamera();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black45,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('姿态检测'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: widget.onBack,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.flip_camera_ios),
            onPressed: _switchCamera,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_isInitialized && _cameraController != null)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _cameraController!.value.previewSize!.height,
                  height: _cameraController!.value.previewSize!.width,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(_cameraController!),
                      ValueListenableBuilder<_PoseStreamVisual?>(
                        valueListenable: _poseVisual,
                        builder: (context, visual, _) {
                          return RepaintBoundary(
                            child: CustomPaint(
                              painter: PosePainter(
                                poses: visual?.poses ?? const [],
                                imageSize:
                                    visual?.imageSize ?? Size.zero,
                                rotation: visual?.rotation ??
                                    InputImageRotation.rotation0deg,
                                cameraLensDirection:
                                    visual?.lensDirection ??
                                        _cameraController!
                                            .description.lensDirection,
                                drawSkeleton:
                                    visual != null && visual.hasPose,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: AppTheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage,
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          // 次要信息：角度结论；骨骼线条为主（见 [PosePainter]）
          Positioned(
            left: 12,
            top: topInset + kToolbarHeight + 8,
            child: IgnorePointer(
              child: ValueListenableBuilder<_PoseStreamVisual?>(
                valueListenable: _poseVisual,
                builder: (context, visual, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        visual == null || !visual.hasPose
                            ? '正在检测人体…'
                            : '已检测到人体',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.92),
                          shadows: const [
                            Shadow(
                              blurRadius: 6,
                              color: Colors.black54,
                              offset: Offset(1, 1),
                            ),
                          ],
                        ),
                      ),
                      if (_isInitialized) ...[
                        const SizedBox(height: 6),
                        Text(
                          '膝角: ${visual?.kneeStatus ?? '检测中...'}  ·  脊柱: ${visual?.spineStatus ?? '检测中...'}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white70,
                            shadows: [
                              Shadow(
                                blurRadius: 4,
                                color: Colors.black54,
                                offset: Offset(1, 1),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 火柴人骨架：ML Kit 返回的是**图像像素坐标**，需映射到与 [CameraPreview] 一致的画布。
/// 线条使用高对比色，便于覆盖在视频上观察。
class PosePainter extends CustomPainter {
  PosePainter({
    required this.poses,
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
    required this.drawSkeleton,
  });

  final List<Pose> poses;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;
  final bool drawSkeleton;

  static const double _minLikelihood = 0.2;

  static final List<List<PoseLandmarkType>> _connections = [
    [PoseLandmarkType.nose, PoseLandmarkType.leftEyeInner],
    [PoseLandmarkType.leftEyeInner, PoseLandmarkType.leftEye],
    [PoseLandmarkType.leftEye, PoseLandmarkType.leftEyeOuter],
    [PoseLandmarkType.leftEyeOuter, PoseLandmarkType.leftEar],
    [PoseLandmarkType.nose, PoseLandmarkType.rightEyeInner],
    [PoseLandmarkType.rightEyeInner, PoseLandmarkType.rightEye],
    [PoseLandmarkType.rightEye, PoseLandmarkType.rightEyeOuter],
    [PoseLandmarkType.rightEyeOuter, PoseLandmarkType.rightEar],
    [PoseLandmarkType.leftMouth, PoseLandmarkType.rightMouth],
    [PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder],
    [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip],
    [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip],
    [PoseLandmarkType.leftHip, PoseLandmarkType.rightHip],
    [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow],
    [PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist],
    [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow],
    [PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist],
    [PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee],
    [PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle],
    [PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee],
    [PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle],
    [PoseLandmarkType.leftAnkle, PoseLandmarkType.leftHeel],
    [PoseLandmarkType.leftHeel, PoseLandmarkType.leftFootIndex],
    [PoseLandmarkType.rightAnkle, PoseLandmarkType.rightHeel],
    [PoseLandmarkType.rightHeel, PoseLandmarkType.rightFootIndex],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (!drawSkeleton || poses.isEmpty) return;
    if (imageSize.width < 1 || imageSize.height < 1) return;

    final pose = poses.first;
    const lineColor = Color(0xFF00E5FF);
    const pointColor = Color(0xFFFFEB3B);

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final shadowPaint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 6.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (final pair in _connections) {
      final a = pose.landmarks[pair[0]];
      final b = pose.landmarks[pair[1]];
      if (a == null || b == null) continue;
      if (a.likelihood < _minLikelihood || b.likelihood < _minLikelihood) {
        continue;
      }
      final p1 = _toCanvas(a, size);
      final p2 = _toCanvas(b, size);
      canvas.drawLine(p1, p2, shadowPaint);
      canvas.drawLine(p1, p2, linePaint);
    }

    final fillPaint = Paint()
      ..color = pointColor
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final landmark in pose.landmarks.values) {
      if (landmark.likelihood < _minLikelihood) continue;
      final p = _toCanvas(landmark, size);
      canvas.drawCircle(p, 7, fillPaint);
      canvas.drawCircle(p, 7, borderPaint);
    }
  }

  Offset _toCanvas(PoseLandmark landmark, Size canvasSize) {
    return Offset(
      _mlKitTranslateX(
        landmark.x,
        canvasSize,
        imageSize,
        rotation,
        cameraLensDirection,
      ),
      _mlKitTranslateY(
        landmark.y,
        canvasSize,
        imageSize,
        rotation,
        cameraLensDirection,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.poses != poses ||
        oldDelegate.drawSkeleton != drawSkeleton ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection;
  }
}
