import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/task_controller.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/fake_eeg_transport.dart';
import 'support/monitoring_fixture.dart';

class Backend implements BaselineBackend {
  final calls = <String>[];
  bool writable = true;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    calls.add(method);
    return switch (method) {
      'baselineCapabilities' => {
        'profile': {'verified': false},
      },
      'baselinePreflight' => {'storageReady': writable, 'unresolved': []},
      'baselineStart' => {
        'id': 'SYNTHETIC SESSION',
        'path': 'TEST.jsonl',
        'attempt': 'TEST ATTEMPT',
      },
      'baselineRetry' => {'attempt': 'TEST RETRY'},
      _ => {},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language learning baseline adaptation and reading fit 320px large text',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        final f = MonitorFixture();
        await f.initialize();
        f.task.monitor = null;
        f.task.usingSavedReference = false;
        f.clock = 5;
        f.task.baseline = BaselineAccumulator(
          attemptId: 'UI TEST',
          context: f.task.context,
        )..advance(5);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: BaselinePage(task: f.task),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(language == 'zh' ? '准备适应' : 'Getting ready'),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text(language == 'zh' ? '默读内容' : 'Reading passage'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -400));
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
  }
  testWidgets(
    'Preparation blocks unconfirmed metadata, cancel creates no record',
    (tester) async {
      final transport = FakeEegTransport(), backend = Backend();
      final eeg = EegController(transport);
      final task = TaskController(eeg, backend: backend);
      // Independent preparation controller has no connected device or verified profile.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        TaskPreparation(task: task, baselineOnly: true),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('开始采集个人基线'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '开始采集个人基线'),
      );
      expect(button.onPressed, isNotNull);
      expect(backend.calls, isNot(contains('baselinePreflight')));
      await tester.tap(find.widgetWithText(FilledButton, '开始采集个人基线'));
      await tester.pumpAndSettle();
      expect(find.text(baselineCheckLabel('disconnected')), findsOneWidget);
      expect(backend.calls, contains('baselinePreflight'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(backend.calls, isNot(contains('baselineStart')));
      expect(task.sessionId, isNull);
      await tester.pumpWidget(const SizedBox());
      task.dispose();
      eeg.dispose();
      await transport.close();
    },
  );
  testWidgets(
    'Attempt invalidates on background without changing device recording',
    (tester) async {
      final transport = FakeEegTransport(), backend = Backend();
      final eeg = EegController(transport);
      final task = TaskController(eeg, backend: backend);
      await eeg.initialize();
      await eeg.connect(
        const EegDevice(
          address: testDeviceAddress,
          name: 'TEST DEVICE',
          rssi: -30,
          advertisesService: true,
        ),
      );
      transport.packet('raw', rawPacket(), DateTime.now());
      // Explicit fixture injection tests state transitions, not physical quality acceptance.
      task.profile = SignalProfile({
        'verified': true,
        'evidence': 'SYNTHETIC TEST ONLY',
        'version': 'test',
        'unit': 'test',
        'sampleRate': 512.0,
        'scale': 1.0,
        'flatStd': .01,
        'maxPeakToPeak': 20.0,
        'maxStep': 2.0,
        'adcMin': -100.0,
        'adcMax': 100.0,
      });
      task.storageReady = true;
      task.quality = const AnalysisWindow(
        sequence: 1,
        start: 0,
        end: 4,
        reason: 'good',
        features: {'alphaRelative': .5},
      );
      expect(task.canStart, true);
      await task.start();
      expect(task.baseline?.state, 'collecting');
      task.baseline!.validSeconds = 30;
      task.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(task.active, false);
      expect(task.baselineInterruption, 'background');
      expect(task.completedSession, isNull);
      expect(
        backend.calls,
        containsAllInOrder([
          'baselineStart',
          'baselineUpdate',
          'baselineFinish',
          'deleteSession',
        ]),
      );
      expect(transport.calls, isNot(contains('stopRecording')));
      task.didChangeAppLifecycleState(AppLifecycleState.resumed);
      task.dispose();
      eeg.dispose();
      await transport.close();
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets('$language preparation fits 320px with large text', (
      tester,
    ) async {
      AppLanguage.instance.resetForTest(language);
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      final transport = FakeEegTransport();
      final eeg = EegController(transport);
      final task = TaskController(eeg, backend: Backend());
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: TaskPreparation(task: task, baselineOnly: true),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      task.dispose();
      eeg.dispose();
      await transport.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      AppLanguage.instance.resetForTest();
    });
  }
}
