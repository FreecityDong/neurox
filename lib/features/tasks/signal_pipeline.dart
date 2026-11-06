import 'dart:convert';
import '../../data/algorithms/recovered_eeg.dart';
import 'baseline_features.dart';
export 'baseline_features.dart';
import 'dart:collection';
import 'dart:math' as math;

/// Metadata retains its evidence and any explicitly accepted assumptions.
class SignalProfile {
  SignalProfile(this.values);
  final Map<String, dynamic> values;
  String get version => values['version'] as String? ?? 'unverified';
  double number(String key) => (values[key] as num?)?.toDouble() ?? double.nan;
  double get hz => number('sampleRate');
  String get unit => values['unit'] as String? ?? '';
  bool get provisional =>
      values['mode'] == 'raw_ratio_provisional' &&
      values['assumptionAccepted'] == true &&
      values['sampleRateAssumed'] == true &&
      values['verified'] != true &&
      hz == 512 &&
      number('scale') == 1 &&
      unit == 'SDK raw';
  bool get usable =>
      (values['verified'] == true || provisional) &&
      (values['evidence'] as String? ?? '').isNotEmpty &&
      unit.isNotEmpty &&
      hz.isFinite &&
      hz >= 128 &&
      hz <= 2048 &&
      [
        'scale',
        'flatStd',
        'maxPeakToPeak',
        'maxStep',
        'adcMin',
        'adcMax',
      ].every((k) => number(k).isFinite) &&
      number('scale') > 0 &&
      number('flatStd') > 0 &&
      number('maxPeakToPeak') > number('flatStd') &&
      number('maxStep') > 0 &&
      number('adcMin') < number('adcMax');
}

class AnalysisWindow {
  const AnalysisWindow({
    required this.sequence,
    required this.start,
    required this.end,
    required this.reason,
    this.features,
    this.observationFeatures,
    this.observationReason,
    this.source = const {},
  });
  final int sequence;
  final double start, end;
  final String reason;
  final Map<String, double>? features;
  // Fresh per-second SDK observation, before the comparison-only median.
  final Map<String, double>? observationFeatures;
  final String? observationReason;
  bool get observationGood =>
      observationReason == 'good' && observationFeatures != null;
  final Map<String, dynamic> source;
  bool get good => reason == 'good' && features != null;
  Map<String, dynamic> toMap() => {
    'sequence': sequence,
    'start': start,
    'end': end,
    'quality': reason,
    'features': features,
    'observationFeatures': observationFeatures,
    'observationReason': observationReason,
    'source': source,
  };
  factory AnalysisWindow.fromMap(Map<String, dynamic> map) => AnalysisWindow(
    sequence: map['sequence'] as int,
    start: (map['start'] as num).toDouble(),
    end: (map['end'] as num).toDouble(),
    reason: map['quality'] as String,
    source: Map<String, dynamic>.from(map['source'] as Map? ?? {}),
    observationReason: map['observationReason'] as String?,
    observationFeatures: (map['observationFeatures'] as Map?)?.map(
      (k, v) => MapEntry(k as String, (v as num).toDouble()),
    ),
    features: (map['features'] as Map?)?.map(
      (k, v) => MapEntry(k as String, (v as num).toDouble()),
    ),
  );
}

