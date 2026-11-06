import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/baseline_guard.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';

AnalysisWindow quality(int end, String reason, {String? raw}) => AnalysisWindow(
  sequence: end,
  start: end - 1.0,
  end: end.toDouble(),
  reason: reason,
  source: {'rawQuality': ?raw},
);
void main() {
  test(
    'A single contact flag, cached time, and a recovered flag cannot confirm contact loss',
    () {
      final g = BaselineGuard();
      expect(g.contact(0, false), isNull);
      expect(g.contactPending, true);
      expect(g.contactConfirmed, false);
      expect(
        g.contact(10, false),
        isNull,
      ); // No fresh continuous reports across this gap.
      expect(g.contact(10.1, true), isNull);
      expect(g.contactPending, false);
      for (var i = 0; i < 100; i++) {
        expect(g.contact(11, false), isNull);
      }
      expect(g.contactConfirmed, false);
    },
  );
  test(
    'Continuous fresh contact reports confirm at three seconds and recovery resets evidence',
    () {
      final g = BaselineGuard();
      for (var i = 0; i < 30; i++) {
        expect(g.contact(i / 10, false), isNull);
      }
      expect(g.contact(3, false), 'contact');
      expect(g.contactConfirmed, true);
      g.contact(3.1, true);
      expect(g.contactConfirmed, false);
    },
  );
  test(
    'Quality confirmation requires distinct consecutive complete windows, not cached observations',
    () {
      final g = BaselineGuard();
      final old = quality(1, 'raw_range');
      for (var i = 0; i < 100; i++) {
        expect(g.quality(old), isNull);
      }
      expect(g.waveWindows, 1);
      for (var i = 2; i < 8; i++) {
        expect(g.quality(quality(i, 'warming', raw: 'raw_range')), isNull);
      }
      expect(g.quality(quality(8, 'warming', raw: 'raw_range')), 'waveform');
      g.reset();
      g.quality(quality(1, 'flat'));
      g.quality(quality(3, 'flat'));
      expect(g.waveWindows, 1);
    },
  );
  test(
    'Waveform and coverage evidence are independent and recover on good raw health',
    () {
      final g = BaselineGuard();
      for (var i = 1; i <= 4; i++) {
        g.quality(quality(i, 'raw_range'));
      }
      for (var i = 5; i <= 8; i++) {
        expect(g.quality(quality(i, 'coverage')), isNull);
      }
      expect(g.waveWindows, 0);
      expect(g.quality(quality(9, 'coverage')), 'data_loss');
      expect(g.quality(quality(10, 'comparison_warming', raw: 'good')), isNull);
      expect(g.missingWindows, 0);
    },
  );
  test(
    'One encoded-boundary sample recovers through real SDK warmup without causing waveform discard',
    () {
      final p = SignalProfile({
        'verified': false,
        'mode': 'raw_ratio_provisional',
        'assumptionAccepted': true,
        'sampleRateAssumed': true,
        'sampleRate': 512.0,
        'scale': 1.0,
        'unit': 'SDK raw',
        'version': 'SYNTHETIC',
        'evidence': 'Synthetic only',
        'flatStd': .000001,
        'adcMin': 0.0,
        'adcMax': 6.5535,
        'maxPeakToPeak': 6.5535,
        'maxStep': 6.5535,
      });
      final pipeline = SignalPipeline(p, randomInteger: () => 0),
          g = BaselineGuard();
      var sawBad = false, sawRecovered = false;
      for (var offset = 0; offset < 26 * 512; offset += 16) {
        final a = List<double>.generate(
          16,
          (i) =>
              3 +
              .1 * math.sin(2 * math.pi * 10 * (offset + i) / 512) +
              .03 * math.sin(2 * math.pi * 6 * (offset + i) / 512) +
              .05 * math.sin(2 * math.pi * 20 * (offset + i) / 512),
        );
        final b = List<double>.from(a);
        if (offset == 12 * 512) a[8] = 0;
        final w = pipeline.push(a, b, offset / 512);
        if (w == null) continue;
        if (w.reason == 'raw_range') sawBad = true;
        if (sawBad && w.good) sawRecovered = true;
        expect(g.quality(w), isNull);
      }
      expect(sawBad, true);
      expect(sawRecovered, true);
      expect(g.waveWindows, 0);
    },
  );
}
