import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehabilitation_app/pages/program_history_page.dart';
import 'package:rehabilitation_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('康复历程按轮展示训练与进阶决策，含进行中轮次', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = _HistoryHttpClient(_roundsPayload());
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: const ProgramHistoryPage(programId: 'p1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 新的在前：第 2 轮（进行中）在顶部
      expect(find.text('第 2 轮 · 恢复期'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);
      // 第 1 轮：决策 + 依据指标 + 训练（可回放）
      expect(find.text('第 1 轮 · 恢复期'), findsOneWidget);
      expect(find.text('本阶段再巩固'), findsOneWidget);
      expect(find.text('动作质量还有隐患，再巩固一轮。'), findsOneWidget);
      expect(find.text('均分 78'), findsOneWidget);
      expect(find.text('最高疼痛 3/10'), findsOneWidget);
      expect(find.text('直腿抬高'), findsOneWidget);
      expect(find.textContaining('第 1/2 组'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => client);
  });
}

Map<String, dynamic> _roundsPayload() => {
  'program_id': 'p1',
  'status': 'active',
  'current_stage_no': 2,
  'rounds': [
    {
      'round_no': 1,
      'stage_no': 1,
      'stage_type': 'sub_acute',
      'stage_label': '恢复期',
      'version': 1,
      'summary_text': '恢复期 v1',
      'started_at': '2026-10-20T09:00:00+08:00',
      'ended_at': '2026-10-22T10:00:00+08:00',
      'decision': 'hold',
      'rationale': '动作质量还有隐患，再巩固一轮。',
      'metrics': {
        'avg_overall_score': 78,
        'pain_max': 3,
        'rom_ratio_avg': 0.9,
        'items_assessed': 2,
        'items_prescribed': 2,
      },
      'in_progress': false,
      'trainings': [
        {
          'task_id': 't1',
          'video_id': 'v1',
          'title': '直腿抬高',
          'set_no': 1,
          'set_total': 2,
          'status': 'done',
          'score': 78,
          'pain_reported': 3,
          'created_at': '2026-10-21T09:00:00+08:00',
        },
      ],
      'trainings_done': 1,
      'avg_score': 78,
    },
    {
      'round_no': 2,
      'stage_no': 1,
      'stage_type': 'sub_acute',
      'stage_label': '恢复期',
      'version': 2,
      'summary_text': '恢复期 v2',
      'started_at': '2026-10-22T11:00:00+08:00',
      'ended_at': null,
      'decision': null,
      'rationale': '',
      'metrics': null,
      'in_progress': true,
      'trainings': [],
      'trainings_done': 0,
      'avg_score': null,
    },
  ],
};

class _HistoryHttpClient extends Fake implements HttpClient {
  final Map<String, dynamic> _data;
  _HistoryHttpClient(this._data);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _HistoryHttpRequest(_data);
  }

  @override
  void close({bool force = false}) {}
}

class _TestHeaders extends Fake implements HttpHeaders {
  final _values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }
}

class _HistoryHttpRequest extends Fake implements HttpClientRequest {
  final Map<String, dynamic> _data;
  _HistoryHttpRequest(this._data);
  final _headers = _TestHeaders();

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
  Future<HttpClientResponse> close() async => _HistoryHttpResponse(_data);
}

class _HistoryHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final String _body;
  final _headers = _TestHeaders();
  _HistoryHttpResponse(Map<String, dynamic> data) : _body = jsonEncode(data);

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
