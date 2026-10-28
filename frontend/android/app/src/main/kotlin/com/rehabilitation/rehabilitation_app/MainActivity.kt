package com.rehabilitation.rehabilitation_app

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 训练 / 跟做期间保持屏幕常亮：Dart 侧 ScreenAwake 通过 MethodChannel("app/screen_awake") 调用。
 * 不引入额外插件，直接操作窗口的 FLAG_KEEP_SCREEN_ON。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "app/screen_awake"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(true)
                    }
                    "disable" -> {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
