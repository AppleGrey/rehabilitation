/// AI 服务根地址（问诊 / 评估）。
///
/// - Android 模拟器：`http://10.0.2.2:8000`
/// - 真机：电脑局域网 IP，例如 `http://192.168.1.112:8000`
const String kBackendBase = String.fromEnvironment(
  'BACKEND_BASE',
  defaultValue: 'http://192.168.1.112:8000',
);

/// core-svc 根地址（视频列表 / 播放等业务边缘能力）。
///
/// - Android 模拟器：`http://10.0.2.2:8081`
/// - 真机：电脑局域网 IP，例如 `http://192.168.1.112:8081`
const String kCoreBase = String.fromEnvironment(
  'CORE_BASE',
  defaultValue: 'http://192.168.1.112:8081',
);

/// 将后端返回的相对路径解析为绝对 URL。
/// `/api/videos/*` 走 core-svc，其余默认走 ai-svc。
String resolveBackendUrl(String pathOrUrl) {
  if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
    return pathOrUrl;
  }
  final path = pathOrUrl.startsWith('/') ? pathOrUrl : '/$pathOrUrl';
  if (path.startsWith('/api/videos')) {
    return '$kCoreBase$path';
  }
  return '$kBackendBase$path';
}
