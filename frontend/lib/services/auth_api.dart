import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'auth_store.dart';

/// 认证接口客户端。用户体系（users 表、密码哈希、令牌签发）全在 core-svc，
/// 因此这些请求直连 kCoreBase，而不是走 ai-svc。
class AuthApi {
  /// 注册：手机号 + 密码，暂不发短信验证码。成功后直接拿到令牌，无需再登录一次。
  static Future<AuthUser> register({
    required String phone,
    required String password,
    String? nickname,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kCoreBase/api/auth/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone': phone,
            'password': password,
            if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
          }),
        )
        .timeout(const Duration(seconds: 20));
    return _consumeSession(resp, '注册失败');
  }

  static Future<AuthUser> login({
    required String phone,
    required String password,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kCoreBase/api/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'phone': phone, 'password': password}),
        )
        .timeout(const Duration(seconds: 20));
    return _consumeSession(resp, '登录失败');
  }

  /// 拉一次当前用户，顺带验证令牌是否还有效（启动时用）。
  static Future<AuthUser?> me() async {
    try {
      final resp = await http
          .get(Uri.parse('$kCoreBase/api/auth/me'), headers: AuthStore.headers())
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        await AuthStore.clear();
        return null;
      }
      if (resp.statusCode != 200) return AuthStore.user;
      final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final user = AuthUser.fromJson((body['user'] as Map).cast<String, dynamic>());
      await AuthStore.save(AuthStore.token, user);
      return user;
    } catch (_) {
      // 网络不通时保留本地登录态，避免离线就被踢出去。
      return AuthStore.user;
    }
  }

  static Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kCoreBase/api/auth/password'),
          headers: AuthStore.headers({'Content-Type': 'application/json'}),
          body: jsonEncode({'old_password': oldPassword, 'new_password': newPassword}),
        )
        .timeout(const Duration(seconds: 20));
    // 改密码后服务端会换发新令牌，这里顺手更新，免得下一步请求 401。
    await _consumeSession(resp, '修改密码失败');
  }

  /// 读取个人资料。网络失败/未登录返回 null（调用方据此跳过「请填写资料」提示）。
  static Future<Map<String, dynamic>?> getProfile() async {
    try {
      final resp = await http
          .get(Uri.parse('$kCoreBase/api/auth/profile'), headers: AuthStore.headers())
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      if (body is Map) return body.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  /// 保存个人资料；nickname 传空表示不改昵称。
  static Future<AuthUser?> saveProfile({
    required Map<String, dynamic> fields,
    String nickname = '',
  }) async {
    final resp = await http
        .put(
          Uri.parse('$kCoreBase/api/auth/profile'),
          headers: AuthStore.headers({'Content-Type': 'application/json'}),
          body: jsonEncode({'nickname': nickname, 'fields': fields}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decode(resp, '保存个人资料失败');
    final rawUser = body['user'];
    if (rawUser is Map) {
      final user = AuthUser.fromJson(rawUser.cast<String, dynamic>());
      await AuthStore.save(AuthStore.token, user);
      return user;
    }
    return AuthStore.user;
  }

  static Future<void> logout() => AuthStore.clear();

  static Future<AuthUser> _consumeSession(http.Response resp, String errPrefix) async {
    final body = _decode(resp, errPrefix);
    final token = body['token']?.toString() ?? '';
    final rawUser = body['user'];
    if (token.isEmpty || rawUser is! Map) {
      throw Exception('$errPrefix（响应格式异常）');
    }
    final user = AuthUser.fromJson(rawUser.cast<String, dynamic>());
    await AuthStore.save(token, user);
    return user;
  }

  static Map<String, dynamic> _decode(http.Response resp, String errPrefix) {
    if (resp.statusCode != 200) {
      String detail = '${resp.statusCode}';
      try {
        final body = jsonDecode(utf8.decode(resp.bodyBytes));
        if (body is Map && body['detail'] != null) detail = body['detail'].toString();
      } catch (_) {}
      throw Exception('$errPrefix：$detail');
    }
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }
}
