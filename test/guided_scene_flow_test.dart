import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/shell/saved_task_card.dart';
import 'package:neurox/features/tasks/competition_guidance.dart';
import 'package:neurox/features/tasks/learning_flow_widgets.dart';
import 'package:neurox/features/tasks/recovery_flow_widgets.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/tasks/scene_widgets.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/monitoring_fixture.dart';

Future<MonitorFixture> prepare(WidgetTester tester, TaskScene scene) async {
  final f = MonitorFixture();
  await f.initialize();
  await f.task.finish();
  f.transport.emit({'type': 'recording', 'active': false, 'state': 'saved'});
  f.task.clearDraft();
  f.task.setScene(scene);
  await tester.runAsync(() => f.task.refresh());
  return f;
}

Future<void> start(MonitorFixture f) async {
  await f.task.startLearning();
  f.transport.emit({'type': 'recording', 'active': true, 'state': 'recording'});
  f.ready();
  await f.task.startMonitoring();
  expect(f.task.learningPreparing, false);
}

void main() {
  for (final scene in [
    TaskScene.esports,
    TaskScene.go,
    TaskScene.archery,
    TaskScene.recovery,
  ]) {
    testWidgets(
      '${scene.name} initial exit discards; started pause/recheck preserves original task and reference',
      (tester) async {
        final f = await prepare(tester, scene);
        try {
          await f.task.startLearning();
          expect(f.task.initialLearningCheck, true);
          final unstarted = f.task.sessionId;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LearningReadyPanel(task: f.task, onEnd: () {}),
              ),
            ),
          );
          expect(find.text('退出'), findsOneWidget);
          expect(find.text('结束并保存'), findsNothing);
          expect(find.text('本次参考基线'), findsNothing);
          expect(find.text('提醒方式'), findsNothing);
          expect(await f.task.discardUnstartedLearning(), true);
          expect(f.backend.arguments['deleteSession']!['id'], unstarted);
          expect(f.task.completedSession, isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() => f.task.refresh());
          await start(f);
          final id = f.task.sessionId,
              original = Map.from(f.task.monitor!.reference);
          final flow = f.task.recoveryFlow;
          if (scene == TaskScene.recovery) {
            expect(flow!.method, 'breathing');
            expect(flow.stage, 'demonstration');
            f.task.advanceRecovery();
            expect(flow.stage, 'guided');
            expect(f.task.sceneStage, 'guided');
            expect(f.task.monitor!.stage, 'guided');
          }
          f.clock = 102;
          f.task.pauseMonitoring();
          expect(f.task.monitor!.phase, 'paused');
          final elapsed = f.task.monitor!.elapsed;
          if (scene == TaskScene.recovery) {
            f.task.advanceRecovery();
            expect(flow!.stage, 'guided');
          }
          f.quality();
          expect(
            f.task.canMonitor,
            false,
            reason: 'cached quality cannot bypass a new check',
          );
          await f.task.continueMonitoring();
          expect(f.task.learningPreparing, true);
          expect(f.task.quality, isNull);
          expect(
            f.backend.arguments['learningRefresh']!['referenceId'],
            'SAVED PERSONAL BASELINE',
          );
          f.clock = 112;
          f.ready();
          await f.task.startMonitoring();
          expect(f.task.sessionId, id);
          expect(f.task.monitor!.reference, original);
          expect(f.task.monitor!.elapsed, elapsed);
          expect(
            f.task.monitor!.phase,
            scene == TaskScene.recovery ? 'recovery' : 'running',
          );
          if (scene == TaskScene.recovery) {
            expect(identical(f.task.recoveryFlow, flow), true);
            expect(flow!.stage, 'guided');
          }
          expect(await f.task.discardUnstartedLearning(), false);
          expect(await f.task.finish(), id);
          expect(f.task.completedTaskScene, scene.name);
          f.task.clearDraft();
          f.task.setScene(TaskScene.learning);
          expect(
            savedTaskTypeLabel(f.task),
            scene.label,
            reason: 'saved type stays frozen after editing a new draft',
          );
          expect(
            f.backend.calls.where(
              (c) => c == 'baselineStart' || c == 'baselineRetry',
            ),
            isEmpty,
          );
        } finally {
          await tester.pumpWidget(const SizedBox());
          await f.close();
        }
      },
    );
  }
  testWidgets(
    'Archery uses whole-group phases; movements never enable baseline comparison',
    (tester) async {
      final f = await prepare(tester, TaskScene.archery);
      try {
        f.task.setCondition(true);
        await start(f);
        expect(f.task.stageSupportsComparison, true);
        expect(
          competitionNextStage(TaskScene.archery, 'preparation'),
          'shooting',
        );
        f.task.changeStage('shooting');
        expect(f.task.stageSupportsComparison, false);
        expect(f.task.monitor!.comparisonAllowed, false);
        expect(competitionNextStage(TaskScene.archery, 'shooting'), 'interval');
        f.task.changeStage('interval');
        expect(f.task.stageSupportsComparison, true);
        expect(competitionNextStage(TaskScene.archery, 'interval'), 'shooting');
        f.task.changeStage('aiming');
        expect(
          f.task.stageSupportsComparison,
          false,
          reason: 'legacy phases remain compatible',
        );
        expect(f.task.targetMinutes, 0);
      } finally {
        await f.close();
      }
    },
  );
  testWidgets(
    'Recovery method selected in setup drives three steps and preset auto finish',
    (tester) async {
      final f = await prepare(tester, TaskScene.recovery);
      try {
        f.task.recoveryMethod = 'release';
        await start(f);
        expect(
          f.backend.arguments['learningStart']!['protocol']['recoveryMethod'],
          'release',
        );
        final m = f.task.monitor!, flow = f.task.recoveryFlow!;
        f.task.rateRecovery(2, after: false);
        for (var i = 0; i < 3; i++) {
          f.clock += 10;
          f.task.advanceRecovery();
        }
        expect(flow.stage, 'independent');
        expect(m.stage, 'independent');
        expect(m.phase, 'recovery');
        expect(
          m.events.where(
            (e) => e['type'] == 'recheck' || e['stage'] == 'recheck',
          ),
          isEmpty,
        );
        final count = m.sequence;
        f.task.advanceRecovery();
        expect(
          m.sequence,
          count,
          reason: 'No extra terminal step or repeated event',
        );
        expect(flow.readinessBefore, 2);
        f.task.rateRecovery(4, after: true);
        expect(flow.readinessAfter, 4);
        expect(m.reference['relax']['mean'], 40);
        expect(m.targetSeconds, 180);
        m.advance(280);
        expect(m.finished, true);
        expect(m.endReason, 'target_reached');
        final id = f.task.sessionId;
        expect(await f.task.finish(), id);
        expect(
          f.task.claimLearningRecoveryPrompt(id!),
          false,
          reason: 'do not offer another recovery after recovery',
        );
      } finally {
        await f.close();
      }
    },
  );
  for (final lang in ['zh', 'en']) {
    for (final scene in [
      TaskScene.esports,
      TaskScene.go,
      TaskScene.archery,
      TaskScene.recovery,
    ]) {
      testWidgets(
        '$lang ${scene.name} setup/check/live at 320px with large text',
        (tester) async {
          AppLanguage.instance.resetForTest(lang);
          tester.view.physicalSize = const Size(320, 850);
          tester.view.devicePixelRatio = 1;
          final f = await prepare(tester, scene);
          Widget page(Widget child) => MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
              child: child,
            ),
          );
          try {
            await tester.pumpWidget(page(TaskPreparation(task: f.task)));
            await tester.pumpAndSettle();
            expect(find.text(scene.preparationLabel), findsWidgets);
            await tester.scrollUntilVisible(
              find.byType(LearningFeedbackSettings),
              180,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(find.byType(LearningFeedbackSettings), findsOneWidget);
            await tester.scrollUntilVisible(
              find.byType(LearningReferencePreview),
              180,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(find.byType(LearningReferencePreview), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await f.task.startLearning();
            f.transport.emit({
              'type': 'recording',
              'active': true,
              'state': 'recording',
            });
            f.ready();
            await tester.pumpWidget(
              page(
                Scaffold(
                  body: LearningReadyPanel(task: f.task, onEnd: () {}),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(scene.beginLabel), findsOneWidget);
            expect(find.byType(LearningFeedbackSettings), findsNothing);
            expect(find.text(tr('结束并保存')), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await f.task.startMonitoring();
            if (scene == TaskScene.recovery) {
              await tester.pumpWidget(
                page(
                  Scaffold(
                    body: RecoveryLivePanel(task: f.task, onEnd: () {}),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final curve = find.byType(SceneCurve);
              await tester.scrollUntilVisible(
                curve,
                200,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.pumpAndSettle();
              final widget = tester.widget<SceneCurve>(curve);
              expect(widget.metric, 'relax');
              expect(widget.standardDeviationReference, true);
              for (var step = 0; step < 3; step++) {
                f.task.advanceRecovery();
                await tester.pumpWidget(
                  page(
                    Scaffold(
                      body: RecoveryLivePanel(task: f.task, onEnd: () {}),
                    ),
                  ),
                );
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull);
              }
              await tester.drag(
                find.byType(ListView).first,
                const Offset(0, 1500),
              );
              await tester.pumpAndSettle();
              expect(find.text(tr('恢复复查')), findsNothing);
              expect(find.text(tr('进入恢复复查')), findsNothing);
              expect(f.task.recoveryFlow!.stage, 'independent');
              expect(
                find.text(tr('按自己的节奏继续练习，到时自动结束；也可以提前结束并保存。')),
                findsOneWidget,
              );
              expect(find.byType(LearningFeedbackSettings), findsNothing);
              expect(tester.takeException(), isNull);
            } else {
              await tester.pumpWidget(
                page(
                  Scaffold(
                    body: LearningLivePanel(task: f.task, onEnd: () {}),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(find.byType(CompetitionPhaseGuide), findsOneWidget);
              expect(find.text(tr('结束并保存')), findsOneWidget);
              expect(tester.takeException(), isNull);
            }
            f.clock = 101;
            final id = f.task.sessionId;
            await f.task.finish();
            await tester.pumpWidget(
              page(
                Scaffold(
                  body: SavedTaskCard(task: f.task, onOpen: () {}),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.textContaining(scene.label), findsOneWidget);
            expect(f.task.completedSession, id);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await f.close();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            AppLanguage.instance.resetForTest();
          }
        },
      );
    }
  }
}
