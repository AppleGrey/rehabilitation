import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'pages/home_page.dart';
import 'pages/training_page.dart';
import 'pages/result_page.dart';
import 'pages/plan_page.dart';
import 'pages/progress_page.dart';
import 'pages/knowledge_page.dart';
import 'pages/profile_center_page.dart';
import 'pages/pose_detection_page.dart';
import 'pages/chat_list_page.dart';
import 'pages/chat_page.dart';
import 'pages/rehab_video_page.dart';
import 'widgets/nav_bar.dart';

class RehabilitationApp extends StatelessWidget {
  const RehabilitationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '运动康复',
      theme: AppTheme.theme,
      debugShowCheckedModeBanner: false,
      home: const AppNavigator(),
    );
  }
}

class AppNavigator extends StatefulWidget {
  const AppNavigator({super.key});

  @override
  State<AppNavigator> createState() => _AppNavigatorState();
}

class _AppNavigatorState extends State<AppNavigator> {
  // 页面索引:
  // 0 = 主页面组（带底部导航）
  // 1 = AI 问诊列表页（历史会话）
  // 2 = AI 问诊对话页
  // 3 = 康复视频 + 动作评估页
  // 4 = 训练详情页
  // 5 = 训练结果页
  // 6 = 姿态检测页
  int _currentPage = 0;
  int _bottomNavIndex = 0;
  bool _showBottomNav = true;

  // 传递给子页面的数据
  String? _rehabVideoUrl;
  String? _rehabVideoId;
  String? _rehabSessionId;
  String? _rehabVideoTitle;
  ConversationRecord? _openRecord; // 打开的历史记录（null = 新建）

  void _navigateToHome() {
    setState(() {
      _currentPage = 0;
      _showBottomNav = true;
    });
  }

  void _navigateToChatList() {
    setState(() {
      _currentPage = 1;
      _showBottomNav = false;
    });
  }

  void _navigateToChat({ConversationRecord? existing}) {
    setState(() {
      _openRecord = existing;
      _currentPage = 2;
      _showBottomNav = false;
    });
  }

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
      _currentPage = 3;
      _showBottomNav = false;
    });
  }

  void _navigateToTraining() {
    setState(() {
      _currentPage = 4;
      _showBottomNav = false;
    });
  }

  void _navigateToResult() {
    setState(() {
      _currentPage = 5;
      _showBottomNav = false;
    });
  }

  void _navigateToPoseDetection() {
    setState(() {
      _currentPage = 6;
      _showBottomNav = false;
    });
  }

  void _onPageSelected(int index) {
    if (index == 1) {
      _navigateToTraining();
    } else {
      setState(() => _bottomNavIndex = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildCurrentPage(),
      bottomNavigationBar: _showBottomNav
          ? NavBar(currentIndex: _bottomNavIndex, onTap: (i) => setState(() => _bottomNavIndex = i))
          : null,
    );
  }

  Widget _buildCurrentPage() {
    switch (_currentPage) {
      case 0:
        return _buildMainPages();
      case 1:
        return ChatListPage(
          onBack: _navigateToHome,
          onOpenChat: (existing) => _navigateToChat(existing: existing),
        );
      case 2:
        return ChatPage(
          key: ValueKey(_openRecord?.sessionId ?? 'new'),
          onBack: _navigateToChatList,
          existingRecord: _openRecord,
          onVideoSelected: (url, videoId, sessionId) => _navigateToRehabVideo(
            videoUrl: url,
            videoId: videoId,
            sessionId: sessionId,
            videoTitle: '康复训练演示',
          ),
        );
      case 3:
        return RehabVideoPage(
          key: ValueKey('$_rehabVideoId-$_rehabSessionId'),
          onBack: _navigateToChatList,
          videoUrl: _rehabVideoUrl,
          videoId: _rehabVideoId,
          sessionId: _rehabSessionId,
          videoTitle: _rehabVideoTitle,
        );
      case 4:
        return TrainingPage(
          onBack: _navigateToHome,
          onViewResult: _navigateToResult,
          onStartRecording: _navigateToResult,
        );
      case 5:
        return ResultPage(onBack: _navigateToHome);
      case 6:
        return PoseDetectionPage(onBack: _navigateToHome);
      default:
        return _buildMainPages();
    }
  }

  Widget _buildMainPages() {
    return Scaffold(
      body: IndexedStack(
        index: _bottomNavIndex,
        children: [
          HomePage(
            onNavigate: (_) {},
            onPageSelected: _onPageSelected,
            onPoseDetection: _navigateToPoseDetection,
            onAiConsult: _navigateToChatList,
          ),
          const PlanPage(),
          const ProgressPage(),
          const KnowledgePage(),
          ProfileCenterPage(onLogout: () {
            setState(() {
              _currentPage = 0;
              _showBottomNav = true;
              _bottomNavIndex = 0;
            });
          }),
        ],
      ),
    );
  }
}
