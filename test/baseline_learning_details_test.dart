import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';
import 'package:neurox/features/tasks/detail_widgets.dart';
import 'package:neurox/features/tasks/monitoring_widgets.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'package:neurox/features/tasks/scene_widgets.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/l10n/app_language.dart';

List<Map<String, dynamic>> savedWindows() => [
  {
    'payload': const AnalysisWindow(
      sequence: 1,
      start: 0,
      end: 1,
      reason: 'warming',
      observationReason: 'warming',
    ).toMap(),
  },
  {
    'payload': const AnalysisWindow(
      sequence: 2,
      start: 5,
      end: 6,
      reason: 'comparison_warming',
      observationReason: 'good',
      observationFeatures: {'attention': 48, 'relax': 55},
    ).toMap(),
  },
  {
    'payload': const AnalysisWindow(
      sequence: 3,
      start: 9,
      end: 10,
      reason: 'good',
      features: {'attention': 60, 'relax': 45},
      observationReason: 'good',
      observationFeatures: {'attention': 50, 'relax': 52},
    ).toMap(),
  },
];
void main() {
  test(
    'Use serialized quality and early observation fields; do not rewrite median comparison features',
    () {
      final windows = savedWindows();
      final events = baselineDetailEvents(windows);
      final quality = events.where((e) => e['type'] == 'quality').toList();
      expect(quality.map((e) => e['reason']), ['warming', 'good']);
      final samples = events.where((e) => e['type'] == 'sample').toList();
      expect(samples.first['scores'], isNull);
      expect((samples[1]['scores'] as Map)['attention'], 48);
      expect((samples[2]['scores'] as Map)['attention'], 50);
      expect(
        ((windows.last['payload'] as Map)['features'] as Map)['attention'],
        60,
      );
      expect(
        baselineDetailEvents([
          {
            'payload': {'end': 1, 'quality': 'gap', 'reason': 'good'},
          },
        ]).last['reason'],
        'gap',
      );
    },
  );
  testWidgets('Missing warmup point still displays its saved quality reason', (
    tester,
  ) async {
    AppLanguage.instance.resetForTest();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SceneCurve(
              interactive: true,
              observationOnly: true,
              events: baselineDetailEvents(savedWindows()),
              eventLabel: (e) => qualityLabel(e['reason'] as String),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(
      find.byKey(const ValueKey('baseline-interactive-plot')),
    );
    await tester.tapAt(Offset(rect.left + rect.width * .1, rect.center.dy));
    await tester.pump();
    expect(find.text('正在等待滤波稳定'), findsOneWidget);
    expect(find.text('专注：—'), findsOneWidget);
    await tester.tapAt(Offset(rect.left + rect.width * .6, rect.center.dy));
    await tester.pump();
    expect(find.text('信号质量合格'), findsOneWidget);
    expect(find.text('专注：48.0'), findsOneWidget);
  });
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language learning retains frozen baseline and removes process/algorithm clutter',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        addTearDown(() => AppLanguage.instance.resetForTest());
        tester.view.physicalSize = const Size(320, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final account = LocalAccount();
        addTearDown(account.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MediaQuery(
                  data: const MediaQueryData(
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: TaskReview(
                    account: account,
                    row: {
                      'name': 'Historical learning',
                      'task_state': 'task_complete',
                      'feedback_json': {},
                      'events': [],
                      'monitor_json': {
                        'version': monitoringVersion,
                        'scene': 'learning',
                        'elapsed': 120,
                        'validSeconds': 90,
                        'durations': {
                          'stable': 75,
                          'deviation': 15,
                          'unknown': 30,
                        },
                        'reference': {
                          'attention': {'mean': 63, 'variance': 42.25},
                          'relax': {'mean': 44, 'variance': 16},
                        },
                        'referenceOrigin': {'collectedAt': 1000},
                      },
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(tr('本次参考基线')), findsOneWidget);
        await tester.ensureVisible(find.text(tr('本次参考基线')));
        await tester.tap(find.text(tr('本次参考基线')));
        await tester.pumpAndSettle();
        expect(find.text('63.0 ± 6.5'), findsOneWidget);
        expect(find.text('44.0 ± 4.0'), findsNothing);
        expect(find.text(tr('建立时间')), findsOneWidget);
        expect(find.text(tr('个人基线与算法')), findsNothing);
        expect(find.text(tr('过程记录')), findsNothing);
        expect(find.text(tr('采集与调整记录')), findsNothing);
        expect(find.text(tr('状态分布')), findsNothing);
        expect(find.text(tr('保存主观反馈')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('learning-attention-plot')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
