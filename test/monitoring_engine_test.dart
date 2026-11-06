import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';

final reference = <String, dynamic>{
  'attention': {'mean': 60.0, 'variance': 25.0},
  'relax': {'mean': 40.0, 'variance': 16.0},
};
MonitoringEngine engine({int target = 300, bool reminders = true}) =>
    MonitoringEngine(
      targetSeconds: target,
      at: 0,
      reference: reference,
      attemptId: 'A',
      context: {'device': 'TEST'},
      reminders: reminders,
    );
void observe(
  MonitoringEngine e,
  double at, {
  double attention = 40,
  bool good = true,
}) => e.observe(
  at: at,
  sampleAt: at,
  features: {'attention': attention, 'relax': 40},
  good: good,
);
void main() {
  test(
    'Personal learning reference is immutable across data preparation and resume',
    () {
      final original = <String, dynamic>{
        'attention': {'mean': 60.0, 'variance': 25.0},
        'relax': {'mean': 40.0, 'variance': 16.0},
      };
      final m = MonitoringEngine(
        targetSeconds: 300,
        at: 0,
        reference: original,
        attemptId: 'A',
        context: {},
        prepared: true,
        referenceOrigin: {'sessionId': 'ORIGINAL'},
      );
      (original['attention'] as Map)['mean'] = 99.0;
      expect(m.attentionMean, 60);
      expect(
        () => (m.reference['attention'] as Map)['mean'] = 0,
        throwsUnsupportedError,
      );
      expect(() => m.resume(10, original, 'B'), throwsStateError);
      m.resume(11, {
        'attention': {'mean': 60.0, 'variance': 25.0},
        'relax': {'mean': 40.0, 'variance': 16.0},
      }, 'B');
      expect(m.attentionMean, 60);
      expect(m.elapsed, 0);
    },
  );
  test(
    'Recovery enables a new episode immediately, but one continuous episode never repeats',
    () {
      final e = engine();
      for (var i = 0; i < 25; i++) {
        observe(e, i.toDouble());
      }
      expect(e.state, 'deviation');
      expect(e.remindersRequested, 1);
      for (var i = 25; i < 34; i++) {
        observe(e, i.toDouble(), attention: 60);
      }
      expect(e.state, 'deviation');
      observe(e, 34, attention: 60);
      expect(e.state, 'stable');
      for (var i = 35; i < 200; i++) {
        observe(e, i.toDouble());
      }
      expect(e.state, 'deviation');
      expect(e.remindersRequested, 2);
      expect(
        e.events.where((v) => v['type'] == 'reminder').last['delivery'],
        'pending',
      );
      // Continued low scores stay within the same episode and do not repeat.
      for (var i = 200; i < 210; i++) {
        observe(e, i.toDouble(), attention: 60);
      }
      for (var i = 210; i < 235; i++) {
        observe(e, i.toDouble());
      }
      expect(e.remindersRequested, 3);
    },
  );
  test(
    'Gap becomes unknown and does not carry a low-value streak across it',
    () {
      final e = engine();
      observe(e, 0);
      e.advance(10);
      expect(e.elapsed, 10);
      expect(e.validSeconds, 2);
      expect(e.durations['unknown'], 8);
      expect(e.remindersRequested, 0);
      for (var i = 10; i <= 33; i++) {
        observe(e, i.toDouble());
      }
      expect(e.remindersRequested, 0);
      observe(e, 34);
      expect(e.remindersRequested, 1);
      observe(e, 36, good: false);
      expect(e.state, 'unknown');
      e.advance(60);
      expect(e.remindersRequested, 1);
    },
  );
  test(
    'Pause/rebaseline/background are excluded from monitoring, long pause requires a new attempt',
    () {
      final e = engine();
      observe(e, 0, attention: 60);
      e.pause(1);
      e.advance(100);
      expect(e.elapsed, 1);
      expect(e.pauseSeconds, 99);
      expect(e.needsBaseline(100), true);
      expect(() => e.resume(100, reference, 'A'), throwsStateError);
      e.rebuild(100);
      e.resume(160, reference, 'B', nextContext: {'device': 'NEW'});
      expect(e.rebuildSeconds, 60);
      expect(e.context['device'], 'NEW');
      observe(e, 160, attention: 60);
      e.interrupt(161, 'background');
      e.advance(1000);
      expect(e.elapsed, 2);
      expect(e.state, 'unknown');
      expect(e.remindersRequested, 0);
    },
  );
  test(
    'Restored native interruption freezes checkpoint instead of counting an unobserved background gap',
    () {
      final e = engine();
      observe(e, 0);
      e.advance(1);
      e.interrupt(1000, 'background', accountTime: false);
      expect(e.elapsed, 1);
      expect(e.phase, 'interrupted');
    },
  );
  test(
    'Hysteresis prevents flicker, turning reminders off cancels subsequent requests',
    () {
      final e = engine();
      observe(e, 0);
      for (var i = 1; i <= 25; i++) {
        observe(e, i.toDouble());
      }
      observe(e, 26, attention: 56);
      expect(e.state, 'deviation');
      observe(e, 27, attention: 57);
      expect(e.state, 'deviation');
      for (var i = 28; i <= 36; i++) {
        observe(e, i.toDouble(), attention: 57);
      }
      expect(e.state, 'stable');
      e.setReminders(false, 36);
      for (var i = 37; i < 290; i++) {
        observe(e, i.toDouble());
      }
      expect(e.remindersRequested, 1);
    },
  );
  test(
    'Target and manual finish are idempotent and all measured state durations sum to the denominator',
    () {
      final e = engine(target: 5);
      observe(e, 0, attention: 60);
      e.advance(10);
      expect(e.elapsed, 5);
      expect(e.finished, true);
      expect(e.endReason, 'target_reached');
      final count = e.events.length;
      e.finish(20, 'user_ended');
      e.advance(50);
      expect(e.events.length, count);
      expect(e.durations.values.reduce((a, b) => a + b), e.elapsed);
      expect(e.validSeconds, 2);
      expect(e.snapshot(50)['validRatio'], .4);
      final manual = engine();
      observe(manual, 0, attention: 60);
      manual.finish(1, 'user_ended');
      expect(manual.elapsed, 1);
    },
  );
  test(
    'Invalid reference and stale/nonfinite observations do not produce a state judgement',
    () {
      expect(
        () => MonitoringEngine(
          targetSeconds: 300,
          at: 0,
          reference: {},
          attemptId: 'X',
          context: {},
        ),
        throwsArgumentError,
      );
      final e = engine();
      e.observe(
        at: 10,
        sampleAt: 0,
        features: {'attention': 40, 'relax': 40},
        good: true,
      );
      expect(e.state, 'unknown');
      e.observe(
        at: 11,
        sampleAt: 11,
        features: {'attention': double.nan, 'relax': 40},
        good: true,
      );
      expect(e.state, 'unknown');
      expect(e.remindersRequested, 0);
    },
  );
}