/// Density-scaled one-sided Welch PSD, periodic Hann, 50% segment overlap,
/// constant detrend. Bands use half-open boundaries so edges are not counted twice.
Map<String, double> welchBands(List<double> samples, double hz) {
  if (samples.length < 128 ||
      !hz.isFinite ||
      hz <= 80 ||
      samples.any((v) => !v.isFinite)) {
    throw ArgumentError('Invalid spectral input');
  }
  var n = 128;
  while (n * 2 <= hz && n * 2 <= samples.length) {
    n *= 2;
  }
  if (n > samples.length) throw ArgumentError('Insufficient samples');
  final psd = List<double>.filled(n ~/ 2 + 1, 0);
  var segments = 0;
  final hann = List.generate(n, (i) => .5 - .5 * math.cos(2 * math.pi * i / n));
  final energy = hann.fold<double>(0, (s, v) => s + v * v);
  for (var offset = 0; offset + n <= samples.length; offset += n ~/ 2) {
    final mean =
        samples.sublist(offset, offset + n).reduce((a, b) => a + b) / n;
    final real = List.generate(
      n,
      (i) => (samples[offset + i] - mean) * hann[i],
    );
    final imag = List<double>.filled(n, 0);
    _fft(real, imag);
    for (var k = 0; k < psd.length; k++) {
      final sided = k == 0 || k == n ~/ 2 ? 1 : 2;
      psd[k] += sided * (real[k] * real[k] + imag[k] * imag[k]) / (hz * energy);
    }
    segments++;
  }
  if (segments == 0) throw ArgumentError('Insufficient segments');
  double band(double low, double high) {
    var power = 0.0;
    for (var k = 0; k < psd.length; k++) {
      final f = k * hz / n;
      if (f >= low && f < high) power += psd[k] / segments * hz / n;
    }
    return power;
  }

  final total = band(1, 40);
  if (!total.isFinite || total <= 1e-20) {
    throw StateError('Degenerate spectrum');
  }
  return {
    'total': total,
    for (final b in [
      ('theta', 4.0, 8.0),
      ('alpha', 8.0, 13.0),
      ('beta', 13.0, 30.0),
    ])
      b.$1: band(b.$2, b.$3),
    for (final b in [
      ('theta', 4.0, 8.0),
      ('alpha', 8.0, 13.0),
      ('beta', 13.0, 30.0),
    ])
      '${b.$1}Relative': band(b.$2, b.$3) / total,
  };
}

void _fft(List<double> re, List<double> im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    while ((j & bit) != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      final r = re[i];
      re[i] = re[j];
      re[j] = r;
    }
  }
  for (var length = 2; length <= n; length <<= 1) {
    final angle = -2 * math.pi / length;
    for (var base = 0; base < n; base += length) {
      for (var k = 0; k < length ~/ 2; k++) {
        final a = base + k, b = a + length ~/ 2;
        final c = math.cos(angle * k), s = math.sin(angle * k);
        final r = re[b] * c - im[b] * s, v = re[b] * s + im[b] * c;
        re[b] = re[a] - r;
        im[b] = im[a] - v;
        re[a] += r;
        im[a] += v;
      }
    }
  }
}

/// Receives already parsed dual-channel SDK values. Uses observed host receive
/// coverage, not invented device timestamps. No result spans a detected gap.
class SignalPipeline {
  SignalPipeline(this.profile, {this.randomInteger}) {
    reset();
  }
  final SignalProfile profile;
  final int Function()? randomInteger;
  late RecoveredEegAlgorithms _sdk;
  Map<String, double>? _scores;
  int _sdkSamples = 0;
  void _resetSdk() {
    _sdk = RecoveredEegAlgorithms(
      randomInteger: randomInteger,
      computeAuxiliary: false,
    );
    _sdkSamples = 0;
    _scoreSamples = 0;
    _scoreAt = null;
    _scores = null;
  }

  final raw1 = ListQueue<double>(),
      raw2 = ListQueue<double>(),
      times = ListQueue<double>();
  final comparison = SecondScoreMedian();
  double? lastAt, _scoreAt;
  int sequence = 0, _scoreId = 0, _scoreSamples = 0;
  int _lastObservationScoreId = -1;
  int? _second;
  void reset() {
    _resetSdk();
    raw1.clear();
    raw2.clear();
    times.clear();
    comparison.reset();
    lastAt = null;
    _scoreAt = null;
    _second = null;
  }

