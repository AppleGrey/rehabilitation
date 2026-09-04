import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'pages/training_page.dart';
import 'pages/result_page.dart';
import 'pages/plan_page.dart';
import 'pages/progress_page.dart';
import 'pages/knowledge_page.dart';
import 'pages/profile_center_page.dart';
import 'pages/chat_list_page.dart';
import 'pages/consult_page.dart';
import 'pages/login_page.dart';
import 'pages/rehab_video_page.dart';
import 'services/auth_api.dart';
import 'services/auth_store.dart';
import 'services/ota_updater.dart';
import 'widgets/nav_bar.dart';

class RehabilitationApp extends StatelessWidget {
  const RehabilitationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '运动康复',
      theme: AppTheme.theme,
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

/// 登录闸门：未登录一律停在登录页。
/// 方案、问诊、评估全部按 user_id 归属，没有登录态就没有「我的」可言。
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late bool _loggedIn = AuthStore.isLoggedIn;

  @override
  void initState() {
    super.initState();
    if (_loggedIn) _revalidate();
  }

  /// 本地有令牌时后台核一次：被停用或令牌过期就退回登录页。
  Future<void> _revalidate() async {
    await AuthApi.me();
    if (!mounted) return;
    if (!AuthStore.isLoggedIn) setState(() => _loggedIn = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loggedIn) {
      return LoginPage(onSuccess: () => setState(() => _loggedIn = true));
    }
    return AppNavigator(onLoggedOut: () => setState(() => _loggedIn = false));
  }
}

class AppNavigator extends StatefulWidget {
  final VoidCallback onLoggedOut;

  const AppNavigator({super.key, required this.onLoggedOut});

  @override
  State<AppNavigator> createState() => _AppNavigatorState();
}

class _AppNavigatorState extends State<AppNavigator> {
  // 0 = 主 Tab（默认中间「问诊」）
  // 1 = 问诊对话  2 = 康复视频  3 = 训练  4 = 结果
  int _currentPage = 0;
  int _bottomNavIndex = 2;
  bool _showBottomNav = true;
  int _planRefreshTick = 0;
  bool _otaChecked = false;

  String? _rehabVideoUrl;
  String? _rehabVideoId;
  String? _rehabSessionId;
  String? _rehabVideoTitle;
  ConversationRecord? _openRecord;

  // 首页「双击退出」记录上次返回键时间
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheckOta());
  }

  Future<void> _autoCheckOta() async {
    if (_otaChecked || !mounted) return;
    _otaChecked = true;
    // 稍晚一点，避免与首屏抢焦点
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    await OtaUpdater.checkAndPrompt(context, manual: false);
  }

  void _navigateToMain({int? tabIndex}) {
    setState(() {
      _currentPage = 0;
      _showBottomNav = true;
      if (tabIndex != null) {
        _bottomNavIndex = tabIndex;
      }
    });
  }

  void _navigateToChatList() {
    _navigateToMain(tabIndex: 2);
  }

  void _navigateToChat({ConversationRecord? existing}) {
    setState(() {
      _openRecord = existing;
      _currentPage = 1;
      _showBottomNav = false;
    });
  }

  // 保留：K2 问诊→方案打通后，由结果卡片跳转康复视频页
  // ignore: unused_element
  void _navigateToRehabVideo({
    String? videoUrl,
    String? videoId,
    String? sessionId,
    String? videoTitle,
  }) {
    setState(() {
      _rehabVideoUrl = videoUrl;
      _rehabVideoId = videoId;
      _rehabSessionId = sessionId;
      _rehabVideoTitle = videoTitle;
      _currentPage = 2;
      _showBottomNav = false;
    });
  }

  void _navigateToResult() {
    setState(() {
      _currentPage = 4;
      _showBottomNav = false;
    });
  }

  /// 处理硬件返回键：子页面返回上一页，非默认 Tab 切回「问诊」，首页双击退出。
  void _handleBack() {
    if (_currentPage != 0) {
      // 子页面：沿用各页 onBack 的「上一页」语义
      switch (_currentPage) {
        case 1: // 问诊对话
        case 2: // 康复视频
          _navigateToChatList();
          break;
        default: // 3 训练 / 4 结果
          _navigateToMain();
      }
      return;
    }
    // 主页面但不在默认「问诊」Tab：切回问诊
    if (_bottomNavIndex != 2) {
      setState(() => _bottomNavIndex = 2);
      return;
    }
    // 真正首页：双击退出
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('再按一次退出应用'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        body: _buildCurrentPage(),
        bottomNavigationBar: _showBottomNav
            ? NavBar(
                currentIndex: _bottomNavIndex,
                onTap: (i) => setState(() {
                  _bottomNavIndex = i;
                  if (i == 0) _planRefreshTick++;
                }),
              )
            : null,
      ),
    );
  }

  Widget _buildCurrentPage() {
    switch (_currentPage) {
      case 0:
        return _buildMainPages();
      case 1:
        return ConsultPage(
          key: ValueKey(_openRecord?.sessionId ?? 'new'),
          onBack: _navigateToChatList,
          existingRecord: _openRecord,
        );
      case 2:
        return RehabVideoPage(
          key: ValueKey('$_rehabVideoId-$_rehabSessionId'),
          onBack: _navigateToChatList,
          videoUrl: _rehabVideoUrl,
          videoId: _rehabVideoId,
          sessionId: _rehabSessionId,
          videoTitle: _rehabVideoTitle,
        );
      case 3:
        return TrainingPage(
          onBack: () => _navigateToMain(),
          onViewResult: _navigateToResult,
          onStartRecording: _navigateToResult,
        );
      case 4:
        return ResultPage(onBack: () => _navigateToMain());
      default:
        return _buildMainPages();
    }
  }

  Widget _buildMainPages() {
    return IndexedStack(
      index: _bottomNavIndex,
      children: [
        PlanPage(refreshTick: _planRefreshTick),
        const ProgressPage(),
        ChatListPage(
          onOpenChat: (existing) => _navigateToChat(existing: existing),
        ),
        const KnowledgePage(),
        ProfileCenterPage(onLogout: widget.onLoggedOut),
      ],
    );
  }
}
