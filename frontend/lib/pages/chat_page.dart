import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../theme/app_theme.dart';
import '../config/api_config.dart';
import 'chat_list_page.dart';
import 'consult_report_page.dart';

enum _Role { user, assistant }

class _Message {
  final _Role role;
  String text;
  bool isStreaming;

  _Message({required this.role, this.text = '', this.isStreaming = false});
}

class _VideoRecommendation {
  final String url;
  final String videoId;
  final String summary;

  const _VideoRecommendation({
    required this.url,
    required this.videoId,
    required this.summary,
  });
}

class ChatPage extends StatefulWidget {
  final VoidCallback onBack;
  final void Function(String url, String videoId, String sessionId) onVideoSelected;
  /// 传入历史记录则恢复；传入 null 则新建会话
  final ConversationRecord? existingRecord;

  const ChatPage({
    super.key,
    required this.onBack,
    required this.onVideoSelected,
    this.existingRecord,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  final List<_Message> _messages = [];
  _VideoRecommendation? _recommendation;

  String? _sessionId;
  bool _isSending = false;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final existing = widget.existingRecord;
    if (existing != null) {
      // 恢复历史对话
      _sessionId = existing.sessionId;
      for (final m in existing.messages) {
        _messages.add(_Message(
          role: m['role'] == 'user' ? _Role.user : _Role.assistant,
          text: m['text'] ?? '',
        ));
      }
      if (existing.recommendedVideoId != null && existing.recommendedVideoUrl != null) {
        _recommendation = _VideoRecommendation(
          url: existing.recommendedVideoUrl!,
          videoId: existing.recommendedVideoId!,
          summary: '',
        );
      }
      if (mounted) {
        setState(() => _isInitializing = false);
        // 恢复历史对话后默认停在底部
        _scrollToBottom(animate: false);
      }
    } else {
      // 新建会话
      try {
        await _startSession();
      } finally {
        if (mounted) setState(() => _isInitializing = false);
      }
      if (_sessionId != null && mounted) {
        unawaited(_sendMessage('你好'));
      }
    }
  }

  Future<void> _startSession() async {
    try {
      final resp = await http
          .get(Uri.parse('$kBackendBase/api/session/new'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _sessionId = data['session_id'] as String;
      } else if (mounted) {
        setState(() {
          _messages.add(_Message(
            role: _Role.assistant,
            text: '⚠️ 创建会话失败（HTTP ${resp.statusCode}），请检查后端日志。',
          ));
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _messages.add(_Message(
            role: _Role.assistant,
            text: '⚠️ 无法连接到服务器，请检查网络及后端地址配置（当前：$kBackendBase）',
          ));
        });
      }
    }
  }

  /// 保存当前对话到本地存储
  Future<void> _saveHistory() async {
    final sid = _sessionId;
    if (sid == null) return;

    final msgList = _messages
        .where((m) => m.text.isNotEmpty)
        .map((m) => {'role': m.role == _Role.user ? 'user' : 'assistant', 'text': m.text})
        .toList();

    // 用第一条用户消息作为标题，若无则用 AI 第一句
    String title = '问诊记录';
    for (final m in msgList) {
      if (m['role'] == 'user' && (m['text']?.isNotEmpty ?? false)) {
        final t = m['text']!;
        title = t.length > 20 ? '${t.substring(0, 20)}…' : t;
        break;
      }
    }

    // 最后一条 AI 消息作为预览
    String preview = '';
    for (final m in msgList.reversed) {
      if (m['role'] == 'assistant' && (m['text']?.isNotEmpty ?? false)) {
        final t = m['text']!;
        preview = t.length > 50 ? '${t.substring(0, 50)}…' : t;
        break;
      }
    }

    final rec = ConversationRecord(
      sessionId: sid,
      title: title,
      previewText: preview,
      createdAt: DateTime.now(),
      messages: msgList,
      recommendedVideoId: _recommendation?.videoId,
      recommendedVideoUrl: _recommendation?.url,
    );
    await ConversationStorage.save(rec);
  }

  Future<void> _sendMessage(String text) async {
    if (_sessionId == null || _isSending) return;
    final userText = text.trim();
    if (userText.isEmpty) return;

    _textController.clear();

    final isInitGreeting = userText == '你好' && _messages.isEmpty;

    setState(() {
      if (!isInitGreeting) {
        _messages.add(_Message(role: _Role.user, text: userText));
      }
      _isSending = true;
    });

    _scrollToBottom();

    var aiMsg = _Message(role: _Role.assistant, isStreaming: true);
    setState(() => _messages.add(aiMsg));

    try {
      final request = http.Request(
        'POST',
        Uri.parse('$kBackendBase/api/chat'),
      )
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'session_id': _sessionId,
          'user_message': userText,
        });

      final streamedResp =
          await request.send().timeout(const Duration(seconds: 30));

      if (streamedResp.statusCode != 200) {
        aiMsg.text = '请求失败（${streamedResp.statusCode}）';
        aiMsg.isStreaming = false;
        setState(() {});
        return;
      }

      final buffer = StringBuffer();
      await streamedResp.stream
          .timeout(const Duration(seconds: 120))
          .transform(utf8.decoder)
          .forEach((chunk) {
        buffer.write(chunk);
        final raw = buffer.toString();
        final lines = raw.split('\n');

        buffer
          ..clear()
          ..write(lines.last);

        for (final line in lines.sublist(0, lines.length - 1)) {
          if (!line.startsWith('data: ')) continue;
          final jsonStr = line.substring(6).trim();
          if (jsonStr.isEmpty) continue;

          try {
            final event = jsonDecode(jsonStr) as Map<String, dynamic>;
            final type = event['type'] as String?;

            if (type == 'text') {
              aiMsg.text += (event['content'] as String? ?? '');
              if (mounted) setState(() {});
              _scrollToBottom();
            } else if (type == 'new_bubble') {
              aiMsg.isStreaming = false;
              final nextMsg =
                  _Message(role: _Role.assistant, isStreaming: true);
              if (mounted) setState(() => _messages.add(nextMsg));
              aiMsg = nextMsg;
              _scrollToBottom();
            } else if (type == 'done') {
              aiMsg.isStreaming = false;
              final isDone = event['is_consultation_done'] == true;
              if (isDone) {
                final url = event['video_url'] as String?;
                final vid = event['video_id'] as String?;
                final summary = event['summary'] as String?;
                if (url != null && vid != null) {
                  _recommendation = _VideoRecommendation(
                    url: resolveBackendUrl(url),
                    videoId: vid,
                    summary: summary ?? '',
                  );
                }
              }
              if (mounted) setState(() {});
            }
          } catch (_) {}
        }
      });

      // 处理末尾可能未换行的最后一行
      final tail = buffer.toString().trim();
      if (tail.startsWith('data: ')) {
        final jsonStr = tail.substring(6).trim();
        if (jsonStr.isNotEmpty) {
          try {
            final event = jsonDecode(jsonStr) as Map<String, dynamic>;
            final type = event['type'] as String?;
            if (type == 'text') {
              aiMsg.text += (event['content'] as String? ?? '');
            } else if (type == 'done') {
              aiMsg.isStreaming = false;
              final isDone = event['is_consultation_done'] == true;
              if (isDone) {
                final url = event['video_url'] as String?;
                final vid = event['video_id'] as String?;
                final summary = event['summary'] as String?;
                if (url != null && vid != null) {
                  _recommendation = _VideoRecommendation(
                    url: resolveBackendUrl(url),
                    videoId: vid,
                    summary: summary ?? '',
                  );
                }
              }
            }
            if (mounted) setState(() {});
          } catch (_) {}
        }
      }

      // 每次发完消息就保存历史
      await _saveHistory();
    } on TimeoutException catch (_) {
      aiMsg.text = '${aiMsg.text}\n（等待回复超时，请检查网络或 LLM 配置后重试）';
      aiMsg.isStreaming = false;
      if (mounted) setState(() {});
    } catch (e) {
      aiMsg.text = '连接错误：$e';
      aiMsg.isStreaming = false;
      if (mounted) setState(() {});
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          aiMsg.isStreaming = false;
        });
      }
      _scrollToBottom();
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (animate) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        // 进入页面时瞬间定位到底部，避免从顶部滚下的突兀感
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppTheme.textPrimary),
          onPressed: () async {
            await _saveHistory();
            widget.onBack();
          },
        ),
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primary, AppTheme.primaryDark],
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child:
                  const Icon(Icons.smart_toy, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Column(
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
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.assignment_outlined,
                color: AppTheme.textPrimary),
            tooltip: '问诊记录',
            onPressed: _sessionId == null
                ? null
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ConsultReportPage(sessionId: _sessionId!),
                      ),
                    );
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isInitializing
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _messages.length +
                        (_recommendation != null ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i < _messages.length) {
                        return _buildMessage(_messages[i]);
                      }
                      return _buildVideoCard(_recommendation!);
                    },
                  ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessage(_Message msg) {
    final isUser = msg.role == _Role.user;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primary, AppTheme.primaryDark],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.smart_toy, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? AppTheme.primary : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: msg.isStreaming && msg.text.isEmpty
                  ? SizedBox(
                      width: 40,
                      child: Row(
                        children: List.generate(
                          3,
                          (i) => _TypingDot(delay: i * 150),
                        ),
                      ),
                    )
                  : Text(
                      msg.text,
                      style: TextStyle(
                        fontSize: 15,
                        color:
                            isUser ? Colors.white : AppTheme.textPrimary,
                        height: 1.5,
                      ),
                    ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildVideoCard(_VideoRecommendation rec) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF667EEA).withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.play_circle_fill,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                const Text(
                  '已为您匹配康复训练视频',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF667EEA),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  elevation: 0,
                ),
                onPressed: () {
                  final sid = _sessionId;
                  if (sid != null) {
                    widget.onVideoSelected(rec.url, rec.videoId, sid);
                  }
                },
                icon: const Icon(Icons.fitness_center, size: 18),
                label: const Text(
                  '开始康复训练 & 动作评估',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: TextField(
                  controller: _textController,
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(_textController.text),
                  decoration: const InputDecoration(
                    hintText: '输入消息…',
                    hintStyle: TextStyle(
                        color: AppTheme.textTertiary, fontSize: 14),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _isSending
                  ? null
                  : () => _sendMessage(_textController.text),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: _isSending
                      ? null
                      : const LinearGradient(
                          colors: [AppTheme.primary, AppTheme.primaryDark],
                        ),
                  color: _isSending ? const Color(0xFFDDDDDD) : null,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: _isSending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : const Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingDot extends StatefulWidget {
  final int delay;
  const _TypingDot({required this.delay});

  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: AppTheme.textTertiary,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}
