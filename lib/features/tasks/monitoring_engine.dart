import 'dart:math' as math;
import 'baseline_features.dart';
import 'scene_protocol.dart';

const monitoringVersion = 'sdk-personal-monitor-v2';

/// Engineering defaults, recorded per task, not a clinically validated classifier.
class MonitoringRules {
  const MonitoringRules({this.scene = TaskScene.learning});
  final TaskScene scene;
  double get sustained => scene.deviationSeconds.toDouble();
  double get recoverySeconds => scene.recoverySeconds.toDouble();
  double get cooldown => 0;
  double get freshness => 2;
  double get longPause => 60;
  Map<String, dynamic> toMap() => {
    'version': monitoringVersion,
    'sustainedSeconds': sustained,
    'recoverySeconds': recoverySeconds,
    'protocol': scene.toMap(),
    'cooldownSeconds': cooldown,
    'freshnessSeconds': freshness,
    'longPauseSeconds': longPause,
    'drop': 'max(1 baseline standard deviation, 5 SDK points)',
    'recovery': 'max(0.5 baseline standard deviation, 3 SDK points)',
    'relaxation': 'independent reference, not the inverse of attention',
    'evidence': 'engineering defaults pending device/behavior validation',
  };
}

class MonitoringEngine {
  MonitoringEngine({
    required this.targetSeconds,
    required double at,
    required Map<String, dynamic> reference,
    required this.attemptId,
    required this.context,
    this.reminders = false,
    this.prepared = false,
    this.referenceOrigin = const {},
    this.rules = const MonitoringRules(),
  }) : _reference = reference,
       _origin = at,
       _last = at {
    _stageStartedAt = at;
    _validateReference(reference);
    if (referenceOrigin.isNotEmpty) {
      _lockedReference = Map<String, dynamic>.unmodifiable({
        for (final e in reference.entries)
          e.key: Map<String, dynamic>.unmodifiable(
            Map<String, dynamic>.from(e.value as Map),
          ),
      });
      _reference = _lockedReference!;
    }
    if (!at.isFinite || targetSeconds < 0 || targetSeconds > 10800) {
      throw ArgumentError('Invalid monitoring target');
    }
    if (prepared) {
      phase = 'preparing';
      reason = 'preparing_data';
    }
    _event(prepared ? 'prepared' : 'start', at);
  }
  final bool prepared;
  Map<String, dynamic> referenceOrigin;
  final int targetSeconds;
  final MonitoringRules rules;
  Map<String, dynamic> context;
  Map<String, dynamic> _reference;
  Map<String, dynamic>? _lockedReference;
  Map<String, dynamic> get reference => _reference;
  String attemptId;
  final double _origin;
  double _last, _evidenceUntil = -1, _candidateSeconds = 0;
  bool _candidate = false, _episodeNotified = false;
  double _recoverySeconds = 0;
  double? _lastSampleAt, _candidateStartedAt;
  int currentKeep = 0, longestKeep = 0;
  String stage = 'study';
  bool comparisonAllowed = true, stageSilenced = false;
  final List<Map<String, dynamic>> comparisonWindow = [];
  double recoveryActivitySeconds = 0;
  int _relaxCount = 0, _relaxCandidate = 0;
  String relaxDirection = 'near';
  double _stageStartedAt = 0;
  Map<String, dynamic> recoveryInfo = {};
  Map<String, dynamic> gameInfo = {};

  double? _checkStarted;
  int _checkValid = 0, _checkKeep = 0;
  final List<double> _deviationEntries = [];
  String? checkResult;
  void recordEvent(
    String type,
    double at, [
    Map<String, dynamic> extra = const {},
  ]) => _event(type, at, extra);
  void changeStage(
    String next,
    double at, {
    required bool allowed,
    bool silenced = false,
  }) {
    advance(at);
    final stageChanged = stage != next;
    if (stageChanged) {
      _event('stage_summary', at, {
        'stage': stage,
        'longestKeepSeconds': longestKeep,
      });
      _stageStartedAt = at;
    }
    stage = next;
    comparisonAllowed = allowed;
    stageSilenced = silenced;
    _clearEvidence();
    comparisonWindow.clear();
    longestKeep = 0;
    _setState('unknown', allowed ? 'waiting' : 'unsupported_stage', at);
    if (stageChanged) _checkStarted = null;
    _event('stage', at, {
      'stage': next,
      'comparisonAllowed': allowed,
      'silenced': silenced,
    });
  }

