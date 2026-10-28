import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'motion.dart';

class NavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// 方案 Tab（index 1）上的角标数量：有新完成的评估没看时显示
  final int badgeCount;

  const NavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.badgeCount = 0,
  });

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, '首页'),
    (Icons.assignment_outlined, Icons.assignment_rounded, '方案'),
    (Icons.insights_outlined, Icons.insights_rounded, '进度'),
    (Icons.forum_outlined, Icons.forum_rounded, '问诊'),
    (Icons.person_outline_rounded, Icons.person_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.bgPrimary,
      child: SafeArea(
        top: false,
        child: Container(
          height: 70,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: List.generate(_items.length, (index) {
              final item = _items[index];
              return Expanded(
                child: _NavItem(
                  icon: item.$1,
                  activeIcon: item.$2,
                  label: item.$3,
                  isActive: currentIndex == index,
                  badge: index == 1 ? badgeCount : 0,
                  onTap: () {
                    if (currentIndex != index) HapticFeedback.selectionClick();
                    onTap(index);
                  },
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final int badge;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppTheme.primaryDark : AppTheme.textTertiary;
    return Semantics(
      selected: isActive,
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: AppMotion.duration(context, AppMotion.standard),
              curve: AppMotion.curve,
              width: isActive ? 40 : 30,
              height: 29,
              decoration: BoxDecoration(
                color: isActive ? AppTheme.primaryLight : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  AnimatedSwitcher(
                    duration: AppMotion.duration(context, AppMotion.quick),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: Icon(
                      isActive ? activeIcon : icon,
                      key: ValueKey(isActive),
                      color: color,
                      size: 21,
                    ),
                  ),
                  if (badge > 0)
                    Positioned(
                      right: -12,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        constraints: const BoxConstraints(minWidth: 15),
                        decoration: BoxDecoration(
                          color: AppTheme.error,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          badge > 9 ? '9+' : '$badge',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
