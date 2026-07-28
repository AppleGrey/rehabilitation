import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地记住用户的康复方案列表（无账号时用设备侧历史）。
class ProgramStore {
  static const _kId = 'current_program_id';
  static const _kSession = 'current_program_session';
  static const _kHistory = 'program_history_v1';

  static Future<void> saveCurrent(String programId, String? sessionId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kId, programId);
    if (sessionId != null) await p.setString(_kSession, sessionId);
    await addToHistory(programId, sessionId);
  }

  static Future<({String id, String? session})?> loadCurrent() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_kId);
    if (id == null || id.isEmpty) return null;
    return (id: id, session: p.getString(_kSession));
  }

  /// 历史条目：[{id, sessionId?}, ...]，新的在前。
  static Future<List<({String id, String? session})>> loadHistory() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kHistory);
    final out = <({String id, String? session})>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final e in list) {
          if (e is! Map) continue;
          final id = e['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          out.add((id: id, session: e['session']?.toString()));
        }
      } catch (_) {}
    }
    // 兼容旧版只存了 current
    if (out.isEmpty) {
      final cur = await loadCurrent();
      if (cur != null) {
        out.add(cur);
        await _persistHistory(out);
      }
    }
    return out;
  }

  static Future<void> addToHistory(String programId, String? sessionId) async {
    final list = await loadHistory();
    list.removeWhere((e) => e.id == programId);
    list.insert(0, (id: programId, session: sessionId));
    await _persistHistory(list);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kId, programId);
    if (sessionId != null) await p.setString(_kSession, sessionId);
  }

  static Future<void> removeFromHistory(String programId) async {
    final list = await loadHistory();
    list.removeWhere((e) => e.id == programId);
    await _persistHistory(list);
    final cur = await loadCurrent();
    if (cur?.id == programId) {
      final p = await SharedPreferences.getInstance();
      if (list.isEmpty) {
        await p.remove(_kId);
        await p.remove(_kSession);
      } else {
        await p.setString(_kId, list.first.id);
        final s = list.first.session;
        if (s != null) {
          await p.setString(_kSession, s);
        } else {
          await p.remove(_kSession);
        }
      }
    }
  }

  static Future<void> _persistHistory(List<({String id, String? session})> list) async {
    final p = await SharedPreferences.getInstance();
    final encoded = jsonEncode([
      for (final e in list) {'id': e.id, if (e.session != null) 'session': e.session},
    ]);
    await p.setString(_kHistory, encoded);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kId);
    await p.remove(_kSession);
    await p.remove(_kHistory);
  }
}
