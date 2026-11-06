import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:neurox/ui/neurox_brand.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/features/tasks/learning_flow_widgets.dart';
import 'package:neurox/features/tasks/learning_report.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'support/monitoring_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        '$language learning stages and attention-only curve fit $width',
        (tester) async {
          AppLanguage.instance.resetForTest(language);
          tester.view.physicalSize = Size(width, 932);
          tester.view.devicePixelRatio = 1;
          final f = MonitorFixture();
          await f.initialize(running: false);
          Widget shell(Widget page) => MaterialApp(
            theme: NeuroxBrand.theme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(width == 320 ? 1.4 : 1)),
              child: child!,
            ),
            home: page,
          );
          try {
            f.task.quality = null;
            await tester.pumpWidget(shell(BaselinePage(task: f.task)));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<LearningStageGuide>(find.byType(LearningStageGuide))
                  .stage,
              1,
            );
            expect(
              tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, tr('开始学习')),
                  )
                  .onPressed,
              isNull,
            );
            f.quality();
            await tester.pump(const Duration(seconds: 1));
            await tester.tap(find.widgetWithText(FilledButton, tr('开始学习')));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<LearningStageGuide>(find.byType(LearningStageGuide))
                  .stage,
              2,
            );
            expect(find.byType(LearningAttentionCurve), findsOneWidget);
            expect(find.textContaining('SDK'), findsNothing);
            expect(find.text(tr('放松度')), findsNothing);
            final plot = tester.widget<LearningAttentionCurve>(
              find.byType(LearningAttentionCurve),
            );
            expect(
              plot.data.mean,
              f.task.monitor!.reference['attention']!['mean'],
            );
            for (var i = 0; i < 5; i++) {
              await tester.drag(
                find.byType(ListView).first,
                const Offset(0, -400),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
            await tester.ensureVisible(find.text(tr('记录调整')));
            await tester.tap(find.text(tr('记录调整')));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text(tr('调整姿势')));
            await tester.pumpAndSettle();
            await tester.tap(find.text(tr('调整姿势')));
            await tester.pumpAndSettle();
            expect(
              f.task.monitor!.events.where(
                (e) => e['type'] == 'adjustment' && e['kind'] == 'posture',
              ),
              hasLength(1),
            );
            expect(f.task.monitor!.phase, 'running');
            f.task.pauseMonitoring();
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(OutlinedButton, tr('继续学习')));
            await tester.pumpAndSettle();
            expect(find.byType(LearningFeedbackSettings), findsNothing);
            expect(find.byType(LearningReferencePreview), findsNothing);
            expect(
              tester
                  .widget<LearningStageGuide>(find.byType(LearningStageGuide))
                  .stage,
              1,
            );
            final resume = find.widgetWithText(FilledButton, tr('继续学习'));
            expect(tester.widget<FilledButton>(resume).onPressed, isNull);
            f.quality();
            await tester.pump(const Duration(seconds: 1));
            await tester.tap(resume);
            await tester.pumpAndSettle();
            expect(f.task.monitor!.phase, 'running');
            await tester.pumpWidget(const SizedBox());
            await f.task.finish();
            f.transport.emit({
              'type': 'recording',
              'active': false,
              'state': 'saved',
            });
            f.task.clearDraft();
            await tester.runAsync(() => f.task.refresh());
            await tester.pumpWidget(shell(TaskPreparation(task: f.task)));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<LearningStageGuide>(find.byType(LearningStageGuide))
                  .stage,
              0,
            );
            expect(find.textContaining('SDK'), findsNothing);
            expect(find.textContaining('512'), findsNothing);
            expect(find.text(tr('准备学习任务')), findsOneWidget);
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

  testWidgets(
    'Saved learning offers recovery once and opens its preparation without starting another session',
    (tester) async {
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
        expect(f.task.active, true);
        expect(f.task.learningPreparing, true);
        f.transport.emit({
          'type': 'recording',
          'active': true,
          'state': 'recording',
        });
        f.quality();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.widgetWithText(FilledButton, tr('开始学习')));
        await tester.pumpAndSettle();
        f.clock = 115;
        f.task.monitor!.observe(
          at: 115,
          sampleAt: 115,
          features: {'attention': 60, 'relax': 40},
          good: true,
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.widgetWithText(FilledButton, tr('结束并保存')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, tr('确认')));
        await tester.pumpAndSettle();
        expect(find.text(tr('学习记录已保存')), findsOneWidget);
        expect(f.task.active, false);
        final calls = f.backend.learningCount;
        await tester.tap(find.text(tr('前往主动恢复')));
        await tester.pumpAndSettle();
        expect(f.task.scene, TaskScene.recovery);
        expect(find.text(tr('恢复任务时长')), findsOneWidget);
        expect(f.task.active, false);
        expect(f.backend.learningCount, calls);
        expect(f.task.claimLearningRecoveryPrompt('SYNTHETIC TASK 2'), false);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await f.close();
      }
    },
  );

  testWidgets(
    'Failed save never enables recovery prompt; successful save offers only once',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.clock = 115;
      f.task.monitor!.observe(
        at: 115,
        sampleAt: 115,
        features: {'attention': 60, 'relax': 40},
        good: true,
      );
      final reference = Map<String, dynamic>.from(f.task.monitor!.reference);
      await f.task.adjust('wearing');
      expect(f.task.learningPreparing, true);
      expect(f.task.monitor!.reference, reference);
      expect(f.backend.calls, isNot(contains('baselineStart')));
      f.quality();
      await f.task.startMonitoring();
      f.clock = 130;
      f.task.monitor!.observe(
        at: 130,
        sampleAt: 130,
        features: {'attention': 60, 'relax': 40},
        good: true,
      );
      f.backend.failFinish = true;
      expect(await f.task.finish(), isNull);
      expect(f.task.claimLearningRecoveryPrompt('SYNTHETIC TASK'), false);
      f.backend.failFinish = false;
      final id = await f.task.finish();
      expect(id, isNotNull);
      expect(f.task.claimLearningRecoveryPrompt(id!), true);
      expect(f.task.claimLearningRecoveryPrompt(id), false);
      await f.close();
    },
  );
}
