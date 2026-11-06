import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/detail_widgets.dart';
import 'package:neurox/features/tasks/scene_detail_results.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/l10n/app_language.dart';
import 'guided_scene_flow_test.dart' as fixture;

void main() {
  testWidgets(
    'Stage entry time shares the curve clock across pauses, rechecks and repeated phases',
    (tester) async {
      final f = await fixture.prepare(tester, TaskScene.go);
      try {
        await fixture.start(f);
        final m = f.task.monitor!;
        f.clock = 105;
        f.task.pauseMonitoring();
        f.clock = 130;
        await f.task.continueMonitoring();
        f.clock = 150;
        f.ready();
        await f.task.startMonitoring();
        f.clock = 155;
        f.task.changeStage('thinking');
        f.clock = 160;
        f.task.pauseMonitoring();
        f.clock = 190;
        await f.task.continueMonitoring();
        f.clock = 195;
        f.ready();
        await f.task.startMonitoring();
        f.clock = 205;
        f.task.changeStage('interval');
        f.clock = 210;
        f.task.changeStage('thinking');
        f.clock = 213;
        f.task.endCompetitionStage();
        final timeline = detailStageTimeline(m.snapshot(f.clock), m.events);
        expect(timeline.map((e) => e['type']), [
          'stage',
          'pause',
          'prepare_data',
          'resume',
          'stage',
          'pause',
          'prepare_data',
          'resume',
          'stage',
          'stage',
          'stage',
        ]);
        expect(timeline.map((e) => e['at']), [
          0,
          5,
          5,
          5,
          10,
          15,
          15,
          15,
          25,
          30,
          33,
        ]);
        expect(
          timeline.where((e) => e['type'] == 'stage').map((e) => e['stage']),
          ['preparation', 'thinking', 'interval', 'thinking', 'post_match'],
        );
        f.clock = 230;
        await tester.pump(const Duration(seconds: 2));
        expect(m.elapsed, 50);
        expect(f.task.active, true);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'Legacy stage summaries are exit boundaries, not entry times; unknown initial time stays unknown',
    () {
      final events = <Map<String, dynamic>>[
        {
          'sequence': 1,
          'type': 'stage_summary',
          'stage': 'preparation',
          'elapsed': 10,
          'wallSeconds': 40,
        },
        {
          'sequence': 2,
          'type': 'stage_summary',
          'stage': 'thinking',
          'elapsed': 25,
          'wallSeconds': 100,
        },
      ];
      final summary = <String, dynamic>{
        'scene': 'go',
        'stage': 'interval',
        'elapsed': 33,
        'eventSequence': 2,
      };
      expect(detailStageTimeline(summary, events).map((e) => e['at']), [
        0,
        10,
        25,
      ]);
      final partial = detailStageTimeline({
        ...summary,
        'eventSequence': 3,
      }, events);
      expect(partial.first['at'], isNull);
      expect(partial.every((e) => e['at'] == null), true);
    },
  );
  for (final lang in ['zh', 'en']) {
    testWidgets(
      '$lang stage history shows timestamp and entered phase, not duration or hold',
      (tester) async {
        AppLanguage.instance.resetForTest(lang);
        try {
          final summary = <String, dynamic>{
            'scene': 'go',
            'elapsed': 35,
            'stage': 'thinking',
            'longestKeepSeconds': 0,
            'eventSequence': 2,
          };
          final events = <Map<String, dynamic>>[
            {
              'type': 'start',
              'sequence': 1,
              'stage': 'preparation',
              'elapsed': 0,
            },
            {
              'type': 'stage',
              'sequence': 2,
              'stage': 'thinking',
              'elapsed': 10,
            },
          ];
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: SceneDetailResults(summary: summary, events: events),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final section = find.text(tr('阶段记录'));
          await tester.ensureVisible(section);
          await tester.pumpAndSettle();
          await tester.tap(section);
          await tester.pumpAndSettle();
          expect(
            find.text(tr('进入{p0}', {'p0': stageLabel('preparation')})),
            findsOneWidget,
          );
          expect(
            find.text(tr('进入{p0}', {'p0': stageLabel('thinking')})),
            findsOneWidget,
          );
          expect(find.text('0:10'), findsWidgets);
          expect(find.text(tr('连续参考范围保持：{p0}', {'p0': '0:00'})), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          AppLanguage.instance.resetForTest();
        }
      },
    );
  }
}
