import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ProfileCenterPage extends StatelessWidget {
  final VoidCallback onLogout;

  const ProfileCenterPage({super.key, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 80),
          child: Column(
            children: [
              _buildProfileHeader(),
              _buildMenuSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
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
              Icons.person,
              size: 40,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '李明',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '138****5678',
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('健康档案'),
          _buildMenuCard([
            _MenuItem(
              icon: Icons.person_outline,
              title: '个人信息',
              onTap: () {},
            ),
            _MenuItem(
              icon: Icons.medical_information_outlined,
              title: '健康信息',
              onTap: () {},
            ),
            _MenuItem(
              icon: Icons.history,
              title: '康复历史',
              onTap: () {},
            ),
          ]),
          const SizedBox(height: 24),
          _buildSectionTitle('设置'),
          _buildMenuCard([
            _MenuItem(
              icon: Icons.notifications_outlined,
              title: '消息通知',
              onTap: () {},
            ),
            _MenuItem(
              icon: Icons.lock_outline,
              title: '隐私设置',
              onTap: () {},
            ),
            _MenuItem(
              icon: Icons.help_outline,
              title: '帮助与反馈',
              onTap: () {},
            ),
          ]),
          const SizedBox(height: 24),
          _buildMenuCard([
            _MenuItem(
              icon: Icons.info_outline,
              title: '关于我们',
              onTap: () {},
            ),
            _MenuItem(
              icon: Icons.article_outlined,
              title: '用户协议',
              onTap: () {},
            ),
          ]),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: onLogout,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.error,
              side: const BorderSide(color: AppTheme.error),
            ),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildMenuCard(List<_MenuItem> items) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          return Column(
            children: [
              _buildMenuListTile(item),
              if (index < items.length - 1)
                const Divider(height: 1, indent: 56),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMenuListTile(_MenuItem item) {
    return ListTile(
      leading: Icon(item.icon, color: AppTheme.primary),
      title: Text(
        item.title,
        style: const TextStyle(
          fontSize: 15,
          color: AppTheme.textPrimary,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right,
        color: AppTheme.textTertiary,
      ),
      onTap: item.onTap,
    );
  }
}

class _MenuItem {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  _MenuItem({
    required this.icon,
    required this.title,
    required this.onTap,
  });
}
