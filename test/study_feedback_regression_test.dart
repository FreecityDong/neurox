import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/features/tasks/training_game.dart';
import 'package:neurox/features/tasks/training_widgets.dart';
import 'package:neurox/features/shell/feedback_preferences.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/monitoring_fixture.dart';

void main() {
  testWidgets(
    'A pending start owns its draft until completed; another module cannot replace its scene',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      f.task.clearDraft();
      f.task.name = 'PENDING START';
      f.task.busy = true;
      f.task.clearDraft();
      f.task.setScene(TaskScene.training);
      expect(f.task.name, 'PENDING START');
      expect(f.task.scene, TaskScene.learning);
      f.task.busy = false;
      await f.close();
    },
  );

  testWidgets(
    'Temporary inactive/resumed from permission UI does not pause, reset or finish a running task',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(f.task.monitor!.phase, 'running');
      f.task.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(f.task.monitor!.phase, 'running');
      expect(f.task.baseline!.state, 'ready');
      expect(f.task.active, true);
      await f.close();
    },
  );
  testWidgets(
    'Back navigation leaves the recorder alive and another start cannot create a concurrent task',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BaselinePage(task: f.task),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(f.task.active, true);
      expect(f.eeg.recording, true);
      expect(f.task.monitor!.phase, 'running');
      final starts = f.backend.calls
          .where((m) => m == 'learningStart' || m == 'baselineStart')
          .length;
      await f.task.startLearning();
      await f.task.start();
      expect(
        f.backend.calls
            .where((m) => m == 'learningStart' || m == 'baselineStart')
            .length,
        starts,
      );
      expect(f.backend.calls, isNot(contains('monitorFinish')));
      f.clock = 10000;
      f.task.monitor!.advance(f.clock);
      expect(f.task.monitor!.finished, false);
      await tester.pumpWidget(const SizedBox());
      await f.close();
    },
  );
  test(
    'Timed recovery includes its own practice time; linked recovery excludes parent study time',
    () {
      final ref = <String, dynamic>{
        'attention': {'mean': 60.0, 'variance': 25.0},
        'relax': {'mean': 40.0, 'variance': 16.0},
      };
      final recovery = MonitoringEngine(
        targetSeconds: 180,
        at: 0,
        reference: ref,
        attemptId: 'R',
        context: {},
        rules: const MonitoringRules(scene: TaskScene.recovery),
      );
      recovery.beginRecovery(0, {});
      recovery.advance(180);
      expect(recovery.finished, true);
      expect(recovery.elapsed, 180);
      expect(recovery.endReason, 'target_reached');
      final study = MonitoringEngine(
        targetSeconds: 0,
        at: 0,
        reference: ref,
        attemptId: 'S',
        context: {},
      );
      study.beginRecovery(0, {});
      study.advance(180);
      expect(study.finished, false);
      expect(study.elapsed, 0);
      expect(study.recoveryActivitySeconds, 180);
    },
  );
  testWidgets(
    'Training persists completed behavior and reports without any alert even after returning from its page',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      f.transport.emit({
        'type': 'recording',
        'active': false,
        'state': 'saved',
      });
      await tester.pump();
      f.task.clearDraft();
      f.task.setScene(TaskScene.training);
      f.task.trainingKind = TrainingKind.obstacles;
      f.task.setFeedback(
        const FeedbackOptions(sound: true, vibration: true, notice: true),
      );
      f.quality();
      await f.task.startLearning();
      f.transport.emit({
        'type': 'recording',
        'active': true,
        'state': 'recording',
      });
      f.ready();
      f.clock = 200;
      await f.task.startMonitoring();
      expect(f.task.monitor!.reminders, false);
      expect(f.task.monitor!.stageSilenced, true);
      expect(f.task.trainingGame, isNotNull);
      f.clock = 210;
      await tester.pump(const Duration(seconds: 1));
      expect(f.task.trainingGame!.elapsed, 10);
      for (var target = 1; target <= 30; target++) {
        f.task.tapTraining(target);
      }
      await tester.pump();
      await tester.pump();
      expect(f.task.active, false);
      expect(f.backend.calls, isNot(contains('monitorAlert')));
      final stored = f.backend.arguments['monitorFinish']!['snapshot'] as Map;
      expect(stored['game']['correct'], 30);
      expect(stored['game']['finished'], true);
      expect(stored['endReason'], 'game_completed');
      await f.close();
    },
  );
  testWidgets(
    'Feedback test reports authorization independently and never creates an attention deviation',
    (tester) async {
      const channel = MethodChannel('neurox/notifications');
      String? called;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            called = call.method;
            return {
              'sound': 'requested',
              'vibration': 'disabled',
              'notice': 'not_authorized',
            };
          });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FeedbackTrial(
              options: FeedbackOptions(sound: true, notice: true),
            ),
          ),
        ),
      );
      await tester.tap(find.text('测试当前提醒'));
      await tester.pumpAndSettle();
      expect(called, 'testFeedback');
      expect(find.textContaining('未授权'), findsOneWidget);
      expect(find.textContaining('声音：已请求'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
  for (final lang in ['zh', 'en']) {
    testWidgets(
      '$lang all four game surfaces fit a narrow phone and preserve silent game operation',
      (tester) async {
        AppLanguage.instance.resetForTest(lang);
        tester.view.physicalSize = const Size(320, 850);
        tester.view.devicePixelRatio = 1;
        final f = MonitorFixture();
        await f.initialize();
        f.task.scene = TaskScene.training;
        for (final kind in TrainingKind.values) {
          f.task.trainingGame = TrainingGame(kind: kind, seed: 7);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: const MediaQueryData(
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: TrainingPanel(task: f.task, onEnd: () {}),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 30));
          expect(find.byType(FeedbackControls), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
        await f.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppLanguage.instance.resetForTest();
      },
    );
  }
}
