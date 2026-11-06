import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/tasks/monitoring_widgets.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'support/monitoring_fixture.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language live task and saved review fit 320px with large text; feedback is explicit',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        tester.view.physicalSize = const Size(320, 850);
        tester.view.devicePixelRatio = 1;
        final f = MonitorFixture();
        await f.initialize();
        f.task.monitor!.observe(
          at: 100,
          sampleAt: 100,
          features: {'attention': 40, 'relax': 50},
          good: true,
        );
        final account = LocalAccount();
        Map? feedback;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, (call) async {
              if (call.method == 'taskFeedback') {
                feedback = call.arguments as Map;
              }
              return null;
            });
        Widget shell(Widget child) => MaterialApp(
          builder: (context, widget) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: widget!,
          ),
          home: Scaffold(body: child),
        );
        await tester.pumpWidget(
          shell(
            MonitoringPanel(
              task: f.task,
              onEnd: () {},
              qualityText: 'TEST QUALITY',
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 7; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -400));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        final summary = {
          'version': monitoringVersion,
          'algorithm': 'neurox-sdk-attention-relax-v3',
          'elapsed': 180,
          'validSeconds': 150,
          'targetSeconds': 300,
          'durations': {'stable': 120, 'deviation': 30, 'unknown': 30},
          'timeline': [
            {'state': 'stable', 'start': 0, 'end': 120},
            {'state': 'deviation', 'start': 120, 'end': 150},
            {'state': 'unknown', 'start': 150, 'end': 180},
          ],
          'endReason': 'user_ended',
          'reference': {
            'attention': {'mean': 60, 'variance': 25},
            'relax': {'mean': 40, 'variance': 16},
          },
        };
        await tester.pumpWidget(
          shell(
            SingleChildScrollView(
              child: TaskReview(
                row: {
                  'id': 'TEST',
                  'kind': 'task',
                  'name': 'ORIGINAL TASK NAME',
                  'task_state': 'task_ended',
                  'monitor_json': jsonEncode(summary),
                  'feedback_json': '{}',
                  'events': [],
                },
                account: account,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('ORIGINAL TASK NAME'), findsOneWidget);
        expect(feedback, isNull);
        await tester.ensureVisible(find.text('4'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('4'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'MY NOTE');
        for (var i = 0; i < 7; i++) {
          await tester.drag(
            find.byType(SingleChildScrollView).first,
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        final save = find.text(
          language == 'zh' ? '保存主观反馈' : 'Save subjective feedback',
        );
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect((feedback!['feedback'] as Map)['rating'], 4);
        expect((feedback!['feedback'] as Map)['note'], 'MY NOTE');
        await tester.pumpWidget(const SizedBox());
        await f.close();
        account.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppLanguage.instance.resetForTest();
      },
    );
  }
}
