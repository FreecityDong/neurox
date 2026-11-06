import 'dart:math' as math;

/// Port of KSEEG102_Python_Mac/{eeg_filters,eeg_entropy,eeg_features,eeg_portable}.py.
/// SDK numerical values; the spectrum's 512 Hz is an inherited assumption.
class RecoveredEegAlgorithms {
  RecoveredEegAlgorithms({
    int Function()? randomInteger,
    int Function()? emotionRandom,
    this.computeAuxiliary = true,
  }) : _randomInteger = randomInteger ?? (() => math.Random().nextInt(32768)),
       _emotionRandom = emotionRandom ?? (() => math.Random().nextInt(15));

  /// Baselines need the identical filter/spectrum/scores without unused entropy/actions.
  final bool computeAuxiliary;
  final int Function() _randomInteger;
  final int Function() _emotionRandom;
  final _filter = _RecoveredFilter();
  final _pending = [<double>[], <double>[]];
  final _spectral = [
    List<double>.filled(1024, 0),
    List<double>.filled(1024, 0),
  ];
  final _states = <String, double>{
    'attention': 0,
    'relax': 0,
    'tired': 0,
    'meditation': 0,
  };
  double _emotion = 0;
  final _blink = <double>[];
  final _gnash = <double>[];
  double _previousPeak = 0, _olderPeak = 0, _gnashStd = 0;
  int _positive = 0, _negative = 0, _blinkEvents = 0, _gnashEvents = 0;

  Map<String, dynamic> process(List<double> a, List<double> b) {
    if (a.length != b.length || [...a, ...b].any((x) => !x.isFinite)) {
      throw ArgumentError('Two finite channels of equal length are required');
    }
    final first = <double>[], second = <double>[];
    final updates = <Map<String, dynamic>>[];
    final blinks = <double>[], gnashes = <double>[];
    for (var i = 0; i < a.length; i++) {
      final x = _filter.channel(a[i], 0), y = _filter.channel(b[i], 1);
      first.add(x);
      second.add(y);
      _pending[0].add(x);
      _pending[1].add(y);
      final blink = computeAuxiliary ? _updateBlink(x) : 0.0,
          gnash = computeAuxiliary ? _updateGnash(x) : 0.0;
      blinks.add(blink);
      gnashes.add(gnash);
      _blinkEvents += blink.toInt();
      _gnashEvents += gnash.toInt();
      if (_pending[0].length == 256) {
        final e1 = computeAuxiliary ? fuzzyEntropy(_pending[0]) : double.nan,
            e2 = computeAuxiliary ? fuzzyEntropy(_pending[1]) : double.nan;
        if (computeAuxiliary) _emotion = 100 * (e1 - e2) * .2 + _emotion * .8;
        if (_emotion.abs() > .9) {
          _emotion =
              (_emotion.isNegative ? -1 : 1) * (.8 + _emotionRandom() / 100);
        }
        final powers = <List<double>>[];
        for (var c = 0; c < 2; c++) {
          _spectral[c].setRange(0, 768, _spectral[c].sublist(256));
          _spectral[c].setRange(768, 1024, _pending[c]);
          powers.add(_bands(_spectral[c]));
        }
        final bands = List<double>.generate(
          6,
          (k) => (powers[0][k] + powers[1][k]) * .5,
        );
        updates.add({
          'fuzzy_entropy_1': e1,
          'fuzzy_entropy_2': e2,
          'emotion': _emotion,
          'bands': {
            for (var k = 0; k < 6; k++)
              ['delta', 'theta', 'alpha', 'beta', 'gamma', 'total'][k]:
                  bands[k],
          },
          'scores': {
            'attention': _score('attention', bands[3], bands[1], 60),
            'relax': _score('relax', bands[2] + bands[1], bands[3], 20),
            'tired': _score('tired', bands[1], bands[3] + bands[2], 40),
            'meditation': _score(
              'meditation',
              bands[3] + bands[2],
              bands[1],
              26,
            ),
          },
          'blink_events': _blinkEvents,
          'gnash_events': _gnashEvents,
          'spectrum_assumed_hz': 512,
        });
        _pending[0].clear();
        _pending[1].clear();
        _blinkEvents = _gnashEvents = 0;
      }
    }
    return {
      'filtered_1': first,
      'filtered_2': second,
      'updates': updates,
      'blink': blinks,
      'gnash': gnashes,
    };
  }

  double _score(
    String name,
    double numerator,
    double denominator,
    double scale,
  ) {
    final state = numerator / denominator * .3 + _states[name]! * .7;
    _states[name] = state;
    var result = state * scale;
    if (result > 99) result = (_randomInteger() % 12 + 85).toDouble();
    return name == 'meditation' ? 100 - result : result;
  }

  double _updateBlink(double x) {
    _blink.add(x);
    if (_blink.length < 152) return 0;
    var peak = _blink.first;
    for (final v in _blink.skip(1)) {
      if (v > peak) peak = v;
    }
    _blink.clear();
    final difference = (_previousPeak - _olderPeak) + _previousPeak - peak;
    _olderPeak = _previousPeak;
    _previousPeak = peak;
    return difference > .04 ? 1 : 0;
  }

