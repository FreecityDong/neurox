import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'package:neurox/features/tasks/scene_protocol.dart';

void main() {
  for (final scene in [
    TaskScene.learning,
    TaskScene.esports,
    TaskScene.go,
    TaskScene.archery,
  ]) {
    test(
      '${scene.name} hysteresis, one alert per episode, immediate new episode and no recovery alert',
      () {
        final m = MonitoringEngine(
          targetSeconds: 0,
          at: 0,
          reference: {
            'attention': {'mean': 60.0, 'variance': 36.0},
            'relax': {'mean': 40.0, 'variance': 4.0},
          },
          attemptId: 'A',
          context: {},
          rules: MonitoringRules(scene: scene),
          reminders: true,
        );
        var second = 0;
        void sample(double attention) {
          final t = (second++).toDouble();
          m.observe(
            at: t,
            sampleAt: t,
            features: {'attention': attention, 'relax': 40},
            good: true,
          );
        }

        expect(m.drop, 6);
        expect(m.recovery, 3);
        sample(54);
        for (var i = 1; i < scene.deviationSeconds; i++) {
          sample(56);
        }
        expect(m.state, 'deviation');
        expect(m.remindersRequested, 1);
        for (var i = 0; i < 20; i++) {
          sample(54);
        }
        expect(m.remindersRequested, 1);
        for (var i = 0; i < scene.recoverySeconds - 1; i++) {
          sample(57);
        }
        expect(m.state, 'deviation');
        expect(m.remindersRequested, 1);
        sample(57);
        expect(m.state, 'stable');
        expect(
          m.remindersRequested,
          1,
          reason: 'Recovery does not create an alert',
        );
        for (var i = 0; i < scene.deviationSeconds; i++) {
          sample(54);
        }
        expect(m.state, 'deviation');
        expect(m.remindersRequested, 2);
        final alerts = m.events.where((e) => e['type'] == 'reminder').toList();
        expect(
          (alerts.last['wallSeconds'] as num) -
              (alerts.first['wallSeconds'] as num),
          lessThan(150),
        );
        expect(alerts.every((e) => e['delivery'] == 'pending'), true);
        expect(m.rules.toMap()['cooldownSeconds'], 0);
      },
    );
  }
}
