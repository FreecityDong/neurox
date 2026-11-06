import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';
import 'package:neurox/features/shell/feedback_preferences.dart';

MonitoringEngine create(TaskScene scene, {bool reminders = true}) =>
    MonitoringEngine(
      targetSeconds: 2700,
      at: 0,
      reference: {
        'attention': {'mean': 70.0, 'variance': 64.0},
        'relax': {'mean': 40.0, 'variance': 0.0},
      },
      referenceOrigin: {'sessionId': 'FROZEN'},
      attemptId: 'A',
      context: {},
      rules: MonitoringRules(scene: scene),
      reminders: reminders,
    );
void sample(MonitoringEngine m, int t, double a) => m.observe(
  at: t.toDouble(),
  sampleAt: t.toDouble(),
  features: {'attention': a, 'relax': 40},
  good: true,
);
void main() {
  test(
    'Same 12 second dip is observed differently by study and competition; recovery requires 15 seconds',
    () {
      final study = create(TaskScene.learning),
          sport = create(TaskScene.esports);
      for (var i = 0; i < 12; i++) {
        sample(study, i, 60);
        sample(sport, i, 60);
      }
      expect(study.state, 'stable');
      expect(sport.state, 'deviation');
      final event = sport.events.singleWhere((e) => e['type'] == 'deviation');
      expect(event['wallSeconds'], 9);
      expect(event['candidateStartedWallSeconds'], 0);
      for (var i = 12; i < 26; i++) {
        sample(sport, i, 67);
      }
      expect(sport.state, 'deviation');
      sample(sport, 26, 67);
      expect(sport.state, 'stable');
    },
  );
  test(
    'Duplicates and delayed timers cannot manufacture completed seconds; gaps break recovery',
    () {
      final m = create(TaskScene.go);
      for (var i = 0; i < 9; i++) {
        sample(m, i, 60);
        sample(m, i, 60);
      }
      expect(m.state, 'stable');
      m.advance(50);
      expect(m.state, 'unknown');
      for (var i = 51; i < 61; i++) {
        sample(m, i, 60);
      }
      expect(m.state, 'deviation');
      for (var i = 61; i < 70; i++) {
        sample(m, i, 70);
      }
      m.block(70, 'data');
      for (var i = 71; i < 80; i++) {
        sample(m, i, 60);
      }
      expect(m.state, 'stable');
      sample(m, 80, 60);
      expect(m.state, 'deviation');
    },
  );
  test(
    'All channels off still produces persisted deviations; enabling later does not replay them',
    () {
      final m = create(TaskScene.esports, reminders: false);
      for (var i = 0; i < 10; i++) {
        sample(m, i, 60);
      }
      expect(m.events.where((e) => e['type'] == 'deviation'), hasLength(1));
      expect(m.remindersRequested, 0);
      m.setReminders(true, 10);
      sample(m, 10, 60);
      expect(m.remindersRequested, 0);
      expect(m.state, 'deviation');
      final all = FeedbackOptions.fromMap({
        'sound': true,
        'vibration': true,
        'notice': false,
      });
      expect(all.enabled, true);
      expect(all.change('sound', false).notice, false);
      expect(all.vibration, true);
    },
  );
  test(
    'Archery action stages stay unknown; optional stage silence affects feedback only',
    () {
      final m = create(TaskScene.archery);
      m.changeStage('aiming', 0, allowed: false);
      for (var i = 0; i < 30; i++) {
        sample(m, i, 60);
      }
      expect(m.state, 'unknown');
      expect(m.remindersRequested, 0);
      m.changeStage('interval', 30, allowed: true, silenced: true);
      for (var i = 30; i < 40; i++) {
        sample(m, i, 60);
      }
      expect(m.state, 'deviation');
      expect(
        m.events.where((e) => e['type'] == 'reminder').last['delivery'],
        'stage_silence',
      );
      expect(m.remindersRequested, 0);
    },
  );
  test(
    'Recovery excludes teaching time, keeps baseline and requires a real return streak',
    () {
      final m = create(TaskScene.learning);
      sample(m, 0, 60);
      m.beginRecovery(1, {'method': 'attention'});
      m.advance(100);
      expect(m.elapsed, 1);
      expect(m.recoveryActivitySeconds, 99);
      expect(m.reference['attention']['mean'], 70);
      m.endRecovery(100, {});
      for (var i = 101; i < 110; i++) {
        sample(m, i, 70);
      }
      expect(m.checkResult, isNull);
      sample(m, 110, 70);
      expect(m.checkResult, 'returned');
      expect(
        m.events.singleWhere((e) => e['type'] == 'recheck')['validSeconds'],
        10,
      );
    },
  );
  test(
    'A paused or changed stage cancels an old return check; unavailable data expires honestly',
    () {
      final m = create(TaskScene.go);
      m.beginRecovery(0, {});
      m.endRecovery(1, {});
      m.advance(122);
      expect(m.checkResult, 'insufficient');
      m.beginRecovery(123, {});
      m.endRecovery(124, {});
      m.pause(125);
      m.resume(126, m.reference, 'A');
      for (var i = 126; i < 150; i++) {
        sample(m, i, 70);
      }
      expect(m.checkResult, isNull);
    },
  );
}
