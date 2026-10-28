import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../theme/app_theme.dart';
import '../config/api_config.dart';
import '../services/auth_store.dart';
import '../services/error_text.dart';
import '../services/program_api.dart';
import '../widgets/common_widgets.dart';
import 'baseline_page.dart';
import 'chat_list_page.dart';
import 'consult_report_page.dart';
import 'program_page.dart';

/// K1 策略树问诊页：对接 /api/ai/consult（SSE，事件 text/input_spec/progress/done）。
/// 与旧 8 节点 ChatPage 并存，本页走图谱驱动的自适应问诊。
enum _Role { user, assistant }

class _Msg {
  final _Role role;
  String text;
  bool streaming;
  _Msg({required this.role, this.text = '', this.streaming = false});
}

/// 当前应展示的输入方式（来自 input_spec 事件）
class _Spec {
  final String
  answerType; // free_text/single_choice/multi_choice/scale_0_10/boolean
  final List<String> options;
  const _Spec(this.answerType, this.options);

  /// 展示为快捷选项的按钮文案（空则回退默认）
  List<String> get chips {
    if (options.isNotEmpty) return options;
    if (answerType == 'boolean') return const ['是', '否', '不确定'];
    if (answerType == 'scale_0_10') {
      return List.generate(11, (i) => '$i');
    }
    return const [];
  }
}

class ConsultPage extends StatefulWidget {
  final VoidCallback onBack;
  final ConversationRecord? existingRecord;

  const ConsultPage({super.key, required this.onBack, this.existingRecord});

  @override
  State<ConsultPage> createState() => _ConsultPageState();
}

