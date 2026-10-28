import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'auth_store.dart';

/// 康复方案接口客户端（走 ai-svc；ai-svc 内部再调 core-svc 落库）。
/// 这些接口都需要登录：ai-svc 解开令牌拿 user_id，用于方案归属与列表过滤。
class ProgramApi {
  static const _base = kBackendBase;

  static Map<String, String> _jsonHeaders() =>
      AuthStore.headers({'Content-Type': 'application/json'});

  /// 问诊完成 → 预览 baseline 视频（不建库）。
  static Future<Map<String, dynamic>> start(String sessionId) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/ai/program/start'),
          headers: _jsonHeaders(),
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
          headers: _jsonHeaders(),
          body: jsonEncode({'session_id': sessionId, 'baseline': baseline}),
        )
        .timeout(const Duration(seconds: 60));
    return _decode(resp, '创建方案失败');
  }

  /// 按问诊会话取最近疗程；没有则返回 null。
  static Future<Map<String, dynamic>?> bySession(String sessionId) async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/ai/program/by-session/$sessionId'),
              headers: AuthStore.headers())
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
        .get(
          Uri.parse('$_base/api/ai/programs?session_id=${Uri.encodeQueryComponent(sessionId)}'),
          headers: AuthStore.headers(),
        )
        .timeout(const Duration(seconds: 25));
    final data = _decode(resp, '列出方案失败');
    return (data['programs'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  /// 当前登录用户名下的全部方案（方案页用）。
  static Future<List<Map<String, dynamic>>> listAll({int limit = 50}) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/programs?limit=$limit'), headers: AuthStore.headers())
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
          headers: _jsonHeaders(),
          body: jsonEncode({'baseline': baseline}),
        )
        .timeout(const Duration(seconds: 60));
    return _decode(resp, '生成方案失败');
  }

  /// 读取疗程全景。
  static Future<Map<String, dynamic>> get(String programId) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/program/$programId'), headers: AuthStore.headers())
        .timeout(const Duration(seconds: 25));
    return _decode(resp, '读取方案失败');
  }

  /// 删除疗程。
  static Future<void> delete(String programId) async {
    final resp = await http
        .delete(Uri.parse('$_base/api/ai/program/$programId'), headers: AuthStore.headers())
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode == 404) return;
    _decode(resp, '删除方案失败');
  }

  /// 查动作评估任务状态。失败/未完成返回 null。
  static Future<Map<String, dynamic>?> assessStatus(String taskId) async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/assess/status/$taskId'), headers: AuthStore.headers())
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// 评估失败/卡死的兜底：让后端复位任务并重新评估。
  static Future<void> retryAssess(String taskId) async {
    final resp = await http
        .post(Uri.parse('$_base/api/ai/assess/retry/$taskId'), headers: AuthStore.headers())
        .timeout(const Duration(seconds: 25));
    _decode(resp, '重试评估失败');
  }

  /// 某个训练项的历史评估（多组训练按组逐条，新的在前）。
  static Future<List<Map<String, dynamic>>> assessHistory(
    String programId,
    String videoId, {
    int limit = 20,
  }) async {
    final resp = await http
        .get(
          Uri.parse(
            '$_base/api/ai/assess/history?program_id=${Uri.encodeQueryComponent(programId)}'
            '&video_id=${Uri.encodeQueryComponent(videoId)}&limit=$limit',
          ),
          headers: AuthStore.headers(),
        )
        .timeout(const Duration(seconds: 25));
    final data = _decode(resp, '加载历史记录失败');
    return (data['history'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 最近完成的训练评估（跨疗程、倒序）：进度页「随时间」趋势。
  static Future<List<Map<String, dynamic>>> timeline({int limit = 30}) async {
    final resp = await http
        .get(Uri.parse('$_base/api/ai/assess/timeline?limit=$limit'),
            headers: AuthStore.headers())
        .timeout(const Duration(seconds: 20));
    final data = _decode(resp, '加载训练趋势失败');
    return (data['timeline'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// K4：做完本轮训练 → 进阶决策。
  static Future<Map<String, dynamic>> progress(String programId) async {
    final resp = await http
        .post(Uri.parse('$_base/api/ai/program/$programId/progress'), headers: _jsonHeaders())
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
