/// 后端 API 根地址（与 AI 问诊、本页「测试后端」共用）。
///
/// - Web + Nginx 同域反代：留空（构建时 `--dart-define=BACKEND_BASE=`）
/// - Android 模拟器：`http://10.0.2.2:8080`
/// - 真机 / 独立后端端口：`http://101.201.170.95:8080`
const String kBackendBase = String.fromEnvironment(
  'BACKEND_BASE',
  defaultValue: 'http://101.201.170.95:8080',
);