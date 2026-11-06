import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/monitoring_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language baseline management has no learning duration and rerecord opens baseline-only setup',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        tester.view.physicalSize = const Size(320, 850);
        tester.view.devicePixelRatio = 1;
        final f = MonitorFixture();
        await f.initialize();
        await f.task.finish();
        f.transport.emit({
          'type': 'recording',
          'active': false,
          'state': 'saved',
        });
        await tester.pump();
        await tester.runAsync(() => f.task.refresh());
        f.quality();
        Widget shell(Widget child) => MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: child,
        );
        await tester.pumpWidget(shell(BaselineLibraryPage(task: f.task)));
        await tester.pumpAndSettle();
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byType(SwitchListTile), findsNothing);
        final rerecord = find.text(
          language == 'zh' ? '重新记录基线' : 'Record baseline again',
        );
        await tester.scrollUntilVisible(
          rerecord,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(rerecord);
        await tester.pumpAndSettle();
        expect(
          find.text(language == 'zh' ? '基线准备' : 'Baseline preparation'),
          findsOneWidget,
        );
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(SwitchListTile), findsNothing);
        await tester.scrollUntilVisible(
          find.text(tr('提醒方式')),
          150,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text(tr('提醒方式')));
        await tester.pumpAndSettle();
        expect(find.byType(SwitchListTile), findsNWidgets(4));
        for (var i = 0; i < 5; i++) {
          await tester.drag(find.byType(ListView).last, const Offset(0, -350));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
        await f.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppLanguage.instance.resetForTest();
      },
    );
    testWidgets(
      '$language first learning task blocks until a personal baseline exists; no reading passage in learning setup',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        final f = MonitorFixture();
        await f.initialize();
        await f.task.finish();
        f.backend.hasReference = false;
        f.transport.emit({
          'type': 'recording',
          'active': false,
          'state': 'saved',
        });
        await tester.pump();
        await tester.runAsync(() => f.task.refresh());
        f.quality();
        await tester.pumpWidget(
          MaterialApp(home: TaskPreparation(task: f.task)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChoiceChip), findsNothing);
        expect(
          find.text(
            language == 'zh'
                ? '默读建立学习参考'
                : 'Read quietly to establish your learning reference',
          ),
          findsNothing,
        );
        expect(
          find.text(
            language == 'zh'
                ? '开始采集个人基线'
                : 'Start collecting personal baseline',
          ),
          findsNothing,
        );
        final start = find.text(
          language == 'zh' ? '准备学习任务' : 'Prepare learning task',
        );
        await tester.scrollUntilVisible(
          start,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final button = tester.widget<FilledButton>(
          find.widgetWithText(
            FilledButton,
            language == 'zh' ? '准备学习任务' : 'Prepare learning task',
          ),
        );
        expect(button.onPressed, isNull);
        expect(f.backend.calls, isNot(contains('baselineStart')));
        await tester.pumpWidget(const SizedBox());
        await f.close();
        AppLanguage.instance.resetForTest();
      },
    );
  }
}
