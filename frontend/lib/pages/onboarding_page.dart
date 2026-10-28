import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';

/// 首次上手引导：三页说明「问诊 → 方案 → 跟做」，最后一页给拍摄建议。
/// 每个用户只出现一次（由 app.dart 的引导闸门控制）。
class OnboardingPage extends StatefulWidget {
  final VoidCallback onDone;

  const OnboardingPage({super.key, required this.onDone});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  int _index = 0;

  static const _pages = [
    (
      Icons.forum_outlined,
      '先聊聊你的情况',
      'AI 问诊会了解疼痛部位、加重因素和康复目标，一般 2–4 分钟。',
    ),
    (
      Icons.assignment_outlined,
      '拿到专属训练方案',
      '方案按阶段编排动作和剂量；也可以先试做 1–2 个基础动作，让方案更贴合你。',
    ),
    (
      Icons.videocam_outlined,
      '跟着视频练，AI 看动作',
      '手机竖放在 1–2 米外，尽量让全身入画；每组练完都会给评分和改进建议。',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_index >= _pages.length - 1) {
      widget.onDone();
      return;
    }
    _controller.nextPage(
      duration: AppMotion.duration(context, AppMotion.standard),
      curve: AppMotion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: widget.onDone,
                  child: const Text('跳过'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) {
                    final (icon, title, body) = _pages[i];
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AppIconBadge(icon: icon, size: 92),
                        const SizedBox(height: 32),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          body,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14.5,
                            height: 1.7,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pages.length, (i) {
                  final active = i == _index;
                  return AnimatedContainer(
                    duration: AppMotion.duration(context, AppMotion.quick),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: active ? AppTheme.primary : AppTheme.bgTertiary,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 22),
              ElevatedButton(
                onPressed: _next,
                child: Text(last ? '开始使用' : '下一步'),
              ),
              const SizedBox(height: 10),
              const Text(
                '问诊、训练和评估数据都只属于你，可在「我的」里随时管理。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
