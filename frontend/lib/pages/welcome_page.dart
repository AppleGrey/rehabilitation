import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class WelcomePage extends StatelessWidget {
  final VoidCallback onStart;

  const WelcomePage({super.key, required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.primaryLight,
              AppTheme.bgPrimary,
            ],
            stops: [0.0, 0.6],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const Spacer(flex: 2),
                _buildLogo(),
                const SizedBox(height: 40),
                _buildTitle(),
                const SizedBox(height: 12),
                _buildSubtitle(),
                const SizedBox(height: 60),
                _buildFeatures(),
                const Spacer(flex: 2),
                _buildStartButton(),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        color: AppTheme.primary,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.3),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const Icon(
        Icons.healing,
        size: 60,
        color: Colors.white,
      ),
    );
  }

  Widget _buildTitle() {
    return const Text(
      '运动康复',
      style: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.bold,
        color: AppTheme.textPrimary,
      ),
    );
  }

  Widget _buildSubtitle() {
    return const Text(
      '智能康复辅助系统，让专业的康复服务触手可及',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 15,
        color: AppTheme.textSecondary,
      ),
    );
  }

  Widget _buildFeatures() {
    return Column(
      children: [
        _FeatureItem(
          icon: Icons.person_outline,
          title: '个性化评估',
          subtitle: '智能分析身体状况，精准定位问题',
        ),
        const SizedBox(height: 20),
        _FeatureItem(
          icon: Icons.play_circle_outline,
          title: '专业视频指导',
          subtitle: '海量康复动作视频，标准示范教学',
        ),
        const SizedBox(height: 20),
        _FeatureItem(
          icon: Icons.psychology_outlined,
          title: '科学康复方案',
          subtitle: '基于知识图谱，定制专属计划',
        ),
      ],
    );
  }

  Widget _buildStartButton() {
    return ElevatedButton(
      onPressed: onStart,
      child: const Text('立即开始'),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _FeatureItem({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppTheme.primaryLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: AppTheme.primary,
            size: 22,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
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
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
