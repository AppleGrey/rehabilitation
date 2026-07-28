import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// 康复方案接口客户端（走 ai-svc；ai-svc 内部再调 core-svc 落库）。
class ProgramApi {
  static const _base = kBackendBase;

  /// 问诊完成 → 预览 baseline 视频（不建库）。
  static Future<Map<String, dynamic>> start(String sessionId) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/ai/program/start'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'session_id': sessionId}),
        )
        .timeout(const Duration(seconds: 25));
    return _decode(resp, '预览基线失败');
  }

  /// 点击生成：建占位(generating) 并后台出方案。
  static Future<Map<String, dynamic>> createAndGenerate(
    String sessionId, {
    List<Map<String, dynamic>>? baseline,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/ai/program/create-and-generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'session_id': sessionId, 'baseline': baseline}),
        )
        .timeout(const Duration(seconds: 60));
    return _decode(resp, '创建方案失败');
  }

  /// 按问诊会话取最近疗程；没有则返回 null。
  static Future<Map<String, dynamic>?> bySession(String sessionId) async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/ai/program/by-session/$sessionId'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 404) return null;
      return _decode(resp, '读取方案失败');
    } catch (_) {
      return null;
    }
  }

  /// 某问诊下全部方案。
  static Future<List<Map<String, dynamic>>> listBySession(String sessionId) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/programs?session_id=${Uri.encodeQueryComponent(sessionId)}'))
        .timeout(const Duration(seconds: 25));
    final data = _decode(resp, '列出方案失败');
    return (data['programs'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  /// 最近全部方案（无账号时方案页用）。
  static Future<List<Map<String, dynamic>>> listAll({int limit = 50}) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/programs?limit=$limit'))
        .timeout(const Duration(seconds: 40));
    final data = _decode(resp, '列出方案失败');
    return (data['programs'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  /// 是否已有可查看的方案（进行中 / 生成中）。
  static bool hasViewablePlan(Map<String, dynamic>? prog) {
    if (prog == null) return false;
    final status = prog['status']?.toString() ?? '';
    return status == 'active' || status == 'generating';
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

  /// 读取疗程全景。
  static Future<Map<String, dynamic>> get(String programId) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/program/$programId'))
        .timeout(const Duration(seconds: 25));
    return _decode(resp, '读取方案失败');
  }

  /// 删除疗程。
  static Future<void> delete(String programId) async {
    final resp = await http
        .delete(Uri.parse('$_base/api/ai/program/$programId'))
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode == 404) return;
    _decode(resp, '删除方案失败');
  }

  /// 查动作评估任务状态。失败/未完成返回 null。
  static Future<Map<String, dynamic>?> assessStatus(String taskId) async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/assess/status/$taskId'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// K4：做完本轮训练 → 进阶决策。
  static Future<Map<String, dynamic>> progress(String programId) async {
    final resp = await http
        .post(Uri.parse('$_base/api/ai/program/$programId/progress'),
            headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 90));
    return _decode(resp, '进阶决策失败');
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
