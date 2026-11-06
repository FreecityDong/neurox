import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:neurox/features/shell/feedback_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/task_controller.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/features/tasks/scene_widgets.dart';
import 'package:neurox/features/tasks/reference_metrics.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';
import 'support/monitoring_fixture.dart';
import 'support/fake_eeg_transport.dart';

class CheckController extends TaskController {
  CheckController(super.eeg, {required super.backend, super.clock});
  bool writable = true;
  @override
  Future<void> refresh({bool prepareSignal = true}) async {
    storageReady = writable;
  }
}

class NoticeBackend extends NativeBaselineBackend {
  final delegate = MonitorBackend();
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) => delegate.call(method, args);
}

void main() {
  testWidgets(
    'Fresh raw stability starts baseline twice without waiting for comparison scores',
    (tester) async {
      await tester.runAsync(() async {
        final f = MonitorFixture();
        await f.initialize();
        await f.task.finish();
        f.transport.emit({
          'type': 'recording',
          'active': false,
          'state': 'saved',
        });
        double clock = 0;
        final task = TaskController(
          f.eeg,
          backend: f.backend,
          clock: () => clock,
        );
        try {
          for (var attempt = 0; attempt < 2; attempt++) {
            task.clearDraft();
            final chosenFeedback = FeedbackOptions(
              sound: attempt == 0,
              vibration: attempt == 1,
              notice: true,
            );
            task.setFeedback(chosenFeedback);
            final starting = task.checkAndStartBaseline();
            await Future<void>.delayed(const Duration(milliseconds: 30));
            expect(task.active, false);
            final origin = clock;
            for (var packet = 0; packet < 10 * 32 && !task.active; packet++) {
              clock = origin + packet / 32;
              final bytes = rawPacket(),
                  data = ByteData.sublistView(rawPacket());
              for (var j = 0; j < 16; j++) {
                final point = packet * 16 + j;
                final value =
                    (30000 +
                            2000 * math.sin(2 * math.pi * 10 * point / 512) +
                            1000 * math.sin(2 * math.pi * 6 * point / 512))
                        .round();
                data.setUint16(4 + j * 4, value);
                data.setUint16(6 + j * 4, value);
              }
              bytes.setAll(0, data.buffer.asUint8List());
              f.transport.packet('raw', bytes, DateTime(2026, 11, 3, 12));
              await Future<void>.delayed(const Duration(milliseconds: 3));
            }
            await Future<void>.delayed(const Duration(milliseconds: 220));
            expect(task.active, true);
            expect(await starting, true);
            expect(task.baselineCheckProgress, 1);
            expect(task.feedback.toMap(), chosenFeedback.toMap());
            expect(task.baseline!.state, 'collecting');
            expect(task.baseline!.snapshot()['validSeconds'], anyOf(isNull, 0));
            expect(await task.cancelBaseline(), true);
            clock += 1;
          }
        } finally {
          task.cancelBaselineCheck();
          task.dispose();
          await f.close();
        }
      });
    },
  );

  testWidgets(
    'Finalization waits through a transient contact report then retains the valid baseline after recovery',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.monitor = null;
      f.task.usingSavedReference = false;
      final b = BaselineAccumulator(
        attemptId: 'FINAL RECOVERY',
        context: f.task.context,
      );
      for (var i = 11; i <= 100; i++) {
        b.advance(i.toDouble());
        b.add(
          AnalysisWindow(
            sequence: i,
            start: i - 1.0,
            end: i.toDouble(),
            reason: 'good',
            features: {'attention': 60.0 + i % 3, 'relax': 40.0 + i % 2},
          ),
        );
      }
      f.task.baseline = b;
      final gate = Completer<void>();
      f.backend.baselineFinishBarrier = gate.future;
      final finish = f.task.finish();
      await tester.pump();
      f.transport.packet('raw', rawPacket(lead: 1), DateTime(2026, 11, 3, 12));
      await tester.pump(const Duration(milliseconds: 100));
      gate.complete();
      await tester.pump();
      expect(f.task.busy, true);
      expect(f.task.completedSession, isNull);
      f.clock = 100.2;
      f.transport.packet('raw', rawPacket(), DateTime(2026, 11, 3, 12));
      await tester.pump();
      expect(await finish, 'SYNTHETIC TASK');
      expect(f.task.completedSession, 'SYNTHETIC TASK');
      expect(f.backend.calls, isNot(contains('deleteSession')));
      await f.close();
    },
  );

  testWidgets(
    'Contact loss during asynchronous finalization cannot leave a qualified saved baseline',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.monitor = null;
      f.task.usingSavedReference = false;
      final baseline = BaselineAccumulator(
        attemptId: 'FINALIZATION',
        context: f.task.context,
      );
      for (var i = 11; i <= 100; i++) {
        baseline.advance(i.toDouble());
        baseline.add(
          AnalysisWindow(
            sequence: i,
            start: i - 1.0,
            end: i.toDouble(),
            reason: 'good',
            features: {'attention': 60.0 + i % 3, 'relax': 40.0 + i % 2},
          ),
        );
      }
      expect(baseline.state, 'ready');
      f.task.baseline = baseline;
      final gate = Completer<void>();
      f.backend.baselineFinishBarrier = gate.future;
      final finishing = f.task.finish();
      await tester.pump();
      expect(f.task.busy, true);
      for (var i = 0; i <= 31; i++) {
        f.clock = 100 + i / 10;
        f.transport.packet(
          'raw',
          rawPacket(lead: 1),
          DateTime(2026, 11, 3, 12),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(f.task.baselineInterruption, 'contact');
      gate.complete();
      expect(await finishing, isNull);
      expect(f.task.completedSession, isNull);
      expect(f.task.baselineDiscarded, true);
      expect(
        f.backend.calls,
        containsAllInOrder(['baselineFinish', 'deleteSession']),
      );
      await f.close();
    },
  );

  testWidgets(
    'A transient contact flag recovers, but three seconds of fresh reports discard with mute respected',
    (tester) async {
      for (final muted in [false, true]) {
        final f = MonitorFixture();
        await f.initialize();
        await f.task.finish();
        final backend = NoticeBackend();
        final sent = <Map>[];
        double clock = 0;
        const channel = MethodChannel('neurox/notifications');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'feedback') {
                sent.add(Map.from(call.arguments as Map));
              }
              return {'notice': 'requested'};
            });
        final task = TaskController(f.eeg, backend: backend, clock: () => clock)
          ..profile = f.task.profile
          ..sessionId = 'CONTACT TEST'
          ..feedback = FeedbackOptions(notice: true, muted: muted);
        task.baseline = BaselineAccumulator(
          attemptId: 'CONTACT',
          context: task.context,
        );
        task.quality = const AnalysisWindow(
          sequence: 1,
          start: 0,
          end: 1,
          reason: 'good',
          features: {'attention': 60, 'relax': 40},
        );
        f.transport.packet(
          'raw',
          rawPacket(lead: 1),
          DateTime(2026, 11, 3, 12),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(task.active, true);
        expect(task.baselineInterruption, isNull);
        expect(sent, isEmpty);
        clock = .2;
        f.transport.packet('raw', rawPacket(), DateTime(2026, 11, 3, 12));
        await tester.pump(const Duration(milliseconds: 100));
        expect(task.active, true);
        expect(task.baselineInterruption, isNull);
        for (var i = 0; i <= 31; i++) {
          clock = 1 + i / 10;
          f.transport.packet(
            'raw',
            rawPacket(lead: 1),
            DateTime(2026, 11, 3, 12),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(task.baselineInterruption, 'contact');
        expect(task.active, false);
        expect(task.baselineDiscarded, true);
        expect(
          backend.delegate.calls,
          containsAllInOrder(['baselineFinish', 'deleteSession']),
        );
        expect(sent.length, muted ? 0 : 1);
        task.dispose();
        await f.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );

  testWidgets(
    'Severe receipt loss is compared with measured preflight rate and aborts before final assessment',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      f.transport.emit({
        'type': 'recording',
        'active': false,
        'state': 'saved',
      });
      double clock = 0;
      final task = CheckController(
        f.eeg,
        backend: f.backend,
        clock: () => clock,
      )..profile = f.task.profile;
      final started = task.checkAndStartBaseline();
      await tester.pump();
      clock = 2;
      for (var i = 0; i < 64; i++) {
        f.transport.packet('raw', rawPacket(), DateTime(2026, 11, 3, 12));
      }
      task.quality = const AnalysisWindow(
        sequence: 2,
        start: 1,
        end: 2,
        reason: 'good',
        features: {'attention': 60, 'relax': 40},
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(await started, true);
      expect(task.baselineReceiptReferenceRate, 512);
      for (var i = 3; i <= 5; i++) {
        clock = i.toDouble();
        f.transport.packet('raw', rawPacket(), DateTime(2026, 11, 3, 12));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(task.baselineInterruption, 'data_loss');
      expect(task.active, false);
      expect(task.completedSession, isNull);
      expect(f.backend.calls, contains('deleteSession'));
      task.dispose();
      await f.close();
    },
  );

  testWidgets(
    'An unstable completed baseline is automatically discarded without publishing history or changing the saved reference',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.monitor = null;
      f.task.usingSavedReference = false;
      final reference = f.task.savedReference;
      final baseline = BaselineAccumulator(
        attemptId: 'UNSTABLE',
        context: f.task.context,
      );
      for (var i = 11; i <= 190; i++) {
        baseline.advance(i.toDouble());
        baseline.add(
          AnalysisWindow(
            sequence: i,
            start: i - 1.0,
            end: i.toDouble(),
            reason: 'good',
            features: {'attention': i.isEven ? 10 : 90, 'relax': 40},
          ),
        );
      }
      expect(baseline.state, 'failed');
      expect(baseline.reason, 'unstable');
      f.task.baseline = baseline;
      await tester.pump(const Duration(seconds: 1));
      expect(f.task.active, false);
      expect(f.task.completedSession, isNull);
      expect(f.task.baselineInterruption, 'unstable');
      expect(f.task.baselineDiscarded, true);
      expect(f.task.savedReference, same(reference));
      expect(
        f.backend.calls,
        containsAllInOrder(['baselineFinish', 'deleteSession']),
      );
      await f.close();
    },
  );

  testWidgets(
    'Early end confirms discard and returns without a saved-detail route',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.monitor = null;
      f.task.usingSavedReference = false;
      f.task.baseline = BaselineAccumulator(
        attemptId: 'CANCEL UI',
        context: f.task.context,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BaselinePage(task: f.task),
                  ),
                ),
                child: const Text('open baseline'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open baseline'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('结束采集'),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('结束采集'));
      await tester.pumpAndSettle();
      expect(find.text('本次尚未完成的基线不会保存，之前的有效基线不受影响。'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.byType(BaselinePage), findsNothing);
      expect(f.task.completedSession, isNull);
      expect(f.task.baselineDiscarded, true);
      expect(f.backend.calls, contains('deleteSession'));
      await tester.pumpWidget(const SizedBox());
      await f.close();
    },
  );

  testWidgets(
    'Reentering baseline preparation resets previous pass and failure hints',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      for (final previous in ['passed', 'quality_timeout']) {
        f.task.baselineCheckReason = previous;
        f.task.baselineCheckProgress = 1;
        await tester.pumpWidget(
          MaterialApp(home: TaskPreparation(task: f.task, baselineOnly: true)),
        );
        await tester.pumpAndSettle();
        expect(f.task.baselineCheckReason, 'idle');
        expect(f.task.baselineCheckProgress, 0);
        expect(find.text(baselineCheckLabel(previous)), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
      f.task.baselineCheckReason = 'passed';
      f.task.clearDraft();
      expect(f.task.baselineCheckReason, 'idle');
      await f.close();
    },
  );

  testWidgets(
    'Manual baseline cancellation closes then deletes only its current record and retries cleanup failures',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.monitor = null;
      f.task.usingSavedReference = false;
      f.task.baseline = BaselineAccumulator(
        attemptId: 'CANCEL',
        context: f.task.context,
      );
      final id = f.task.sessionId, reference = f.task.savedReference;
      f.backend.failDelete = true;
      expect(await f.task.cancelBaseline(), false);
      expect(f.task.active, true);
      expect(f.task.baseline?.state, 'invalid');
      expect(f.task.error, isNotNull);
      expect(f.task.savedReference, same(reference));
      f.backend.failDelete = false;
      expect(await f.task.cancelBaseline(), true);
      expect(
        f.backend.calls.indexOf('baselineFinish'),
        lessThan(f.backend.calls.indexOf('deleteSession')),
      );
      expect(f.backend.arguments['deleteSession'], {'id': id});
      expect(f.task.active, false);
      expect(f.task.baselineDiscarded, true);
      expect(f.task.completedSession, isNull);
      expect(f.task.completedBaseline, isNull);
      expect(f.task.savedReference, same(reference));
      expect(f.backend.calls, isNot(contains('baselineSelect')));
      await f.close();
    },
  );

  testWidgets(
    'Baseline feedback is quiet normally and debounces wearing anomalies with mute respected',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      final sent = <Map>[];
      const channel = MethodChannel('neurox/notifications');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'feedback') {
              sent.add(Map.from(call.arguments as Map));
            }
            return {'notice': 'requested'};
          });
      double clock = 0;
      final task =
          TaskController(f.eeg, backend: NoticeBackend(), clock: () => clock)
            ..profile = f.task.profile
            ..sessionId = 'BASELINE TEST'
            ..feedback = const FeedbackOptions(notice: true);
      task.baseline = BaselineAccumulator(
        attemptId: 'TEST',
        context: task.context,
      );
      task.quality = const AnalysisWindow(
        sequence: 1,
        start: 0,
        end: 1,
        reason: 'good',
        features: {'attention': 60, 'relax': 40},
      );
      await tester.pump(const Duration(seconds: 1));
      expect(sent, isEmpty);
      task.quality = const AnalysisWindow(
        sequence: 2,
        start: 1,
        end: 2,
        reason: 'flat',
      );
      clock = 1;
      await tester.pump(const Duration(seconds: 1));
      expect(sent, isEmpty);
      task.feedback = const FeedbackOptions(notice: true, muted: true);
      clock = 7;
      await tester.pump(const Duration(seconds: 1));
      expect(sent, isEmpty);
      expect(task.baselineInterruption, isNull);
      expect(task.active, true);
      expect(task.baselineDiscarded, false);
      task.feedback = const FeedbackOptions(notice: true);
      clock = 8;
      await tester.pump(const Duration(seconds: 1));
      expect(sent, isEmpty);
      clock = 9;
      await tester.pump(const Duration(seconds: 1));
      expect(sent, isEmpty);
      task.dispose();
      await f.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  testWidgets(
    'Start checks require fresh quality; cancellation and timeout create no record',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      f.transport.emit({
        'type': 'recording',
        'active': false,
        'state': 'saved',
      });
      final task = CheckController(f.eeg, backend: f.backend)
        ..profile = f.task.profile;
      final initialStarts = f.backend.calls
          .where((c) => c == 'baselineStart')
          .length;
      task.quality = const AnalysisWindow(
        sequence: 1,
        start: 0,
        end: 1,
        reason: 'good',
        features: {'attention': 60, 'relax': 40},
      );
      final cancelled = task.checkAndStartBaseline();
      await tester.pump();
      expect(task.quality, isNull);
      expect(task.baselineChecking, true);
      expect(task.baselineCheckProgress, .45);
      expect(task.canStartLearning, false);
      task.cancelBaselineCheck();
      expect(await cancelled, false);
      final timeout = task.checkAndStartBaseline(
        timeout: const Duration(milliseconds: 400),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(await timeout, false);
      expect(task.baselineCheckReason, 'quality_timeout');
      expect(task.active, false);
      expect(
        f.backend.calls.where((c) => c == 'baselineStart').length,
        initialStarts,
      );
      final passed = task.checkAndStartBaseline();
      await tester.pump();
      task.quality = const AnalysisWindow(
        sequence: 2,
        start: 1,
        end: 2,
        reason: 'good',
        features: {'attention': 60, 'relax': 40},
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(await passed, true);
      expect(task.baselineCheckProgress, 1);
      expect(task.active, true);
      expect(
        f.backend.calls.where((c) => c == 'baselineStart').length,
        initialStarts + 1,
      );
      task.dispose();
      await f.close();
    },
  );

  testWidgets('Blocked storage fails initial checks without starting capture', (
    tester,
  ) async {
    final f = MonitorFixture();
    await f.initialize();
    await f.task.finish();
    f.transport.emit({'type': 'recording', 'active': false, 'state': 'saved'});
    final task = CheckController(f.eeg, backend: f.backend)
      ..profile = f.task.profile
      ..writable = false;
    expect(await task.checkAndStartBaseline(), false);
    expect(task.baselineCheckReason, 'storage');
    expect(f.backend.calls, isNot(contains('baselineStart')));
    task.dispose();
    await f.close();
  });

  testWidgets(
    'Quiet recording has no live curve; failed end assessment keeps rerecord action visible',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.monitor = null;
      f.task.usingSavedReference = false;
      final baseline = BaselineAccumulator(
        attemptId: 'BASELINE TEST',
        context: f.task.context,
      );
      f.task.baseline = baseline;
      await tester.pumpWidget(MaterialApp(home: BaselinePage(task: f.task)));
      await tester.pump();
      expect(find.byType(SceneCurve), findsNothing);
      expect(find.byType(ReferenceMetrics), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      baseline.state = 'failed';
      baseline.reason = 'unstable';
      await f.task.finish();
      await tester.pumpAndSettle();
      expect(find.text('需要重新采集'), findsOneWidget);
      expect(find.text(baselineFailureLabel('unstable')), findsOneWidget);
      expect(find.text('重新采集基线'), findsOneWidget);
      expect(f.task.active, false);
      expect(f.task.completedBaseline, isNull);
      expect(f.task.completedSession, isNull);
      expect(f.task.baselineDiscarded, true);
      expect(f.backend.calls, contains('deleteSession'));
      expect(f.backend.calls, contains('baselineFinish'));
      await tester.pumpWidget(const SizedBox());
      await f.close();
    },
  );
}
