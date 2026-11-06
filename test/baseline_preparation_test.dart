import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/baseline_preparation.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';
import 'stage3_signal_test.dart' show rawRatioProfile;

AnalysisWindow sample(int second, String raw) => AnalysisWindow(
  sequence: second,
  start: second - 1.0,
  end: second.toDouble(),
  reason: 'comparison_warming',
  source: {'rawQuality': raw},
);
void main() {
  test(
    'Preparation requires three fresh full raw seconds; duplicates, contact and gaps do not pass',
    () {
      final check = BaselinePreparation();
      check.add(sample(1, 'good'), contactGood: true);
      for (var i = 0; i < 10; i++) {
        check.add(sample(1, 'good'), contactGood: true);
      }
      expect(check.ready, false);
      check.add(sample(2, 'good'), contactGood: false);
      expect(check.stableWindows, 0);
      check.add(sample(3, 'good'), contactGood: true);
      check.add(sample(5, 'good'), contactGood: true);
      expect(check.stableWindows, 1);
      check.add(sample(6, 'raw_range'), contactGood: true);
      expect(check.stableWindows, 0);
      for (var i = 7; i <= 9; i++) {
        check.add(sample(i, 'good'), contactGood: true);
      }
      expect(check.ready, true);
      check.reset();
      expect(check.ready, false);
    },
  );
  test(
    'Real raw pipeline passes preparation before comparison warm-up, and a second preparation starts fresh',
    () {
      for (var attempt = 0; attempt < 2; attempt++) {
        final pipeline = SignalPipeline(
          rawRatioProfile(),
          randomInteger: () => 0,
        );
        final check = BaselinePreparation();
        AnalysisWindow? ready;
        for (var offset = 0; offset < 10 * 512; offset += 16) {
          final a = List<double>.generate(
            16,
            (i) =>
                3 +
                .2 * math.sin(2 * math.pi * 10 * (offset + i) / 512) +
                .1 * math.sin(2 * math.pi * 6 * (offset + i) / 512),
          );
          final w = pipeline.push(a, a, offset / 512);
          if (w == null) continue;
          check.add(w, contactGood: true);
          if (check.ready) {
            ready = w;
            break;
          }
        }
        expect(ready, isNotNull);
        expect(ready!.end, lessThanOrEqualTo(7));
        expect(
          ready.good,
          false,
          reason: 'Preparation does not fabricate a valid comparison score',
        );
      }
    },
  );
}
