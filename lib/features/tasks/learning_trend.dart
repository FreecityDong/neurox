import 'report_insights.dart';
import 'dart:math' as math;
import 'detail_widgets.dart';

class LearningPoint {
  const LearningPoint(this.time, this.value);
  final double time;
  final double? value;
}

class LearningSpan {
  const LearningSpan(this.start, this.end, this.state);
  final double start, end;
  final String state;
}

/// Read the saved task clock and classifier timeline. Never classify scores again.
class LearningTrend {
  LearningTrend(this.summary, this.events) {
    final byTime = <double, LearningPoint>{};
    for (final e in events) {
      if (e['type'] != 'sample') continue;
      final at = e['elapsed'];
      if (at is! num || !at.isFinite || at < 0 || at > total) continue;
      final score = detailMap(e['scores'])['attention'];
      byTime[at.toDouble()] = LearningPoint(
        at.toDouble(),
        score is num && score.isFinite && score >= 0 && score <= 100
            ? score.toDouble()
            : null,
      );
    }
    points = byTime.values.toList()..sort((a, b) => a.time.compareTo(b.time));
    final raw = summary['timeline'];
    if (raw is List) {
      for (final item in raw) {
        final m = detailMap(item),
            a = detailMap(item)['start'],
            b = detailMap(item)['end'];
        if (a is! num ||
            b is! num ||
            !a.isFinite ||
            !b.isFinite ||
            a < 0 ||
            b <= a ||
            b > total + .01 ||
            !['stable', 'deviation', 'unknown'].contains(m['state'])) {
          continue;
        }
        spans.add(
          LearningSpan(
            a.toDouble(),
            math.min(total, b.toDouble()),
            m['state'] as String,
          ),
        );
      }
    }
    spans.sort((a, b) => a.start.compareTo(b.start));
    final sums = {'stable': 0.0, 'deviation': 0.0, 'unknown': 0.0};
    var end = 0.0;
    var valid = total > 0 && spans.isNotEmpty;
    for (final s in spans) {
      if ((s.start - end).abs() > .01) valid = false;
      end = s.end;
      sums[s.state] = sums[s.state]! + s.end - s.start;
    }
    timelineComplete =
        valid &&
        (end - total).abs() <= .01 &&
        sums.keys.every(
          (k) =>
              number(savedDurations[k]) != null &&
              (sums[k]! - number(savedDurations[k])!).abs() < .1,
        );
    // Malformed/overlapping timelines must not paint contradictory intervals.
    if (!timelineComplete) spans.clear();
    _derivePresentation(events);
  }
  final Map<String, dynamic> summary;
  final List<Map<String, dynamic>> events;
  late final List<LearningPoint> points;
  final List<LearningSpan> spans = [];
  late final bool timelineComplete;
  final List<LearningSpan> displaySpans = [];
  bool candidateOriginsMissing = false;

  void _derivePresentation(List<Map<String, dynamic>> events) {
    if (!timelineComplete) return;
    final candidates = <LearningSpan>[];
    double? pending;
    var confirmedCount = 0;
    for (final event in events) {
      final type = event['type'];
      if (type == 'state') {
        if (event['state'] == 'stable' && event['reason'] == 'candidate') {
          pending = number(event['elapsed']);
        } else if (event['state'] == 'unknown' || event['state'] == 'stable') {
          pending = null;
        }
      }
      if ([
        'pause',
        'interruption',
        'stage',
        'recovery_start',
        'data_unavailable',
      ].contains(type)) {
        pending = null;
      }
      if (type != 'deviation') continue;
      confirmedCount++;
      final end = number(event['elapsed']);
      var start = pending;
      final wall = number(event['wallSeconds']),
          candidateWall = number(event['candidateStartedWallSeconds']);
      if (end != null &&
          wall != null &&
          candidateWall != null &&
          wall >= candidateWall) {
        final blocked = events.any((e) {
          final at = number(e['wallSeconds']);
          if (at == null || at < candidateWall || at >= wall) return false;
          return [
                'pause',
                'interruption',
                'stage',
                'recovery_start',
                'data_unavailable',
              ].contains(e['type']) ||
              e['type'] == 'state' &&
                  (e['state'] == 'unknown' ||
                      e['state'] == 'stable' && e['reason'] != 'candidate');
        });
        start = blocked ? null : end - (wall - candidateWall);
      }
      if (start != null &&
          end != null &&
          start >= 0 &&
          end <= total + .01 &&
          end > start) {
        final covered = spans
            .where((s) => s.state == 'stable')
            .fold<double>(
              0,
              (sum, s) =>
                  sum +
                  math.max(0, math.min(end, s.end) - math.max(start!, s.start)),
            );
        if ((covered - (end - start)).abs() < .05) {
          candidates.add(
            LearningSpan(start, math.min(end, total), 'candidate'),
          );
        } else {
          candidateOriginsMissing = true;
        }
      } else {
        candidateOriginsMissing = true;
      }
      pending = null;
    }
    if (confirmedCount == 0 && spans.any((s) => s.state == 'deviation')) {
      candidateOriginsMissing = true;
    }
    for (final span in spans) {
      if (span.state != 'stable') {
        displaySpans.add(span);
        continue;
      }
      final cuts = <double>{span.start, span.end};
      for (final c in candidates) {
        if (c.start > span.start && c.start < span.end) cuts.add(c.start);
        if (c.end > span.start && c.end < span.end) cuts.add(c.end);
      }
      final sorted = cuts.toList()..sort();
      for (var i = 1; i < sorted.length; i++) {
        final middle = (sorted[i - 1] + sorted[i]) / 2;
        displaySpans.add(
          LearningSpan(
            sorted[i - 1],
            sorted[i],
            candidates.any((c) => middle >= c.start && middle < c.end)
                ? 'candidate'
                : 'stable',
          ),
        );
      }
    }
  }

