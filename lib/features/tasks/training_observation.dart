import 'dart:math' as math;
import 'signal_pipeline.dart';

/// Observe on the game clock, independently of baseline comparison eligibility.
/// A packet's receipt time never stretches a completed second into more data.
Map<String, dynamic>? trainingSample({
  required AnalysisWindow window,
  required double sampleAt,
  required double receivedAt,
  required double gameSeconds,
  required String attempt,
}) {
  if (![sampleAt, receivedAt, gameSeconds].every((v) => v.isFinite)) {
    return null;
  }
  final lag = receivedAt - sampleAt;
  final end = gameSeconds - lag;
  if (end <= 0 || lag < -.01) return null;
  final duration = math.min(end, math.max(0.0, window.end - window.start));
  final fresh = lag <= 2 && duration > 0 && duration <= 1;
  return {
    'curveSeconds': end,
    'observationKey': '$attempt:${window.end}',
    'observationDuration': fresh && window.observationGood ? duration : 0.0,
    'scores': fresh && window.observationGood
        ? window.observationFeatures
        : null,
    'quality': fresh
        ? window.observationReason ?? window.reason
        : 'stale_score',
    'stage': 'training',
    'comparisonAllowed': false,
    'scoreSource': 'sdk_completed_second_before_comparison_median',
  };
}

/// Preparation may take arbitrarily long; it is never part of the game plot.
/// Engine elapsed excludes pauses and uses the same clock as the game timer.
List<Map<String, dynamic>> trainingCurveEvents(
  List<Map<String, dynamic>> events,
) {
  final start = events.indexWhere((e) => e['type'] == 'game_start');
  return [
    for (final e in events.skip(start < 0 ? 0 : start))
      {...e, 'curveSeconds': e['curveSeconds'] ?? e['elapsed'] ?? 0.0},
  ];
}

Map<String, dynamic> trainingObservation(List<Map<String, dynamic>> events) {
  final unique = <Object, Map<String, dynamic>>{};
  for (final event in events.where((e) => e['type'] == 'sample')) {
    final scores = event['scores'];
    final time = event['sampleAt'] ?? event['wallSeconds'];
    final key =
        event['observationKey'] ??
        (time is num && time.isFinite ? time.floor() : null);
    final duration = (event['observationDuration'] as num?)?.toDouble() ?? 1.0;
    if (key == null || !duration.isFinite || duration <= 0 || duration > 1) {
      continue;
    }
    if (scores is Map &&
        ['attention', 'relax'].every(
          (k) =>
              scores[k] is num &&
              (scores[k] as num).isFinite &&
              (scores[k] as num) >= 0 &&
              (scores[k] as num) <= 100,
        )) {
      unique[key] = {'scores': scores, 'duration': duration};
    }
  }
  final seconds = unique.values.fold<double>(
    0,
    (v, s) => v + (s['duration'] as double),
  );
  Map<String, double>? statistics(String key) {
    if (seconds == 0) return null;
    final mean =
        unique.values.fold<double>(
          0,
          (v, s) =>
              v +
              (s['scores'][key] as num).toDouble() * (s['duration'] as double),
        ) /
        seconds;
    return {
      'mean': mean,
      'sd': math.sqrt(
        unique.values.fold<double>(
              0,
              (v, s) =>
                  v +
                  math.pow((s['scores'][key] as num) - mean, 2) *
                      (s['duration'] as double),
            ) /
            seconds,
      ),
    };
  }

  return {
    'validSeconds': seconds,
    'attention': statistics('attention'),
    'relax': statistics('relax'),
  };
}
