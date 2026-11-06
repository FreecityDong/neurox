import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/scene_widgets.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/shell/feedback_preferences.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/monitoring_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language recovery teaching returns to original task without baseline recalculation at large text',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        tester.view.physicalSize = const Size(320, 850);
        tester.view.devicePixelRatio = 1;
        final f = MonitorFixture();
        await f.initialize();
        final origin = f.task.monitor!.referenceOrigin['sessionId'];
        f.task.startRecovery('attention');
        expect(f.task.monitor!.phase, 'recovery');
        Widget page() => MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: RecoveryPanel(task: f.task, onEnd: () {}),
            ),
          ),
        );
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        for (var step = 0; step < 3; step++) {
          final next = find.text(tr('下一步'));
          await tester.scrollUntilVisible(
            next,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(next);
          await tester.pumpAndSettle();
          await tester.tap(next);
          await tester.pump();
          // The production page listens to the controller; explicitly rebuild this isolated panel.
          await tester.pumpWidget(page());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(f.task.recoveryFlow!.stage, 'recheck');
        expect(f.task.monitor!.phase, 'running');
        final back = find.text(tr('继续原任务'));
        await tester.scrollUntilVisible(
          back,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(back);
        await tester.pumpAndSettle();
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(f.task.recoveryFlow, isNull);
        expect(f.task.monitor!.referenceOrigin['sessionId'], origin);
        expect(
          f.backend.calls.where(
            (v) => v == 'baselineStart' || v == 'baselineRetry',
          ),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox());
        await f.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppLanguage.instance.resetForTest();
      },
    );
  }
  testWidgets(
    'Choosing or cancelling recovery pauses and returns without a false completed practice',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.chooseRecovery();
      expect(f.task.recoveryChoosing, true);
      expect(f.task.monitor!.phase, 'recovery');
      f.task.leaveRecovery();
      expect(f.task.recoveryChoosing, false);
      expect(f.task.monitor!.phase, 'running');
      expect(
        f.task.monitor!.events.where((e) => e['type'] == 'recheck'),
        isEmpty,
      );
      await f.close();
    },
  );
  testWidgets(
    'Notification delivery failure does not interrupt recording or invalidate the reference',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.backend.failAlert = true;
      f.task.setFeedback(const FeedbackOptions(vibration: true));
      for (var i = 100; i < 125; i++) {
        f.clock = i.toDouble();
        f.task.monitor!.observe(
          at: f.clock,
          sampleAt: f.clock,
          features: {'attention': 40, 'relax': 40},
          good: true,
        );
      }
      f.task.setFeedback(const FeedbackOptions(vibration: true));
      await tester.pump();
      await tester.pump();
      expect(f.backend.calls, contains('monitorAlert'));
      expect(f.task.monitor!.phase, 'running');
      expect(f.task.error, isNull);
      expect(f.task.baseline!.state, 'ready');
      expect(
        f.task.monitor!.events.where(
          (e) =>
              e['type'] == 'feedback_delivery' &&
              e['delivery'] == 'unavailable',
        ),
        isNotEmpty,
      );
      await f.close();
    },
  );
  testWidgets(
    'Channel choices are independent; all-off preserves curve and fixed state display',
    (tester) async {
      var value = const FeedbackOptions();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ListView(
                children: [
                  FeedbackControls(
                    value: value,
                    onChanged: (v) => setState(() => value = v),
                  ),
                  const Text('固定状态'),
                  const SceneCurve(
                    events: [
                      {'type': 'deviation', 'wallSeconds': 25.0},
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(SwitchListTile, '声音'));
      await tester.pumpAndSettle();
      expect(value.sound, true);
      expect(value.vibration, false);
      expect(value.notice, false);
      await tester.tap(find.widgetWithText(SwitchListTile, '声音'));
      await tester.pumpAndSettle();
      expect(value.enabled, false);
      expect(find.text('固定状态'), findsOneWidget);
      expect(find.byType(SceneCurve), findsOneWidget);
    },
  );
  testWidgets(
    'Archery controls expose stages and condition gating; no baseline picker',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.scene = TaskScene.archery;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [SceneControls(task: f.task)]),
          ),
        ),
      );
      expect(find.text('瞄准'), findsOneWidget);
      await tester.tap(find.text('瞄准'));
      await tester.pumpAndSettle();
      expect(f.task.sceneStage, 'aiming');
      expect(f.task.monitor!.comparisonAllowed, false);
      expect(find.text('设为当前'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await f.close();
    },
  );
  testWidgets(
    'Attention is shown as green/red ranges with explicit legends instead of event markers',
    (tester) async {
      final events = <Map<String, dynamic>>[
        {'type': 'state', 'wallSeconds': 0.0, 'state': 'stable'},
        {
          'type': 'sample',
          'wallSeconds': 1.0,
          'scores': {'attention': 70.0, 'relax': 40.0},
        },
        {
          'type': 'deviation',
          'wallSeconds': 25.0,
          'candidateStartedWallSeconds': 1.0,
        },
        {
          'type': 'sample',
          'wallSeconds': 26.0,
          'scores': {'attention': 40.0, 'relax': 30.0},
        },
        {'type': 'recovery', 'wallSeconds': 35.0},
      ];
      final spans = curveStateSpans(events, 40);
      expect(spans.map((s) => s.state), ['stable', 'deviation', 'stable']);
      expect(spans[1].start, 25);
      expect(spans[1].end, 35);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SceneCurve(events: events)),
          ),
        ),
      );
      expect(find.text('绿色范围：专注'), findsOneWidget);
      expect(find.text('红色范围：偏离'), findsOneWidget);
      expect(find.text('确认偏离'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    },
  );
}