  void beginRecovery(double at, Map<String, dynamic> info) {
    advance(at);
    if (finished) return;
    phase = 'recovery';
    _clearEvidence();
    state = 'unknown';
    reason = 'recovery';
    recoveryInfo = Map.from(info);
    _event('recovery_start', at, info);
  }

  void endRecovery(
    double at,
    Map<String, dynamic> info, {
    bool beginCheck = true,
  }) {
    advance(at);
    if (finished) return;
    phase = 'running';
    _clearEvidence();
    state = 'unknown';
    reason = 'waiting';
    _checkStarted = beginCheck ? at : null;
    _checkValid = 0;
    _checkKeep = 0;
    checkResult = null;
    recoveryInfo = Map.from(info);
    _event('recovery_end', at, info);
  }

  void _check(double at, bool valid, bool keep) {
    if (_checkStarted == null) return;
    if (valid) _checkValid++;
    _checkKeep = valid && keep ? _checkKeep + 1 : 0;
    if (_checkKeep >= rules.recoverySeconds) {
      checkResult = 'returned';
    } else if (_checkValid >= 60) {
      checkResult = 'not_observed';
    } else if (at - _checkStarted! >= 120) {
      checkResult = 'insufficient';
    }
    if (checkResult != null) {
      _event('recheck', at, {
        'result': checkResult,
        'validSeconds': _checkValid,
      });
      _checkStarted = null;
    }
  }

  bool reminders;
  String phase = 'running',
      state = 'unknown',
      reason = 'waiting',
      endReason = '';
  double elapsed = 0, validSeconds = 0, pauseSeconds = 0, rebuildSeconds = 0;
  double? _pausedAt;
  Map<String, double>? scores;
  int remindersRequested = 0;
  final List<Map<String, dynamic>> events = [], timeline = [];
  final Map<String, double> durations = {
    'stable': 0,
    'deviation': 0,
    'unknown': 0,
  };
  bool get openEnded => targetSeconds == 0;
  double get remaining =>
      openEnded ? double.infinity : math.max(0.0, targetSeconds - elapsed);
  bool get finished => phase == 'finished';
  int get sequence => events.length;
  double get drop => math.max(
    math.sqrt(((reference['attention'] as Map)['variance'] as num).toDouble()),
    5,
  );
  double get recovery => math.max(
    math.sqrt(((reference['attention'] as Map)['variance'] as num).toDouble()) *
        .5,
    3,
  );
  double get attentionMean =>
      ((reference['attention'] as Map)['mean'] as num).toDouble();
  static void _validateReference(Map<String, dynamic> value) {
    for (final key in referenceMetricKeys) {
      final entry = value[key];
      if (entry is! Map ||
          entry['mean'] is! num ||
          entry['variance'] is! num ||
          !(entry['mean'] as num).isFinite ||
          !(entry['variance'] as num).isFinite ||
          (entry['mean'] as num) < 0 ||
          (entry['mean'] as num) > 100 ||
          (entry['variance'] as num) < minimumReferenceVariance) {
        throw ArgumentError('Invalid personal reference');
      }
    }
  }

  void _event(
    String type,
    double at, [
    Map<String, dynamic> extra = const {},
  ]) => events.add({
    'sequence': events.length + 1,
    'type': type,
    'elapsed': elapsed,
    'wallSeconds': math.max(0.0, at - _origin),
    'attempt': attemptId,
    ...extra,
  });
  void _setState(String next, String why, double at) {
    if (state != next || reason != why) {
      _event('state', at, {'state': next, 'reason': why});
    }
    state = next;
    reason = why;
  }

