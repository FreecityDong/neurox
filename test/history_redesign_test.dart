import 'package:neurox/features/tasks/record_display_name.dart';
import 'package:neurox/features/shell/history_widgets.dart';
import 'package:neurox/l10n/app_language.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/features/shell/history_models.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/ui/neurox_brand.dart';
import 'support/fake_eeg_transport.dart';
import 'support/monitoring_fixture.dart';
import 'package:neurox/features/shell/feedback_preferences.dart';

Map<String, dynamic> taskRow(
  String id,
  String scene, {
  String taskState = 'task_complete',
  DateTime? started,
}) => {
  'id': id,
  'kind': 'task',
  'name': id,
  'task_state': taskState,
  'state': 'saved',
  'exists': true,
  'started':
      (started ?? DateTime(2026, 11, 4, 10)).millisecondsSinceEpoch / 1000,
  'task_json': jsonEncode({'scene': scene}),
  'monitor_json': jsonEncode({'elapsed': 90}),
};

void main() {
  test(
    'Stored default names follow locale in both directions without changing custom titles',
    () {
      addTearDown(() => AppLanguage.instance.resetForTest());
      final rows = [
        {'kind': 'task', 'name': '学习场景'},
        {'kind': 'task', 'name': '专注训练任务'},
        {'kind': 'baseline', 'name': '个人基线'},
        {'kind': 'task', 'name': '主动恢复'},
        {'kind': 'task', 'name': '[Replay] 学习场景'},
        {'kind': 'task', 'name': '数学自习：第一章'},
        {'kind': 'task', 'name': '完成'},
      ];
      final original = jsonEncode(rows);
      AppLanguage.instance.resetForTest('en');
      expect(rows.map(recordDisplayName).toList(), [
        'Study',
        'Attention training',
        'Personal baseline',
        'Active recovery',
        '[Replay] Study',
        '数学自习：第一章',
        '完成',
      ]);
      AppLanguage.instance.resetForTest('zh');
      expect(recordDisplayName({'kind': 'task', 'name': 'Study'}), '学习场景');
      expect(
        recordDisplayName({
          'kind': 'task',
          'name': '[Replay] Attention training',
        }),
        '[Replay] 专注训练任务',
      );
      expect(jsonEncode(rows), original);
    },
  );
  testWidgets('History renders a stored Chinese default title in English', (
    tester,
  ) async {
    AppLanguage.instance.resetForTest('en');
    addTearDown(() => AppLanguage.instance.resetForTest());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HistoryTaskCard(
            entry: HistoryEntry({
              ...taskRow('default', 'training'),
              'name': '专注训练任务',
            }),
            onTap: () {},
          ),
        ),
      ),
    );
    expect(find.text('Attention training'), findsNWidgets(2));
    expect(find.text('专注训练任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'History classifies saved task scenes without inventing a type for legacy/corrupt metadata',
    () {
      expect(HistoryEntry({'kind': 'baseline'}).type, HistoryTaskType.baseline);
      for (final scene in ['esports', 'go', 'archery']) {
        expect(
          HistoryEntry(taskRow(scene, scene)).type,
          HistoryTaskType.competition,
        );
      }
      expect(
        HistoryEntry(taskRow('study', 'learning')).type,
        HistoryTaskType.learning,
      );
      expect(
        HistoryEntry(taskRow('game', 'training')).type,
        HistoryTaskType.training,
      );
      expect(
        HistoryEntry(taskRow('rest', 'recovery')).type,
        HistoryTaskType.recovery,
      );
      expect(
        HistoryEntry({'kind': 'task', 'task_json': 'broken'}).type,
        HistoryTaskType.other,
      );
      expect(HistoryEntry({'kind': 'diagnostic'}).type, HistoryTaskType.other);
    },
  );
  test(
    'Task completion follows task state, never merely the saved file state',
    () {
      expect(
        HistoryEntry(taskRow('done', 'learning')).status,
        HistoryTaskStatus.completed,
      );
      expect(
        HistoryEntry(
          taskRow('early', 'learning', taskState: 'task_ended'),
        ).status,
        HistoryTaskStatus.incomplete,
      );
      expect(
        HistoryEntry(
          taskRow('interrupted', 'learning', taskState: 'interrupted_pending'),
        ).status,
        HistoryTaskStatus.interrupted,
      );
      expect(
        HistoryEntry({
          ...taskRow('paused', 'learning', taskState: 'active'),
          'monitor_json': jsonEncode({'phase': 'paused'}),
        }).status,
        HistoryTaskStatus.paused,
      );
      expect(
        HistoryEntry({
          ...taskRow('failed', 'learning'),
          'state': 'save_failed',
        }).status,
        HistoryTaskStatus.saveFailed,
      );
      expect(
        HistoryEntry({'kind': 'diagnostic', 'state': 'saved'}).status,
        HistoryTaskStatus.saved,
      );
    },
  );
  test(
    'Duration prefers actual session counters and leaves unsupported/imported timing unknown',
    () {
      final measured = HistoryEntry({
        ...taskRow('study', 'learning'),
        'started': 100,
        'ended': 10000,
        'monitor_json': jsonEncode({'elapsed': 80}),
      });
      expect(measured.durationSeconds, 80);
      expect(historyDuration(measured.durationSeconds), '01:20');
      expect(
        HistoryEntry({
          'kind': 'baseline',
          'baseline_json': jsonEncode({'attemptElapsed': 105, 'elapsed': 95}),
        }).durationSeconds,
        105,
      );
      expect(
        HistoryEntry({
          'state': 'saved',
          'started': 10,
          'ended': 80,
        }).durationSeconds,
        70,
      );
      expect(
        HistoryEntry({
          'state': 'imported',
          'started': 10,
          'ended': 80,
        }).durationSeconds,
        isNull,
      );
      expect(
        HistoryEntry({'state': 'recording', 'started': 10}).durationSeconds,
        isNull,
      );
      expect(
        HistoryEntry({
          'state': 'saved',
          'started': 80,
          'ended': 10,
        }).durationSeconds,
        isNull,
      );
      expect(historyDuration(null), '—');
      expect(historyDuration(double.nan), '—');
      expect(historyDuration(90061), '25:01:01');
    },
  );
  test(
    'Calendar-day filters are inclusive at the start, exclusive tomorrow, and reject missing dates',
    () {
      final now = DateTime(2026, 11, 4, 15);
      final boundary = HistoryEntry(
        taskRow('boundary', 'learning', started: DateTime(2026, 10, 29)),
      );
      final before = HistoryEntry(
        taskRow(
          'before',
          'learning',
          started: DateTime(2026, 10, 28, 23, 59, 59),
        ),
      );
      expect(boundary.inPeriod(HistoryPeriod.week, now), true);
      expect(before.inPeriod(HistoryPeriod.week, now), false);
      expect(
        HistoryEntry(
          taskRow('today', 'learning', started: DateTime(2026, 11, 4)),
        ).inPeriod(HistoryPeriod.today, now),
        true,
      );
      expect(
        HistoryEntry(
          taskRow('tomorrow', 'learning', started: DateTime(2026, 11, 5)),
        ).inPeriod(HistoryPeriod.today, now),
        false,
      );
      expect(
        HistoryEntry({
          'started': double.nan,
        }).inPeriod(HistoryPeriod.month, now),
        false,
      );
      expect(HistoryEntry({}).inPeriod(HistoryPeriod.all, now), true);
    },
  );
  testWidgets(
    'Three dropdown categories combine filters; legacy data remain accessible and task types use different backgrounds',
    (tester) async {
      final now = DateTime(2026, 11, 4, 15);
      final rows = [
        taskRow('学习已完成', 'learning'),
        taskRow('学习未完成', 'learning', taskState: 'task_ended'),
        taskRow('专注训练记录', 'training'),
        taskRow(
          '上周学习',
          'learning',
          started: now.subtract(const Duration(days: 9)),
        ),
        {
          'id': 'legacy',
          'name': '旧记录保留',
          'state': 'saved',
          'kind': 'diagnostic',
          'started': 1000,
          'exists': true,
        },
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            LocalAccount.channel,
            (call) async => call.method == 'sessions' ? rows : [],
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null),
      );
      final transport = FakeEegTransport();
      final eeg = EegController(transport);
      final account = LocalAccount();
      await tester.pumpWidget(
        MaterialApp(
          theme: NeuroxBrand.theme(Brightness.light),
          home: HistoryPage(
            account: account,
            controller: eeg,
            clock: () => now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(
        find.byType(DropdownButtonFormField<HistoryTaskStatus?>),
        findsOneWidget,
      );
      expect(find.text('采集记录 · 当前本机账号'), findsNothing);
      expect(find.text('持续时间  01:30'), findsWidgets);
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('history-card-学习已完成')))
            .color,
        isNot(
          tester
              .widget<Material>(
                find.byKey(const ValueKey('history-card-专注训练记录')),
              )
              .color,
        ),
      );
      Future<void> select(String field, String label) async {
        await tester.ensureVisible(find.byKey(ValueKey(field)));
        await tester.tap(find.byKey(ValueKey(field)));
        await tester.pumpAndSettle();
        expect(find.text('采集诊断'), findsNothing);
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await select('history-status', '已完成');
      await select('history-status', '全部');
      expect(find.byKey(const ValueKey('history-card-学习未完成')), findsOneWidget);
      await select('history-status', '已完成');
      await select('history-type', '学习场景');
      await select('history-period', '今天');
      expect(find.byKey(const ValueKey('history-card-学习已完成')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-card-学习未完成')), findsNothing);
      expect(find.byKey(const ValueKey('history-card-上周学习')), findsNothing);
      expect(find.byKey(const ValueKey('history-card-专注训练记录')), findsNothing);
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('history-card-legacy')),
        180,
      );
      expect(find.byKey(const ValueKey('history-card-legacy')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      account.dispose();
      eeg.dispose();
      await transport.close();
    },
  );
  testWidgets(
    'Active history uses the live task counter rather than extrapolating a saved timestamp',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      final row = {
        ...taskRow(f.task.sessionId!, 'learning', taskState: 'active'),
        'monitor_json': jsonEncode({'elapsed': 1}),
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            LocalAccount.channel,
            (call) async => call.method == 'sessions' ? [row] : [],
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null),
      );
      final account = LocalAccount();
      await tester.pumpWidget(
        MaterialApp(
          theme: NeuroxBrand.theme(Brightness.light),
          home: HistoryPage(account: account, controller: f.eeg, task: f.task),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('持续时间  00:00'), findsOneWidget);
      f.clock = 130;
      f.task.monitor!.advance(f.clock);
      f.task.setFeedback(const FeedbackOptions());
      await tester.pumpAndSettle();
      expect(find.text('持续时间  00:30'), findsOneWidget);
      expect(f.task.active, true);
      f.task.monitor!.pause(f.clock);
      f.task.setFeedback(const FeedbackOptions());
      await tester.pumpAndSettle();
      expect(find.text('已暂停'), findsOneWidget);
      row['task_state'] = 'task_ended';
      row['monitor_json'] = jsonEncode({'elapsed': 30});
      await f.task.finish();
      await tester.pumpAndSettle();
      expect(find.text('未完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      account.dispose();
      await f.close();
    },
  );
}
