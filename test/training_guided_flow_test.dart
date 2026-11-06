import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/features/tasks/training_game.dart';
import 'package:neurox/features/tasks/training_widgets.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/l10n/app_language.dart';
import 'guided_scene_flow_test.dart' as fixture;

void main() {
  for (final lang in ['zh', 'en']) {
    for (final kind in TrainingKind.values) {
      testWidgets(
        '$lang ${kind.name} guided selection and signal check precede silent game timing',
        (tester) async {
          AppLanguage.instance.resetForTest(lang);
          final width = kind.index.isOdd ? 320.0 : 430.0;
          tester.view.physicalSize = Size(width, 932);
          tester.view.devicePixelRatio = 1;
          final f = await fixture.prepare(tester, TaskScene.training);
          try {
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width == 320 ? 1.4 : 1),
                  ),
                  child: child!,
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => TaskPreparation(task: f.task),
                        ),
                      ),
                      child: const Text('OPEN'),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('OPEN'));
            await tester.pumpAndSettle();
            expect(
              find.byType(DropdownButtonFormField<TrainingKind>),
              findsNothing,
            );
            final card = find.byKey(ValueKey('training-game-${kind.name}'));
            await tester.scrollUntilVisible(
              card,
              200,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.ensureVisible(card);
            await tester.pumpAndSettle();
            await tester.tap(card);
            await tester.pumpAndSettle();
            expect(f.task.trainingKind, kind);
            if (kind == TrainingKind.tracking) {
              final level = find.text(trSource(TrackingLevel.values[2].label));
              await tester.scrollUntilVisible(
                level,
                200,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.ensureVisible(level);
              await tester.pumpAndSettle();
              await tester.tap(level);
              await tester.pumpAndSettle();
              expect(f.task.trackingLevel, 2);
            }
            expect(find.textContaining('SDK'), findsNothing);
            final prepare = find.text(TaskScene.training.prepareButtonLabel);
            await tester.tap(prepare);
            await tester.pumpAndSettle();
            expect(f.task.initialLearningCheck, true);
            expect(f.task.trainingGame, isNull);
            expect(f.task.monitor!.elapsed, 0);
            expect(find.text(tr('退出')), findsOneWidget);
            f.transport.emit({
              'type': 'recording',
              'active': true,
              'state': 'recording',
            });
            f.ready();
            f.task.setCondition(false);
            await tester.pump();
            await tester.tap(find.text(TaskScene.training.beginLabel));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(f.task.learningPreparing, false);
            expect(f.task.initialLearningCheck, false);
            expect(find.byType(TrainingPanel), findsOneWidget);
            expect(f.task.trainingGame!.kind, kind);
            expect(f.task.monitor!.elapsed, 0);
            expect(f.task.monitor!.reminders, false);
            expect(f.task.monitor!.stageSilenced, true);
            expect(
              f.backend.arguments['learningStart']!['protocol']['gameKind'],
              kind.name,
            );
            expect(
              f.task.monitor!.events.where((e) => e['type'] == 'game_start'),
              hasLength(1),
            );
            expect(f.backend.calls.where((c) => c == 'monitorAlert'), isEmpty);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            final id = f.task.sessionId;
            expect(await f.task.finish(), id);
            expect(f.task.completedTaskScene, 'training');
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
    testWidgets(
      '$lang training first signal check exits without a saved task',
      (tester) async {
        AppLanguage.instance.resetForTest(lang);
        final f = await fixture.prepare(tester, TaskScene.training);
        try {
          await f.task.startLearning();
          final id = f.task.sessionId;
          expect(f.task.unstartedLearning, true);
          expect(await f.task.discardUnstartedLearning(), true);
          expect(f.backend.arguments['deleteSession']!['id'], id);
          expect(f.task.active, false);
          expect(f.task.trainingGame, isNull);
          expect(f.task.completedSession, isNull);
        } finally {
          await f.close();
          AppLanguage.instance.resetForTest();
        }
      },
    );
  }
}
