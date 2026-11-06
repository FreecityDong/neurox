import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'support/monitoring_fixture.dart';

void main() {
  testWidgets(
    'Preparation requested at the target saves once without rebinding the reference',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize(minutes: 5);
      f.clock = 400;
      await f.task.prepareLearning();
      expect(f.task.active, false);
      expect(f.backend.calls.where((m) => m == 'monitorFinish').length, 1);
      expect(f.backend.calls, isNot(contains('learningRefresh')));
      await f.close();
    },
  );
  testWidgets(
    'Consecutive learning tasks reuse one saved baseline without another calibration',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      final first = f.task.sessionId;
      await f.task.finish();
      f.transport.emit({
        'type': 'recording',
        'active': false,
        'state': 'saved',
      });
      await tester.pump();
      f.quality();
      f.task.clearDraft();
      await f.task.startLearning();
      expect(f.task.sessionId, isNot(first));
      expect(f.task.learningPreparing, true);
      expect(
        f.task.baseline?.snapshot()['referenceOrigin']['sessionId'],
        'SAVED PERSONAL BASELINE',
      );
      expect(f.backend.calls.where((m) => m == 'learningStart').length, 2);
      expect(f.backend.calls, isNot(contains('baselineStart')));
      expect(f.backend.calls, isNot(contains('baselineRetry')));
      await f.close();
    },
  );
  testWidgets(
    'Saved reference does not expire with age; preparing time does not consume learning target',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize(running: false);
      f.clock = 10000;
      expect(f.task.canMonitor, true);
      expect(f.task.monitor?.elapsed, 0);
      expect(f.task.monitor?.phase, 'preparing');
      await f.task.startMonitoring();
      expect(f.task.monitor?.phase, 'running');
      expect(f.task.monitor?.elapsed, 0);
      expect(f.backend.calls, contains('learningStart'));
      expect(f.backend.calls, isNot(contains('baselineStart')));
      await f.close();
    },
  );
  testWidgets(
    'Resume with missed lifecycle callbacks freezes monitoring and requires a new baseline',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.clock = 1000;
      f.backend.nativeInterrupted = true;
      f.task.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(f.task.monitor?.elapsed, 0);
      expect(f.task.monitor?.phase, 'interrupted');
      expect(f.task.baseline?.state, 'invalid');
      await tester.pump(const Duration(seconds: 2));
      expect(f.backend.calls, isNot(contains('monitorFinish')));
      await f.close();
    },
  );

  testWidgets(
    'Target completion pops the active page once and opens the same saved session result',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize(minutes: 5);
      expect(f.task.monitor?.phase, 'running');
      f.task.latestReminderSequence = 3;
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push(
                    MaterialPageRoute<String>(
                      builder: (_) => BaselinePage(task: f.task),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      f.clock = 400;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(result, 'SYNTHETIC TASK');
      expect(f.task.active, false);
      expect(f.task.latestReminderSequence, isNull);
      expect(f.backend.calls.where((x) => x == 'monitorFinish').length, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(f.backend.calls.where((x) => x == 'monitorFinish').length, 1);
      await tester.pumpWidget(const SizedBox());
      await f.close();
    },
  );
  testWidgets(
    'Long pause rebinds saved reference without collecting another baseline',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.clock = 101;
      f.task.pauseMonitoring();
      f.clock = 162;
      await f.task.continueMonitoring();
      expect(f.task.monitor?.phase, 'rebuilding');
      expect(f.task.sessionId, 'SYNTHETIC TASK');
      expect(f.task.baseline?.attemptId, 'B1');
      expect(
        f.task.baseline?.snapshot()['referenceOrigin']['sessionId'],
        'SAVED PERSONAL BASELINE',
      );
      expect(f.task.baseline?.state, 'ready');
      expect(f.backend.calls, isNot(contains('baselineRetry')));
      f.ready();
      f.clock = 262;
      await f.task.startMonitoring();
      expect(f.task.monitor?.phase, 'running');
      expect(f.task.monitor?.attemptId, 'B1');
      expect(f.task.monitor?.elapsed, 1);
      await f.transport.disconnect();
      await tester.pump();
      expect(f.task.monitor?.state, 'unknown');
      expect(f.task.baseline?.state, 'invalid');
      await f.task.finish();
      await f.close();
    },
  );
  testWidgets(
    'Failed final save keeps the task visible and explicit retry finishes it',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.backend.failFinish = true;
      expect(await f.task.finish(), isNull);
      expect(f.task.active, true);
      expect(f.task.completedSession, isNull);
      expect(f.task.monitor?.finished, true);
      f.backend.failFinish = false;
      expect(await f.task.finish(), 'SYNTHETIC TASK');
      expect(f.task.active, false);
      await f.close();
    },
  );
}
