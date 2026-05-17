import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class ResultPage extends StatelessWidget {
  final VoidCallback onBack;

  const ResultPage({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: onBack,
        ),
        title: const Text('训练报告'),
        backgroundColor: AppTheme.bgPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCompletionCard(),
            const SizedBox(height: 24),
            _buildAnalysisTitle(),
            const SizedBox(height: 12),
            _buildProblemCard(
              title: '右肩活动受限',
              severity: '轻度',
              level: 35,
              progressColor: AppTheme.success,
              description: '您的右肩在外展动作时存在约15度的活动受限，建议加强肩袖肌群的训练。',
            ),
            const SizedBox(height: 12),
            _buildProblemCard(
              title: '肩胛骨稳定性不足',
              severity: '轻度',
              level: 28,
              progressColor: AppTheme.success,
              description: '训练过程中肩胛骨出现轻微前倾，建议加强中下斜方肌的力量训练。',
            ),
            const SizedBox(height: 16),
            const AlertBox(
              icon: Icons.check_circle_outline,
              title: '康复方案已更新',
              content: '根据本次训练结果，系统已为您优化康复方案，增加了肩袖肌群训练内容。',
              iconColor: AppTheme.success,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onBack,
              child: const Text('返回首页'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletionCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: const BoxDecoration(
              color: AppTheme.primaryLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle,
              size: 40,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '训练完成',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '动作完成度 85%',
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisTitle() {
    return const Text(
      '问题分析',
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: AppTheme.textPrimary,
      ),
    );
  }

  Widget _buildProblemCard({
    required String title,
    required String severity,
    required int level,
    required Color progressColor,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.person_outline,
                  color: AppTheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Column(
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
                  Text(
                    '严重程度：$severity',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
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
              color: AppTheme.bgTertiary,
              borderRadius: BorderRadius.circular(3),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: level / 100,
              child: Container(
                decoration: BoxDecoration(
                  color: progressColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('轻微', style: TextStyle(fontSize: 11, color: AppTheme.textTertiary)),
              Text('严重', style: TextStyle(fontSize: 11, color: AppTheme.textTertiary)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
