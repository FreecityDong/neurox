import 'package:neurox/features/tasks/monitoring_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/learning_trend.dart';

Map<String, dynamic> saved() => {
  'elapsed': 100,
  'validSeconds': 90,
  'durations': {'stable': 70, 'deviation': 20, 'unknown': 10},
  'timeline': [
    {'start': 0, 'end': 30, 'state': 'stable'},
    {'start': 30, 'end': 50, 'state': 'deviation'},
    {'start': 50, 'end': 90, 'state': 'stable'},
    {'start': 90, 'end': 100, 'state': 'unknown'},
  ],
};
void main() {
  test(
    'Actual engine events recover the observed candidate interval without changing live confirmation',
    () {
      final engine = MonitoringEngine(
        targetSeconds: 0,
        at: 0,
        reference: {
          'attention': {'mean': 60, 'variance': 25},
          'relax': {'mean': 40, 'variance': 9},
        },
        attemptId: 'example',
        context: {},
      );
      for (var i = 1; i <= 26; i++) {
        engine.observe(
          at: i.toDouble(),
          sampleAt: i.toDouble(),
          features: {'attention': 40, 'relax': 40},
          good: true,
        );
      }
      expect(engine.state, 'deviation');
      engine.finish(27, 'user_completed');
      final snapshot = engine.snapshot(27),
          data = LearningTrend(engine.snapshot(27), engine.events);
      final marker = engine.events.firstWhere((e) => e['type'] == 'deviation');
      final observed = engine.events.firstWhere(
        (e) => e['type'] == 'state' && e['reason'] == 'candidate',
      );
      expect(
        data.candidateSeconds,
        (marker['elapsed'] as num) - (observed['elapsed'] as num),
      );
      expect(
        data.combinedDeviation,
        data.candidateSeconds! +
            ((snapshot['durations'] as Map)['deviation'] as num),
      );
      expect(data.candidateOriginsMissing, isFalse);
      expect(engine.state, 'deviation');
    },
  );
  test(
    'A pause inside an explicit candidate interval is not filled in as yellow',
    () {
      final data = LearningTrend(saved(), [
        {'type': 'pause', 'elapsed': 20, 'wallSeconds': 120},
        {
          'type': 'deviation',
          'elapsed': 30,
          'wallSeconds': 130,
          'candidateStartedWallSeconds': 110,
        },
      ]);
      expect(data.candidateSeconds, 0);
      expect(data.candidateOriginsMissing, isTrue);
    },
  );
  test(
    'Confirmed episode reattributes only its candidate period to yellow; canceled observations remain green',
    () {
      final original = saved();
      final d = LearningTrend(original, [
        {
          'type': 'state',
          'state': 'stable',
          'reason': 'candidate',
          'elapsed': 10,
          'wallSeconds': 110,
        },
        {
          'type': 'state',
          'state': 'deviation',
          'reason': 'attention_drop',
          'elapsed': 30,
          'wallSeconds': 130,
        },
        {
          'type': 'deviation',
          'elapsed': 30,
          'wallSeconds': 130,
          'candidateStartedWallSeconds': 110,
        },
        {
          'type': 'state',
          'state': 'stable',
          'reason': 'candidate',
          'elapsed': 60,
          'wallSeconds': 160,
        },
        {
          'type': 'state',
          'state': 'stable',
          'reason': 'within_reference',
          'elapsed': 65,
          'wallSeconds': 165,
        },
      ]);
      expect(d.candidateSeconds, 20);
      expect(d.combinedDeviation, 40);
      expect(d.durations['stable'], 50);
      expect(d.durations['deviation'], 20);
      expect(d.durations['unknown'], 10);
      expect(d.share('stable'), '50.0%');
      expect(d.share('candidate'), '20.0%');
      expect(d.share('combined'), '40.0%');
      expect(d.presentationStateAt(15), 'candidate');
      expect(d.presentationStateAt(35), 'deviation');
      expect(d.presentationStateAt(62), 'stable');
      expect(d.presentationStateAt(95), 'unknown');
      expect((original['durations'] as Map)['stable'], 70);
      expect(
        d.displaySpans.fold<double>(0, (sum, s) => sum + s.end - s.start),
        100,
      );
    },
  );
  test(
    'Explicit saved wall-clock start is usable; duplicate confirmation cannot double count',
    () {
      final e = {
        'type': 'deviation',
        'elapsed': 30,
        'wallSeconds': 230,
        'candidateStartedWallSeconds': 210,
      };
      final d = LearningTrend(saved(), [e, e]);
      expect(d.candidateSeconds, 20);
      expect(d.combinedDeviation, 40);
    },
  );
  test(
    'No confirmed episode means no yellow, and missing origins are never inferred from a threshold',
    () {
      final d = LearningTrend(saved(), [
        {
          'type': 'state',
          'state': 'stable',
          'reason': 'candidate',
          'elapsed': 10,
        },
      ]);
      expect(d.candidateSeconds, 0);
      expect(d.candidateOriginsMissing, isTrue);
      final missing = LearningTrend(saved(), [
        {'type': 'deviation', 'elapsed': 30},
      ]);
      expect(missing.candidateSeconds, 0);
      expect(missing.candidateOriginsMissing, isTrue);
      final empty = LearningTrend({
        ...saved(),
        'elapsed': 0,
        'durations': {'stable': 0, 'deviation': 0, 'unknown': 0},
        'timeline': [],
      }, []);
      expect(empty.share('combined'), '—');
    },
  );
}
