import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// 存在本地的单条会话摘要
class ConversationRecord {
  final String sessionId;
  final String title;
  final String previewText;
  final DateTime createdAt;
  final List<Map<String, String>> messages; // [{role, text}]
  final String? recommendedVideoId;
  final String? recommendedVideoUrl;

  const ConversationRecord({
    required this.sessionId,
    required this.title,
    required this.previewText,
    required this.createdAt,
    required this.messages,
    this.recommendedVideoId,
    this.recommendedVideoUrl,
  });

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'title': title,
        'previewText': previewText,
        'createdAt': createdAt.toIso8601String(),
        'messages': messages,
        'recommendedVideoId': recommendedVideoId,
        'recommendedVideoUrl': recommendedVideoUrl,
      };

  factory ConversationRecord.fromJson(Map<String, dynamic> j) =>
      ConversationRecord(
        sessionId: j['sessionId'] as String,
        title: j['title'] as String? ?? '问诊记录',
        previewText: j['previewText'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        messages: (j['messages'] as List<dynamic>?)
                ?.map((e) => Map<String, String>.from(e as Map))
                .toList() ??
            [],
        recommendedVideoId: j['recommendedVideoId'] as String?,
        recommendedVideoUrl: j['recommendedVideoUrl'] as String?,
      );
}

/// 本地会话历史管理（静态方法）
class ConversationStorage {
  static const _key = 'conversation_history';

  static Future<List<ConversationRecord>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) =>
              ConversationRecord.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(ConversationRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    final idx = all.indexWhere((r) => r.sessionId == record.sessionId);
    if (idx >= 0) {
      all[idx] = record;
    } else {
      all.insert(0, record);
    }
    await prefs.setString(_key, jsonEncode(all.map((r) => r.toJson()).toList()));
  }

  static Future<void> delete(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    all.removeWhere((r) => r.sessionId == sessionId);
    await prefs.setString(_key, jsonEncode(all.map((r) => r.toJson()).toList()));
  }
}

/// 对话历史列表页（作为底部 Tab 时无需返回按钮）
class ChatListPage extends StatefulWidget {
  /// 点击「开始新对话」或历史记录时回调，传入 null 表示新建
  final void Function(ConversationRecord? existing) onOpenChat;

  const ChatListPage({
    super.key,
    required this.onOpenChat,
  });

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  List<ConversationRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await ConversationStorage.loadAll();
    if (mounted) setState(() { _records = list; _loading = false; });
  }

  Future<void> _delete(ConversationRecord r) async {
    await ConversationStorage.delete(r.sessionId);
    await _load();
  }

  String _fmtDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '今天 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return '昨天';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      return '${dt.month}月${dt.day}日';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        automaticallyImplyLeading: false,
        centerTitle: false,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AI 康复助手',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            Text(
              '智能问诊 · 精准推荐',
              style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // 发起新对话按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                onPressed: () => widget.onOpenChat(null),
                icon: const Icon(Icons.add_comment_outlined, size: 20),
                label: const Text(
                  '发起新问诊对话',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          if (_records.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  const Text(
                    '历史记录',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textTertiary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${_records.length} 条',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: _records.length,
                        itemBuilder: (_, i) => _buildItem(_records[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '暂无问诊记录',
            style: TextStyle(fontSize: 15, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            '点击上方按钮开始第一次问诊',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(ConversationRecord r) {
    return Dismissible(
      key: Key(r.sessionId),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
      ),
      onDismissed: (_) => _delete(r),
      child: GestureDetector(
        onTap: () => widget.onOpenChat(r),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.primary, AppTheme.primaryDark],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Icon(Icons.smart_toy, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            r.title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _fmtDate(r.createdAt),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      r.previewText.isEmpty ? '暂无内容' : r.previewText,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (r.recommendedVideoId != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.video_library_outlined,
                              size: 13, color: AppTheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            '已推荐视频: ${r.recommendedVideoId}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  color: AppTheme.textTertiary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
