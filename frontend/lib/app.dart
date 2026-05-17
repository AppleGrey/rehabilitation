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
  // Demo 模式：直接从首页开始，跳过欢迎/注册/档案
  // 0 = 主页面组（带底部导航）
  // 1 = AI 问诊对话页
  // 2 = 康复视频 + 动作评估页
  // 3 = 训练详情页
  // 4 = 训练结果页
  // 5 = 姿态检测页
  int _currentPage = 0;
  int _bottomNavIndex = 0;
  bool _showBottomNav = true;

  // 传递给子页面的视频信息
  String? _rehabVideoUrl;
  String? _rehabVideoTitle;

  void _navigateToHome() {
    setState(() {
      _currentPage = 0;
      _showBottomNav = true;
    });
  }

  void _navigateToChat() {
    setState(() {
      _currentPage = 1;
      _showBottomNav = false;
    });
  }

  void _navigateToRehabVideo({String? videoUrl, String? videoTitle}) {
    setState(() {
      _rehabVideoUrl = videoUrl;
      _rehabVideoTitle = videoTitle;
      _currentPage = 2;
      _showBottomNav = false;
    });
  }

  void _navigateToTraining() {
    setState(() {
      _currentPage = 3;
      _showBottomNav = false;
    });
  }

  void _navigateToResult() {
    setState(() {
      _currentPage = 4;
      _showBottomNav = false;
    });
  }

  void _navigateToPoseDetection() {
    setState(() {
      _currentPage = 5;
      _showBottomNav = false;
    });
  }

  void _onBottomNavTap(int index) {
    setState(() {
      _bottomNavIndex = index;
    });
  }

  void _onPageSelected(int index) {
    if (index == 1) {
      _navigateToTraining();
    } else {
      setState(() {
        _bottomNavIndex = index;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentPage,
        children: [
          _buildMainPages(),
          ChatPage(
            onBack: _navigateToHome,
            onVideoSelected: (url, title) =>
                _navigateToRehabVideo(videoUrl: url, videoTitle: title),
          ),
          RehabVideoPage(
            onBack: _navigateToHome,
            videoUrl: _rehabVideoUrl,
            videoTitle: _rehabVideoTitle,
          ),
          TrainingPage(
            onBack: _navigateToHome,
            onViewResult: _navigateToResult,
            onStartRecording: _navigateToResult,
          ),
          ResultPage(onBack: _navigateToHome),
          PoseDetectionPage(onBack: _navigateToHome),
        ],
      ),
      bottomNavigationBar: _showBottomNav
          ? NavBar(currentIndex: _bottomNavIndex, onTap: _onBottomNavTap)
          : null,
    );
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
            onAiConsult: _navigateToChat,
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
