import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/competition_guidance.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/l10n/app_language.dart';
import 'guided_scene_flow_test.dart' as fixture;

void main() {
  for (final lang in ['zh', 'en']) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        '$lang $width project cards select the actual scene, phase protocol and end action',
        (tester) async {
          AppLanguage.instance.resetForTest(lang);
          tester.view.physicalSize = Size(width, 932);
          tester.view.devicePixelRatio = 1;
          final f = await fixture.prepare(tester, TaskScene.esports);
          try {
            await tester.pumpWidget(
              MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(width == 320 ? 1.4 : 1),
                  ),
                  child: TaskPreparation(task: f.task),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.byType(DropdownButtonFormField<TaskScene>),
              findsNothing,
            );
            for (final scene in [
              TaskScene.esports,
              TaskScene.go,
              TaskScene.archery,
            ]) {
              final card = find.byKey(
                ValueKey('competition-project-${scene.name}'),
              );
              await tester.scrollUntilVisible(
                card,
                160,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.ensureVisible(card);
              await tester.pumpAndSettle();
              await tester.tap(card);
              await tester.pumpAndSettle();
              expect(f.task.scene, scene);
              expect(f.task.sceneStage, 'preparation');
              expect(f.task.targetMinutes, 0);
              expect(f.task.conditionMatches, false);
              expect(tester.takeException(), isNull);
            }
            expect(find.byType(CompetitionProjectPicker), findsOneWidget);
            await tester.pumpWidget(const SizedBox());
            await fixture.start(f);
            expect(f.backend.arguments['learningStart']!['scene'], 'archery');
            expect(f.task.monitor!.rules.scene, TaskScene.archery);
            f.task.setScene(TaskScene.go);
            expect(
              f.task.scene,
              TaskScene.archery,
              reason: 'An active task cannot be changed by the picker',
            );
            expect(f.task.scene.endLabel, tr('结束训练'));
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
