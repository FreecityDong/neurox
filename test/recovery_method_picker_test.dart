import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/recovery_flow_widgets.dart';
import 'package:neurox/features/tasks/scene_detail_results.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/l10n/app_language.dart';
import 'guided_scene_flow_test.dart' as fixture;

void main() {
  for (final lang in ['zh', 'en']) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        '$lang $width recovery cards choose the actual method used by the three-step flow',
        (tester) async {
          AppLanguage.instance.resetForTest(lang);
          tester.view.physicalSize = Size(width, 932);
          tester.view.devicePixelRatio = 1;
          final f = await fixture.prepare(tester, TaskScene.recovery);
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
            expect(find.byType(DropdownButtonFormField<String>), findsNothing);
            for (final method in ['breathing', 'attention', 'release']) {
              final card = find.byKey(ValueKey('recovery-method-$method'));
              await tester.scrollUntilVisible(
                card,
                160,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.ensureVisible(card);
              await tester.pumpAndSettle();
              await tester.tap(card);
              await tester.pumpAndSettle();
              expect(f.task.recoveryMethod, method);
              expect(tester.takeException(), isNull);
            }
            expect(find.byType(RecoveryMethodPicker), findsOneWidget);
            await tester.pumpWidget(const SizedBox());
            await fixture.start(f);
            final flow = f.task.recoveryFlow!;
            expect(flow.method, 'release');
            expect(flow.steps, ['demonstration', 'guided', 'independent']);
            f.task.advanceRecovery();
            f.task.pauseMonitoring();
            await f.task.continueMonitoring();
            f.ready();
            await f.task.startMonitoring();
            f.task.advanceRecovery();
            f.clock = 110;
            f.task.monitor!.advance(f.clock);
            final summary = {
              ...f.task.monitor!.snapshot(f.clock),
              'scene': 'recovery',
            };
            final events = List<Map<String, dynamic>>.from(
              f.task.monitor!.events,
            );
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: ListView(
                    children: [
                      SceneDetailResults(summary: summary, events: events),
                    ],
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(tr('复查未完成')), findsNothing);
            final stages = find.text(tr('练习阶段'));
            await tester.scrollUntilVisible(
              stages,
              220,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.ensureVisible(stages);
            await tester.pumpAndSettle();
            await tester.tap(stages);
            await tester.pumpAndSettle();
            final independent = find.text(stageLabel('independent'));
            await tester.scrollUntilVisible(
              independent,
              150,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(independent, findsOneWidget);
            expect(
              find.byIcon(Icons.circle),
              findsNWidgets(3),
              reason:
                  'Resuming the same practice keeps all visited steps in its report',
            );
            expect(find.text(stageLabel('recheck')), findsNothing);
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