  AnalysisWindow? push(List<double> a, List<double> b, double at) {
    AnalysisWindow invalid(String reason) => AnalysisWindow(
      sequence: ++sequence,
      start: at,
      end: at,
      reason: reason,
    );
    if (!profile.usable || profile.hz != 512) return invalid('metadata');
    if (!at.isFinite ||
        at < 0 ||
        a.length != b.length ||
        a.isEmpty ||
        a.length > 256 ||
        [...a, ...b].any((v) => !v.isFinite)) {
      reset();
      return invalid('invalid_input');
    }
    if (lastAt != null && (at <= lastAt! || at - lastAt! > .25)) {
      reset();
      lastAt = at;
      return invalid('gap');
    }
    // Close the previous whole second BEFORE adding this packet. A later SDK
    // result can never be assigned backwards to an already completed second.
    AnalysisWindow? closed;
    final second = at.floor();
    if (_second != null && second > _second!) {
      final end = (_second! + 1).toDouble();
      final rawQuality = _rawQuality(end);
      final reason = _quality(end, rawQuality);
      final observationGood =
          reason == 'good' &&
          _scoreAt != null &&
          end - _scoreAt! <= 1 &&
          _scoreAt! <= end &&
          _scoreId > _lastObservationScoreId;
      if (observationGood) _lastObservationScoreId = _scoreId;
      final value = comparison.add(
        end: end,
        scoreId: _scoreId,
        scores: _scores,
        good:
            reason == 'good' &&
            _scoreAt != null &&
            end - _scoreAt! <= 1 &&
            _scoreAt! <= end,
      );
      closed = AnalysisWindow(
        sequence: ++sequence,
        start: end - 1,
        end: end,
        reason: reason != 'good'
            ? reason
            : value == null
            ? 'comparison_warming'
            : 'good',
        features: value,
        observationFeatures: observationGood ? Map.from(_scores!) : null,
        observationReason: reason != 'good'
            ? reason
            : observationGood
            ? 'good'
            : 'stale_score',
        source: {
          'rawQuality': rawQuality,
          'clock': 'host monotonic completed seconds',
          'sdkEndSample': _scoreSamples,
          'nominalSdkEndSeconds': _scoreSamples / profile.hz,
          'nominalSampleRate': profile.hz,
          'sampleTimeOrigin':
              'most recent SDK reset; derived, not device timestamp',
          'sdkReceivedAt': _scoreAt,
        },
      );
      if (!['good', 'warming'].contains(reason)) _resetSdk();
    }
    _second = second;
    lastAt = at;
    final updates = _sdk.process(a, b)['updates'] as List;
    _sdkSamples += a.length;
    if (updates.isNotEmpty) {
      final scores = (updates.last as Map)['scores'] as Map;
      _scores = {
        for (final key in referenceMetricKeys)
          key: (scores[key] as num).toDouble(),
      };
      _scoreAt = at;
      _scoreSamples = (_sdkSamples ~/ 256) * 256;
      _scoreId++;
    }
    for (var i = 0; i < a.length; i++) {
      raw1.add(a[i]);
      raw2.add(b[i]);
      times.add(at);
    }
    final size = (4 * profile.hz).round();
    while (raw1.length > size) {
      raw1.removeFirst();
      raw2.removeFirst();
      times.removeFirst();
    }
    return closed;
  }

  String _quality(double end, String rawQuality) {
    if (_sdkSamples < (6 * profile.hz).round() ||
        raw1.length < (4 * profile.hz).round()) {
      return 'warming';
    }
    if (rawQuality != 'good') return rawQuality;
    return validReferenceFeatures(_scores) ? 'good' : 'sdk_score_invalid';
  }

  String _rawQuality(double end) {
    if (raw1.length < (4 * profile.hz).round() || times.isEmpty) {
      return 'warming';
    }
    if (end - times.last > .25 ||
        times.last - times.first < 3.2 ||
        times.last - times.first > 5) {
      return 'coverage';
    }
    for (final raw in [raw1, raw2]) {
      if (raw.any(
        (v) => v <= profile.number('adcMin') || v >= profile.number('adcMax'),
      )) {
        return profile.provisional ? 'raw_range' : 'saturation';
      }
      final values = raw.map((v) => v * profile.number('scale')).toList();
      final mean = values.reduce((a, b) => a + b) / values.length;
      final variance =
          values.fold<double>(0, (s, v) => s + (v - mean) * (v - mean)) /
          values.length;
      if (math.sqrt(variance) < profile.number('flatStd')) return 'flat';
      if (profile.provisional) continue;
      if (values.reduce(math.max) - values.reduce(math.min) >
          profile.number('maxPeakToPeak')) {
        return 'amplitude';
      }
      for (var i = 1; i < values.length; i++) {
        if ((values[i] - values[i - 1]).abs() > profile.number('maxStep')) {
          return 'step';
        }
      }
    }
    return 'good';
  }
}

