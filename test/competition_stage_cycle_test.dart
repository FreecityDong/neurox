import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/competition_guidance.dart';
import 'package:neurox/features/tasks/learning_flow_widgets.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/l10n/app_language.dart';
import 'guided_scene_flow_test.dart' as fixture;

void main() {
  for (final lang in ['zh', 'en']) {
    for (final scene in [TaskScene.esports, TaskScene.go, TaskScene.archery]) {
      testWidgets(
        '$lang ${scene.name} cycles without post stage and saves directly from interval',
        (tester) async {
          AppLanguage.instance.resetForTest(lang);
          final f = await fixture.prepare(tester, scene);
          String? saved;
          try {
            await fixture.start(f);
            final monitor = f.task.monitor!, id = f.task.sessionId;
            final baseline = Map.from(monitor.reference);
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: ListenableBuilder(
                    listenable: f.task,
                    builder: (_, _) => f.task.monitor == null
                        ? const Text('SAVED')
                        : LearningLivePanel(
                            task: f.task,
                            onEnd: () async {
                              saved = await f.task.finish();
                            },
                          ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(tr('练后复查')), findsNothing);
            await tester.tap(find.byType(PopupMenuButton<String>));
            await tester.pumpAndSettle();
            expect(
              find.text(tr('练后复查')),
              findsNothing,
              reason: 'No alternate post-stage entry in the menu',
            );
            await tester.tapAt(const Offset(5, 5));
            await tester.pumpAndSettle();
            final playing = scene == TaskScene.esports
                ? 'match'
                : scene == TaskScene.go
                ? 'thinking'
                : 'shooting';
            for (final next in [playing, 'interval', playing, 'interval']) {
              final action = find.text(
                competitionAction(scene, f.task.sceneStage),
              );
              await tester.ensureVisible(action);
              await tester.pumpAndSettle();
              await tester.tap(action);
              await tester.pumpAndSettle();
              expect(f.task.sceneStage, next);
              expect(f.task.sessionId, id);
              expect(monitor.reference, baseline);
              expect(find.text(tr('练后复查')), findsNothing);
            }
            await tester.tap(find.text(tr('结束并保存')));
            await tester.pumpAndSettle();
            expect(saved, id);
            expect(f.task.active, false);
            expect(f.task.completedTaskScene, scene.name);
            expect(monitor.events.where((e) => e['stage'] == 'post'), isEmpty);
            expect(f.backend.calls, contains('monitorFinish'));
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await f.close();
            AppLanguage.instance.resetForTest();
          }
        },
      );
    }
  }
}
