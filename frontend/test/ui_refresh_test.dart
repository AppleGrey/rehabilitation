import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehabilitation_app/pages/chat_list_page.dart';
import 'package:rehabilitation_app/pages/login_page.dart';
import 'package:rehabilitation_app/pages/profile_center_page.dart';
import 'package:rehabilitation_app/theme/app_theme.dart';
import 'package:rehabilitation_app/widgets/common_widgets.dart';
import 'package:rehabilitation_app/widgets/nav_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget child) => MaterialApp(theme: AppTheme.theme, home: child);

Future<void> _setPhoneSize(WidgetTester tester, {double width = 360}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('登录页支持模式切换，窄屏无溢出', (tester) async {
    await _setPhoneSize(tester, width: 320);
    await tester.pumpWidget(_app(LoginPage(onSuccess: () {})));
    expect(find.text('登录'), findsWidgets);
    await tester.tap(find.text('创建账号'));
    await tester.pumpAndSettle();
    expect(find.text('开始康复之旅'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部导航触发切换且有选中反馈', (tester) async {
    await _setPhoneSize(tester);
    late StateSetter update;
    var selected = 0;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: NavBar(
                currentIndex: selected,
                onTap: (i) => selected = i,
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    update(() {});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('进度'), findsOneWidget);
    final selectedTab = find.semantics.byPredicate(
      (node) =>
          node.label == '进度' &&
          node.getSemanticsData().flagsCollection.isSelected.toBoolOrNull() ==
              true,
    );
    expect(selectedTab, findsOneWidget);
    expect(
      selectedTab,
      matchesSemantics(
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('问诊列表空状态和刷新布局正常', (tester) async {
    await _setPhoneSize(tester);
    await tester.pumpWidget(_app(ChatListPage(onOpenChat: (_) {})));
    await tester.pumpAndSettle();
    expect(find.text('还没有问诊记录'), findsOneWidget);
    expect(find.text('发起新问诊'), findsOneWidget);
    await tester.tap(find.text('开始第一次问诊'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('个人中心窄屏自适应且帮助入口可用', (tester) async {
    await _setPhoneSize(tester, width: 320);
    await tester.pumpWidget(
      _app(ProfileCenterPage(onLogout: () {}, onOpenFreeFollow: () {})),
    );
    await tester.pump();
    expect(find.text('自由跟做'), findsOneWidget);
    await tester.ensureVisible(find.text('帮助与训练指南'));
    await tester.tap(find.text('帮助与训练指南'));
    await tester.pumpAndSettle();
    expect(find.text('如何开始训练'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用错误卡片提供重试操作', (tester) async {
    await _setPhoneSize(tester);
    var retried = false;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: AppEmptyState(
              icon: Icons.cloud_off_outlined,
              title: '暂时没有连上康复记录',
              body: '请检查网络连接后重试。',
              actionLabel: '重新加载',
              onAction: () => retried = true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('重新加载'));
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });
}
