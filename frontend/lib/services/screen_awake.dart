import 'package:flutter/services.dart';

/// 训练 / 跟做现场保持屏幕常亮（防息屏）。
/// Android 端由 MainActivity 的原生 MethodChannel 设置 FLAG_KEEP_SCREEN_ON；
/// 其它平台静默忽略。支持多个页面同时要求常亮（引用计数）。
class ScreenAwake {
  static const _channel = MethodChannel('app/screen_awake');
  static int _depth = 0;

  static Future<void> enable() async {
    _depth++;
    if (_depth > 1) return;
    try {
      await _channel.invokeMethod('enable');
    } catch (_) {
      // 测试环境 / 非 Android 平台：忽略
    }
  }

  static Future<void> disable() async {
    if (_depth == 0) return;
    _depth--;
    if (_depth > 0) return;
    try {
      await _channel.invokeMethod('disable');
    } catch (_) {}
  }
}
