import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/task_pages.dart';
import 'package:neurox/features/tasks/learning_flow_widgets.dart';
import 'package:neurox/features/shell/feedback_preferences.dart';
import 'support/monitoring_fixture.dart';
import 'support/fake_eeg_transport.dart';

Future<void> freshSignal(MonitorFixture f) async {
  final origin = f.clock;
  for (var packet = 0; packet < 25 * 32 && !f.task.canMonitor; packet++) {
    f.clock = origin + packet / 32;
    final bytes = rawPacket();
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < 16; i++) {
      final at = packet * 16 + i;
      final value =
          (30000 +
                  2000 * math.sin(2 * math.pi * 10 * at / 512) +
                  1000 * math.sin(2 * math.pi * 6 * at / 512))
              .round();
      data.setUint16(4 + i * 4, value);
      data.setUint16(6 + i * 4, value);
    }
    f.transport.packet('raw', bytes, DateTime(2026, 11, 3, 12));
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await Future<void>.delayed(const Duration(milliseconds: 30));
  expect(f.task.canMonitor, true);
  expect(
    f.clock - origin,
    greaterThan(5),
    reason: 'New stable comparison evidence must replace cached quality',
  );
}

void main() {
  testWidgets(
    'Short pause and reconnect each require fresh quality while retaining the same task, reference and elapsed time',
    (tester) async {
      await tester.runAsync(() async {
        final f = MonitorFixture();
        await f.initialize();
        try {
          await f.task.refresh();
          final id = f.task.sessionId;
          final reference = Map<String, dynamic>.from(
            f.task.monitor!.reference,
          );
          final device = f.eeg.selected!;
          f.clock = 101;
          f.task.pauseMonitoring();
          expect(f.task.monitor!.phase, 'paused');
          f.quality(); // Even a cached positive status cannot bypass the preparation gate.
          expect(f.task.canMonitor, false);
          await f.task.startMonitoring();
          expect(f.task.monitor!.phase, 'paused');
          await f.task.continueMonitoring();
          expect(f.task.learningPreparing, true);
          expect(f.task.quality, isNull);
          expect(f.task.learningResuming, true);
          final elapsed = f.task.monitor!.elapsed;
          await freshSignal(f);
          expect(f.task.monitor!.elapsed, elapsed);
          await f.task.startMonitoring();
          expect(f.task.monitor!.phase, 'running');
          expect(f.task.sessionId, id);
          expect(f.task.monitor!.reference, reference);
          await f.transport.disconnect();
          expect(f.task.monitor!.phase, 'interrupted');
          expect(f.task.active, true);
          expect(f.task.canMonitor, false);
          expect(f.backend.calls, isNot(contains('monitorFinish')));
          await f.eeg.connect(device);
          f.transport.packet('raw', rawPacket(), DateTime(2026, 11, 3, 12));
          await f.task.continueMonitoring();
          f.transport.emit({
            'type': 'recording',
            'active': true,
            'state': 'recording',
          });
          expect(f.task.learningPreparing, true);
          expect(f.task.canMonitor, false);
          final before = f.task.monitor!.elapsed;
          await freshSignal(f);
          expect(f.task.monitor!.elapsed, before);
          await f.task.startMonitoring();
          expect(f.task.monitor!.phase, 'running');
          expect(f.task.sessionId, id);
          expect(f.task.monitor!.reference, reference);
          expect(f.backend.learningCount, 1);
          expect(f.backend.calls, isNot(contains('baselineStart')));
          expect(f.backend.calls, isNot(contains('baselineRetry')));
          for (
            var packet = 0;
            packet < 15 * 32 && f.task.monitor!.phase == 'running';
            packet++
          ) {
            f.clock += 1 / 32;
            final bytes = rawPacket(), data = ByteData.sublistView(rawPacket());
            for (var i = 0; i < 16; i++) {
              data.setUint16(4 + i * 4, 30000);
              data.setUint16(6 + i * 4, 30000);
            }
            bytes.setAll(0, data.buffer.asUint8List());
            f.transport.packet('raw', bytes, DateTime(2026, 11, 3, 12));
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(f.task.monitor!.phase, 'interrupted');
          expect(f.task.monitor!.reason, 'waveform');
          expect(f.task.active, true);
          await f.task.continueMonitoring();
          final beforeQuality = f.task.monitor!.elapsed;
          await freshSignal(f);
          expect(f.task.monitor!.elapsed, beforeQuality);
          await f.task.startMonitoring();
          expect(f.task.monitor!.phase, 'running');
          expect(f.task.sessionId, id);
          expect(f.task.monitor!.reference, reference);
        } finally {
          await f.close();
        }
      });
    },
  );

  testWidgets(
    'Signal check contains no duplicate settings and labels a resumed task correctly',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      const chosen = FeedbackOptions(sound: true, notice: true);
      f.task.setFeedback(chosen);
      f.clock = 101;
      f.task.pauseMonitoring();
      await tester.pumpWidget(MaterialApp(home: BaselinePage(task: f.task)));
      await tester.pumpAndSettle();
      final resume = find.widgetWithText(OutlinedButton, '继续学习');
      expect(tester.widget<OutlinedButton>(resume).onPressed, isNotNull);
      await tester.tap(resume);
      await tester.pumpAndSettle();
      expect(find.byType(LearningFeedbackSettings), findsNothing);
      expect(find.byType(LearningReferencePreview), findsNothing);
      expect(find.byType(LearningSignalCheck), findsOneWidget);
      final start = find.widgetWithText(FilledButton, '继续学习');
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      f.quality();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(f.task.monitor!.phase, 'running');
      expect(f.task.feedback.toMap(), chosen.toMap());
      await tester.pumpWidget(const SizedBox());
      await f.close();
    },
  );

  testWidgets(
    'Sustained contact issue interrupts learning without saving or ending it',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      for (var i = 0; i <= 31; i++) {
        f.clock = 101 + i / 10;
        f.transport.packet(
          'raw',
          rawPacket(lead: 1),
          DateTime(2026, 11, 3, 12),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(f.task.monitor!.phase, 'interrupted');
      expect(f.task.monitor!.reason, 'contact');
      expect(f.task.active, true);
      expect(f.task.canMonitor, false);
      expect(f.backend.calls, isNot(contains('monitorFinish')));
      await f.close();
    },
  );
}
