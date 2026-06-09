import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../theme/app_theme.dart';
import '../config/api_config.dart';
import '../models/exercise.dart';
import '../widgets/exercise_card.dart';
import '../widgets/common_widgets.dart';

class HomePage extends StatelessWidget {
  final Function(int) onNavigate;
  final Function(int) onPageSelected;
  final VoidCallback onAiConsult;

  const HomePage({
    super.key,
    required this.onNavigate,
    required this.onPageSelected,
    required this.onAiConsult,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 80),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              _buildTodayPlan(),
              _buildTodayTraining(),
              _buildQuickActions(),
              _buildBackendTestRow(context),
              _buildKnowledgeSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return const Padding(
      padding: EdgeInsets.all(20),
      child: Text(
        '首页',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _buildTodayPlan() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppTheme.primary, AppTheme.primaryDark],
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '今日训练计划',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '肩部康复训练',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '完成进度',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '2/5',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(3),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTodayTraining() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '今日训练',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              GestureDetector(
                onTap: () => onPageSelected(1),
                child: const Text(
                  '查看全部',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(
            children: [
              ExerciseListItem(
                exercise: Exercise(
                  id: '1',
                  title: '颈部放松运动',
                  type: ExerciseType.warmup,
                  durationMinutes: 3,
                  description: '',
                  status: ExerciseStatus.completed,
                ),
                onTap: () => onPageSelected(1),
              ),
              const SizedBox(height: 8),
              ExerciseListItem(
                exercise: Exercise(
                  id: '2',
                  title: '肩部环绕练习',
                  type: ExerciseType.main,
                  durationMinutes: 5,
                  description: '',
                  status: ExerciseStatus.inProgress,
                ),
                onTap: () => onPageSelected(1),
              ),
              const SizedBox(height: 8),
              ExerciseListItem(
                exercise: Exercise(
                  id: '3',
                  title: '肩部拉伸训练',
                  type: ExerciseType.main,
                  durationMinutes: 5,
                  description: '',
                  status: ExerciseStatus.pending,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '快捷入口',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              QuickActionButton(
                icon: Icons.smart_toy_outlined,
                title: 'AI 问诊',
                onTap: onAiConsult,
              ),
              QuickActionButton(
                icon: Icons.bar_chart,
                title: '康复进度',
                onTap: () => onPageSelected(2),
              ),
              QuickActionButton(
                icon: Icons.menu_book,
                title: '知识中心',
                onTap: () => onPageSelected(3),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBackendTestRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => runBackendPingTest(context),
          icon: const Icon(Icons.cloud_sync_outlined, size: 20),
          label: const Text('测试后端连接'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primary,
            side: const BorderSide(color: AppTheme.primary),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKnowledgeSection() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '康复知识',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              GestureDetector(
                onTap: () => onPageSelected(3),
                child: const Text(
                  '更多',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const ArticleCard(
            title: '肩周炎的自我康复训练方法',
            meta: '阅读 2,356 · 5分钟前',
          ),
          const SizedBox(height: 8),
          const ArticleCard(
            title: '办公室久坐人群如何预防颈椎病',
            meta: '阅读 1,892 · 1小时前',
          ),
        ],
      ),
    );
  }
}

/// 调用后端 `GET /api/test/ping`，用 SnackBar 展示结果。
Future<void> runBackendPingTest(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    const SnackBar(content: Text('正在请求 /api/test/ping…')),
  );
  try {
    final uri = Uri.parse('$kBackendBase/api/test/ping');
    final rsp = await http.get(uri).timeout(const Duration(seconds: 8));
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    if (rsp.statusCode == 200) {
      final decoded = jsonDecode(rsp.body);
      final msg = decoded is Map<String, dynamic>
          ? '${decoded['message'] ?? 'ok'} · ${decoded['time_utc'] ?? ''}'
          : rsp.body;
      messenger.showSnackBar(
        SnackBar(
          content: Text('互通成功：$msg'),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('HTTP ${rsp.statusCode}：${rsp.body}'),
          backgroundColor: Colors.deepOrange,
        ),
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('连接失败：$e\n当前地址：$kBackendBase'),
        backgroundColor: const Color(0xFFC62828),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}