class _ConsultPageState extends State<ConsultPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  final List<_Msg> _messages = [];
  _Spec? _spec;
  Map<String, dynamic>? _progress;
  Map<String, dynamic>? _result; // done 事件
  _Msg? _streaming; // 当前正在追加文本的 AI 气泡

  String? _sessionId;
  bool _isSending = false;
  bool _isInitializing = true;
  bool _isDone = false;

  /// 后台正在做什么（「正在思考 / 查询知识库…」），来自 SSE status 事件
  String? _statusLabel;

  /// 本会话已有方案时的 program_id（结束卡传送门）
  String? _existingProgramId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final existing = widget.existingRecord;
    if (existing != null) {
      _sessionId = existing.sessionId;
      for (final m in existing.messages) {
        _messages.add(
          _Msg(
            role: m['role'] == 'user' ? _Role.user : _Role.assistant,
            text: m['text'] ?? '',
          ),
        );
      }
      await _restoreState(); // 恢复结论卡片 / 预选项 / 结束态
      if (mounted) {
        setState(() => _isInitializing = false);
        _scrollToBottom(animate: false);
      }
    } else {
      await _newSession();
      if (mounted) setState(() => _isInitializing = false);
    }
  }

  /// 退出重进时从后端恢复问诊「展示态」（是否结束 / 预选项 / 结论卡片）。
  Future<void> _restoreState() async {
    final sid = _sessionId;
    if (sid == null) return;
    try {
      final resp = await http
          .get(
            Uri.parse('$kBackendBase/api/ai/consult/$sid/state'),
            headers: AuthStore.headers(),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return;
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final rv = data['resume_view'] as Map<String, dynamic>?;
      if (rv == null) return;
      if (rv['is_done'] == true) {
        _isDone = true;
        _result = rv['result'] as Map<String, dynamic>?;
        await _refreshExistingProgram();
      } else {
        final spec = rv['spec'] as Map<String, dynamic>?;
        if (spec != null) {
          _spec = _Spec(
            spec['answer_type'] as String? ?? 'free_text',
            ((spec['options'] as List<dynamic>?) ?? const [])
                .map((e) => e.toString())
                .toList(),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _newSession() async {
    try {
      final resp = await http
          .get(
            Uri.parse('$kBackendBase/api/ai/consult/new'),
            headers: AuthStore.headers(),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _sessionId = data['session_id'] as String?;
        final events = (data['events'] as List<dynamic>? ?? []);
        final ai = _Msg(role: _Role.assistant);
        _messages.add(ai);
        _streaming = ai;
        for (final e in events) {
          _applyEvent(e as Map<String, dynamic>);
        }
        _streaming = null;
      } else {
        _messages.add(
          _Msg(
            role: _Role.assistant,
            text: '⚠️ 创建问诊会话失败（HTTP ${resp.statusCode}）。',
          ),
        );
      }
    } catch (_) {
      _messages.add(
        _Msg(
          role: _Role.assistant,
          text: '⚠️ 无法连接服务器，请检查网络与后端地址（当前：$kBackendBase）。',
        ),
      );
    }
  }

  /// 统一处理一个 SSE 事件（/new 与 /consult 复用）
  void _applyEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'text':
        final ai = _streaming ?? _appendAi();
        ai.text += (event['content'] as String? ?? '');
        _statusLabel = null;
        break;
      case 'status':
        // 大模型思考中 / 查询知识库 / 建策略树：给用户一点「它在干什么」的反馈
        _statusLabel = event['text'] as String? ?? '';
        break;
      case 'input_spec':
        _spec = _Spec(
          event['answer_type'] as String? ?? 'free_text',
          ((event['options'] as List<dynamic>?) ?? const [])
              .map((e) => e.toString())
              .toList(),
        );
        break;
      case 'progress':
        _progress = event;
        break;
      case 'done':
        _result = event;
        _isDone =
            event['should_stop'] == true &&
            (event['outcome'] as String?) != 'continue';
        _spec = null;
        _statusLabel = null;
        if (_isDone) {
          // ignore: unawaited_futures
          _refreshExistingProgram();
        }
        break;
      case 'error':
        final ai = _streaming ?? _appendAi();
        ai.text += '\n[错误] ${event['content'] ?? ''}';
        break;
    }
    if (mounted) setState(() {});
    _scrollToBottom();
  }

  Future<void> _refreshExistingProgram() async {
    final sid = _sessionId;
    if (sid == null) return;
    final prog = await ProgramApi.bySession(sid);
    if (!mounted) return;
    final pid = prog?['program_id']?.toString();
    setState(() {
      _existingProgramId = ProgramApi.hasViewablePlan(prog) ? pid : null;
    });
  }

  _Msg _appendAi() {
    final ai = _Msg(role: _Role.assistant, streaming: true);
    _messages.add(ai);
    _streaming = ai;
    return ai;
  }

  Future<void> _send(String text) async {
    final userText = text.trim();
    if (_sessionId == null || _isSending || _isDone || userText.isEmpty) return;

    _textController.clear();
    setState(() {
      _messages.add(_Msg(role: _Role.user, text: userText));
      _spec = null;
      _isSending = true;
    });
    _scrollToBottom();

    final ai = _Msg(role: _Role.assistant, streaming: true);
    setState(() => _messages.add(ai));
    _streaming = ai;

    try {
      final request =
          http.Request('POST', Uri.parse('$kBackendBase/api/ai/consult'))
            ..headers['Content-Type'] = 'application/json'
            ..headers.addAll(AuthStore.headers())
            ..body = jsonEncode({
              'session_id': _sessionId,
              'user_message': userText,
            });

      final streamed = await request.send().timeout(
        const Duration(seconds: 40),
      );
      if (streamed.statusCode != 200) {
        ai.text = '请求失败（${streamed.statusCode}）';
        ai.streaming = false;
        setState(() {});
        return;
      }

      final buffer = StringBuffer();
      await streamed.stream
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
                _applyEvent(jsonDecode(jsonStr) as Map<String, dynamic>);
              } catch (_) {}
            }
          });
      // 末尾可能未换行的最后一行
      final tail = buffer.toString().trim();
      if (tail.startsWith('data: ')) {
        final jsonStr = tail.substring(6).trim();
        if (jsonStr.isNotEmpty) {
          try {
            _applyEvent(jsonDecode(jsonStr) as Map<String, dynamic>);
          } catch (_) {}
        }
      }
      await _saveHistory();
    } on TimeoutException {
      ai.text = '${ai.text}\n（等待回复超时，请检查网络后重试）';
    } catch (e) {
      ai.text = '${ai.text}\n（${friendlyError(e)}）';
    } finally {
      ai.streaming = false;
      _streaming = null;
      if (mounted) setState(() => _isSending = false);
      _scrollToBottom();
    }
  }

  Future<void> _saveHistory() async {
    final sid = _sessionId;
    if (sid == null) return;
    final msgList = _messages
        .where((m) => m.text.isNotEmpty)
        .map(
          (m) => {
            'role': m.role == _Role.user ? 'user' : 'assistant',
            'text': m.text,
          },
        )
        .toList();
    String title = '问诊记录';
    for (final m in msgList) {
      if (m['role'] == 'user' && (m['text']?.isNotEmpty ?? false)) {
        final t = m['text']!;
        title = t.length > 20 ? '${t.substring(0, 20)}…' : t;
        break;
      }
    }
    String preview = '';
    for (final m in msgList.reversed) {
      if (m['role'] == 'assistant' && (m['text']?.isNotEmpty ?? false)) {
        final t = m['text']!;
        preview = t.length > 50 ? '${t.substring(0, 50)}…' : t;
        break;
      }
    }
    await ConversationStorage.save(
      ConversationRecord(
        sessionId: sid,
        title: title,
        previewText: preview,
        createdAt: DateTime.now(),
        messages: msgList,
      ),
    );
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent + 160;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
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
    final itemCount = _messages.length + (_result != null ? 1 : 0);
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        leading: AppBackButton(
          onTap: () async {
            await _saveHistory();
            widget.onBack();
          },
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AI 智能问诊',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            Text(
              '耐心描述，我会逐步了解你的情况',
              style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.insights_outlined,
              color: AppTheme.textPrimary,
            ),
            tooltip: '问诊过程与结果',
            onPressed: _sessionId == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ConsultReportPage(sessionId: _sessionId!),
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress != null) _buildProgressStrip(),
          Expanded(
            child: _isInitializing
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    itemCount: itemCount,
                    itemBuilder: (ctx, i) {
                      if (i < _messages.length) {
                        return _buildMessage(_messages[i]);
                      }
                      return _buildResultCard(_result!);
                    },
                  ),
          ),
          if (_spec != null && _spec!.chips.isNotEmpty && !_isDone)
            _buildChips(),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildProgressStrip() {
    final pct = ((_progress!['pct'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
    final pending = _progress!['pending'] as String? ?? '';
    final known = (_progress!['known'] as List<dynamic>? ?? []).length;
    final etaMin = (_progress!['eta_min'] as num?)?.toInt();
    final etaMax = (_progress!['eta_max'] as num?)?.toInt();
    final etaText = (etaMin != null && etaMax != null)
        ? '预计还需约 $etaMin–$etaMax 个问题'
        : null;
    return Container(
      color: AppTheme.primaryLight,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '已了解 $known 项 · 正在确认$pending',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryDark,
                  ),
                ),
              ),
              if (etaText != null && !_isDone)
                Text(
                  etaText,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.primaryDark,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: Colors.white,
              valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChips() {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _spec!.chips.map((opt) {
          return ActionChip(
            label: Text(opt),
            labelStyle: const TextStyle(
              fontSize: 13,
              color: AppTheme.primaryDark,
            ),
            backgroundColor: AppTheme.primaryLight,
            side: const BorderSide(color: AppTheme.primary, width: 0.8),
            onPressed: _isSending ? null : () => _send(opt),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMessage(_Msg msg) {
    final isUser = msg.role == _Role.user;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[_avatar(), const SizedBox(width: 8)],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? AppTheme.primaryDark : Colors.white,
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
              child: msg.streaming && msg.text.isEmpty
                  ? _TypingDots(label: msg == _streaming ? _statusLabel : null)
                  : Text(
                      msg.text,
                      style: TextStyle(
                        fontSize: 15,
                        color: isUser ? Colors.white : AppTheme.textPrimary,
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

  Widget _avatar() => const AppIconBadge(
    icon: Icons.spa_outlined,
    size: 32,
    color: AppTheme.primaryDark,
  );

  Widget _buildResultCard(Map<String, dynamic> result) {
    final outcome = result['outcome'] as String? ?? '';
    final impression = (result['impression'] as List<dynamic>? ?? []);
    final summary = result['summary'] as String? ?? '';

    final isRefer = outcome == 'refer';
    final title = switch (outcome) {
      'ready_for_plan' => '问诊完成，可开始康复训练',
      'refer' => '建议先线下就医',
      'best_effort_impression' => '已根据现有信息给出评估',
      _ => '问诊小结',
    };
    final color = isRefer ? AppTheme.warning : AppTheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.12),
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
                Icon(
                  isRefer
                      ? Icons.local_hospital_outlined
                      : Icons.verified_outlined,
                  color: color,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                summary,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
            if (impression.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '倾向：${_topImpressionText(impression)}',
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (!isRefer) ...[
              if (_existingProgramId != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primary,
                      side: const BorderSide(color: AppTheme.primary),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ProgramPage(
                          programId: _existingProgramId!,
                          sessionId: _sessionId,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text(
                      '查看我的康复方案',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _sessionId == null
                      ? null
                      : () => _generatePlanFlow(),
                  icon: Icon(
                    _existingProgramId != null
                        ? Icons.refresh
                        : Icons.assignment_turned_in,
                    size: 18,
                  ),
                  label: Text(
                    _existingProgramId != null ? '生成新的康复方案' : '生成我的康复方案',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _sessionId == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ConsultReportPage(sessionId: _sessionId!),
                        ),
                      ),
                icon: const Icon(Icons.insights_outlined, size: 18),
                label: const Text('查看问诊过程与结果'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 生成 / 重新生成方案。已有方案时先说明「旧方案会保留」，避免误解为覆盖。
  Future<void> _generatePlanFlow() async {
    final sid = _sessionId;
    if (sid == null) return;
    if (_existingProgramId != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('生成新的康复方案？'),
          content: const Text(
            '将基于本次问诊生成一份新方案；已有方案会保留在「方案」列表里，不会被覆盖。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BaselinePage(sessionId: sid)),
    );
    if (mounted) await _refreshExistingProgram();
  }

  /// 结论卡只展示一条：最可能的临床方向 + 可能性档位（不展示两位小数）。
  String _topImpressionText(List<dynamic> impression) {
    final top = impression.first;
    if (top is! Map) return '';
    final name = top['name'] as String? ?? '';
    final conf = (top['confidence'] as num?)?.toDouble() ?? 0;
    return '$name · 可能性${_confidenceLabel(conf)}';
  }

  String _confidenceLabel(double conf) {
    if (conf >= 0.6) return '高';
    if (conf >= 0.4) return '中';
    return '低';
  }

  Widget _buildInputBar() {
    final hint = _isDone ? '本次问诊已结束' : '输入你的回答…';
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
                  enabled: !_isDone,
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(_textController.text),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 14,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: '发送回答',
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: (_isSending || _isDone)
                    ? null
                    : () => _send(_textController.text),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: (_isSending || _isDone)
                        ? null
                        : const LinearGradient(
                            colors: [AppTheme.primary, AppTheme.primaryDark],
                          ),
                    color: (_isSending || _isDone)
                        ? const Color(0xFFDDDDDD)
                        : null,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: _isSending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : const Icon(
                          Icons.arrow_upward_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「正在输入」指示：三点动画 + 可选的状态文案（正在思考 / 查询知识库…）
class _TypingDots extends StatefulWidget {
  final String? label;

  const _TypingDots({this.label});
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dots = SizedBox(
      width: 40,
      height: 16,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final t = (_ctrl.value * 3 - i).clamp(0.0, 1.0);
              final o = (0.3 + 0.7 * (t < 0.5 ? t * 2 : (1 - t) * 2)).clamp(
                0.3,
                1.0,
              );
              return Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: AppTheme.textTertiary.withValues(alpha: o),
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          );
        },
      ),
    );
    final label = widget.label;
    if (label == null || label.isEmpty) return dots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        dots,
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      ],
    );
  }
}
