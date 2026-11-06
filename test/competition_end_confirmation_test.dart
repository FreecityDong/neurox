import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/l10n/app_language.dart';
import 'guided_scene_flow_test.dart' as fixture;

void main() {
  for (final scene in [TaskScene.esports, TaskScene.go, TaskScene.archery]) {
    for (final lang in ['zh', 'en']) {
      testWidgets(
        '$lang ${scene.name} enters post phase and keeps monitoring; pause/recheck preserves it; saving stops',
        (tester) async {
          AppLanguage.instance.resetForTest(lang);
          final f = await fixture.prepare(tester, scene);
          try {
            await fixture.start(f);
            f.task.setCondition(true);
            final id = f.task.sessionId,
                m = f.task.monitor!,
                reference = Map.from(f.task.monitor!.reference);
            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BaselinePage(task: f.task),
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
            await tester.tap(find.text(scene.endLabel));
            await tester.pumpAndSettle();
            expect(
              find.text(tr('确认后不能返回此前阶段，监测仍会继续，点击“结束并保存”才会停止。')),
              findsOneWidget,
            );
            await tester.tap(find.text(tr('取消')));
            await tester.pumpAndSettle();
            expect(f.task.sceneStage, 'preparation');
            final saves = f.backend.calls
                .where((c) => c == 'monitorFinish')
                .length;
            await tester.tap(find.text(scene.endLabel));
            await tester.pumpAndSettle();
            await tester.tap(find.text(tr('确认')));
            await tester.pumpAndSettle();
            expect(f.task.competitionPostStage, true);
            expect(f.task.sceneStage, scene.postStage);
            expect(m.phase, 'running');
            expect(m.finished, false);
            expect(find.byType(PopupMenuButton<String>), findsNothing);
            expect(find.text(scene.endLabel), findsNothing);
            f.task.changeStage('preparation');
            expect(f.task.sceneStage, scene.postStage);
            f.clock = 102;
            m.observe(
              at: 102,
              sampleAt: 102,
              features: {'attention': 65, 'relax': 45},
              good: true,
            );
            f.clock = 103;
            await tester.pump(const Duration(seconds: 1));
            expect(m.elapsed, 3);
            expect(
              m.events.where(
                (e) => e['type'] == 'sample' && e['stage'] == scene.postStage,
              ),
              isNotEmpty,
            );
            expect(
              f.backend.calls.where((c) => c == 'monitorFinish').length,
              saves,
            );
            await tester.tap(find.text(tr('暂停任务')));
            await tester.pumpAndSettle();
            expect(m.phase, 'paused');
            f.clock = 120;
            await tester.tap(find.text(tr('继续监测')));
            await tester.pumpAndSettle();
            expect(f.task.learningPreparing, true);
            expect(f.task.sceneStage, scene.postStage);
            expect(m.elapsed, 3);
            f.clock = 125;
            f.ready();
            f.task.setCondition(true);
            await tester.pump();
            await tester.tap(find.text(tr('继续监测')));
            await tester.pumpAndSettle();
            expect(m.phase, 'running');
            expect(f.task.sceneStage, scene.postStage);
            expect(m.reference, reference);
            expect(f.task.sessionId, id);
            f.clock = 130;
            await tester.pump(const Duration(seconds: 1));
            expect(m.elapsed, 8);
            await tester.tap(find.text(tr('结束并保存')));
            await tester.pumpAndSettle();
            await tester.tap(find.text(tr('取消')));
            await tester.pumpAndSettle();
            expect(m.finished, false);
            expect(f.task.active, true);
            await tester.tap(find.text(tr('结束并保存')));
            await tester.pumpAndSettle();
            await tester.tap(find.text(tr('确认')));
            await tester.pumpAndSettle();
            expect(m.finished, true);
            expect(f.task.active, false);
            expect(f.task.completedSession, id);
            expect(
              f.backend.calls.where((c) => c == 'monitorFinish').length,
              saves + 1,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await f.close();
            AppLanguage.instance.resetForTest();
          }
        },
      );
    }
    testWidgets('${scene.name} failed final save only retries the same save', (
      tester,
    ) async {
      final f = await fixture.prepare(tester, scene);
      try {
        await fixture.start(f);
        f.task.endCompetitionStage();
        final id = f.task.sessionId, m = f.task.monitor!;
        f.backend.failFinish = true;
        expect(await f.task.finish(), isNull);
        expect(m.finished, true);
        expect(f.task.active, true);
        f.ready();
        expect(f.task.canMonitor, false);
        final starts = f.backend.calls.where((c) => c == 'monitorStart').length;
        await f.task.startMonitoring();
        await f.task.continueMonitoring();
        expect(m.finished, true);
        expect(
          f.backend.calls.where((c) => c == 'monitorStart').length,
          starts,
        );
        f.backend.failFinish = false;
        expect(await f.task.finish(), id);
        expect(f.task.active, false);
      } finally {
        await f.close();
      }
    });
  }
}
