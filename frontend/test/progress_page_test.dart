import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehabilitation_app/pages/progress_page.dart';
import 'package:rehabilitation_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('进度页：近 3 个方案进度，节奏与趋势在最近训练上方', (tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = _ProgressHttpClient();
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.theme, home: const ProgressPage()),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 近 3 个方案，每个一行进度
      expect(find.text('方案进度'), findsOneWidget);
      expect(find.text('颈痛康复'), findsOneWidget);
      expect(find.text('腰背养护'), findsOneWidget);
      expect(find.text('肩部调理'), findsOneWidget);
      expect(find.text('恢复期 · 第 2 轮'), findsOneWidget);
      expect(find.text('0/2'), findsOneWidget); // 本轮进度环
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('已结业'), findsOneWidget);
      expect(find.text('生成中'), findsOneWidget);

      // 达标条件卡片已移除
      expect(find.text('本阶段达标条件'), findsNothing);
      expect(find.text('当前阶段'), findsNothing);

      // 顺序：方案进度 → 本周节奏 → 训练趋势 → 最近训练
      double top(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(top('方案进度'), lessThan(top('本周节奏')));
      expect(top('本周节奏'), lessThan(top('训练趋势')));
      expect(top('训练趋势'), lessThan(top('最近训练')));

      // 统计带
      expect(find.text('累计训练 / 次'), findsOneWidget);
      expect(find.text('连续训练 / 天'), findsOneWidget);
      expect(find.text('80'), findsOneWidget); // 平均得分 (85+75)/2
      expect(find.text('本周 2 组训练'), findsOneWidget);

      // 最近训练：评估中在前，已完成可回放
      expect(find.text('颈侧屈'), findsOneWidget);
      expect(find.textContaining('评估中'), findsWidgets);
      expect(find.text('颈部旋转'), findsOneWidget);
      expect(find.text('肩部环绕'), findsOneWidget);
      expect(find.textContaining('第 2/2 组'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => client);
  });
}

Map<String, dynamic> _programsPayload() {
  final now = DateTime.now().toUtc().toIso8601String();
  return {
    'programs': [
      {
        'program_id': 'p1',
        'session_id': 's1',
        'condition': '颈痛康复',
        'status': 'active',
        'current_stage_no': 1,
        'stats': {'trainings_done': 10, 'avg_score': 83.0},
        'current': {
          'stage': {'stage_type': 'sub_acute'},
          'plan': {'version': 2},
          'items': [
            {
              'video_id': 'v1',
              'title': '颈部旋转',
              'training': {'status': 'none'},
            },
            {
              'video_id': 'v2',
              'title': '颈侧屈',
              'training': {'status': 'processing', 'created_at': now},
            },
          ],
        },
      },
      {
        'program_id': 'p2',
        'session_id': 's2',
        'condition': '腰背养护',
        'status': 'discharged',
        'current_stage_no': 4,
        'stats': {'trainings_done': 20},
        'current': {
          'stage': {'stage_type': 'return'},
          'plan': {'version': 1},
          'items': [
            {
              'video_id': 'v9',
              'title': '核心稳定',
              'training': {'status': 'done'},
            },
            {
              'video_id': 'v8',
              'title': '臀桥',
              'training': {'status': 'done'},
            },
          ],
        },
      },
      {
        'program_id': 'p3',
        'session_id': 's3',
        'condition': '肩部调理',
        'status': 'generating',
        'current_stage_no': 1,
      },
    ],
  };
}

Map<String, dynamic> _timelinePayload() {
  final now = DateTime.now().toUtc();
  return {
    'timeline': [
      {
        'task_id': 't1',
        'video_id': 'v1',
        'title': '颈部旋转',
        'score': 85,
        'pain_reported': 2,
        'set_no': 2,
        'set_total': 2,
        'created_at': now
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      },
      {
        'task_id': 't2',
        'video_id': 'v3',
        'title': '肩部环绕',
        'score': 75,
        'pain_reported': 1,
        'set_no': 1,
        'set_total': 1,
        'created_at': now
            .subtract(const Duration(minutes: 2))
            .toIso8601String(),
      },
    ],
  };
}

class _ProgressHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (url.path.contains('/assess/timeline')) {
      return _ProgressHttpRequest(_timelinePayload());
    }
    return _ProgressHttpRequest(_programsPayload());
  }

  @override
  void close({bool force = false}) {}
}

class _ProgressHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void forEach(void Function(String name, List<String> values) action) {}
}

class _ProgressHttpRequest extends Fake implements HttpClientRequest {
  final Map<String, dynamic> _data;
  _ProgressHttpRequest(this._data);
  final _headers = _ProgressHeaders();

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
  Future<HttpClientResponse> close() async => _ProgressHttpResponse(_data);
}

class _ProgressHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final String _body;
  final _headers = _ProgressHeaders();
  _ProgressHttpResponse(Map<String, dynamic> data) : _body = jsonEncode(data);

  @override
  HttpHeaders get headers => _headers;

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
