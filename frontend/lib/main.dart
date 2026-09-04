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

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const RehabilitationApp());
}
