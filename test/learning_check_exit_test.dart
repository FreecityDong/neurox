import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'support/monitoring_fixture.dart';

void main() {
  for (final lang in ['zh', 'en']) {
    for (final way in ['exit', 'back', 'home']) {
      testWidgets(
        '$lang first signal check $way closes and discards only the unstarted task',
        (tester) async {
          AppLanguage.instance.resetForTest(lang);
          final f = MonitorFixture();
          await f.initialize();
          await f.task.finish();
          f.transport.emit({
            'type': 'recording',
            'active': false,
            'state': 'saved',
          });
          f.task.clearDraft();
          await tester.runAsync(() => f.task.refresh());
          final reference = Map<String, dynamic>.from(f.task.savedReference);
          try {
            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<String>(
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
            await tester.tap(find.text(tr('准备学习任务')));
            await tester.pumpAndSettle();
            expect(f.task.initialLearningCheck, true);
            final id = f.task.sessionId;
            expect(find.text(tr('退出')), findsOneWidget);
            expect(find.text(tr('结束并保存')), findsNothing);
            if (way == 'exit') {
              await tester.tap(find.text(tr('退出')));
            } else if (way == 'home') {
              await tester.tap(find.byIcon(Icons.home_outlined));
            } else {
              await tester.binding.handlePopRoute();
            }
            await tester.pumpAndSettle();
            expect(f.task.active, false);
            expect(f.task.learningPreparing, false);
            expect(f.task.completedSession, isNull);
            expect(f.task.learningPreparationDiscarded, true);
            expect(f.backend.arguments['deleteSession']?['id'], id);
            expect(
              f.backend.calls,
              containsAllInOrder(['monitorFinish', 'deleteSession']),
            );
            expect(f.task.savedReference, reference);
            expect(find.byType(TaskPreparation), findsNothing);
            expect(find.byType(BaselinePage), findsNothing);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await f.close();
            AppLanguage.instance.resetForTest();
          }
        },
      );
    }
  }

  testWidgets(
    'Failed first-check cleanup remains retryable without publishing history',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize(running: false);
      f.backend.failDelete = true;
      expect(await f.task.discardUnstartedLearning(), false);
      expect(f.task.active, true);
      expect(f.task.error, isNotNull);
      expect(f.task.canMonitor, false);
      expect(f.task.completedSession, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(f.backend.calls.where((m) => m == 'monitorFinish').length, 1);
      f.backend.failDelete = false;
      expect(await f.task.discardUnstartedLearning(), true);
      expect(f.task.active, false);
      expect(f.task.completedSession, isNull);
      await f.close();
    },
  );

  testWidgets(
    'Resume check keeps finish-and-save and never discards an already started session',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.clock = 101;
      f.task.pauseMonitoring();
      await f.task.continueMonitoring();
      bool ended = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LearningReadyPanel(task: f.task, onEnd: () => ended = true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.task.initialLearningCheck, false);
      expect(find.text('退出'), findsNothing);
      expect(find.text('结束并保存'), findsOneWidget);
      await tester.tap(find.text('结束并保存'));
      expect(ended, true);
      expect(await f.task.discardUnstartedLearning(), false);
      await tester.pumpWidget(const SizedBox());
      final id = f.task.sessionId;
      expect(await f.task.finish(), id);
      expect(f.backend.calls, isNot(contains('deleteSession')));
      expect(f.task.completedSession, id);
      await f.close();
    },
  );
}
