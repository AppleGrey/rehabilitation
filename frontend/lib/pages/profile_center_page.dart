import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/auth_api.dart';
import '../services/auth_store.dart';
import '../services/ota_updater.dart';
import '../services/program_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';

class ProfileCenterPage extends StatefulWidget {
  /// 退出登录后回调，由 AuthGate 切回登录页。
  final VoidCallback onLogout;
  final VoidCallback onOpenFreeFollow;

  const ProfileCenterPage({
    super.key,
    required this.onLogout,
    required this.onOpenFreeFollow,
  });

  @override
  State<ProfileCenterPage> createState() => _ProfileCenterPageState();
}

class _ProfileCenterPageState extends State<ProfileCenterPage> {
  String _versionLabel = '';
  bool _checking = false;
  AuthUser? _user = AuthStore.user;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _refreshUser();
  }

  Future<void> _refreshUser() async {
    final u = await AuthApi.me();
    if (!mounted) return;
    setState(() => _user = u ?? AuthStore.user);
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _versionLabel = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _versionLabel = '');
    }
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await OtaUpdater.checkAndPrompt(context, manual: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _changePassword() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '当前密码'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '新密码（6-64 位）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AuthApi.changePassword(
        oldPassword: oldCtrl.text,
        newPassword: newCtrl.text,
      );
      if (!mounted) return;
      _toast('密码已修改');
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新登录才能查看康复方案。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AuthApi.logout();
    // 本地疗程历史是设备侧缓存，换账号后不应残留。
    await ProgramStore.clear();
    if (!mounted) return;
    widget.onLogout();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showInformation({
    required String title,
    required IconData icon,
    required List<({String title, String body})> sections,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.bgSecondary,
      sheetAnimationStyle: AnimationStyle(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 420),
        ),
        reverseDuration: AppMotion.duration(context, AppMotion.standard),
        curve: AppMotion.curve,
        reverseCurve: AppMotion.emphasized,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 32),
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.bgTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            AppIconBadge(icon: icon, size: 52),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 22),
            ...sections.map(
              (section) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        section.title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        section.body,
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.7,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showHelp() => _showInformation(
    title: '帮助与训练指南',
    icon: Icons.help_outline_rounded,
    sections: const [
      (
        title: '如何开始训练',
        body: '先在「问诊」中描述身体情况，生成方案后进入动作详情。观看标准演示，再按照屏幕提示录制跟练视频。',
      ),
      (
        title: '拍摄的小技巧',
        body: '将手机竖直固定，保持光线充足，让全身完整出现在画面中。请穿着方便活动的衣服，并预留足够的安全空间。',
      ),
      (title: '疼痛与不适', body: '训练应以可承受为前提。如果疼痛明显、眩晕或不适加重，请立刻停止并及时联系专业医生。'),
      (
        title: '关于 AI 评估',
        body: '姿态识别与问诊内容用于辅助康复，不构成医疗诊断。动作得分只是训练参考，请结合自身感受与专业建议。',
      ),
    ],
  );

  void _showPrivacy() => _showInformation(
    title: '隐私与使用说明',
    icon: Icons.privacy_tip_outlined,
    sections: const [
      (
        title: '你的训练数据',
        body: '登录信息、问诊与训练记录用于生成方案、完成动作评估及展示个人进度。请勿在公共设备上保存登录状态。',
      ),
      (title: '摄像头使用', body: '摄像头仅在你主动进入训练时使用，用于动作跟练与视频评估。录制前请确认周围环境与入镜人员隐私。'),
      (title: '服务边界', body: '本应用提供康复辅助与健康管理功能，不替代医疗机构的诊断、处方或急救服务。'),
    ],
  );

  void _showAbout() => _showInformation(
    title: '关于运动康复',
    icon: Icons.spa_outlined,
    sections: [
      (title: '让科学的康复更简单', body: '从问诊、专属方案到动作评估和进度记录，陪你把每一次训练踏实完成。'),
      if (_versionLabel.isNotEmpty)
        (title: '当前版本', body: '运动康复 v$_versionLabel'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppPageHeader(
                eyebrow: 'YOUR SPACE',
                title: '个人中心',
                subtitle: '管理训练与账号，安心地持续恢复',
              ),
              const SizedBox(height: 22),
              _buildProfileHeader(),
              _buildMenuSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileHeader() {
    final user = _user;
    final name = user?.displayName ?? '未登录';
    final initial = name.isEmpty ? '我' : name.characters.first.toUpperCase();
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: AppTheme.primaryDark,
          borderRadius: BorderRadius.circular(26),
        ),
        child: constraints.maxWidth < 330
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _avatar(initial),
                  const SizedBox(height: 16),
                  _userDetails(name, user?.maskedPhone ?? '—'),
                ],
              )
            : Row(
                children: [
                  _avatar(initial),
                  const SizedBox(width: 16),
                  Expanded(child: _userDetails(name, user?.maskedPhone ?? '—')),
                ],
              ),
      ),
    );
  }

  Widget _avatar(String initial) => Container(
    width: 64,
    height: 64,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: AppTheme.primaryLight,
      borderRadius: BorderRadius.circular(22),
    ),
    child: Text(
      initial,
      style: const TextStyle(
        fontSize: 27,
        fontWeight: FontWeight.w800,
        color: AppTheme.primaryDark,
      ),
    ),
  );

  Widget _userDetails(String name, String phone) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        phone,
        style: TextStyle(
          fontSize: 13,
          color: Colors.white.withValues(alpha: 0.65),
        ),
      ),
      const SizedBox(height: 10),
      const AppPill(
        label: '我的健康，由每一步积累',
        icon: Icons.verified_user_outlined,
        color: AppTheme.primaryLight,
        backgroundColor: Color(0xFF31594B),
      ),
    ],
  );

  Widget _buildMenuSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 26),
        const SectionHeader(title: '训练工具'),
        const SizedBox(height: 12),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: widget.onOpenFreeFollow,
            child: AppCard(
              color: AppTheme.primaryLight,
              child: Row(
                children: [
                  const AppIconBadge(
                    icon: Icons.accessibility_new_rounded,
                    color: Colors.white,
                    backgroundColor: AppTheme.primary,
                    size: 50,
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '自由跟做',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.primaryDark,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          '随时选择动作，实时查看姿态反馈',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: AppTheme.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 26),
        const SectionHeader(title: '账号与支持'),
        const SizedBox(height: 12),
        _buildMenuCard([
          _MenuItem(
            icon: Icons.lock_outline_rounded,
            title: '修改密码',
            subtitle: '保护你的账号安全',
            onTap: _changePassword,
          ),
          _MenuItem(
            icon: Icons.help_outline_rounded,
            title: '帮助与训练指南',
            subtitle: '拍摄技巧与安全提示',
            onTap: _showHelp,
          ),
          _MenuItem(
            icon: Icons.system_update_alt_rounded,
            title: _checking ? '正在检查更新…' : '检查更新',
            subtitle: _versionLabel.isEmpty ? '获取最新版本' : '当前 v$_versionLabel',
            onTap: _checking ? () {} : _checkUpdate,
          ),
        ]),
        const SizedBox(height: 26),
        const SectionHeader(title: '关于'),
        const SizedBox(height: 12),
        _buildMenuCard([
          _MenuItem(
            icon: Icons.privacy_tip_outlined,
            title: '隐私与使用说明',
            onTap: _showPrivacy,
          ),
          _MenuItem(
            icon: Icons.info_outline_rounded,
            title: '关于运动康复',
            onTap: _showAbout,
          ),
        ]),
        const SizedBox(height: 28),
        OutlinedButton.icon(
          onPressed: _logout,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.error,
            side: BorderSide(color: AppTheme.error.withValues(alpha: 0.3)),
            backgroundColor: Colors.white,
          ),
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const Text('退出当前账号'),
        ),
      ],
    );
  }

  Widget _buildMenuCard(List<_MenuItem> items) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.border),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: AppIconBadge(icon: item.icon, size: 40),
      title: Text(
        item.title,
        style: const TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
        ),
      ),
      subtitle: item.subtitle == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                item.subtitle!,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
      trailing: const Icon(
        Icons.arrow_forward_ios_rounded,
        color: AppTheme.textTertiary,
        size: 14,
      ),
      onTap: item.onTap,
    );
  }
}

class _MenuItem {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  _MenuItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });
}
