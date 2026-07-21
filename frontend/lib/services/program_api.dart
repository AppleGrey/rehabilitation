import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// 康复方案接口客户端（走 ai-svc；ai-svc 内部再调 core-svc 落库）。
class ProgramApi {
  static const _base = kBackendBase;

  /// 问诊完成 → 建疗程 + 返回 baseline 视频。
  static Future<Map<String, dynamic>> start(String sessionId) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/ai/program/start'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'session_id': sessionId}),
        )
        .timeout(const Duration(seconds: 25));
    return _decode(resp, '建疗程失败');
  }

  /// 据问诊 + baseline 表现生成当前分期方案。baseline 可为空。
  static Future<Map<String, dynamic>> generatePlan(
    String programId, {
    List<Map<String, dynamic>>? baseline,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/ai/program/$programId/plan'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'baseline': baseline}),
        )
        .timeout(const Duration(seconds: 60));
    return _decode(resp, '生成方案失败');
  }

  /// 读疗程全景。
  static Future<Map<String, dynamic>> get(String programId) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/program/$programId'))
        .timeout(const Duration(seconds: 25));
    return _decode(resp, '读取方案失败');
  }

  static Map<String, dynamic> _decode(http.Response resp, String errPrefix) {
    if (resp.statusCode != 200) {
      String detail = '${resp.statusCode}';
      try {
        final body = jsonDecode(utf8.decode(resp.bodyBytes));
        if (body is Map && body['detail'] != null) detail = body['detail'].toString();
      } catch (_) {}
      throw Exception('$errPrefix（$detail）');
    }
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }
}
