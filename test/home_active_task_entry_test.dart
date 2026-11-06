import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/features/tasks/task_controller.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/fake_eeg_transport.dart';

void main() {
  for (final lang in ['zh', 'en']) {
    testWidgets(
      '$lang five home modules offer the same existing task; cancel, continue, and direct continue preserve it',
      (tester) async {
        AppLanguage.instance.resetForTest(lang);
        final transport = FakeEegTransport(), calls = <String>[];
        final eeg = EegController(transport);
        final account = LocalAccount()..profile = {'nickname': 'TEST'};
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, (call) async {
              calls.add(call.method);
              return null;
            });
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: AppShell(account: account, controller: eeg),
            ),
          );
          await tester.pumpAndSettle();
          final dynamic shell = tester.state(find.byType(AppShell));
          final task = shell.task as TaskController;
          task.sessionId = 'EXISTING TASK';
          task.changeStage('study');
          await tester.pumpAndSettle();
          for (final type in [
            'baseline',
            'training',
            'learning',
            'competition',
            'recovery',
          ]) {
            final entry = find.byKey(ValueKey('home-module-$type'));
            await tester.scrollUntilVisible(
              entry,
              250,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.ensureVisible(entry);
            await tester.pumpAndSettle();
            await tester.tap(entry);
            await tester.pumpAndSettle();
            expect(find.text(tr('当前有任务未结束')), findsOneWidget);
            expect(find.byType(TaskPreparation), findsNothing);
            expect(find.byType(BaselineLibraryPage), findsNothing);
            await tester.tap(find.text(tr('取消')));
            await tester.pumpAndSettle();
            expect(task.sessionId, 'EXISTING TASK');
            expect(task.scene.name, 'learning');
            expect(find.byType(BaselinePage), findsNothing);
          }
          // Confirm a different module, then return to the unchanged task on the home card.
          await tester.tap(find.byKey(const ValueKey('home-module-recovery')));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, tr('继续任务')).last);
          await tester.pumpAndSettle();
          expect(find.byType(BaselinePage), findsOneWidget);
          expect(task.sessionId, 'EXISTING TASK');
          expect(task.scene.name, 'learning');
          await tester.tap(find.byIcon(Icons.home_outlined).first);
          await tester.pumpAndSettle();
          final direct = find.widgetWithText(FilledButton, tr('继续任务'));
          await tester.scrollUntilVisible(
            direct,
            -300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(direct);
          await tester.pumpAndSettle();
          await tester.tap(direct);
          await tester.pumpAndSettle();
          expect(find.byType(BaselinePage), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(task.sessionId, 'EXISTING TASK');
          expect(
            calls.where(
              (c) => [
                'baselineStart',
                'learningStart',
                'monitorFinish',
                'deleteSession',
              ].contains(c),
            ),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          eeg.dispose();
          account.dispose();
          await transport.close();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(LocalAccount.channel, null);
          AppLanguage.instance.resetForTest();
        }
      },
    );
    testWidgets(
      '$lang task ended while dialog open does not open a different task',
      (tester) async {
        AppLanguage.instance.resetForTest(lang);
        final transport = FakeEegTransport();
        final eeg = EegController(transport);
        final account = LocalAccount();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, (_) async => null);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: AppShell(account: account, controller: eeg),
            ),
          );
          await tester.pumpAndSettle();
          final dynamic shell = tester.state(find.byType(AppShell));
          final task = shell.task as TaskController;
          task.sessionId = 'OLD TASK';
          task.changeStage('study');
          await tester.pumpAndSettle();
          final entry = find.byKey(const ValueKey('home-module-baseline'));
          await tester.scrollUntilVisible(
            entry,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(entry);
          await tester.pumpAndSettle();
          await tester.tap(entry);
          await tester.pumpAndSettle();
          task.sessionId = null;
          task.changeStage('study');
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, tr('继续任务')));
          await tester.pumpAndSettle();
          expect(find.byType(BaselinePage), findsNothing);
          expect(find.byType(BaselineLibraryPage), findsNothing);
          expect(find.byType(TaskPreparation), findsNothing);
          expect(task.active, false);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          eeg.dispose();
          account.dispose();
          await transport.close();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(LocalAccount.channel, null);
          AppLanguage.instance.resetForTest();
        }
      },
    );
  }
}