  double _updateGnash(double x) {
    _gnash.add(x);
    if (_gnash.length < 76) return 0;
    var sum = 0.0;
    for (final v in _gnash) {
      sum += v;
    }
    final mean = sum / 76;
    var variance = 0.0;
    for (final v in _gnash) {
      variance += (v - mean) * (v - mean);
    }
    _gnashStd = math.sqrt(variance / 76) * .5 + _gnashStd * .5;
    _gnash.clear();
    if (mean.abs() < .02 && _gnashStd > .015) {
      _positive++;
      if (_positive >= 2) {
        _negative = 0;
        return 1;
      }
    } else {
      _negative++;
      if (_negative >= 2) _positive = 0;
    }
    return 0;
  }

  static double fuzzyEntropy(List<double> values) {
    if (values.length != 256 || values.any((v) => !v.isFinite)) {
      throw ArgumentError('Fuzzy entropy requires 256 finite samples');
    }
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    final mean = sum * .00390625;
    var variance = 0.0;
    for (final v in values) {
      variance += (v - mean) * (v - mean);
    }
    final tolerance = math.sqrt(variance * .00390625) * .15;
    if (tolerance == 0 || tolerance.isNaN) return double.nan;
    return -math.log(
      _similarity(values, 3, tolerance) / _similarity(values, 2, tolerance),
    );
  }

  static double _similarity(
    List<double> samples,
    int dimension,
    double tolerance,
  ) {
    final means = List<double>.generate(254, (i) {
      var total = 0.0;
      for (var k = 0; k < dimension; k++) {
        total += samples[i + k];
      }
      return dimension == 2 ? total * .5 : total / 3;
    });
    var aggregate = 0.0;
    for (var i = 0; i < 254; i++) {
      final centered = List<double>.generate(
        dimension,
        (k) => samples[i + k] - means[i],
      );
      var row = 0.0;
      for (var j = 0; j < 254; j++) {
        final first = ((centered[0] - samples[j]) + means[j]).abs();
        final second = ((centered[1] - samples[j + 1]) + means[j]).abs();
        var distance = dimension == 2
            ? (second <= first ? first : second)
            : first;
        if (dimension == 3) {
          if (distance < second) distance = second;
          final third = ((centered[2] - samples[j + 2]) + means[j]).abs();
          if (distance < third) distance = third;
        }
        row += math.exp(-(distance * distance) / tolerance);
      }
      aggregate += (row - 1) / 253;
    }
    return aggregate / 253;
  }

  static List<double> _bands(List<double> values) {
    final re = List<double>.filled(1024, 0), im = List<double>.filled(1024, 0);
    for (var i = 0; i < 1024; i++) {
      var reverse = 0, v = i;
      for (var k = 0; k < 10; k++) {
        reverse = (reverse << 1) | (v & 1);
        v >>= 1;
      }
      re[reverse] = values[i];
    }
    for (var width = 2; width <= 1024; width *= 2) {
      final half = width ~/ 2;
      for (var start = 0; start < 1024; start += width) {
        for (var j = 0; j < half; j++) {
          final angle = (j * (1024 ~/ width)) * (2 * math.pi) / 1024;
          final cos = math.cos(angle),
              sin = -math.sin(angle),
              p = start + j,
              q = p + half;
          final oddRe = cos * re[q] - sin * im[q],
              oddIm = cos * im[q] + sin * re[q];
          final evenRe = re[p], evenIm = im[p];
          re[p] = evenRe + oddRe;
          im[p] = evenIm + oddIm;
          re[q] = evenRe - oddRe;
          im[q] = evenIm - oddIm;
        }
      }
    }
    final sums = List<double>.filled(6, 0);
    for (var k = 1; k <= 96; k++) {
      final magnitude = math.sqrt(re[k] * re[k] + im[k] * im[k]);
      final power = math.pow(magnitude, 2) / 1024 / 512 * 2;
      final band = k <= 8
          ? 0
          : k <= 16
          ? 1
          : k <= 26
          ? 2
          : k <= 60
          ? 3
          : 4;
      sums[band] += power;
    }
    for (var k = 0; k < 5; k++) {
      sums[5] += sums[k];
    }
    return sums;
  }
}

class _RecoveredFilter {
  // Exact binary64 constants rendered as round-trip decimal literals by Python.
  static const coefficients = <double>[
    0.0008888818546827,
    0.004444409273413,
    0.008888818546827,
    -8.110112692924,
    29.68087320904,
    -64.60700161655,
    92.69722668556,
    -91.65211204565,
    63.26165178773,
    -30.10437152949,
    9.452565383626,
    -1.768383332701,
    0.1496641513596,
  ];
  final _x = [List<double>.filled(10, 0), List<double>.filled(10, 0)];
  final _y = [List<double>.filled(10, 0), List<double>.filled(10, 0)];
  double channel(double value, int c) {
    final x = _x[c],
        y = _y[c],
        b0 = coefficients[0],
        b2 = coefficients[1],
        b4 = coefficients[2];
    var result = value * b0 + 0.0;
    result = result + x[0] * 0.0;
    result = result - x[1] * b2;
    result = result + x[2] * 0.0;
    result = result + x[3] * b4;
    result = result + x[4] * 0.0;
    result = result - x[5] * b4;
    result = result + x[6] * 0.0;
    result = result + x[7] * b2;
    result = result + x[8] * 0.0;
    result = result - x[9] * b0;
    for (var k = 0; k < 10; k++) {
      result = result - y[k] * coefficients[k + 3];
    }
    for (var k = 9; k > 0; k--) {
      x[k] = x[k - 1];
      y[k] = y[k - 1];
    }
    x[0] = value;
    y[0] = result;
    return result;
  }
}
