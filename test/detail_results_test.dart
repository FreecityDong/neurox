import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/detail_widgets.dart';
import 'package:neurox/features/tasks/scene_detail_results.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/features/tasks/baseline_features.dart';
import 'package:neurox/l10n/app_language.dart';

void main() {
  test(
    'Unknown values remain unknown, ratios validate their denominator, time is unbounded',
    () {
      expect(detailTime(null), '—');
      expect(detailTime(double.nan), '—');
      expect(detailTime(90061), '25:01:01');
      expect(detailRatio(5, 10), '50.0%');
      expect(detailRatio(10, 0), '—');
      expect(detailRatio(11, 10), '—');
    },
  );
  test(
    'Stage longest uses maximum not sum or last stage; incomplete logs cannot claim whole-session result',
    () {
      final events = [
        {
          'sequence': 1,
          'type': 'stage_summary',
          'stage': 'match',
          'longestKeepSeconds': 65,
        },
        {
          'sequence': 2,
          'type': 'stage_summary',
          'stage': 'interval',
          'longestKeepSeconds': 5,
        },
      ];
      final summary = {
        'eventSequence': 2,
        'stage': 'post',
        'longestKeepSeconds': 10,
      };
      expect(detailLongest(summary, events), '1:05');
      expect(detailStages(summary, events).length, 3);
      expect(detailLongest({...summary, 'checkpointOnly': true}, events), '—');
      expect(detailLongest(summary, events.skip(1).toList()), '—');
    },
  );
  test(
    'Baseline quality log records only transitions, preserves every sample and good recovery',
    () {
      final reasons = [
        'warming',
        'warming',
        'comparison_warming',
        'comparison_warming',
        'good',
        'good',
        'gap',
        'gap',
        'good',
      ];
      final windows = [
        for (var i = 0; i < reasons.length; i++)
          {
            'payload': {
              'end': i + 1,
              'reason': reasons[i],
              'features': {'attention': 60, 'relax': 40},
            },
          },
      ];
      final events = baselineDetailEvents(windows);
      expect(events.where((e) => e['type'] == 'sample').length, 9);
      final changes = events.where((e) => e['type'] == 'quality').toList();
      expect(changes.map((e) => e['reason']), [
        'warming',
        'comparison_warming',
        'good',
        'gap',
        'good',
      ]);
      expect(changes.map((e) => e['wallSeconds']), [1, 3, 5, 7, 9]);
      expect(
        baselineDetailEvents([
          {
            'payload': {'end': double.nan, 'reason': 'good'},
          },
        ]),
        isEmpty,
      );
    },
  );
  for (final language in ['zh', 'en']) {
    for (final scene in ['learning', 'archery', 'training', 'recovery']) {
      testWidgets(
        '$language $scene shows scene-specific details at 320px large text',
        (tester) async {
          AppLanguage.instance.resetForTest(language);
          addTearDown(() => AppLanguage.instance.resetForTest());
          tester.view.physicalSize = const Size(320, 1600);
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
                    child: SceneDetailResults(
                      summary: {
                        'scene': scene,
                        'phase': 'finished',
                        'elapsed': 120,
                        'validSeconds': 80,
                        'stage': 'aiming',
                        'longestKeepSeconds': 20,
                        'durations': {
                          'stable': 60,
                          'deviation': 20,
                          'unknown': 40,
                        },
                        if (scene == 'training')
                          'game': {
                            'kind': 'tracking',
                            'level': 1,
                            'elapsed': 33,
                            'correct': 1,
                            'goal': 2,
                            'mistakes': 1,
                            'outcome': 'completed',
                          },
                        if (scene == 'recovery')
                          'recoveryTeaching': {
                            'method': 'breathing',
                            'stage': 'guided',
                            'readinessBefore': 2,
                          },
                      },
                      events: const [],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (['training', 'recovery'].contains(scene)) {
            expect(
              find.text(tr(scene == 'training' ? '放松度' : '专注度')),
              findsNothing,
            );
            expect(find.text(tr('趋势与统计说明')), findsOneWidget);
            expect(find.text(tr('结果说明')), findsNothing);
            expect(find.text(tr('放松均值 ± 标准差')), findsNothing);

            expect(
              find.byKey(const ValueKey('baseline-interactive-plot')),
              findsOneWidget,
            );
            expect(find.text(tr('过程曲线')), findsOneWidget);
            expect(
              find.text(tr('分母包含监测中的未知/受阻，排除实时准备、暂停和后台中断。')),
              findsNothing,
            );
          }
          if (scene == 'recovery') {
            expect(find.text(tr('练习前准备度')), findsOneWidget);
            expect(find.text(tr('可判断比例')), findsNothing);
          } else if (scene == 'training') {
            expect(find.text(tr('完成目标')), findsOneWidget);
            expect(find.text(tr('连续参考范围保持')), findsNothing);
          } else {
            if (['learning', 'archery'].contains(scene)) {
              expect(
                find.byKey(const ValueKey('learning-attention-plot')),
                findsOneWidget,
              );
            } else {
              expect(find.text(tr('可判断比例')), findsOneWidget);
            }
            expect(find.text(tr('恢复练习记录')), findsNothing);
          }
          if (scene == 'archery') {
            await tester.ensureVisible(find.text(tr('阶段记录')));
            await tester.tap(find.text(tr('阶段记录')));
            await tester.pumpAndSettle();
            expect(find.text(tr('时间点未记录')), findsOneWidget);
          }
        },
      );
    }
  }
  testWidgets(
    'Baseline reference and quality remain visible without technical attempts',
    (tester) async {
      AppLanguage.instance.resetForTest();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BaselineHistorySummary(
                row: {
                  'name': 'Named baseline',
                  'task_state': 'baseline_ready',
                  'baseline_json': {
                    'algorithm': baselineAlgorithmVersion,
                    'state': 'ready',
                    'elapsed': 100,
                    'validSeconds': 80,
                    'statistics': {
                      'attention': {'mean': 60, 'standardDeviation': 4},
                      'relax': {'mean': 40, 'standardDeviation': 3},
                    },
                  },
                  'attempts': [],
                  'windows': [],
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('80.0%'), findsOneWidget);
      expect(find.text('60.0 ± 4.0'), findsOneWidget);
      expect(find.text('40.0 ± 3.0'), findsOneWidget);
      expect(find.text('Named baseline'), findsOneWidget);
      expect(find.text('尝试与算法详情'), findsNothing);
    },
  );
}
