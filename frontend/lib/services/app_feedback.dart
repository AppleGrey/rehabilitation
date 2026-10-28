import 'package:flutter/services.dart';

/// 训练现场的轻量反馈：系统嗒声 + 震动。
/// 不引入音频资源（弱网离线也可用），音效由系统通道提供。
class AppFeedback {
  const AppFeedback._();

  /// 倒计时每秒的「嗒」
  static void tick() {
    SystemSound.play(SystemSoundType.click);
    HapticFeedback.selectionClick();
  }

  /// 开始录制 / 进入下一组
  static void start() {
    HapticFeedback.mediumImpact();
  }

  /// 结束录制 / 提交
  static void stop() {
    HapticFeedback.heavyImpact();
  }

  /// 完成、提醒（休息结束、评估完成）
  static void done() {
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
  }

  /// 出错提醒
  static void warn() {
    HapticFeedback.heavyImpact();
  }
}
