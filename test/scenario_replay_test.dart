import 'package:flutter/material.dart';
import 'package:neurox/features/tasks/learning_trend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/tasks/scenario_replay.dart';
import 'package:neurox/features/tasks/scene_detail_results.dart';
import 'package:neurox/features/tasks/baseline_features.dart';
import 'package:neurox/features/tasks/learning_report.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/fake_eeg_transport.dart';

Map<String, dynamic> replaySource() {
  final ref = {
    'attention': {'mean': 60.0, 'variance': 25.0},
    'relax': {'mean': 40.0, 'variance': 9.0},
  };
  final m = MonitoringEngine(
    targetSeconds: 0,
    at: 0,
    reference: ref,
    attemptId: 'source',
    context: {},
  );
  for (var i = 1; i <= 60; i++) {
    m.observe(
      at: i.toDouble(),
      sampleAt: i.toDouble(),
      features: {'attention': i >= 6 && i <= 25 ? 40 : 65, 'relax': 40},
      good: true,
    );
  }
  m.finish(60, 'user_completed');
  return {
    'id': 'source',
    'name': 'Example',
    'kind': 'task',
    'state': 'saved',
    'task_state': 'task_complete',
    'started': 1000,
    'ended': 1060,
    'exists': true,
    'device': 'Fake',
    'task_json': {'scene': 'learning'},
    'baseline_json': {'algorithm': baselineAlgorithmVersion, 'statistics': ref},
    'monitor_json': m.snapshot(60),
    'events': [
      for (final e in m.events) {'payload': e},
    ],
  };
}

void main() {
  test(
    'Replay preserves all source curve points even inside unknown quality',
    () {
      final source = replaySource();
      final summary = source['monitor_json'] as Map<String, dynamic>;
      summary['timeline'] = [
        {'start': 0.0, 'end': 10.0, 'state': 'unknown'},
        {'start': 10.0, 'end': 60.0, 'state': 'stable'},
      ];
      summary['durations'] = {
        'stable': 50.0,
        'deviation': 0.0,
        'unknown': 10.0,
      };
      final sourceEvents = [
        for (final row in source['events'] as List)
          Map<String, dynamic>.from((row as Map)['payload'] as Map),
      ];
      final expected = LearningTrend(summary, sourceEvents);
      for (final scene in [
        TaskScene.esports,
        TaskScene.go,
        TaskScene.archery,
      ]) {
        final replay = buildScenarioReplay(source, scene);
        final trend = LearningTrend(replay.summary, replay.events);
        expect(
          trend.points.map((p) => (p.time, p.value)).toList(),
          expected.points.map((p) => (p.time, p.value)).toList(),
        );
        expect(replay.events.where((e) => e['type'] == 'stage').length, 1);
        expect(replay.summary['eventSequence'], replay.events.length);
        expect(trend.timelineComplete, true);
        expect(trend.stateAt(5), 'unknown');
      }
    },
  );

  test(
    'Copied replay runs competitive 10/15 rules without reusing study classifications or modifying source',
    () {
      final source = replaySource();
      final original = source['monitor_json'] as Map;
      expect((original['durations'] as Map)['deviation'], 0);
      for (final scene in [
        TaskScene.esports,
        TaskScene.go,
        TaskScene.archery,
      ]) {
        final r = buildScenarioReplay(source, scene);
        expect(r.summary['isReplay'], true);
        expect((r.summary['rules'] as Map)['sustainedSeconds'], 10);
        expect((r.summary['rules'] as Map)['recoverySeconds'], 15);
        expect((r.summary['durations'] as Map)['deviation'], greaterThan(0));
        expect(r.summary['reference'], original['reference']);
        expect(r.summary['remindersRequested'], 0);
        expect(
          r.summary['stage'],
          scene == TaskScene.archery
              ? 'preparation'
              : scene == TaskScene.go
              ? 'thinking'
              : 'match',
        );
      }
      expect((original['durations'] as Map)['deviation'], 0);
    },
  );
  test(
    'Unfinished, recursive, incompatible or incomplete learning records cannot be replayed',
    () {
      final source = replaySource();
      expect(
        () => buildScenarioReplay({
          ...source,
          'task_state': 'active',
        }, TaskScene.go),
        throwsStateError,
      );
      expect(
        () => buildScenarioReplay({
          ...source,
          'task_json': {'scene': 'learning', 'isReplay': true},
        }, TaskScene.go),
        throwsStateError,
      );
      expect(
        () => buildScenarioReplay({
          ...source,
          'monitor_json': {...source['monitor_json'] as Map, 'timeline': []},
        }, TaskScene.go),
        throwsStateError,
      );
      expect(
        () => buildScenarioReplay(source, TaskScene.learning),
        throwsStateError,
      );
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language competitive details share focused layout and folded stages',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        addTearDown(() => AppLanguage.instance.resetForTest());
        tester.view.physicalSize = const Size(320, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final r = buildScenarioReplay(replaySource(), TaskScene.archery);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MediaQuery(
                  data: const MediaQueryData(
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: SceneDetailResults(
                    summary: r.summary,
                    events: r.events,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(LearningAttentionCurve), findsOneWidget);
        expect(find.text(tr('训练概况')), findsOneWidget);
        expect(find.text(tr('阶段记录')), findsOneWidget);
        expect(find.text(tr('分阶段记录')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Study review keeps export and delete but removes replay copy and repeat actions',
    (tester) async {
      AppLanguage.instance.resetForTest();
      final source = replaySource(),
          account = LocalAccount(),
          transport = FakeEegTransport();
      final eeg = EegController(transport);
      Map? copyArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalAccount.channel, (call) async {
            if (call.method == 'saveScenarioReplay') {
              copyArgs = call.arguments as Map;
              return {'id': 'replay-id'};
            }
            if (call.method == 'detail' &&
                (call.arguments as Map)['id'] == 'replay-id') {
              return {
                ...source,
                'id': 'replay-id',
                'name': '[Replay] Example',
                'task_json': {'scene': 'esports', 'isReplay': true},
                'monitor_json': copyArgs!['snapshot'],
              };
            }
            return source;
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
        account.dispose();
        eeg.dispose();
        await transport.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RecordDetail(account: account, controller: eeg, id: 'source'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('删除记录'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('删除记录'), findsOneWidget);
      expect(find.text('导出原始 JSONL'), findsOneWidget);
      expect(find.text('复制为竞技／运动测试回放'), findsNothing);
      expect(find.text('再来一次'), findsNothing);
      expect(copyArgs, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
