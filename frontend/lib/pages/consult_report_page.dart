import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../theme/app_theme.dart';

/// 本次问诊的「AI 个性化康复评估问卷」填写报告
class ConsultReportPage extends StatefulWidget {
  final String sessionId;

  const ConsultReportPage({super.key, required this.sessionId});

  @override
  State<ConsultReportPage> createState() => _ConsultReportPageState();
}

class _ConsultReportPageState extends State<ConsultReportPage> {
  Map<String, dynamic>? _report;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadReport();
  }

  Future<void> _loadReport() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http
          .get(Uri.parse(
              '$kBackendBase/api/session/${widget.sessionId}/report'))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        setState(() {
          _report = jsonDecode(resp.body) as Map<String, dynamic>;
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
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text(
          '问诊记录',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
            onPressed: _loading ? null : _loadReport,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadReport,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final report = _report!;
    final progress = (report['progress'] as num?)?.toDouble() ?? 0.0;
    final filled = report['filled_count'] as int? ?? 0;
    final total = report['total_count'] as int? ?? 0;
    final stepLabel = report['current_step_label'] as String? ?? '';
    final isDone = report['is_consultation_done'] == true;
    final sections = report['sections'] as List<dynamic>? ?? [];

    return RefreshIndicator(
      onRefresh: _loadReport,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _buildProgressCard(progress, filled, total, stepLabel, isDone),
          const SizedBox(height: 12),
          const Text(
            '问诊过程中，系统会根据您的回答自动填写下方问卷。'
            '尚未采集的条目显示为「—」。',
            style: TextStyle(fontSize: 12, color: AppTheme.textTertiary, height: 1.5),
          ),
          const SizedBox(height: 16),
          ...sections.map((s) => _buildSection(s as Map<String, dynamic>)),
        ],
      ),
    );
  }

  Widget _buildProgressCard(
    double progress,
    int filled,
    int total,
    String stepLabel,
    bool isDone,
  ) {
    final pct = (progress * 100).round();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.assignment, color: AppTheme.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _report?['title'] as String? ?? 'AI 个性化康复评估问卷',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppTheme.bgPrimary,
              valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '已填写 $filled / $total 项（$pct%）',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
              if (isDone)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '已完成',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFF4CAF50),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          if (stepLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '当前问诊阶段：$stepLabel',
              style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSection(Map<String, dynamic> section) {
    final title = section['title'] as String? ?? '';
    final note = section['note'] as String?;
    final items = section['items'] as List<dynamic>? ?? [];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      note,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            ...items.map((raw) {
              final item = raw as Map<String, dynamic>;
              return _buildItemRow(item);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildItemRow(Map<String, dynamic> item) {
    final label = item['label'] as String? ?? '';
    final display = item['display'] as String? ?? '—';
    final filled = item['filled'] == true;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            filled ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: filled ? const Color(0xFF4CAF50) : AppTheme.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: filled
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                    fontWeight:
                        filled ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  display,
                  style: TextStyle(
                    fontSize: 14,
                    color: filled
                        ? AppTheme.textPrimary
                        : AppTheme.textTertiary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
