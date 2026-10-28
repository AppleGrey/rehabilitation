import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'auth_store.dart';

/// 服务端问诊历史（K1 策略会话）：列表 / 对话记录 / 删除。
/// 问诊历史存服务器后，换设备、重装都能看到；本地缓存仅作离线兜底。
class ConsultApi {
  static const _base = kBackendBase;

  /// 会话列表：[{session_id, title, preview, updated_at, is_done, outcome}]
  static Future<List<Map<String, dynamic>>> sessions({int limit = 50}) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/consult/sessions?limit=$limit'),
            headers: AuthStore.headers())
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) throw Exception('加载问诊记录失败');
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (body['sessions'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 某个会话的完整对话记录与展示态。
  static Future<Map<String, dynamic>> transcript(String sessionId) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/consult/$sessionId/transcript'),
            headers: AuthStore.headers())
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) throw Exception('加载问诊记录失败');
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 删除一条问诊记录（服务端 + 本地由调用方处理）。
  static Future<void> deleteSession(String sessionId) async {
    final resp = await http
        .delete(Uri.parse('$_base/api/ai/consult/$sessionId'),
            headers: AuthStore.headers())
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200 && resp.statusCode != 404) {
      throw Exception('删除问诊记录失败');
    }
  }
}
