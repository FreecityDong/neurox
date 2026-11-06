import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/fake_eeg_transport.dart';
import 'support/monitoring_fixture.dart';

Map<String, dynamic> row(
  String id,
  String scene, {
  bool active = false,
  bool baseline = false,
}) => {
  'id': id,
  'name': id,
  'kind': baseline ? 'baseline' : 'task',
  'state': active ? 'recording' : 'saved',
  'task_state': active
      ? 'active'
      : baseline
      ? 'baseline_ready'
      : 'task_complete',
  'started': 1793836800.0,
  'task_json': {'scene': scene},
  'monitor_json': {
    'scene': scene,
    'elapsed': 120.0,
    'phase': active ? 'running' : 'finished',
  },
};
Future<void> visibleTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final lang in ['zh', 'en']) {
    testWidgets(
      '$lang selection entry precedes refresh; filters clear hidden selection; confirm deletes only current selected results',
      (tester) async {
        AppLanguage.instance.resetForTest(lang);
        tester.view.physicalSize = const Size(320, 932);
        tester.view.devicePixelRatio = 1;
        final transport = FakeEegTransport(), eeg = EegController(transport);
        final account = LocalAccount();
        final rows = [
          row('A', 'learning'),
          row('B', 'go'),
          row('C', 'learning'),
          row('RUNNING', 'learning', active: true),
        ];
        final deleted = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, (call) async {
              if (call.method == 'sessions') return rows;
              if (call.method == 'legacy') return ['UNOWNED.jsonl'];
              if (call.method == 'deleteSession') {
                final id = (call.arguments as Map)['id'] as String;
                deleted.add(id);
                rows.removeWhere((r) => r['id'] == id);
              }
              return null;
            });
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: HistoryPage(account: account, controller: eeg),
            ),
          );
          await tester.pumpAndSettle();
          final entry = find.byKey(const ValueKey('history-batch-delete'));
          expect(
            tester.getCenter(entry).dx,
            lessThan(tester.getCenter(find.byTooltip(tr('刷新'))).dx),
          );
          await tester.tap(entry);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('history-select-B')),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await visibleTap(
            tester,
            find.byKey(const ValueKey('history-select-B')),
          );
          final kind = find.byKey(const ValueKey('history-type'));
          await tester.scrollUntilVisible(
            kind,
            -250,
            scrollable: find.byType(Scrollable).first,
          );
          await visibleTap(tester, kind);
          await tester.tap(find.text(tr('学习场景')).last);
          await tester.pumpAndSettle();
          final button = find.byKey(const ValueKey('history-delete-selected'));
          expect(
            tester.widget<FilledButton>(button).onPressed,
            isNull,
            reason: 'Changing filters clears hidden selections',
          );
          await tester.tap(find.text(tr('全选当前结果')));
          await tester.pumpAndSettle();
          expect(find.text(tr('删除 {p0} 条', {'p0': 2})), findsOneWidget);
          await tester.tap(button);
          await tester.pumpAndSettle();
          await tester.tap(find.text(tr('取消')));
          await tester.pumpAndSettle();
          expect(deleted, isEmpty);
          await tester.tap(button);
          await tester.pumpAndSettle();
          await tester.tap(find.text(tr('确认')));
          await tester.pumpAndSettle();
          expect(deleted, ['A', 'C']);
          expect(rows.map((r) => r['id']), ['B', 'RUNNING']);
          expect(
            find.byKey(const ValueKey('history-delete-selected')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          eeg.dispose();
          account.dispose();
          await transport.close();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(LocalAccount.channel, null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          AppLanguage.instance.resetForTest();
        }
      },
    );
    testWidgets(
      '$lang partial failure leaves only failed records selected for retry',
      (tester) async {
        AppLanguage.instance.resetForTest(lang);
        final transport = FakeEegTransport(), account = LocalAccount();
        final eeg = EegController(transport);
        final rows = [
              row('A', 'learning'),
              row('B', 'go'),
              row('C', 'recovery'),
            ],
            deleted = <String>[];
        var fail = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, (call) async {
              if (call.method == 'sessions') return rows;
              if (call.method == 'legacy') return [];
              if (call.method == 'deleteSession') {
                final id = (call.arguments as Map)['id'] as String;
                if (id == 'B' && fail) {
                  throw PlatformException(
                    code: 'storage',
                    message: 'TEST retry',
                  );
                }
                deleted.add(id);
                rows.removeWhere((r) => r['id'] == id);
              }
              return null;
            });
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: HistoryPage(account: account, controller: eeg),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('history-batch-delete')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(tr('全选当前结果')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('history-delete-selected')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(tr('确认')));
          await tester.pumpAndSettle();
          expect(deleted, ['A', 'C']);
          expect(rows.single['id'], 'B');
          expect(
            tester
                .widget<Checkbox>(
                  find.byKey(const ValueKey('history-select-B')),
                )
                .value,
            true,
          );
          fail = false;
          await tester.tap(
            find.byKey(const ValueKey('history-delete-selected')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(tr('确认')));
          await tester.pumpAndSettle();
          expect(rows, isEmpty);
          expect(deleted, ['A', 'C', 'B']);
          expect(
            find.byKey(const ValueKey('history-delete-selected')),
            findsNothing,
          );
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
  testWidgets(
    'A capture beginning during confirmation blocks all deletes and selection can still be cancelled',
    (tester) async {
      final transport = FakeEegTransport(), account = LocalAccount();
      final eeg = EegController(transport);
      await eeg.initialize();
      final deleted = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalAccount.channel, (call) async {
            if (call.method == 'sessions') return [row('A', 'learning')];
            if (call.method == 'legacy') return [];
            if (call.method == 'deleteSession') {
              deleted.add((call.arguments as Map)['id'] as String);
            }
            return null;
          });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: HistoryPage(account: account, controller: eeg),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('history-batch-delete')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选当前结果'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
        await tester.pumpAndSettle();
        transport.emit({
          'type': 'recording',
          'active': true,
          'state': 'recording',
        });
        expect(eeg.recording, true);
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(deleted, isEmpty);
        await tester.tap(find.byKey(const ValueKey('history-batch-delete')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('history-delete-selected')),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        eeg.dispose();
        account.dispose();
        await transport.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
      }
    },
  );
  testWidgets(
    'Deleting saved baseline and last task refreshes references and clears the deleted home shortcut',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      f.transport.emit({
        'type': 'recording',
        'active': false,
        'state': 'saved',
      });
      final account = LocalAccount();
      final rows = [
        row('SAVED PERSONAL BASELINE', '', baseline: true),
        row('SYNTHETIC TASK', 'learning'),
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalAccount.channel, (call) async {
            if (call.method == 'sessions') return rows;
            if (call.method == 'legacy') return [];
            if (call.method == 'deleteSession') {
              final id = (call.arguments as Map)['id'];
              if (id == 'SAVED PERSONAL BASELINE') {
                f.backend.hasReference = false;
              }
              rows.removeWhere((r) => r['id'] == id);
            }
            return null;
          });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: HistoryPage(
              account: account,
              controller: f.eeg,
              task: f.task,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('history-batch-delete')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选当前结果'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
        await tester.pumpAndSettle();
        expect(find.textContaining('所选基线也会删除'), findsOneWidget);
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(rows, isEmpty);
        expect(f.task.hasSavedReference, false);
        expect(f.task.completedSession, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await f.close();
        account.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
      }
    },
  );
}