/// One unique completed second per SDK update, never fills gaps or repeats.
class SecondScoreMedian {
  final _values = <Map<String, double>>[];
  double? _end;
  int _lastScoreId = -1;
  void reset() {
    _values.clear();
    _end = null;
    _lastScoreId = -1;
  }

  Map<String, double>? add({
    required double end,
    required int scoreId,
    required Map<String, double>? scores,
    required bool good,
  }) {
    if (!end.isFinite ||
        end != end.floorToDouble() ||
        (_end != null && end <= _end!)) {
      return null;
    }
    if (_end != null && end != _end! + 1) _values.clear();
    _end = end;
    if (!good || !validReferenceFeatures(scores) || scoreId <= _lastScoreId) {
      _values.clear();
      return null;
    }
    _lastScoreId = scoreId;
    _values.add(Map.from(scores!));
    if (_values.length > 5) _values.removeAt(0);
    if (_values.length < 5) return null;
    return {
      for (final key in referenceMetricKeys)
        key: ((_values.map((v) => v[key]!).toList()..sort())[2]),
    };
  }
}

/// One attempt only. A retry constructs a fresh instance and attempt ID.
class BaselineAccumulator {
  BaselineAccumulator({required this.attemptId, required this.context});
  BaselineAccumulator.fromSaved({
    required this.attemptId,
    required this.context,
    required Map<String, dynamic> snapshot,
  }) {
    _saved = Map<String, dynamic>.from(jsonDecode(jsonEncode(snapshot)) as Map);
    state = 'ready';
    reason = 'good';
    elapsed = (snapshot['elapsed'] as num?)?.toDouble() ?? 0;
    attemptElapsed = (snapshot['attemptElapsed'] as num?)?.toDouble() ?? 0;
    validSeconds = (snapshot['validSeconds'] as num?)?.toDouble() ?? 0;
  }
  Map<String, dynamic>? _saved;
  final String attemptId;
  final Map<String, dynamic> context;
  String state = 'collecting', reason = 'adapting';
  double elapsed = 0, attemptElapsed = 0, validSeconds = 0;
  double? readyAt;
  int windows = 0, _lastSequence = 0;
  final _seconds = <int>{};
  final _values = <Map<String, double>>[];
  final _means = <String, double>{}, _m2 = <String, double>{};
  double get progress => math
      .min(validSeconds / 60, elapsed / baselineMinimumSeconds)
      .clamp(0.0, 1.0);
  bool get adapting =>
      state == 'collecting' && attemptElapsed < baselineAdaptationSeconds;
  void advance(double seconds) {
    if (!seconds.isFinite ||
        seconds < attemptElapsed ||
        state != 'collecting') {
      return;
    }
    attemptElapsed = math.min(
      seconds,
      baselineAdaptationSeconds + baselineMaximumSeconds.toDouble(),
    );
    elapsed = math.max(0, attemptElapsed - baselineAdaptationSeconds);
    if (adapting) {
      reason = 'adapting';
      return;
    }
    _evaluate();
    // At exactly 190s allow the completed final second to arrive before failing.
    if (state == 'collecting' &&
        seconds > baselineAdaptationSeconds + baselineMaximumSeconds + .5) {
      state = 'failed';
    }
  }