  void _segment(String status, double seconds) {
    if (seconds <= 0) return;
    durations[status] = durations[status]! + seconds;
    if (timeline.isNotEmpty &&
        timeline.last['state'] == status &&
        timeline.last['attempt'] == attemptId) {
      timeline.last['end'] = elapsed + seconds;
    } else {
      timeline.add({
        'start': elapsed,
        'end': elapsed + seconds,
        'state': status,
        'attempt': attemptId,
      });
    }
    elapsed += seconds;
  }

  void advance(double at) {
    if (!at.isFinite || at < _last || finished) return;
    final dt = at - _last;
    comparisonWindow.removeWhere((v) => at - (v['at'] as double) >= 30);
    if (phase == 'recovery') {
      final counted = rules.scene == TaskScene.recovery
          ? math.min(dt, remaining)
          : dt;
      recoveryActivitySeconds += counted;
      if (rules.scene == TaskScene.recovery) {
        _segment('unknown', counted);
      }
      _last = at;
      if (!openEnded && remaining <= 1e-6) _finish(at, 'target_reached');
      return;
    }
    if (phase == 'paused') {
      pauseSeconds += dt;
      _last = at;
      return;
    }
    if (phase == 'rebuilding') {
      rebuildSeconds += dt;
      _last = at;
      return;
    }
    if (phase != 'running') {
      _last = at;
      return;
    }
    final interval = math.min(dt, remaining);
    final known = math.min(interval, math.max(0.0, _evidenceUntil - _last));
    if (known > 0) {
      validSeconds += known;
      _segment(state == 'deviation' ? 'deviation' : 'stable', known);
    }
    if (interval > known) {
      _clearEvidence();
      _checkKeep = 0;
      _setState(
        'unknown',
        comparisonAllowed ? 'data' : 'unsupported_stage',
        _last + known,
      );
      _segment('unknown', interval - known);
    }
    if (_checkStarted != null && at - _checkStarted! >= 120) {
      _check(at, false, false);
    }
    _last = at;
    if (remaining <= 1e-6) {
      _finish(at, 'target_reached');
      return;
    }
    _maybeReminder(at);
  }

  void _maybeReminder(double at) {
    if (phase != 'running' || state != 'deviation' || _episodeNotified) return;
    // Decide exactly once at entry: suppressed episodes are never sent late.
    _episodeNotified = true;
    final delivery = !reminders
        ? 'disabled'
        : stageSilenced
        ? 'stage_silence'
        : 'pending';
    if (delivery == 'pending') {
      remindersRequested++;
    }
    _event('reminder', at, {
      'delivery': delivery,
      'candidateSeconds': _candidateSeconds,
      'scores': scores,
      'baselineAttention': attentionMean,
      'drop': drop,
      'rules': rules.toMap(),
    });
  }

