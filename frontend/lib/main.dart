import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'services/auth_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 先把本地登录态读进内存，首帧就能决定进登录页还是主界面。
  await AuthStore.load();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  // 横竖屏策略在 app.dart 的 OrientationGate 里按设备形态决定：
  // 手机（窄屏）锁定竖屏；平板放开横屏（首页/进度页有专门的横屏分栏布局）。
  runApp(const RehabilitationApp());
}
