import 'baseline_features.dart';
import 'detail_widgets.dart';
import 'learning_trend.dart';
import 'monitoring_engine.dart';
import 'scene_protocol.dart';

class ScenarioReplay {
  const ScenarioReplay(this.summary, this.events);
  final Map<String, dynamic> summary;
  final List<Map<String, dynamic>> events;
}

/// Offline replay of saved comparison metrics, never a new hardware capture.
ScenarioReplay buildScenarioReplay(
  Map<String, dynamic> source,
  TaskScene target,
) {
  final task = detailMap(source['task_json']),
      original = detailMap(source['monitor_json']);
  if (source['kind'] != 'task' ||
      source['task_state'] != 'task_complete' ||
      source['state'] != 'saved' ||
      task['scene'] != 'learning' ||
      task['isReplay'] == true ||
      !target.competitive ||
      original['algorithm'] != baselineAlgorithmVersion) {
    throw StateError(
      'Only a completed compatible learning task can be replayed.',
    );
  }
  final frozen = detailMap(source['baseline_json']);
  final reference = detailMap(original['reference'] ?? frozen['statistics']);
  final total = LearningTrend.number(original['elapsed']);
  if (total == null || total <= 0) throw StateError('No saved task time.');
  final sourceEvents = [
    for (final e in source['events'] as List? ?? [])
      detailMap((e as Map)['payload']),
  ];
  final quality = LearningTrend(original, sourceEvents);
  if (!quality.timelineComplete) {
    throw StateError('Saved quality intervals are incomplete.');
  }
  final engine = MonitoringEngine(
    targetSeconds: 0,
    at: 0,
    reference: reference,
    attemptId: 'test-replay',
    context: {...detailMap(original['context']), 'testReplay': true},
    referenceOrigin: detailMap(
      original['referenceOrigin'] ?? frozen['referenceOrigin'],
    ),
    rules: MonitoringRules(scene: target),
  );
  // Archery data contain no aiming/release evidence; replay only static preparation.
  engine.stage = target == TaskScene.esports
      ? 'match'
      : target == TaskScene.go
      ? 'thinking'
      : 'preparation';
  engine.recordEvent('stage', 0, {
    'stage': engine.stage,
    'comparisonAllowed': true,
    'testReplay': true,
  });
  final markers =
      <Map<String, dynamic>>[
        for (final s in quality.spans)
          if (s.state == 'unknown') {'at': s.start, 'block': true},
        for (final e in sourceEvents)
          if (e['type'] == 'sample' &&
              LearningTrend.number(e['elapsed']) != null)
            {'at': e['elapsed'], 'event': e},
      ]..sort((a, b) {
        final c = (a['at'] as num).compareTo(b['at'] as num);
        return c != 0
            ? c
            : a['block'] == true
            ? -1
            : b['block'] == true
            ? 1
            : 0;
      });
  var observed = 0;
  for (final marker in markers) {
    final at = (marker['at'] as num).toDouble();
    if (at < 0 || at > total) continue;
    if (marker['block'] == true) {
      engine.block(at, 'source_data_unavailable');
      continue;
    }
    final event = detailMap(marker['event']),
        scores = detailMap(event['scores']);
    final good =
        quality.stateAt(at) != 'unknown' &&
        validReferenceFeatures({
          for (final e in scores.entries)
            if (e.value is num) e.key: (e.value as num).toDouble(),
        });
    if (!good) {
      engine.block(at, 'source_data_unavailable');
      continue;
    }
    engine.observe(
      at: at,
      sampleAt: at,
      features: {
        for (final key in referenceMetricKeys)
          key: (scores[key] as num).toDouble(),
      },
      good: true,
    );
    observed++;
  }
  if (observed == 0) throw StateError('No comparable saved metrics.');
  engine.finish(total, 'replay_finished');
  // Classification may reject a saved point in an unknown-quality interval.
  // The displayed trace still retains every source sample, including nulls.
  final combined = <Map<String, dynamic>>[
    for (final event in engine.events)
      if (event['type'] != 'sample') {...event},
    for (final event in sourceEvents)
      if (event['type'] == 'sample' &&
          LearningTrend.number(event['elapsed']) != null &&
          (event['elapsed'] as num) >= 0 &&
          (event['elapsed'] as num) <= total)
        {
          ...event,
          'stage': engine.stage,
          'wallSeconds': event['elapsed'],
          'sampleAt': event['elapsed'],
          'replaySourceSequence': event['sequence'],
        },
  ];
  final ordered = combined.indexed.toList()
    ..sort((a, b) {
      final time = (a.$2['elapsed'] as num).compareTo(b.$2['elapsed'] as num);
      return time != 0 ? time : a.$1.compareTo(b.$1);
    });
  final events = <Map<String, dynamic>>[
    for (var i = 0; i < ordered.length; i++)
      {...ordered[i].$2, 'sequence': i + 1},
  ];
  final summary = engine.snapshot(total)
    ..addAll({
      'eventSequence': events.length,
      'isReplay': true,
      'replaySourceId': source['id'],
      'replayInput':
          'saved learning comparison metrics; not raw EEG or actual competition',
      'checkpointOnly': original['checkpointOnly'] == true,
    });
  return ScenarioReplay(summary, events);
}