  void observe({
    required double at,
    required double sampleAt,
    required Map<String, double>? features,
    required bool good,
    String why = 'quality',
  }) {
    advance(at);
    if (phase != 'running') return;
    if (!good ||
        !validReferenceFeatures(features) ||
        !sampleAt.isFinite ||
        sampleAt > at + .01 ||
        at - sampleAt > rules.freshness) {
      block(at, why);
      return;
    }
    if (!comparisonAllowed) {
      block(at, 'unsupported_stage');
      return;
    }
    if (_lastSampleAt != null && sampleAt.floor() <= _lastSampleAt!.floor()) {
      return;
    }
    if (_lastSampleAt != null && sampleAt - _lastSampleAt! > 1.5) {
      _clearEvidence();
      _setState('unknown', 'gap', at);
    }
    _lastSampleAt = sampleAt;
    scores = Map.from(features!);
    final r = reference['relax'] as Map,
        delta = features['relax']! - (r['mean'] as num),
        band = math.max(math.sqrt((r['variance'] as num).toDouble()), 5);
    final direction = delta >= band
        ? 1
        : delta <= -band
        ? -1
        : 0;
    _relaxCount = direction == _relaxCandidate ? _relaxCount + 1 : 1;
    _relaxCandidate = direction;
    relaxDirection = direction == 0
        ? 'near'
        : _relaxCount >= 5
        ? (direction > 0 ? 'above' : 'below')
        : 'observing';
    _evidenceUntil = sampleAt + rules.freshness;
    final a = features['attention']!, keep = a >= attentionMean - recovery;
    currentKeep = keep ? currentKeep + 1 : 0;
    longestKeep = math.max(longestKeep, currentKeep);
    comparisonWindow.add({
      'at': sampleAt,
      'keep': keep,
      'low': a <= attentionMean - drop,
    });
    comparisonWindow.removeWhere((v) => sampleAt - (v['at'] as double) >= 30);
    if (state == 'deviation') {
      _recoverySeconds = keep ? _recoverySeconds + 1 : 0;
      if (_recoverySeconds >= rules.recoverySeconds) {
        _candidate = false;
        _candidateSeconds = 0;
        _episodeNotified = false;
        _recoverySeconds = 0;
        _setState('stable', 'recovered', at);
        _event('recovery', at, {'confirmedAt': at});
      } else if (keep) {
        reason = 'recovering';
      } else {
        reason = 'attention_drop';
      }
    } else if (_candidate) {
      if (keep) {
        _candidate = false;
        _candidateSeconds = 0;
        _setState('stable', 'within_reference', at);
      } else {
        _candidateSeconds++;
      }
    } else if (a <= attentionMean - drop) {
      _candidate = true;
      _candidateSeconds = 1;
      _candidateStartedAt = at;
      _episodeNotified = false;
      _setState('stable', 'candidate', at);
    } else {
      _setState('stable', 'within_reference', at);
    }
    if (_candidate &&
        state != 'deviation' &&
        _candidateSeconds >= rules.sustained) {
      _setState('deviation', 'attention_drop', at);
      _event('deviation', at, {
        'candidateStartedAt': _candidateStartedAt,
        'candidateStartedWallSeconds': _candidateStartedAt == null
            ? null
            : _candidateStartedAt! - _origin,
        'confirmedAt': at,
        'scores': scores,
      });
      _deviationEntries.add(elapsed);
      _deviationEntries.removeWhere((v) => elapsed - v > 300);
      if (_deviationEntries.length >= 3 && rules.scene == TaskScene.learning) {
        _event('repeated_deviation', at);
      }
      _maybeReminder(at);
    }
    _check(at, true, keep);
    _event('sample', at, {
      'scores': scores,
      'sampleAt': sampleAt,
      'stage': stage,
      'attentionDelta': a - attentionMean,
      'relaxDelta':
          features['relax']! - ((reference['relax'] as Map)['mean'] as num),
    });
  }

  void block(double at, String why) {
    advance(at);
    if (phase != 'running') return;
    _clearEvidence();
    _check(at, false, false);
    _setState('unknown', why, at);
  }

  void pause(double at) {
    advance(at);
    if (phase != 'running' && phase != 'recovery') return;
    phase = 'paused';
    _pausedAt = at;
    _checkStarted = null;
    _clearEvidence();
    _event('pause', at);
    state = 'unknown';
    reason = 'paused';
  }

  bool needsBaseline(double at) =>
      phase == 'interrupted' ||
      phase == 'rebuilding' ||
      (_pausedAt != null && at - _pausedAt! >= rules.longPause);
  void interrupt(double at, String why, {bool accountTime = true}) {
    if (accountTime) {
      advance(at);
    } else {
      _last = at;
    }
    if (finished || phase == 'interrupted') return;
    _checkStarted = null;
    phase = 'interrupted';
    state = 'unknown';
    reason = why;
    _clearEvidence();
    _event('interruption', at, {'reason': why});
  }

  void rebuild(double at, {bool reuseReference = false}) {
    advance(at);
    if (finished) return;
    phase = 'rebuilding';
    state = 'unknown';
    reason = reuseReference ? 'preparing_data' : 'rebaseline';
    _clearEvidence();
    _event(reuseReference ? 'prepare_data' : 'rebaseline', at);
  }

