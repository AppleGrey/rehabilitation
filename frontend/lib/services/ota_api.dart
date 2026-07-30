import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

class AppUpdateInfo {
  final bool hasUpdate;
  final bool forceUpdate;
  final String platform;
  final String? versionName;
  final int? versionCode;
  final String? changelog;
  final int? fileSize;
  final String? fileName;
  final String? downloadUrl;
  final String? releaseId;

  const AppUpdateInfo({
    required this.hasUpdate,
    this.forceUpdate = false,
    this.platform = 'android',
    this.versionName,
    this.versionCode,
    this.changelog,
    this.fileSize,
    this.fileName,
    this.downloadUrl,
    this.releaseId,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      hasUpdate: json['has_update'] == true,
      forceUpdate: json['force_update'] == true,
      platform: json['platform']?.toString() ?? 'android',
      versionName: json['version_name']?.toString(),
      versionCode: _asInt(json['version_code']),
      changelog: json['changelog']?.toString(),
      fileSize: _asInt(json['file_size']),
      fileName: json['file_name']?.toString(),
      downloadUrl: json['download_url']?.toString(),
      releaseId: json['release_id']?.toString(),
    );
  }

  String get absoluteDownloadUrl {
    final url = downloadUrl ?? '';
    return resolveBackendUrl(url);
  }

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }
}

class OtaApi {
  static Future<AppUpdateInfo> checkUpdate({
    required String platform,
    required int versionCode,
  }) async {
    final uri = Uri.parse(
      '$kCoreBase/api/app/update/check'
      '?platform=${Uri.encodeQueryComponent(platform)}'
      '&version_code=$versionCode',
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('检查更新失败: ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body);
    if (body is! Map<String, dynamic>) {
      throw Exception('检查更新返回格式错误');
    }
    return AppUpdateInfo.fromJson(body);
  }
}
