import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 当前登录用户（core-svc 签发的令牌里带的那份）。
class AuthUser {
  final String id;
  final String phone;
  final String nickname;
  final String role;

  const AuthUser({
    required this.id,
    required this.phone,
    this.nickname = '',
    this.role = 'user',
  });

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: j['id']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        nickname: j['nickname']?.toString() ?? '',
        role: j['role']?.toString() ?? 'user',
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'phone': phone, 'nickname': nickname, 'role': role};

  /// 展示用：昵称优先，没有就用打码手机号。
  String get displayName => nickname.isNotEmpty ? nickname : maskedPhone;

  String get maskedPhone =>
      phone.length == 11 ? '${phone.substring(0, 3)}****${phone.substring(7)}' : phone;
}

/// 登录态本地缓存。令牌是无状态 JWT，服务端不保存会话，所以这里就是唯一的存放处。
class AuthStore {
  static const _kToken = 'auth_token';
  static const _kUser = 'auth_user';

  static String _token = '';
  static AuthUser? _user;

  static String get token => _token;
  static AuthUser? get user => _user;
  static bool get isLoggedIn => _token.isNotEmpty;

  /// 应用启动时调用一次，把磁盘上的登录态读进内存。
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _token = p.getString(_kToken) ?? '';
    final raw = p.getString(_kUser);
    if (raw != null && raw.isNotEmpty) {
      try {
        _user = AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        _user = null;
      }
    }
  }

  static Future<void> save(String token, AuthUser user) async {
    _token = token;
    _user = user;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, token);
    await p.setString(_kUser, jsonEncode(user.toJson()));
  }

  static Future<void> clear() async {
    _token = '';
    _user = null;
    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
    await p.remove(_kUser);
  }

  /// 所有需要登录的请求都带上这个头。
  static Map<String, String> headers([Map<String, String>? extra]) => {
        if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
        ...?extra,
      };
}