  void resume(
    double at,
    Map<String, dynamic> nextReference,
    String nextAttempt, {
    Map<String, dynamic>? nextContext,
  }) {
    advance(at);
    if (finished) return;
    if (needsBaseline(at) && nextAttempt == attemptId) {
      throw StateError('需要重新建立基线');
    }
    final firstStart = phase == 'preparing';
    _validateReference(nextReference);
    if (_lockedReference != null) {
      for (final key in referenceMetricKeys) {
        final before = _lockedReference![key] as Map,
            after = nextReference[key] as Map;
        if (before.length != after.length ||
            before.keys.any((k) => before[k] != after[k])) {
          throw StateError('学习会话已锁定原基线，不能更换或重算。');
        }
      }
    }
    if (nextContext != null) context = nextContext;
    _reference = _lockedReference ?? nextReference;
    attemptId = nextAttempt;
    phase = 'running';
    state = 'unknown';
    reason = 'waiting';
    _pausedAt = null;
    _last = at;
    _clearEvidence();
    _event(firstStart ? 'start' : 'resume', at, {'stage': stage});
  }

  void reanchor(double at) {
    if (at.isFinite && at >= _last) _last = at;
  }

  void _clearEvidence() {
    _evidenceUntil = -1;
    _recoverySeconds = 0;
    _relaxCount = 0;
    _relaxCandidate = 0;
    relaxDirection = 'unknown';
    currentKeep = 0;
    _lastSampleAt = null;
    _candidate = false;
    _candidateSeconds = 0;
    _episodeNotified = false;
    scores = null;
  }

  void setReminders(bool value, double at) {
    advance(at);
    if (reminders == value || finished) return;
    reminders = value;
    _event('reminders', at, {'enabled': value});
  }

  void adjustment(String kind, double at) {
    advance(at);
    if (!finished) _event('adjustment', at, {'kind': kind});
  }

  void finish(double at, String why) {
    advance(at);
    if (!finished) _finish(at, why);
  }

  void _finish(double at, String why) {
    if (finished) return;
    // advance calls finish at the deadline; do not recursively advance here.
    phase = 'finished';
    endReason = why;
    _clearEvidence();
    _event('finish', at, {'reason': why});
  }

  Map<String, dynamic> snapshot(double at) => {
    'version': monitoringVersion,
    'scene': rules.scene.name,
    'stage': stage,
    'comparisonAllowed': comparisonAllowed,
    'currentKeepSeconds': currentKeep,
    'longestKeepSeconds': longestKeep,
    'candidateSeconds': _candidateSeconds,
    'recoveryConsecutiveSeconds': _recoverySeconds,
    'recoveryActivitySeconds': recoveryActivitySeconds,
    'recoveryTeaching': recoveryInfo,
    'game': gameInfo,
    'relaxDirection': relaxDirection,
    'comparisonWindow': {
      'seconds': 30,
      'validSeconds': comparisonWindow.length,
      'keepRatio': at - _stageStartedAt >= 30 && comparisonWindow.length >= 21
          ? comparisonWindow.where((v) => v['keep'] == true).length /
                comparisonWindow.length
          : null,
      'lowRatio': at - _stageStartedAt >= 30 && comparisonWindow.length >= 21
          ? comparisonWindow.where((v) => v['low'] == true).length /
                comparisonWindow.length
          : null,
    },
    'recheckResult': checkResult,
    'algorithm': baselineAlgorithmVersion,
    'phase': phase,
    'state': state,
    'reason': reason,
    'endReason': endReason,
    'targetSeconds': targetSeconds,
    'openEnded': openEnded,
    'elapsed': elapsed,
    'validSeconds': validSeconds,
    'validRatio': elapsed > 0 ? validSeconds / elapsed : null,
    'durations': Map.from(durations),
    'pauseSeconds': pauseSeconds,
    'pauseStartedWallSeconds': _pausedAt == null ? null : _pausedAt! - _origin,
    'rebuildSeconds': rebuildSeconds,
    'wallSeconds': math.max(0.0, at - _origin),
    'remindersEnabled': reminders,
    'remindersRequested': remindersRequested,
    'eventSequence': sequence,
    'referenceAttempt': attemptId,
    'reference': reference,
    'referenceOrigin': referenceOrigin,
    'context': context,
    'rules': rules.toMap(),
    'timeline': [for (final item in timeline) Map<String, dynamic>.from(item)],
  };
}
