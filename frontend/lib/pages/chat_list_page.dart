import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../services/auth_api.dart';
import '../services/auth_store.dart';
import '../services/consult_api.dart';
import '../widgets/common_widgets.dart';
import 'profile_edit_page.dart';

/// 单条会话摘要（服务端列表项 / 本地缓存共用）
class ConversationRecord {
  final String sessionId;
  final String title;
  final String previewText;
  final DateTime createdAt;
  final List<Map<String, String>> messages; // [{role, text}]
  final String? recommendedVideoId;
  final String? recommendedVideoUrl;

  /// 来自服务端列表、完整对话尚未拉取（点击后再补）
  final bool remote;

  const ConversationRecord({
    required this.sessionId,
    required this.title,
    required this.previewText,
    required this.createdAt,
    required this.messages,
    this.recommendedVideoId,
    this.recommendedVideoUrl,
    this.remote = false,
  });

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'title': title,
    'previewText': previewText,
    'createdAt': createdAt.toIso8601String(),
    'messages': messages,
    'recommendedVideoId': recommendedVideoId,
    'recommendedVideoUrl': recommendedVideoUrl,
    'remote': remote,
  };

  factory ConversationRecord.fromJson(Map<String, dynamic> j) =>
      ConversationRecord(
        sessionId: j['sessionId'] as String,
        title: j['title'] as String? ?? '问诊记录',
        previewText: j['previewText'] as String? ?? '',
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        messages:
            (j['messages'] as List<dynamic>?)
                ?.map((e) => Map<String, String>.from(e as Map))
                .toList() ??
            [],
        recommendedVideoId: j['recommendedVideoId'] as String?,
        recommendedVideoUrl: j['recommendedVideoUrl'] as String?,
        remote: j['remote'] as bool? ?? false,
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
          .map((e) => ConversationRecord.fromJson(e as Map<String, dynamic>))
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
    await prefs.setString(
      _key,
      jsonEncode(all.map((r) => r.toJson()).toList()),
    );
  }

  static Future<void> delete(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    all.removeWhere((r) => r.sessionId == sessionId);
    await prefs.setString(
      _key,
      jsonEncode(all.map((r) => r.toJson()).toList()),
    );
  }
}

/// 对话历史列表页（作为底部 Tab 时无需返回按钮）
class ChatListPage extends StatefulWidget {
  /// 点击「开始新对话」或历史记录时回调，传入 null 表示新建
  final void Function(ConversationRecord? existing) onOpenChat;

