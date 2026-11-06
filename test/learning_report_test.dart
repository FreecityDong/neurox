import 'package:flutter/services.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'support/fake_eeg_transport.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/learning_trend.dart';
import 'package:neurox/features/tasks/learning_report.dart';
import 'package:neurox/l10n/app_language.dart';

Map<String, dynamic> summary() => {
  'version': 'sdk-personal-monitor-v2',
  'scene': 'learning',
  'elapsed': 60,
  'validSeconds': 60,
  'durations': {'stable': 40, 'deviation': 20, 'unknown': 0},
  'reference': {
    'attention': {'mean': 60, 'variance': 25},
  },
  'rules': {'sustainedSeconds': 25, 'recoverySeconds': 10},
  'timeline': [
    {'start': 0, 'end': 20, 'state': 'stable'},
    {'start': 20, 'end': 40, 'state': 'deviation'},
    {'start': 40, 'end': 60, 'state': 'stable'},
  ],
};
List<Map<String, dynamic>> events() => [
  for (var i = 1; i <= 60; i++)
    {
      'type': 'sample',
      'elapsed': i,
      'wallSeconds': i + 100,
      'scores': {
        'attention': i <= 20
            ? 65
            : i <= 40
            ? 45
            : 70,
        'relax': 30,
      },
    },
];
void main() {
  test(
    'Saved task clock and state intervals align with overview, upper band never reclassifies a deviation',
    () {
      final d = LearningTrend(summary(), events());
      expect(d.timelineComplete, isTrue);
      expect(
        d.spans.where((s) => s.state == 'deviation').single.end -
            d.spans.where((s) => s.state == 'deviation').single.start,
        20,
      );
      expect(d.lower, 55);
      expect(d.upper, 65);
      expect(d.points.last.time, 60);
      expect(d.stateAt(50), 'stable');
      expect(d.at(60).value, 70);
      expect(d.trendDelta, 5);
      expect(d.at(5).time, 5);
    },
  );
  test(
    'Missing intervals or inconsistent durations are not reconstructed as red deviations',
    () {
      final d = LearningTrend({...summary(), 'timeline': []}, events());
      expect(d.timelineComplete, isFalse);
      expect(d.spans, isEmpty);
      expect(d.trendDelta, isNull);
      final mismatch = LearningTrend({
        ...summary(),
        'durations': {'stable': 30, 'deviation': 30, 'unknown': 0},
      }, events());
      expect(mismatch.spans, isEmpty);
      final missing = LearningTrend(
        summary(),
        events()
            .where(
              (e) => (e['elapsed'] as int) < 10 || (e['elapsed'] as int) > 30,
            )
            .toList(),
      );
      expect(missing.at(20).value, isNull);
      expect(missing.trendDelta, isNull);
    },
  );
  testWidgets(
    'PNG is a complete independent image containing the plot and explanation',
    (tester) async {
      final bytes = await tester.runAsync(
        () => renderLearningReport({
          'name': 'Example study',
          'started': 1000,
          'monitor_json': summary(),
          'events': [
            for (final e in events()) {'payload': e},
          ],
        }),
      );
      expect(bytes!.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await tester.runAsync(
        () => ui.instantiateImageCodec(bytes),
      );
      final frame = await tester.runAsync(() => codec!.getNextFrame());
      expect(frame!.image.width, 1100);
      expect(frame.image.height, greaterThan(1000));
      frame.image.dispose();
      codec!.dispose();
    },
  );
  testWidgets(
    'Study export button shares PNG with record id instead of JSON events',
    (tester) async {
      AppLanguage.instance.resetForTest();
      final account = LocalAccount(), transport = FakeEegTransport();
      final eeg = EegController(transport);
      Map? args;
      String? method;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            LocalAccount.channel,
            (call) async => {
              'id': 'example',
              'kind': 'task',
              'task_state': 'task_complete',
              'state': 'saved',
              'name': 'Example study',
              'started': 1000,
              'device': 'Fake',
              'exists': true,
              'task_json': {'scene': 'learning'},
              'monitor_json': summary(),
              'feedback_json': {},
              'events': [
                for (final e in events()) {'payload': e},
              ],
            },
          );
      const channel = MethodChannel('neurox/eeg/methods');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            method = call.method;
            args = call.arguments as Map;
            return true;
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        account.dispose();
        eeg.dispose();
        await transport.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RecordDetail(account: account, controller: eeg, id: 'example'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('记录概况')).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('learning-attention-plot')))
              .dy,
        ),
      );
      expect(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey('learning-attention-plot')),
            )
            .dy,
        lessThan(tester.getTopLeft(find.text('学习概况')).dy),
      );
      expect(find.text('导出任务摘要与事件'), findsNothing);
      final button = find.text('导出学习报告图片');
      await tester.scrollUntilVisible(
        button,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final exportButton = tester.widget<FilledButton>(
        find.ancestor(of: button, matching: find.byType(FilledButton)).first,
      );
      expect(exportButton.onPressed, isNotNull);
      exportButton.onPressed!();
      for (var i = 0; i < 100 && method == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        method,
        'exportLearningReport',
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '),
      );
      expect(args!['id'], 'example');
      expect((args!['png'] as List).take(8).toList(), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language focus-only curve supports inspection at narrow large font',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        addTearDown(() => AppLanguage.instance.resetForTest());
        tester.view.physicalSize = const Size(320, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MediaQuery(
                  data: const MediaQueryData(
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: LearningAttentionCurve(
                    data: LearningTrend(summary(), events()),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text(tr('放松度')), findsNothing);
        final r = tester.getRect(
          find.byKey(const ValueKey('learning-attention-plot')),
        );
        await tester.tapAt(
          Offset(r.left + 42 + (r.width - 52) * .5, r.center.dy),
        );
        await tester.pump();
        expect(find.text(tr('专注：{p0}', {'p0': '45.0'})), findsOneWidget);
        expect(find.text(tr('确认偏离')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
