/// 后端 API 根地址（与 AI 问诊、本页「测试后端」共用）。
///
/// - Web + Nginx 同域反代：留空（构建时 `--dart-define=BACKEND_BASE=`）
/// - Android 模拟器：`http://10.0.2.2:8000`
/// - 真机：改为电脑局域网 IP，例如 `http://192.168.1.112:8000`
const String kBackendBase = String.fromEnvironment(
  'BACKEND_BASE',
  defaultValue: 'http://101.201.170.95:8080',
);