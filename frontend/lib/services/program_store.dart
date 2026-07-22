import 'package:shared_preferences/shared_preferences.dart';

/// 记住用户「当前康复方案」，供首页(计划页)「我的方案」入口再进入。
class ProgramStore {
  static const _kId = 'current_program_id';
  static const _kSession = 'current_program_session';

  static Future<void> saveCurrent(String programId, String? sessionId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kId, programId);
    if (sessionId != null) await p.setString(_kSession, sessionId);
  }

  static Future<({String id, String? session})?> loadCurrent() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_kId);
    if (id == null || id.isEmpty) return null;
    return (id: id, session: p.getString(_kSession));
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kId);
    await p.remove(_kSession);
  }
}
