import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../theme/app_theme.dart';

/// 「问诊过程与结果」：读取策略树最新快照，展示临床方向、已采集信息、安全排查与进度。
/// （替代原「AI 个性化康复评估问卷」页；数据源 /api/ai/session/{id}/strategy）
class ConsultReportPage extends StatefulWidget {
  final String sessionId;

  const ConsultReportPage({super.key, required this.sessionId});

  @override
  State<ConsultReportPage> createState() => _ConsultReportPageState();
}

class _ConsultReportPageState extends State<ConsultReportPage> {
  Map<String, dynamic>? _snap;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http
          .get(Uri.parse('$kBackendBase/api/ai/session/${widget.sessionId}/strategy'))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        setState(() {
          _snap = jsonDecode(resp.body) as Map<String, dynamic>;
          _loading = false;
        });
      } else if (resp.statusCode == 404) {
        setState(() {
          _error = '本次问诊还没有生成策略快照（可能仍在粗问阶段，多聊几轮后再看）。';
          _loading = false;
        });
      } else {
        setState(() {
          _error = '加载失败（${resp.statusCode}）';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '无法连接服务器：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text('问诊过程与结果',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
            onPressed: _loading ? null : _load,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary, height: 1.5)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final snap = _snap!;
    final slots = (snap['slots'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final hyps = (snap['hypotheses'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .where((h) => (h['status'] ?? 'active') == 'active')
        .toList()
      ..sort((a, b) => ((b['confidence'] as num?) ?? 0).compareTo((a['confidence'] as num?) ?? 0));

    final safety = slots.where((s) => s['category'] == 'S').toList();
    final plan = slots.where((s) => s['category'] == 'P').toList();
    final diff = slots.where((s) => s['category'] == 'D').toList();

    final known = slots.where((s) => s['status'] == 'known').length;
    final total = slots.isEmpty ? 1 : slots.length;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _headerCard(snap, known, total),
          const SizedBox(height: 12),
          if (hyps.isNotEmpty) _impressionCard(hyps),
          if (safety.isNotEmpty) _slotCard('安全排查（红旗/禁忌）', Icons.health_and_safety_outlined, AppTheme.error, safety),
          if (plan.isNotEmpty) _slotCard('方案必填信息', Icons.tune, AppTheme.warning, plan),
          if (diff.isNotEmpty) _slotCard('鉴别追问', Icons.alt_route, AppTheme.primary, diff),
          const SizedBox(height: 8),
          const Text(
            '说明：以上「临床方向」为系统内部用于决定追问方向的候选，并非医学诊断；如症状加重或有疑虑请及时线下就医。',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textTertiary, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _headerCard(Map<String, dynamic> snap, int known, int total) {
    final turn = snap['turn_no'] ?? 0;
    final phase = snap['phase'] as String? ?? '';
    final pct = known / total;
    final phaseLabel = phase == 'tree' ? '按策略树追问' : (phase == 'warmup' ? '粗问了解需求' : phase);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.timeline, color: AppTheme.primary, size: 22),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('问诊进度',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(8)),
              child: Text('第 $turn 轮',
                  style: const TextStyle(fontSize: 11, color: AppTheme.primaryDark, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppTheme.bgTertiary,
              valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
            ),
          ),
          const SizedBox(height: 8),
          Text('已采集 $known / $total 项关键信息 · 当前阶段：$phaseLabel',
              style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _impressionCard(List<Map<String, dynamic>> hyps) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: const [
            Icon(Icons.psychology_outlined, color: AppTheme.primary, size: 20),
            SizedBox(width: 8),
            Text('临床方向（内部参考）',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ]),
          const SizedBox(height: 12),
          ...hyps.map((h) {
            final conf = ((h['confidence'] as num?) ?? 0).toDouble();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(
                  flex: 5,
                  child: Text(h['name'] as String? ?? '',
                      style: const TextStyle(fontSize: 13.5, color: AppTheme.textPrimary),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                Expanded(
                  flex: 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: conf.clamp(0.0, 1.0),
                      minHeight: 7,
                      backgroundColor: AppTheme.bgTertiary,
                      valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(conf.toStringAsFixed(2),
                    style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
              ]),
            );
          }),
        ],
      ),
    );
  }

  Widget _slotCard(String title, IconData icon, Color color, List<Map<String, dynamic>> slots) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ]),
          const SizedBox(height: 6),
          ...slots.map(_slotRow),
        ],
      ),
    );
  }

  Widget _slotRow(Map<String, dynamic> s) {
    final status = s['status'] as String? ?? 'missing';
    final title = s['title'] as String? ?? s['slot_id'] as String? ?? '';
    final value = s['value'];
    final known = status == 'known';
    final unknown = status == 'unknown';
    final icon = known
        ? Icons.check_circle
        : (unknown ? Icons.help_outline : Icons.radio_button_unchecked);
    final iconColor = known
        ? AppTheme.success
        : (unknown ? AppTheme.textTertiary : AppTheme.textTertiary);
    final valStr = known && value != null
        ? (value is List ? value.join('、') : value.toString())
        : (unknown ? '用户表示不确定' : '待采集');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 13,
                        color: known ? AppTheme.textPrimary : AppTheme.textSecondary,
                        fontWeight: known ? FontWeight.w500 : FontWeight.normal)),
                const SizedBox(height: 2),
                Text(valStr,
                    style: TextStyle(
                        fontSize: 13.5,
                        color: known ? AppTheme.textPrimary : AppTheme.textTertiary,
                        height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: child,
    );
  }
}
