import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehabilitation_app/pages/home_page.dart';
import 'package:rehabilitation_app/pages/progress_page.dart';
import 'package:rehabilitation_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页和进度页横屏分栏且不溢出', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: HomePage(onConsult: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('肩颈功能康复'), findsOneWidget);
      final hero = tester.getRect(find.byKey(const Key('landscape-hero')));
      final stats = tester.getRect(find.byKey(const Key('landscape-stats')));
      final training = tester.getRect(
        find.byKey(const Key('landscape-training')),
      );
      expect(training.top, moreOrLessEquals(hero.top, epsilon: 1));
      expect(training.bottom, moreOrLessEquals(stats.bottom, epsilon: 1));
      expect(stats.left, moreOrLessEquals(hero.left, epsilon: 1));
      expect(stats.right, moreOrLessEquals(hero.right, epsilon: 1));
      expect(training.left, greaterThan(hero.right));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.theme, home: const ProgressPage()),
      );
      await tester.pumpAndSettle();
      final progress = tester.getRect(
        find.byKey(const Key('landscape-progress-main')),
      );
      final history = tester.getRect(
        find.byKey(const Key('landscape-history')),
      );
      expect(history.top, moreOrLessEquals(progress.top, epsilon: 1));
      expect(history.bottom, moreOrLessEquals(progress.bottom, epsilon: 1));
      expect(history.left, greaterThan(progress.right));
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => _LayoutHttpClient());
  });

  testWidgets('较矮的横屏仍可滚动且不溢出', (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: HomePage(onConsult: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本期训练'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.theme, home: const ProgressPage()),
      );
      await tester.pumpAndSettle();
      // 新版进度页内容更长：矮横屏下先滚动到「本周节奏」，确认可滚动且完整渲染
      await tester.scrollUntilVisible(
        find.text('本周节奏'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('本周节奏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => _LayoutHttpClient());
  });
}

Map<String, dynamic> _programs() => {
  'programs': [
    {
      'program_id': 'preview',
      'condition': '肩颈功能康复',
      'status': 'active',
      'current_stage_no': 2,
      'current': {
        'stage': {'stage_type': 'sub_acute'},
        'plan': {'summary_text': '按阶段恢复。'},
        'items': [
          {
            'title': '颈部轻柔伸展',
            'sets': 3,
            'reps': 10,
            'training': {
              'status': 'done',
              'overall_score': 88,
              'created_at': DateTime.now().toIso8601String(),
            },
          },
          {'title': '肩部环绕放松', 'sets': 3, 'reps': 10},
        ],
      },
    },
  ],
};

class _LayoutHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _LayoutHttpRequest();

  @override
  void close({bool force = false}) {}
}

class _LayoutHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void forEach(void Function(String name, List<String> values) action) {}
}

class _LayoutHttpRequest extends Fake implements HttpClientRequest {
  final _headers = _LayoutHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  set followRedirects(bool value) {}

  @override
  set maxRedirects(int value) {}

  @override
  set contentLength(int value) {}

  @override
  set persistentConnection(bool value) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async => _LayoutHttpResponse();
}

class _LayoutHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final String _body = jsonEncode(_programs());

  @override
  HttpHeaders get headers => _LayoutHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> data)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(_body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int get statusCode => 200;

  @override
  int get contentLength => utf8.encode(_body).length;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
