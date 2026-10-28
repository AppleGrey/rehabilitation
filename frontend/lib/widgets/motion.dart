import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'common_widgets.dart';

/// 克制的动效节奏：短反馈、缓出到位，不让康复内容等待动画。
class AppMotion {
  const AppMotion._();

  static const Duration quick = Duration(milliseconds: 160);
  static const Duration standard = Duration(milliseconds: 320);
  static const Duration progress = Duration(milliseconds: 700);
  static const Curve curve = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;

  static Duration duration(BuildContext context, Duration normal) {
    return MediaQuery.disableAnimationsOf(context) ? Duration.zero : normal;
  }
}

/// 只给可点击区域一点按压缩放，使用 Listener 避免抢占内部手势。
class AppPressable extends StatefulWidget {
  final Widget child;
  final bool enabled;

  const AppPressable({super.key, required this.child, this.enabled = true});

  @override
  State<AppPressable> createState() => _AppPressableState();
}

class _AppPressableState extends State<AppPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !widget.enabled) return;
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(covariant AppPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: widget.enabled && _pressed ? 0.975 : 1,
        duration: AppMotion.duration(context, AppMotion.quick),
        curve: AppMotion.curve,
        child: widget.child,
      ),
    );
  }
}

/// 少量核心内容使用短距离上浮，列表不逐项循环播放。
class AppReveal extends StatefulWidget {
  final Widget child;
  final int order;

  const AppReveal({super.key, required this.child, this.order = 0});

  @override
  State<AppReveal> createState() => _AppRevealState();
}

class _AppRevealState extends State<AppReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    final start = (widget.order * 0.12).clamp(0.0, 0.45);
    final curved = CurvedAnimation(parent: _controller, curve: AppMotion.curve);
    _opacity = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Interval(start, 1)));
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.035),
      end: Offset.zero,
    ).animate(curved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 480),
    );
    if (!_controller.isAnimating && !_controller.isCompleted) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}

/// 更新训练数据时从当前值平滑过渡，不闪回、不突然跳变。
class AppProgressBar extends StatelessWidget {
  final double value;
  final Color color;
  final Color? backgroundColor;
  final double height;

  const AppProgressBar({
    super.key,
    required this.value,
    this.color = AppTheme.primary,
    this.backgroundColor,
    this.height = 7,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '完成进度 ${(value.clamp(0.0, 1.0) * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
          duration: AppMotion.duration(context, AppMotion.progress),
          curve: AppMotion.curve,
          builder: (context, progress, _) => LinearProgressIndicator(
            value: progress,
            minHeight: height,
            color: color,
            backgroundColor: backgroundColor ?? AppTheme.bgTertiary,
          ),
        ),
      ),
    );
  }
}

/// 标题保持稳定，仅展开的内容做高度和透明度过渡。
class AppDisclosure extends StatefulWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final bool initiallyExpanded;

  const AppDisclosure({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<AppDisclosure> createState() => _AppDisclosureState();
}

class _AppDisclosureState extends State<AppDisclosure> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.duration(context, AppMotion.standard);
    return Column(
      children: [
        Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  AppIconBadge(icon: widget.icon, size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: duration,
                    curve: AppMotion.emphasized,
                    child: const Icon(
                      Icons.keyboard_arrow_right_rounded,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ClipRect(
          child: AnimatedSize(
            duration: duration,
            reverseDuration: AppMotion.duration(context, AppMotion.quick),
            curve: AppMotion.emphasized,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(0, 18, 0, 2),
                    child: SizedBox(
                      width: double.infinity,
                      child: widget.child,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ),
      ],
    );
  }
}

/// 底部标签切换时淡入新页面，同时保留各页已加载的数据和滚动位置。
class AppTabStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const AppTabStack({super.key, required this.index, required this.children});

  @override
  State<AppTabStack> createState() => _AppTabStackState();
}

class _AppTabStackState extends State<AppTabStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 260),
    );
  }

  @override
  void didUpdateWidget(covariant AppTabStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: AppMotion.curve),
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
