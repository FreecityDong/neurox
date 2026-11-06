import 'dart:math' as math;
import 'package:neurox/data/algorithms/recovered_eeg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';
import 'package:neurox/features/tasks/signal_worker.dart';

// Synthetic test profile only; these numbers are not KSEEG102 specifications.
SignalProfile fixtureProfile() => SignalProfile({
  'verified': true,
  'version': 'synthetic-v1',
  'evidence': 'Analytic synthetic test signal only',
  'unit': 'test-unit',
  'sampleRate': 512.0,
  'scale': 1.0,
  'flatStd': .01,
  'maxPeakToPeak': 20.0,
  'maxStep': 2.0,
  'adcMin': -100.0,
  'adcMax': 100.0,
});
List<double> signal(int offset, [double amplitude = 1]) => List.generate(
  16,
  (i) =>
      amplitude * math.sin(2 * math.pi * 10 * (i + offset) / 512) +
      .3 * math.sin(2 * math.pi * 6 * (i + offset) / 512),
);
AnalysisWindow window(
  int seq,
  double start,
  double end, {
  bool good = true,
  double value = .5,
}) => AnalysisWindow(
  sequence: seq,
  start: start,
  end: end,
  reason: good ? 'good' : 'flat',
  features: good
      ? {
          'ch1_alphaRelative': value,
          'ch1_alpha': value * 10,
          'attention': value * 10,
          'relax': value,
        }
      : null,
);
void main() {
  test(
    'Saved baseline copies cannot be mutated or recomputed by learning observations',
    () {
      final saved = <String, dynamic>{
        'statistics': {
          'attention': {'mean': 60.0, 'variance': 25.0, 'drift': 0.0},
          'relax': {'mean': 40.0, 'variance': 16.0, 'drift': 0.0},
        },
        'elapsed': 90.0,
        'validSeconds': 70.0,
      };
      final b = BaselineAccumulator.fromSaved(
        attemptId: 'REUSED',
        context: {},
        snapshot: saved,
      );
      ((saved['statistics'] as Map)['attention'] as Map)['mean'] = 99.0;
      b.state = 'collecting';
      b.advance(100);
      b.add(learningWindow(100, attention: 90));
      final view = b.snapshot();
      view['statistics']['attention']['mean'] = 0;
      expect(b.snapshot()['statistics']['attention']['mean'], 60);
      expect(b.variance('attention'), 25);
      expect(b.validSeconds, 70);
    },
  );
  test(
    'Completed seconds: 5-second median rejects spikes, duplicates, reused scores and gaps',
    () {
      final series = SecondScoreMedian();
      Map<String, double>? result;
      for (var i = 1; i <= 5; i++) {
        result = series.add(
          end: i.toDouble(),
          scoreId: i,
          scores: {
            'attention': <double>[60, 61, 99, 63, 64][i - 1],
            'relax': 40,
          },
          good: true,
        );
      }
      expect(result!['attention'], 63);
      expect(
        series.add(
          end: 5,
          scoreId: 6,
          scores: {'attention': 1, 'relax': 1},
          good: true,
        ),
        isNull,
      );
      expect(
        series.add(
          end: 6,
          scoreId: 5,
          scores: {'attention': 1, 'relax': 1},
          good: true,
        ),
        isNull,
      );
      for (var i = 7; i <= 10; i++) {
        expect(
          series.add(
            end: i.toDouble(),
            scoreId: i,
            scores: {'attention': 60, 'relax': 40},
            good: true,
          ),
          isNull,
        );
      }
      expect(
        series.add(
          end: 11,
          scoreId: 11,
          scores: {'attention': 60, 'relax': 40},
          good: true,
        ),
        isNotNull,
      );
      expect(
        series.add(
          end: 13,
          scoreId: 13,
          scores: {'attention': 60, 'relax': 40},
          good: true,
        ),
        isNull,
      );
      expect(
        series.add(
          end: 14,
          scoreId: 14,
          scores: {'attention': 60, 'relax': double.nan},
          good: true,
        ),
        isNull,
      );
    },
  );
  test(
    'Adaptation excluded; 90-second minimum, constant scores and reference expiry',
    () {
      final b = BaselineAccumulator(attemptId: 'A', context: {});
      for (var i = 1; i <= 99; i++) {
        b.advance(i.toDouble());
        b.add(learningWindow(i));
      }
      expect(b.state, 'collecting');
      expect(b.elapsed, 89);
      expect(b.validSeconds, 89);
      b.advance(100);
      b.add(learningWindow(100));
      expect(b.state, 'ready');
      expect(b.snapshot()['statistics']['attention']['variance'], 0);
      b.advance(10000);
      expect(b.state, 'ready');
      expect(b.snapshot()['readingVersion'], baselineReadingVersion);
    },
  );
  test(
    'Each completed valid second counts once; invalid, duplicate and 4-second coverage never backfill',
    () {
      final b = BaselineAccumulator(attemptId: 'A', context: {});
      b.advance(11);
      b.add(learningWindow(11));
      b.add(learningWindow(11));
      b.add(
        const AnalysisWindow(
          sequence: 12,
          start: 8,
          end: 12,
          reason: 'good',
          features: {'attention': 60, 'relax': 40},
        ),
      );
      b.add(
        const AnalysisWindow(
          sequence: 13,
          start: 12,
          end: 13,
          reason: 'good',
          features: {'attention': double.nan, 'relax': 40},
        ),
      );
      b.advance(14);
      b.add(learningWindow(14));
      expect(b.validSeconds, 2);
      expect(b.snapshot()['statistics']['attention']['mean'], 60);
    },
  );
  test(
    'Instability, drift, low reference and sparse coverage do not publish ready',
    () {
      for (final mode in ['unstable', 'drift', 'floor', 'insufficient']) {
        final b = BaselineAccumulator(attemptId: mode, context: {});
        for (var i = 11; i <= 190; i++) {
          b.advance(i.toDouble());
          if (mode == 'insufficient' && i.isOdd) continue;
          final a = mode == 'unstable'
              ? (i.isEven ? 10.0 : 90.0)
              : mode == 'drift'
              ? (i < 71 ? 30.0 : 60.0)
              : mode == 'floor'
              ? 4.0
              : 60.0;
          b.add(learningWindow(i, attention: a));
        }
        b.advance(191);
        expect(b.state, 'failed', reason: mode);
        expect(b.reason, mode);
      }
    },
  );
  test(
    '70 percent coverage can qualify at deadline; final second is not lost to timer',
    () {
      final b = BaselineAccumulator(attemptId: 'deadline', context: {});
      for (var i = 11; i <= 190; i++) {
        b.advance(i.toDouble());
        if (i >= 65) b.add(learningWindow(i));
      }
      expect(b.validSeconds, 126);
      expect(b.elapsed, 180);
      expect(b.state, 'ready');
    },
  );
  test(
    'Scores-only mode matches the complete tested SDK path at every update',
    () {
      final full = RecoveredEegAlgorithms(
        randomInteger: () => 7,
        emotionRandom: () => 0,
      );
      final scores = RecoveredEegAlgorithms(
        randomInteger: () => 7,
        computeAuxiliary: false,
      );
      for (var block = 0; block < 4; block++) {
        final a = List.generate(
          256,
          (i) =>
              math.sin(2 * math.pi * 10 * (i + block * 256) / 512) +
              .3 * math.sin(2 * math.pi * 6 * (i + block * 256) / 512),
        );
        final first = (full.process(a, a)['updates'] as List).single as Map;
        final second = (scores.process(a, a)['updates'] as List).single as Map;
        expect(second['scores'], first['scores']);
        expect(second['bands'], first['bands']);
      }
    },
  );
  test(
    'Provisional SDK mode retains assumption and common-gain invariance',
    () {
      final profile = rawRatioProfile();
      expect(profile.usable, true);
      expect(profile.values['verified'], false);
      final missing = {...profile.values}..remove('assumptionAccepted');
      expect(SignalProfile(missing).usable, false);
      final one = SignalPipeline(profile, randomInteger: () => 7),
          two = SignalPipeline(profile, randomInteger: () => 7);
      AnalysisWindow? a, b;
      final oracle = RecoveredEegAlgorithms(
        randomInteger: () => 7,
        computeAuxiliary: false,
      );
      Map? oracleScores;
      final oracleSeconds = <Map>[];
      for (var packet = 0; packet < 384; packet++) {
        final samples = List.generate(16, (j) {
          final t = (packet * 16 + j) / 512;
          return 2.5 +
              .1 * math.sin(2 * math.pi * 10 * t) +
              .03 * math.sin(2 * math.pi * 6 * t);
        });
        if (packet >= 192 && packet % 32 == 0 && oracleScores != null) {
          oracleSeconds.add(Map.from(oracleScores));
        }
        final updates = oracle.process(samples, samples)['updates'] as List;
        if (updates.isNotEmpty) {
          oracleScores = (updates.last as Map)['scores'] as Map;
        }
        a = one.push(samples, samples, packet / 32) ?? a;
        b =
            two.push(
              samples.map((v) => v * 2).toList(),
              samples.map((v) => v * 2).toList(),
              packet / 32,
            ) ??
            b;
      }
      expect(a!.good, true);
      expect(a.source['sdkReceivedAt'] as double, lessThanOrEqualTo(a.end));
      expect((a.source['sdkEndSample'] as int) % 256, 0);
      expect(AnalysisWindow.fromMap(a.toMap()).source, a.source);
      expect(b!.good, true);
      for (final key in ['attention', 'relax']) {
        final recent =
            oracleSeconds
                .sublist(oracleSeconds.length - 5)
                .map((v) => (v[key] as num).toDouble())
                .toList()
              ..sort();
        expect(a.features![key], recent[2]);
      }
      expect(a.features!.length, 2);
      expect(a.features!.keys, containsAll(['attention', 'relax']));
      expect(a.features!.containsKey('ch1_alpha'), false);
      for (final key in a.features!.keys) {
        expect(a.features![key], closeTo(b.features![key]!, 1e-9));
      }
      final flat = SignalPipeline(profile);
      AnalysisWindow? last;
      for (var i = 0; i < 384; i++) {
        last =
            flat.push(List.filled(16, 2.5), List.filled(16, 2.5), i / 32) ??
            last;
      }
      expect(last!.good, false);
    },
  );
  test('Unknown or incomplete metadata cannot enable analysis', () {
    expect(SignalProfile({}).usable, false);
    final values = {...fixtureProfile().values}..remove('scale');
    expect(SignalProfile(values).usable, false);
    expect(
      SignalPipeline(SignalProfile({})).push(signal(0), signal(0), 0)?.reason,
      'metadata',
    );
  });
  test('Welch density recovers analytic power and relative bands', () {
    final input = List.generate(
      1024,
      (i) =>
          2 * math.sin(2 * math.pi * 6 * i / 128) +
          3 * math.sin(2 * math.pi * 10 * i / 128) +
          4 * math.sin(2 * math.pi * 20 * i / 128),
    );
    final bands = welchBands(input, 128);
    expect(bands['theta'], closeTo(2, 1e-9));
    expect(bands['alpha'], closeTo(4.5, 1e-9));
    expect(bands['beta'], closeTo(8, 1e-9));
    expect(bands['total'], closeTo(14.5, 1e-9));
    expect(bands['alphaRelative'], closeTo(4.5 / 14.5, 1e-9));
    expect(() => welchBands(List.filled(1024, 0), 128), throwsStateError);
    expect(() => welchBands([double.nan, ...input], 128), throwsArgumentError);
  });
  test('Quality rejects flat, saturation, gaps and malformed batches', () {
    AnalysisWindow? feed(List<double> Function(int) make) {
      final pipeline = SignalPipeline(fixtureProfile());
      AnalysisWindow? last;
      for (var i = 0; i < 384; i++) {
        final w = pipeline.push(make(i * 16), make(i * 16), i / 32);
        if (w != null &&
            (w.good || !['warming', 'comparison_warming'].contains(w.reason))) {
          last = w;
        }
      }
      return last;
    }

    expect(feed(signal)?.good, true);
    expect(feed((_) => List.filled(16, 1))?.reason, 'flat');
    expect(feed((_) => List.filled(16, 100))?.reason, 'saturation');
    final p = SignalPipeline(fixtureProfile());
    p.push(signal(0), signal(0), 0);
    expect(p.push(signal(16), signal(16), 2)?.reason, 'gap');
    expect(p.push([double.nan], [0], 3)?.reason, 'invalid_input');
    expect(p.raw1, isEmpty);
  });
  test(
    'Isolate processes a configured fixture and resets generations',
    () async {
      final worker = SignalWorker();
      final output = <AnalysisWindow>[];
      final sub = worker.windows.listen(output.add);
      await worker.start(fixtureProfile());
      for (var i = 0; i < 384; i++) {
        await worker.push(signal(i * 16), signal(i * 16), i / 32);
        if (i % 16 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(output.any((w) => w.good), true);
      final previousSequence = output.last.sequence;
      worker.reset();
      output.clear();
      await worker.push(signal(0), signal(0), 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(output, isEmpty);
      for (var i = 1; i < 384; i++) {
        await worker.push(signal(i * 16), signal(i * 16), i / 32);
        if (i % 16 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(output.any((w) => w.good), true);
      expect(output.every((w) => w.sequence > previousSequence), true);
      await sub.cancel();
      await worker.close();
    },
  );
}

// The product's provisional profile uses raw code limits, not calibrated ADC limits.
SignalProfile rawRatioProfile() => SignalProfile({
  'verified': false,
  'mode': 'raw_ratio_provisional',
  'assumptionAccepted': true,
  'sampleRateAssumed': true,
  'version': 'raw-ratio-assumed512-v1',
  'evidence': 'User accepted temporary rate; synthetic validation only',
  'unit': 'SDK raw',
  'sampleRate': 512.0,
  'scale': 1.0,
  'flatStd': .000001,
  'adcMin': 0.0,
  'adcMax': 6.5535,
  'maxPeakToPeak': 6.5535,
  'maxStep': 6.5535,
});

AnalysisWindow learningWindow(
  int second, {
  double attention = 60,
  double relax = 40,
}) => AnalysisWindow(
  sequence: second,
  start: second - 1.0,
  end: second.toDouble(),
  reason: 'good',
  features: {'attention': attention, 'relax': relax},
);
