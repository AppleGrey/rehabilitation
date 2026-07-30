/// AI 服务根地址（问诊 / 评估）。
///
/// - Android 模拟器：`http://10.0.2.2:8000`
/// - 真机：电脑局域网 IP，例如 `http://192.168.1.112:8000`
/// - 服务器：`http://101.201.170.95:18000`
const String kBackendBase = String.fromEnvironment(
  'BACKEND_BASE',
  defaultValue: 'http://192.168.1.112:8000',
);

/// core-svc 根地址（视频列表 / 播放 / OTA 检查更新）。
///
/// - Android 模拟器：`http://10.0.2.2:8081`
/// - 真机：电脑局域网 IP，例如 `http://192.168.1.112:8081`
/// - 服务器：`http://101.201.170.95:18081`
const String kCoreBase = String.fromEnvironment(
  'CORE_BASE',
  defaultValue: 'http://192.168.1.112:8081',
);

/// 将后端返回的相对路径解析为绝对 URL。
/// `/api/videos/*`、`/api/app/*` 走 core-svc，其余默认走 ai-svc。
String resolveBackendUrl(String pathOrUrl) {
  if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
    return pathOrUrl;
  }
  final path = pathOrUrl.startsWith('/') ? pathOrUrl : '/$pathOrUrl';
  if (path.startsWith('/api/videos') ||
      path.startsWith('/api/uploads') ||
      path.startsWith('/api/app')) {
    return '$kCoreBase$path';
  }
  return '$kBackendBase$path';
}
