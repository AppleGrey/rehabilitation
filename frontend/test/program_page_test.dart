import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehabilitation_app/pages/program_page.dart';
import 'package:rehabilitation_app/theme/app_theme.dart';
import 'package:rehabilitation_app/widgets/motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('方案详情展示真实数据，支持说明展开与窄屏布局', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = _ProgramHttpClient();
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.theme,
          home: const ProgramPage(programId: 'preview'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('暂时没有连上康复方案'),
        findsNothing,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('\n'),
      );
      expect(find.text('肩颈功能康复'), findsOneWidget);
      expect(find.text('本期已完成 1 / 2'), findsOneWidget);
      expect(find.text('继续我的训练'), findsOneWidget);
      final verticalScroll = find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      );
      await tester.scrollUntilVisible(
        find.text('88 分'),
        300,
        scrollable: verticalScroll,
      );
      expect(find.text('88 分'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ListView && widget.scrollDirection == Axis.horizontal,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('查看评估'));
      await tester.pumpAndSettle();
      expect(find.text('动作评估'), findsOneWidget);
      expect(find.text('综合评分'), findsOneWidget);
      Navigator.of(tester.element(find.text('综合评分'))).pop();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('方案详情'),
        300,
        scrollable: verticalScroll,
      );
      expect(find.text('方案详情'), findsOneWidget);
      expect(find.text('注意事项'), findsOneWidget);
      expect(find.text('按阶段逐步恢复肩颈活动。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => client);
  });

  testWidgets('减少动态效果会关闭非必要过渡', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: SizedBox.shrink(),
      ),
    );
    final context = tester.element(find.byType(SizedBox));
    expect(AppMotion.duration(context, AppMotion.standard), Duration.zero);
  });
}

Map<String, dynamic> _programView() => {
  'program_id': 'preview',
  'session_id': 'session-preview',
  'condition': '肩颈功能康复',
  'status': 'active',
  'current_stage_no': 2,
  'current': {
    'stage': {
      'stage_type': 'sub_acute',
      'goals': ['改善活动度', '缓解僵硬'],
    },
    'plan': {
      'summary_text': '按阶段逐步恢复肩颈活动。',
      'precautions': ['保持呼吸自然，不要耸肩。'],
    },
    'items': [
      {
        'video_id': 'neck_stretch',
        'title': '颈部轻柔伸展',
        'role': 'warmup',
        'sets': 3,
        'reps': 10,
        'frequency': '每日1次',
        'training': {
          'task_id': 'assessment-preview',
          'status': 'done',
          'overall_score': 88,
          'rom_target_ratio': 0.9,
        },
      },
      {
        'video_id': 'shoulder_circle',
        'title': '肩部环绕放松',
        'role': 'main',
        'sets': 3,
        'reps': 10,
        'frequency': '每日1次',
        'notes': '动作缓慢，保持躯干稳定。',
      },
    ],
  },
};

class _ProgramHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _ProgramHttpRequest(
      url.path.contains('/assess/status/')
          ? {
              'assessment': {'overall_score': 88},
              'summary': '动作完成稳定。',
            }
          : _programView(),
    );
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

class _ProgramHttpRequest extends Fake implements HttpClientRequest {
  final Map<String, dynamic> _data;
  _ProgramHttpRequest(this._data);
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
  Future<HttpClientResponse> close() async => _ProgramHttpResponse(_data);
}

class _ProgramHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final String _body;
  final _headers = _TestHeaders();
  _ProgramHttpResponse(Map<String, dynamic> data) : _body = jsonEncode(data);

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
