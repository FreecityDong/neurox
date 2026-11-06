import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/report_insights.dart';
import 'package:neurox/features/tasks/learning_trend.dart';
import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'package:neurox/l10n/app_language.dart';

Map<String, dynamic> reference() => {
  'attention': {'mean': 60.0, 'variance': 36.0},
  'relax': {'mean': 40.0, 'variance': 4.0},
};
List<Map<String, dynamic>> samples(
  int total,
  double Function(int) attention,
  double Function(int) relax,
) => [
  for (var t = 1; t <= total; t++)
    {
      'type': 'sample',
      'elapsed': t.toDouble(),
      'curveSeconds': t.toDouble(),
      'wallSeconds': t.toDouble(),
      'observationDuration': 1.0,
      'scores': {'attention': attention(t), 'relax': relax(t)},
    },
];
Map<String, dynamic> summary(
  String scene,
  double total, {
  bool compared = true,
}) => {
  'scene': scene,
  'elapsed': total,
  'reference': reference(),
  'validSeconds': compared ? total : 0,
  'durations': {
    'stable': compared ? total : 0,
    'deviation': 0.0,
    'unknown': compared ? 0.0 : total,
  },
  'timeline': [
    {'start': 0.0, 'end': total, 'state': compared ? 'stable' : 'unknown'},
  ],
};
void main() {
  setUp(() => AppLanguage.instance.resetForTest());
  test(
    'Baseline describes saved variability and absolute drift without inventing direction',
    () {
      final saved = {
        'state': 'ready',
        'statistics': {
          'attention': {'mean': 60.0, 'variance': 36.0, 'drift': 2.0},
          'relax': {'mean': 40.0, 'standardDeviation': 4.0, 'drift': 5.0},
        },
      };
      final before = jsonEncode(saved), lines = baselineInsights(saved).join();
      expect(lines, contains('6.0'));
      expect(lines, contains('4.0'));
      expect(lines, contains('2.0'));
      expect(lines, contains('5.0'));
      expect(lines, isNot(contains('升高')));
      expect(lines, isNot(contains('降低')));
      expect(jsonEncode(saved), before);
      expect(baselineInsights({}).join(), contains('未形成'));
      expect(baselineInsights({}).join(), contains('不足'));
    },
  );
  test(
    'Learning uses saved confirmed episodes, describes recovery and never mutates or reclassifies',
    () {
      final m = MonitoringEngine(
        targetSeconds: 0,
        at: 0,
        reference: reference(),
        attemptId: 'A',
        context: {},
      );
      for (var t = 0; t < 90; t++) {
        m.observe(
          at: t.toDouble(),
          sampleAt: t.toDouble(),
          features: {
            'attention': t < 30
                ? 60.0
                : t < 60
                ? 40.0
                : 65.0,
            'relax': 40,
          },
          good: true,
        );
      }
      m.finish(90, 'user_completed');
      final snapshot = m.snapshot(90),
          before = jsonEncode([snapshot, m.events]);
      final data = LearningTrend(snapshot, m.events), lines = data.explanations;
      expect(lines.length, lessThanOrEqualTo(4));
      expect(lines.join(), contains('有所升高'));
      expect(lines.join(), contains('确认偏离 1 次'));
      expect(lines.join(), contains('确认恢复'));
      expect(data.statisticalNotes.join(), contains('未知不等于不专注'));
      expect(jsonEncode([snapshot, m.events]), before);
      final invalid = LearningTrend({
        ...snapshot,
        'timeline': [],
      }, m.events).explanations.join();
      expect(invalid, contains('不完整'));
      expect(invalid, isNot(contains('最长连续正常')));
    },
  );
  for (final compared in [true, false]) {
    test(
      'Competition separates match and post phases; comparison=$compared never changes saved state',
      () {
        final s = summary('go', 120, compared: compared);
        final events = <Map<String, dynamic>>[
          {'type': 'start', 'elapsed': 0.0, 'stage': 'preparation'},
          {'type': 'stage', 'elapsed': 30.0, 'stage': 'thinking'},
          {'type': 'stage', 'elapsed': 60.0, 'stage': 'interval'},
          {'type': 'stage', 'elapsed': 90.0, 'stage': 'post_match'},
          ...samples(
            120,
            (t) => t <= 30
                ? 60
                : t <= 60
                ? 50
                : t <= 90
                ? 70
                : 40,
            (_) => 40,
          ),
        ];
        final before = jsonEncode([s, events]),
            lines = LearningTrend(s, events).explanations.join();
        expect(lines, contains('思考中'));
        expect(lines, contains('50.0'));
        expect(lines, contains('赛后阶段'));
        expect(lines, contains('40.0'));
        expect(lines, isNot(contains('后段专注较前段')));
        expect(lines, contains(compared ? '赛中确认偏离 0 次' : '未形成可用的基线对比'));
        expect(jsonEncode([s, events]), before);
      },
    );
  }
  test(
    'Archery excludes action judgement and respects missing phase observations',
    () {
      final s = summary('archery', 90, compared: false);
      final events = <Map<String, dynamic>>[
        {'type': 'start', 'elapsed': 0.0, 'stage': 'preparation'},
        {'type': 'stage', 'elapsed': 30.0, 'stage': 'shooting'},
        {'type': 'stage', 'elapsed': 60.0, 'stage': 'post_training'},
        ...samples(90, (_) => 50, (_) => 40),
      ];
      final lines = LearningTrend(s, events).explanations.join();
      expect(lines, contains('射箭动作阶段只观察曲线'));
      expect(lines, contains('训练后阶段'));
      expect(lines, isNot(contains('赛中确认偏离')));
      expect(
        LearningTrend(summary('go', 15), []).explanations.join(),
        contains('未记录到比赛或思考阶段'),
      );
    },
  );
  test(
    'Training explains target behavior and own game-clock trend without using relaxation',
    () {
      final s = {
        'elapsed': 90.0,
        'game': {
          'kind': 'obstacles',
          'goal': 30,
          'correct': 20,
          'mistakes': 2,
          'elapsed': 90.0,
          'outcome': 'timeout',
        },
      };
      final e = samples(90, (t) => t <= 30 ? 40 : 60, (_) => 90);
      final lines = trainingInsights(s, e).join();
      expect(lines, contains('20/30'));
      expect(lines, contains('4.5'));
      expect(lines, contains('有所升高'));
      expect(lines, contains('未完成全部目标'));
      expect(lines, isNot(contains('放松')));
      final tracking = trainingInsights({
        'elapsed': 90.0,
        'game': {
          'kind': 'tracking',
          'goal': 3,
          'correct': 2,
          'mistakes': 1,
          'responseSeconds': 4.0,
          'outcome': 'completed',
        },
      }, e).join();
      expect(tracking, contains('识别出 2/3'));
      expect(tracking, contains('4.0'));
      expect(tracking, isNot(contains('每个正确目标')));
      expect(trainingInsights(s, []).join(), contains('有效脑波不足'));
    },
  );
  test(
    'Recovery describes demonstration to independent relaxation and optional feelings, not attention or efficacy',
    () {
      final s = {
        ...summary('recovery', 90),
        'recoveryTeaching': {
          'readinessBefore': 2,
          'readinessAfter': 4,
          'version': 'recovery-teaching-v2',
          'linked': false,
        },
      };
      final e = <Map<String, dynamic>>[
        {'type': 'start', 'stage': 'demonstration', 'elapsed': 0.0},
        {'type': 'stage', 'stage': 'guided', 'elapsed': 30.0},
        {'type': 'stage', 'stage': 'independent', 'elapsed': 60.0},
        ...samples(
          90,
          (t) => 100.0 - t,
          (t) => t <= 30
              ? 20
              : t <= 60
              ? 40
              : 60,
        ),
      ];
      final before = jsonEncode([s, e]), lines = recoveryInsights(s, e).join();
      expect(lines, contains('有所升高'));
      expect(lines, contains('40.0'));
      expect(lines, contains('跟随阶段'));
      expect(lines, contains('准备度由 2 变为 4'));
      expect(lines, isNot(contains('恢复成功')));
      expect(lines, isNot(contains('专注')));
      expect(jsonEncode([s, e]), before);
      expect(
        recoveryInsights({...s, 'elapsed': 15.0}, []).join(),
        contains('有效数据不足'),
      );
    },
  );
  test(
    'Pause boundaries break continuous normal interpretation even if saved timeline merged green intervals',
    () {
      final s = summary('learning', 60);
      final e = <Map<String, dynamic>>[
        {'type': 'pause', 'elapsed': 30.0},
        ...samples(60, (_) => 60, (_) => 40),
      ];
      final text = LearningTrend(s, e).explanations.join();
      expect(text, contains('持续 0:30'));
      expect(text, isNot(contains('持续 1:00')));
    },
  );
}