  const ChatListPage({super.key, required this.onOpenChat});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  List<ConversationRecord> _records = [];
  bool _loading = true;
  bool _serverLoaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 优先服务端（换设备/重装也能看到）；失败时回落到本机缓存
    List<ConversationRecord> list;
    try {
      final remote = await ConsultApi.sessions();
      list = remote.map(_fromServer).toList();
      _serverLoaded = true;
    } catch (_) {
      list = await ConversationStorage.loadAll();
      _serverLoaded = false;
    }
    if (mounted) {
      setState(() {
        _records = list;
        _loading = false;
      });
    }
  }

  ConversationRecord _fromServer(Map<String, dynamic> s) {
    final at =
        DateTime.tryParse(s['updated_at']?.toString() ?? '') ?? DateTime.now();
    final title = s['title']?.toString().trim() ?? '';
    return ConversationRecord(
      sessionId: s['session_id']?.toString() ?? '',
      title: title.isEmpty ? '问诊记录' : title,
      previewText: s['preview']?.toString() ?? '',
      createdAt: at.toLocal(),
      messages: const [],
      remote: true,
    );
  }

  /// 打开一条记录：服务端列表只有摘要，先拉取完整对话再进入问诊页。
  Future<void> _open(ConversationRecord r) async {
    var record = r;
    if (r.remote && r.messages.isEmpty) {
      try {
        final data = await ConsultApi.transcript(r.sessionId);
        final msgs = (data['transcript'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map(
              (e) => {
                'role': e['role']?.toString() ?? 'assistant',
                'text': e['text']?.toString() ?? '',
              },
            )
            .toList();
        record = ConversationRecord(
          sessionId: r.sessionId,
          title: r.title,
          previewText: r.previewText,
          createdAt: r.createdAt,
          messages: msgs,
        );
        try {
          await ConversationStorage.save(record);
        } catch (_) {}
      } catch (_) {
        // 拉取失败也进入：问诊页会从 /state 恢复展示态
      }
    }
    widget.onOpenChat(record);
  }

  /// 发起新问诊前的个人资料提示（每个用户只提示一次；不填也放行）。
  Future<void> _startNew() async {
    final uid = AuthStore.user?.id ?? 'anon';
    var prompted = false;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      prompted = prefs.getBool('consult_profile_prompted_v1_$uid') ?? false;
    } catch (_) {}
    if (!prompted) {
      final profile = await AuthApi.getProfile();
      if (mounted && profile != null && _profileEmpty(profile)) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('完善个人资料，问诊更准确'),
            content: const Text(
              '填写性别、年龄、基础病史等信息后，AI 能更快问到重点（1 分钟，可不填全）。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('暂不填写'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('去填写'),
              ),
            ],
          ),
        );
        if (go == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProfileEditPage()),
          );
        }
      }
      try {
        await prefs?.setBool('consult_profile_prompted_v1_$uid', true);
      } catch (_) {}
    }
    if (mounted) widget.onOpenChat(null);
  }

  bool _profileEmpty(Map<String, dynamic> profile) {
    const keys = [
      'gender',
      'birth_year',
      'height_cm',
      'weight_kg',
      'activity_level',
      'chronic_conditions',
      'surgery_history',
      'allergies',
    ];
    for (final k in keys) {
      final v = profile[k];
      if (v == null) continue;
      if (v is String && v.trim().isEmpty) continue;
      if (v is List && v.isEmpty) continue;
      return false;
    }
    return true;
  }

  Future<void> _delete(ConversationRecord r) async {
    // 服务端删除（失败也不阻断本地清理；本地只是缓存）
    try {
      await ConsultApi.deleteSession(r.sessionId);
    } catch (_) {}
    await ConversationStorage.delete(r.sessionId);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('问诊记录已删除')));
  }

  Future<void> _confirmDelete(ConversationRecord r) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条问诊记录？'),
        content: const Text('记录将从服务器与本机一并删除，删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _delete(r);
    }
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
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const AppPageHeader(
                      eyebrow: 'YOUR AI COMPANION',
                      title: 'AI 康复助手',
                      subtitle: '认真倾听，陪你找到合适的康复方向',
                    ),
                    const SizedBox(height: 22),
                    _newConsultCard(),
                    const SizedBox(height: 26),
                    if (!_loading && _records.isNotEmpty)
                      SectionHeader(
                        title: '历史问诊',
                        subtitle:
                            '共 ${_records.length} 条 · ${_serverLoaded ? '已同步到你的账号' : '仅存本机'} · 左滑可删除',
                      ),
                  ]),
                ),
              ),
              if (_loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppLoading(),
                )
              else if (_records.isEmpty)
                SliverPadding(
                  padding: const EdgeInsets.all(20),
                  sliver: SliverToBoxAdapter(
                    child: AppEmptyState(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: '还没有问诊记录',
                      body: '从一次简单的描述开始，我们会逐步了解你的情况。',
                      actionLabel: '开始第一次问诊',
                      onAction: _startNew,
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 30),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => _buildItem(_records[index]),
                      childCount: _records.length,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _newConsultCard() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primaryLight, Color(0xFFF0F4E6)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              AppIconBadge(
                icon: Icons.forum_outlined,
                color: Colors.white,
                backgroundColor: AppTheme.primaryDark,
              ),
              SizedBox(width: 12),
              Text(
                '需要新的康复建议？',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.primaryDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '描述你的不适与日常活动，AI 会逐步追问，帮你梳理康复方向。',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.65,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _startNew,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('发起新问诊'),
          ),
          const SizedBox(height: 12),
          const Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 14,
                color: AppTheme.textTertiary,
              ),
              SizedBox(width: 5),
              Expanded(
                child: Text(
                  '问诊建议仅供参考，不能替代医生诊断。',
                  style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildItem(ConversationRecord r) {
    return Dismissible(
      key: Key(r.sessionId),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        await _confirmDelete(r);
        return false;
      },
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppTheme.error,
          borderRadius: BorderRadius.circular(22),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(
          Icons.delete_outline_rounded,
          color: Colors.white,
          size: 24,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () => _open(r),
            child: AppCard(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const AppIconBadge(icon: Icons.forum_rounded, size: 44),
                  const SizedBox(width: 13),
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
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _fmtDate(r.createdAt),
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.textTertiary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          r.previewText.isEmpty ? '暂无内容' : r.previewText,
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: AppTheme.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (r.recommendedVideoId != null) ...[
                          const SizedBox(height: 8),
                          const AppPill(
                            label: '已推荐训练视频',
                            icon: Icons.play_circle_outline_rounded,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: AppTheme.textTertiary,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
