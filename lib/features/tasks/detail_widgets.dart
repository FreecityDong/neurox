import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';

Map<String, dynamic> detailMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  try {
    final decoded = jsonDecode(value as String);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  } catch (_) {
    return {};
  }
}

String detailNumber(Object? value, {int decimals = 1}) =>
    value is num && value.isFinite ? value.toStringAsFixed(decimals) : '—';
String detailTime(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return '—';
  final s = value.floor();
  final tail = '${s ~/ 60 % 60}'.padLeft(2, '0');
  return s >= 3600
      ? '${s ~/ 3600}:$tail:${(s % 60).toString().padLeft(2, '0')}'
      : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class DetailSection extends StatelessWidget {
  const DetailSection({super.key, required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    ),
  );
}

class DetailFacts extends StatelessWidget {
  const DetailFacts({super.key, required this.values});
  final List<(String, String)> values;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final two =
          box.maxWidth >= 280 &&
          MediaQuery.textScalerOf(context).scale(1) < 1.4;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final (label, value) in values)
            SizedBox(
              width: two ? (box.maxWidth - 16) / 2 : box.maxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(value, style: Theme.of(context).textTheme.titleSmall),
                ],
              ),
            ),
        ],
      );
    },
  );
}

/// Summarize saved stage events only. Never rerun a signal classifier.
List<Map<String, dynamic>> detailStages(
  Map<String, dynamic> summary,
  List<Map<String, dynamic>> events,
) {
  final result = <Map<String, dynamic>>[];
  for (final e in events) {
    if (e['type'] != 'stage_summary') continue;
    result.add({'stage': e['stage'], 'longest': e['longestKeepSeconds']});
  }
  if (summary['stage'] is String) {
    result.add({
      'stage': summary['stage'],
      'longest': summary['longestKeepSeconds'],
    });
  }
  return result;
}

/// Read saved transition times on the same active task clock as the curve.
List<Map<String, dynamic>> detailStageTimeline(
  Map<String, dynamic> summary,
  List<Map<String, dynamic>> events,
) {
  final result = <Map<String, dynamic>>[];
  String? current;
  String initial = switch (summary['scene']) {
    'esports' || 'go' || 'archery' => 'preparation',
    'training' => 'game',
    _ => 'study',
  };
  for (final e in events) {
    if (e['type'] == 'stage_summary' && e['stage'] is String) {
      initial = e['stage'] as String;
      break;
    }
  }
  double? at(Object? value) =>
      value is num &&
          value.isFinite &&
          value >= 0 &&
          (summary['elapsed'] is! num ||
              value <= (summary['elapsed'] as num) + .01)
      ? value.toDouble()
      : null;
  for (final e in events) {
    final type = e['type'];
    if (type == 'start') {
      current = e['stage'] as String? ?? initial;
      result.add({'type': 'stage', 'stage': current, 'at': at(e['elapsed'])});
    } else if (type == 'stage' && e['stage'] is String) {
      if (e['stage'] == current) continue;
      current = e['stage'] as String;
      result.add({'type': 'stage', 'stage': current, 'at': at(e['elapsed'])});
    } else if ([
      'pause',
      'prepare_data',
      'interruption',
      'resume',
      'finish',
    ].contains(type)) {
      if (type == 'finish' && current == 'ended') {
        continue;
      }
      result.add({'type': type, 'stage': current, 'at': at(e['elapsed'])});
    }
  }
  if (result.isNotEmpty) return result;
  // Legacy summaries contain exit times; each following stage begins at that boundary.
  final complete = detailEventsComplete(summary, events);
  double? previous = complete ? 0 : null;
  for (final e in events) {
    if (e['type'] != 'stage_summary') continue;
    result.add({'type': 'stage', 'stage': e['stage'], 'at': previous});
    previous = complete ? at(e['elapsed']) : null;
  }
  if (summary['stage'] is String) {
    result.add({'type': 'stage', 'stage': summary['stage'], 'at': previous});
  }
  return result;
}

bool detailEventsComplete(
  Map<String, dynamic> summary,
  List<Map<String, dynamic>> events,
) {
  if (summary['checkpointOnly'] == true ||
      events.isEmpty ||
      summary['eventSequence'] != events.length) {
    return false;
  }
  for (var i = 0; i < events.length; i++) {
    if (events[i]['sequence'] != i + 1) return false;
  }
  return true;
}

String detailLongest(
  Map<String, dynamic> summary,
  List<Map<String, dynamic>> events,
) {
  if (!detailEventsComplete(summary, events)) return '—';
  final values = detailStages(
    summary,
    events,
  ).map((e) => e['longest']).toList();
  if (values.isEmpty || values.any((v) => v is! num || !v.isFinite || v < 0)) {
    return '—';
  }
  return detailTime(values.cast<num>().reduce((a, b) => a > b ? a : b));
}

String detailRatio(Object? numerator, Object? denominator) {
  if (numerator is! num ||
      denominator is! num ||
      !numerator.isFinite ||
      !denominator.isFinite ||
      denominator <= 0 ||
      numerator < 0 ||
      numerator > denominator) {
    return '—';
  }
  return '${(100 * numerator / denominator).toStringAsFixed(1)}%';
}

/// Baseline quality rows describe transitions, not every rejected window.
/// This changes presentation only; saved windows and eligibility stay intact.
List<Map<String, dynamic>> baselineDetailEvents(List windows) {
  final events = <Map<String, dynamic>>[];
  String? previous;
  for (final raw in windows) {
    if (raw is! Map) continue;
    final window = detailMap(raw['payload']);
    final at = window['end'];
    if (at is! num || !at.isFinite || at < 0) continue;
    final observation = detailMap(window['observationFeatures']);
    final hasObservation =
        window['observationReason'] == 'good' && observation.isNotEmpty;
    final reason =
        (hasObservation
                ? window['observationReason']
                : window['quality'] ?? window['reason'])
            as String? ??
        'waiting';
    events.add({
      'type': 'sample',
      'wallSeconds': at,
      'scores': hasObservation ? observation : window['features'],
    });
    if (reason != previous) {
      events.add({'type': 'quality', 'wallSeconds': at, 'reason': reason});
      previous = reason;
    }
  }
  return events;
}

String detailDeviation(Map<String, dynamic> statistics) {
  final variance = statistics['variance'];
  if (variance is num && variance.isFinite && variance >= 0) {
    return detailNumber(math.sqrt(variance.toDouble()));
  }
  return detailNumber(statistics['standardDeviation']);
}