  double? get candidateSeconds => timelineComplete
      ? displaySpans
            .where((s) => s.state == 'candidate')
            .fold<double>(0, (sum, s) => sum + s.end - s.start)
      : null;
  double? get combinedDeviation {
    final red = number(savedDurations['deviation']), yellow = candidateSeconds;
    return red != null && yellow != null ? red + yellow : null;
  }

  String presentationStateAt(double at) {
    for (final s in displaySpans) {
      if (at >= s.start && (at < s.end || at == total && at == s.end)) {
        return s.state;
      }
    }
    return 'unknown';
  }

  static double? number(Object? v) =>
      v is num && v.isFinite ? v.toDouble() : null;
  double get total => math.max(0, number(summary['elapsed']) ?? 0);
  Map<String, dynamic> get savedDurations => detailMap(summary['durations']);
  Map<String, dynamic> get durations {
    final raw = savedDurations,
        yellow = candidateSeconds,
        stable = number(savedDurations['stable']);
    return {
      ...raw,
      'stable': stable != null && yellow != null
          ? math.max(0, stable - yellow)
          : null,
      'candidate': yellow,
    };
  }

  Map<String, dynamic> get reference =>
      detailMap(detailMap(summary['reference'])['attention']);
  double? get mean => number(reference['mean']);
  double? get sd {
    final v = number(reference['variance']);
    return v != null && v >= 0 ? math.sqrt(v) : null;
  }

  double? get lower => mean != null && sd != null ? mean! - sd! : null;
  double? get upper => mean != null && sd != null ? mean! + sd! : null;
  String stateAt(double at) {
    for (final s in spans) {
      if (at >= s.start && (at < s.end || at == total && at == s.end)) {
        return s.state;
      }
    }
    return 'unknown';
  }

  LearningPoint at(double requested) {
    LearningPoint? selected;
    var distance = double.infinity;
    for (final p in points) {
      final d = (p.time - requested).abs();
      if (d < distance) {
        distance = d;
        selected = p;
      }
    }
    return distance <= .75 ? selected! : LearningPoint(requested, null);
  }

  double? get trendDelta {
    if (!timelineComplete || total < 30) return null;
    double? part(double a, double b) {
      var weight = 0.0, sum = 0.0, previous = 0.0;
      for (final p in points) {
        final start = math.max(previous, p.time - 1);
        previous = p.time;
        if (p.value == null ||
            stateAt(math.max(0, p.time - .001)) == 'unknown') {
          continue;
        }
        final w = math.max(0.0, math.min(b, p.time) - math.max(a, start));
        weight += w;
        sum += w * p.value!;
      }
      return weight >= 10 && weight >= (b - a) * .5 ? sum / weight : null;
    }

    final early = part(0, total / 3), late = part(total * 2 / 3, total);
    return early != null && late != null ? late - early : null;
  }

  String share(String key) => detailRatio(
    key == 'combined' ? combinedDeviation : durations[key],
    total,
  );

  List<String> get explanations => focusInsights(this);
  List<String> get statisticalNotes => focusNotes(this);
}
