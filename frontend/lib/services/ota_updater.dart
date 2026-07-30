import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ota_api.dart';

/// App OTA：检查、弹窗、下载安装。
class OtaUpdater {
  OtaUpdater._();

  static const _skipKeyPrefix = 'ota_skip_version_';
  static bool _dialogShowing = false;

  static Future<PackageInfo> currentInfo() => PackageInfo.fromPlatform();

  static String platformName() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// 启动时静默检查；有更新则弹窗。手动检查时 [manual]=true，无更新也会提示。
  static Future<void> checkAndPrompt(
    BuildContext context, {
    bool manual = false,
  }) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      if (manual && context.mounted) {
        _toast(context, '当前平台不支持应用内更新');
      }
      return;
    }

    try {
      final info = await currentInfo();
      final versionCode = int.tryParse(info.buildNumber) ?? 0;
      final update = await OtaApi.checkUpdate(
        platform: platformName(),
        versionCode: versionCode,
      );

      if (!context.mounted) return;

      if (!update.hasUpdate) {
        if (manual) {
          _toast(context, '已是最新版本（${info.version}+${info.buildNumber}）');
        }
        return;
      }

      if (!manual && !update.forceUpdate) {
        final skipped = await _isSkipped(update.versionCode ?? 0);
        if (skipped) return;
      }

      if (!context.mounted) return;
      await showUpdateDialog(context, update, current: info);
    } catch (e) {
      if (manual && context.mounted) {
        _toast(context, '检查更新失败：$e');
      }
    }
  }

  static Future<void> showUpdateDialog(
    BuildContext context,
    AppUpdateInfo update, {
    PackageInfo? current,
  }) async {
    if (_dialogShowing || !context.mounted) return;
    _dialogShowing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: !update.forceUpdate,
        builder: (ctx) => _UpdateDialog(update: update, current: current),
      );
    } finally {
      _dialogShowing = false;
    }
  }

  static Future<bool> _isSkipped(int versionCode) async {
    if (versionCode <= 0) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_skipKeyPrefix$versionCode') == true;
  }

  static Future<void> skipVersion(int versionCode) async {
    if (versionCode <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_skipKeyPrefix$versionCode', true);
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 下载 APK 并调起系统安装器（仅 Android）。
  static Future<void> downloadAndInstall(
    BuildContext context,
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw Exception('仅 Android 支持应用内安装');
    }
    final url = update.absoluteDownloadUrl;
    if (url.isEmpty) {
      throw Exception('下载地址为空');
    }

    final dir = await getTemporaryDirectory();
    final name = (update.fileName?.isNotEmpty == true)
        ? update.fileName!
        : 'rehab-${update.versionName ?? 'update'}.apk';
    final file = File('${dir.path}/$name');

    final req = http.Request('GET', Uri.parse(url));
    final resp = await req.send().timeout(const Duration(minutes: 10));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('下载失败: HTTP ${resp.statusCode}');
    }

    final total = resp.contentLength ?? update.fileSize ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(received / total);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      throw Exception(result.message);
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  final AppUpdateInfo update;
  final PackageInfo? current;

  const _UpdateDialog({required this.update, this.current});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _startDownload() async {
    if (!Platform.isAndroid) {
      setState(() {
        _error = 'iOS 请前往 App Store 更新（当前仅支持 Android APK）';
      });
      return;
    }
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    try {
      await OtaUpdater.downloadAndInstall(
        context,
        widget.update,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted && !widget.update.forceUpdate) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final cur = widget.current;
    return PopScope(
      canPop: !u.forceUpdate && !_downloading,
      child: AlertDialog(
        title: Text(u.forceUpdate ? '必须更新后才能继续使用' : '发现新版本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '最新版本：${u.versionName ?? '-'}+${u.versionCode ?? '-'}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (cur != null) ...[
              const SizedBox(height: 4),
              Text(
                '当前版本：${cur.version}+${cur.buildNumber}',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
              ),
            ],
            if ((u.changelog ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('更新内容', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(u.changelog!.trim()),
                ),
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 6),
              Text(
                _progress > 0
                    ? '下载中… ${(_progress * 100).toStringAsFixed(0)}%'
                    : '下载中…',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
        actions: [
          if (!u.forceUpdate && !_downloading)
            TextButton(
              onPressed: () async {
                await OtaUpdater.skipVersion(u.versionCode ?? 0);
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('以后再说'),
            ),
          TextButton(
            onPressed: _downloading ? null : _startDownload,
            child: Text(Platform.isAndroid ? '立即更新' : '前往更新'),
          ),
        ],
      ),
    );
  }
}
