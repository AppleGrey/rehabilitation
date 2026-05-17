import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class TrainingPage extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onViewResult;
  final VoidCallback onStartRecording;

  const TrainingPage({
    super.key,
    required this.onBack,
    required this.onViewResult,
    required this.onStartRecording,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: onBack,
        ),
        title: const Text('肩部环绕练习'),
        backgroundColor: AppTheme.bgPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildVideoArea(),
            const SizedBox(height: 20),
            _buildInstructions(),
            const SizedBox(height: 16),
            _buildPrecautions(),
            const SizedBox(height: 16),
            _buildAlert(),
            const SizedBox(height: 24),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    return Container(
      width: double.infinity,
      height: 220,
      decoration: BoxDecoration(
        color: AppTheme.bgTertiary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.play_arrow,
              size: 40,
              color: AppTheme.primary.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '标准动作演示',
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructions() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '动作要领',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          const _InstructionItem(text: '站立或坐姿，保持背部挺直'),
          const _InstructionItem(text: '双臂自然下垂，肩胛骨放松'),
          const _InstructionItem(text: '以肩关节为轴，向前做环绕动作'),
          const _InstructionItem(text: '画圈幅度由小到大，逐渐增加'),
          const _InstructionItem(text: '每组10圈，完成后反向环绕'),
        ],
      ),
    );
  }

  Widget _buildPrecautions() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '注意事项',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TagWidget(text: '动作缓慢'),
              TagWidget(text: '避免疼痛'),
              TagWidget(text: '循序渐进'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAlert() {
    return const AlertBox(
      icon: Icons.warning_amber_outlined,
      title: '温馨提示',
      content: '如果训练过程中出现剧烈疼痛或不适，请立即停止并咨询专业医生。',
      iconColor: AppTheme.warning,
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: onViewResult,
            child: const Text('查看对比'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: ElevatedButton(
            onPressed: onStartRecording,
            child: const Text('开始录制'),
          ),
        ),
      ],
    );
  }
}

class _InstructionItem extends StatelessWidget {
  final String text;

  const _InstructionItem({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 7),
            decoration: const BoxDecoration(
              color: AppTheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