  void add(AnalysisWindow w) {
    if (_saved != null ||
        state != 'collecting' ||
        w.sequence <= _lastSequence ||
        !w.end.isFinite ||
        !w.start.isFinite ||
        w.end > w.end.floorToDouble() ||
        w.end > attemptElapsed + .01 ||
        attemptElapsed - w.end > 2 ||
        w.end - w.start != 1 ||
        w.start < baselineAdaptationSeconds ||
        w.end > baselineAdaptationSeconds + baselineMaximumSeconds) {
      return;
    }
    _lastSequence = w.sequence;
    if (!w.good || !validReferenceFeatures(w.features)) {
      reason = w.good ? 'feature_schema' : w.reason;
      return;
    }
    if (!_seconds.add(w.end.toInt())) return;
    final value = {
      for (final key in referenceMetricKeys) key: w.features![key]!,
    };
    _values.add(value);
    validSeconds = _values.length.toDouble();
    windows++;
    for (final e in value.entries) {
      final old = _means[e.key] ?? 0, delta = e.value - old;
      final mean = old + delta / validSeconds;
      _means[e.key] = mean;
      _m2[e.key] = (_m2[e.key] ?? 0) + delta * (e.value - mean);
    }
    _evaluate();
    if (state == 'collecting' && elapsed >= baselineMaximumSeconds) {
      state = 'failed';
    }
  }

  void _evaluate() {
    if (elapsed < baselineMinimumSeconds) {
      reason = 'collecting';
      return;
    }
    if (validSeconds < 60 || validSeconds / elapsed < .7) {
      reason = 'insufficient';
      return;
    }
    if (referenceMetricKeys.any((k) => math.sqrt(variance(k)) > 20)) {
      reason = 'unstable';
      return;
    }
    if (referenceMetricKeys.any((k) => drift(k) > 10)) {
      reason = 'drift';
      return;
    }
    if ((_means['attention'] ?? 0) <=
        math.max(math.sqrt(variance('attention')), 5)) {
      reason = 'floor';
      return;
    }
    state = 'ready';
    reason = 'good';
    readyAt = attemptElapsed;
  }

  double variance(String key) => _saved != null
      ? (((_saved!['statistics'] as Map)[key] as Map)['variance'] as num)
            .toDouble()
      : validSeconds > 0
      ? math.max(0, (_m2[key] ?? 0) / validSeconds)
      : 0;
  double drift(String key) {
    if (_saved != null) {
      return (((_saved!['statistics'] as Map)[key] as Map)['drift'] as num?)
              ?.toDouble() ??
          0;
    }
    if (_values.length < 60) return 0;
    double average(Iterable<Map<String, double>> rows) =>
        rows.fold<double>(0, (s, v) => s + v[key]!) / 30;
    return (average(_values.take(30)) -
            average(_values.skip(_values.length - 30)))
        .abs();
  }

  void invalidate(String cause) {
    if (['collecting', 'ready'].contains(state)) {
      state = 'invalid';
      reason = cause;
    }
  }

  Map<String, dynamic> snapshot() => _saved != null
      ? Map<String, dynamic>.from(
          jsonDecode(
                jsonEncode({
                  ..._saved!,
                  'attemptId': attemptId,
                  'context': context,
                  'state': state,
                  'reason': reason,
                }),
              )
              as Map,
        )
      : {
          'attemptId': attemptId,
          'state': state,
          'reason': reason,
          'elapsed': elapsed,
          'attemptElapsed': attemptElapsed,
          'adaptationSeconds': baselineAdaptationSeconds,
          'readyAt': readyAt,
          'validSeconds': validSeconds,
          'validRatio': elapsed > 0 ? validSeconds / elapsed : 0,
          'windows': windows,
          'context': context,
          'statistics': {
            for (final key in _means.keys)
              key: {
                'mean': _means[key],
                'variance': variance(key),
                'standardDeviation': math.sqrt(variance(key)),
                'drift': drift(key),
                'minimum': _values.map((v) => v[key]!).reduce(math.min),
                'maximum': _values.map((v) => v[key]!).reduce(math.max),
              },
          },
          'algorithm': baselineAlgorithmVersion,
          'referenceMetrics': referenceMetricKeys,
          'featureDefinition': baselineFeatureDefinition(),
          'readingVersion': baselineReadingVersion,
          'usageVersion': baselineUsageVersion,
          'timing':
              'one completed valid host-monotonic comparison second, weight 1; adaptation excluded',
        };
}
