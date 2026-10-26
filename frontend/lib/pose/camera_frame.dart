import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'follow_models.dart';
import 'skeleton_painter.dart';

/// 立刻拷贝 ImageStream 帧，避免 await 之后底层 buffer 被回收。
class CapturedCameraFrame {
  CapturedCameraFrame._({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.nv21,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final bool nv21;

  static CapturedCameraFrame? tryCapture(CameraImage image) {
    if (image.planes.length != 1 || image.width <= 0 || image.height <= 0) {
      return null;
    }
    final plane = image.planes.first;
    final nv21 = image.format.group == ImageFormatGroup.nv21;
    final bgra = image.format.group == ImageFormatGroup.bgra8888;
    if (!nv21 && !bgra) return null;
    late Uint8List bytes;
    var bytesPerRow = plane.bytesPerRow;
    if (nv21) {
      final layout = _nv21Layout(
        plane.bytes.length,
        image.width,
        image.height,
        plane.bytesPerRow,
      );
      if (layout == null) return null;
      final (yStride, uvOffset, uvStride) = layout;
      final uvRowBytes = (image.width + 1) & ~1;
      final uvRows = (image.height + 1) >> 1;
      final ySize = image.width * image.height;
      final packedLength = ySize + uvRowBytes * uvRows;
      // Android ML Kit 的 NV21 输入忽略 bytesPerRow。采集时统一打包，
      // 让检测与显示消费完全相同的像素；常见的 CameraX packed 帧只拷贝一次。
      if (yStride == image.width && uvStride == uvRowBytes) {
        bytes = Uint8List.fromList(
          Uint8List.sublistView(plane.bytes, 0, packedLength),
        );
      } else {
        bytes = Uint8List(packedLength);
        for (var y = 0; y < image.height; y++) {
          final destination = y * image.width;
          bytes.setRange(
            destination,
            destination + image.width,
            plane.bytes,
            y * yStride,
          );
        }
        for (var y = 0; y < uvRows; y++) {
          final destination = ySize + y * uvRowBytes;
          bytes.setRange(
            destination,
            destination + uvRowBytes,
            plane.bytes,
            uvOffset + y * uvStride,
          );
        }
      }
      bytesPerRow = image.width;
    } else {
      if (plane.bytesPerRow < image.width * 4 ||
          plane.bytes.length <
              (image.height - 1) * plane.bytesPerRow + image.width * 4) {
        return null;
      }
      bytes = Uint8List.fromList(plane.bytes);
    }
    return CapturedCameraFrame._(
      bytes: bytes,
      width: image.width,
      height: image.height,
      bytesPerRow: bytesPerRow,
      nv21: nv21,
    );
  }

  Future<ui.Image> toUiImage({
    required InputImageRotation rotation,
    required bool mirror,
  }) => _decode(
    _convertPixels(
      bytes,
      width,
      height,
      bytesPerRow,
      nv21,
      quarterTurnsFor(rotation),
      mirror,
    ),
  );
}

/// 为实时预览复用一个转换 isolate；整帧转换后才交给调用方配对发布。
///
/// [dispose] 会结束待转换请求。已经进入引擎的解码会在完成后释放图像，
/// 并以 StateError 结束，因此调用方不会收到销毁后的迟到图像。
class CameraFrameDecoder {
  Isolate? _isolate;
  ReceivePort? _responses;
  Completer<SendPort>? _ready;
  final _pending = <int, Completer<_TransferredPixels>>{};
  var _nextId = 0;
  var _disposed = false;

  Future<ui.Image> decode(
    CapturedCameraFrame frame, {
    required InputImageRotation rotation,
    required bool mirror,
  }) async {
    _checkAlive();
    final turns = quarterTurnsFor(rotation);
    late _Pixels pixels;
    if (!frame.nv21 && turns == 0 && !mirror) {
      // BGRA 可让引擎直接读取行跨度，不再做打包和 isolate 往返。
      pixels = _Pixels(
        frame.bytes,
        frame.width,
        frame.height,
        frame.bytesPerRow,
        true,
      );
    } else {
      final port = await _workerPort();
      _checkAlive();
      final id = _nextId++;
      final result = Completer<_TransferredPixels>();
      _pending[id] = result;
      try {
        port.send(
          _ConversionRequest(
            id,
            TransferableTypedData.fromList([frame.bytes]),
            frame.width,
            frame.height,
            frame.bytesPerRow,
            frame.nv21,
            turns,
            mirror,
          ),
        );
        final converted = await result.future;
        _checkAlive();
        pixels = _Pixels(
          converted.bytes.materialize().asUint8List(),
          converted.width,
          converted.height,
          converted.bytesPerRow,
          converted.bgra,
        );
      } finally {
        _pending.remove(id);
      }
    }
    final image = await _decode(pixels);
    if (_disposed) {
      image.dispose();
      _checkAlive();
    }
    return image;
  }

  Future<SendPort> _workerPort() {
    final ready = _ready;
    if (ready != null) return ready.future;
    final starting = Completer<SendPort>();
    _ready = starting;
    final responses = ReceivePort();
    _responses = responses;
    responses.listen((Object? message) {
      if (message is SendPort) {
        starting.complete(message);
      } else if (message is _TransferredPixels) {
        _pending.remove(message.id)?.complete(message);
      } else if (message is _ConversionFailure) {
        _pending
            .remove(message.id)
            ?.completeError(
              StateError(message.error),
              StackTrace.fromString(message.stack),
            );
      } else {
        // onError / onExit 共用响应端口；意外退出后允许下一帧重新启动。
        final error = message is List
            ? StateError('Camera frame worker failed: ${message.first}')
            : StateError('Camera frame worker exited');
        _stopWorker(error, StackTrace.current);
      }
    });
    unawaited(
      Isolate.spawn<SendPort>(
        _convertFrames,
        responses.sendPort,
        onError: responses.sendPort,
        onExit: responses.sendPort,
        debugName: 'camera-frame-converter',
      ).then(
        (worker) {
          if (_disposed || _responses != responses) {
            worker.kill(priority: Isolate.immediate);
          } else {
            _isolate = worker;
          }
        },
        onError: (Object error, StackTrace stack) {
          if (_responses == responses) _stopWorker(error, stack);
        },
      ),
    );
    return starting.future;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('CameraFrameDecoder has been disposed');
  }

  void _stopWorker(Object error, StackTrace stack) {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _responses?.close();
    _responses = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) ready.completeError(error, stack);
    final pending = _pending.values.toList();
    _pending.clear();
    for (final result in pending) {
      result.completeError(error, stack);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopWorker(
      StateError('CameraFrameDecoder has been disposed'),
      StackTrace.current,
    );
  }
}

class _ConversionRequest {
  const _ConversionRequest(
    this.id,
    this.bytes,
    this.width,
    this.height,
    this.bytesPerRow,
    this.nv21,
    this.turns,
    this.mirror,
  );

  final int id;
  final TransferableTypedData bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final bool nv21;
  final int turns;
  final bool mirror;
}

class _TransferredPixels {
  _TransferredPixels(this.id, _Pixels pixels)
    : bytes = TransferableTypedData.fromList([pixels.bytes]),
      width = pixels.width,
      height = pixels.height,
      bytesPerRow = pixels.bytesPerRow,
      bgra = pixels.bgra;

  final int id;
  final TransferableTypedData bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final bool bgra;
}

class _ConversionFailure {
  const _ConversionFailure(this.id, this.error, this.stack);

  final int id;
  final String error;
  final String stack;
}

void _convertFrames(SendPort results) {
  final requests = ReceivePort();
  results.send(requests.sendPort);
  requests.listen((Object? message) {
    if (message is! _ConversionRequest) return;
    try {
      final pixels = _convertPixels(
        message.bytes.materialize().asUint8List(),
        message.width,
        message.height,
        message.bytesPerRow,
        message.nv21,
        message.turns,
        message.mirror,
      );
      results.send(_TransferredPixels(message.id, pixels));
    } catch (error, stack) {
      results.send(
        _ConversionFailure(message.id, error.toString(), stack.toString()),
      );
    }
  });
}

class _Pixels {
  const _Pixels(
    this.bytes,
    this.width,
    this.height,
    this.bytesPerRow,
    this.bgra,
  );

  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final bool bgra;
}

Future<ui.Image> _decode(_Pixels pixels) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels.bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: pixels.width,
      height: pixels.height,
      rowBytes: pixels.bytesPerRow,
      pixelFormat: pixels.bgra
          ? ui.PixelFormat.bgra8888
          : ui.PixelFormat.rgba8888,
    );
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// (Y 行跨度, VU 起点, VU 行跨度)。VU 每个样本始终包含两个字节。
(int, int, int)? _nv21Layout(int length, int width, int height, int stride) {
  if (stride < width) return null;
  final uvRowBytes = (width + 1) & ~1;
  final uvRows = (height + 1) >> 1;
  final ySize = stride * height;
  if (stride >= uvRowBytes &&
      length >= ySize + stride * (uvRows - 1) + uvRowBytes) {
    return (stride, ySize, stride);
  }
  // 少数相机上报 padding stride，但返回的 NV21 已打包。只接受完整的
  // packed 长度，避免把一个截断的 padded buffer 误当成完整图像。
  if (length == width * height + uvRowBytes * uvRows) {
    return (width, width * height, uvRowBytes);
  }
  return null;
}

_Pixels _convertPixels(
  Uint8List bytes,
  int width,
  int height,
  int stride,
  bool nv21,
  int turns,
  bool mirror,
) {
  if (!nv21 && turns == 0 && !mirror) {
    return _Pixels(bytes, width, height, stride, true);
  }
  final outWidth = turns.isOdd ? height : width;
  final outHeight = turns.isOdd ? width : height;
  // 将源像素直接写入最终位置，旋转和镜像不再各分配一张 RGBA 图。
  var (origin, xStep, yStep) = switch (turns) {
    1 => (height - 1, height, -1),
    2 => (width * height - 1, -1, -width),
    3 => ((width - 1) * height, -height, 1),
    _ => (0, 1, width),
  };
  if (mirror) {
    origin += outWidth - 1 - 2 * (origin % outWidth);
    if (turns.isOdd) {
      yStep = -yStep;
    } else {
      xStep = -xStep;
    }
  }
  final out = Uint8List(width * height * 4);
  if (nv21) {
    final layout = _nv21Layout(bytes.length, width, height, stride);
    if (layout == null) throw const FormatException('Incomplete NV21 frame');
    final (yStride, uvOffset, uvStride) = layout;
    final pixels = out.buffer.asUint32List();
    for (var y = 0; y < height; y++) {
      final yRow = y * yStride;
      final uvRow = uvOffset + (y >> 1) * uvStride;
      var destination = origin + y * yStep;
      for (var x = 0; x < width; x += 2) {
        final v = bytes[uvRow + x] - 128;
        final u = bytes[uvRow + x + 1] - 128;
        final red = 1634 * v;
        final green = -833 * v - 400 * u;
        final blue = 2066 * u;
        pixels[destination] = _rgbaPixel(bytes[yRow + x], red, green, blue);
        destination += xStep;
        if (x + 1 < width) {
          pixels[destination] = _rgbaPixel(
            bytes[yRow + x + 1],
            red,
            green,
            blue,
          );
          destination += xStep;
        }
      }
    }
  } else {
    for (var y = 0; y < height; y++) {
      var source = y * stride;
      var destination = (origin + y * yStep) * 4;
      for (var x = 0; x < width; x++) {
        out[destination] = bytes[source];
        out[destination + 1] = bytes[source + 1];
        out[destination + 2] = bytes[source + 2];
        out[destination + 3] = bytes[source + 3];
        source += 4;
        destination += xStep * 4;
      }
    }
  }
  return _Pixels(out, outWidth, outHeight, outWidth * 4, !nv21);
}

int _rgbaPixel(int y, int red, int green, int blue) {
  final luma = y > 16 ? 1192 * (y - 16) : 0;
  final r = _clampByte((luma + red) >> 10);
  final g = _clampByte((luma + green) >> 10);
  final b = _clampByte((luma + blue) >> 10);
  if (Endian.host == Endian.little) {
    return 0xff000000 | (b << 16) | (g << 8) | r;
  }
  return (r << 24) | (g << 16) | (b << 8) | 0xff;
}

int _clampByte(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return v;
}

int quarterTurnsFor(InputImageRotation rotation) {
  return switch (rotation) {
    InputImageRotation.rotation0deg => 0,
    InputImageRotation.rotation90deg => 1,
    InputImageRotation.rotation180deg => 2,
    InputImageRotation.rotation270deg => 3,
  };
}

/// 画面和骨骼来自同一帧，并已转成与预览相同的朝向。
class SyncedPosePreview extends StatelessWidget {
  const SyncedPosePreview({
    super.key,
    required this.image,
    required this.landmarks,
    required this.score,
    required this.detected,
    this.focusJoints = const [24, 26, 28],
    this.color,
  });

  final ui.Image image;
  final List<OffsetLandmark> landmarks;
  final double score;
  final bool detected;
  final List<int> focusJoints;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: image.width.toDouble(),
          height: image.height.toDouble(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RawImage(
                image: image,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
              ),
              CustomPaint(
                painter: SkeletonPainter(
                  landmarks: landmarks,
                  mirrorX: false,
                  score: score,
                  detected: detected,
                  focusJoints: focusJoints,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
