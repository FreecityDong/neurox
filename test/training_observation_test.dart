import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/training_observation.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';
import 'package:neurox/features/tasks/scene_widgets.dart';
import 'stage3_signal_test.dart' show fixtureProfile, signal;

void main() {
  test(
    'SDK observation is available before comparison median; isolate payload preserves both',
    () {
      final pipeline = SignalPipeline(fixtureProfile(), randomInteger: () => 7);
      final windows = <AnalysisWindow>[];
      for (var i = 0; i <= 12 * 32; i++) {
        final w = pipeline.push(signal(i * 16), signal(i * 16), i / 32);
        if (w != null) windows.add(AnalysisWindow.fromMap(w.toMap()));
      }
      final observed = windows.where((w) => w.observationGood).toList();
      final comparable = windows.where((w) => w.good).toList();
      expect(observed, isNotEmpty);
      expect(comparable, isNotEmpty);
      expect(observed.first.end, comparable.first.end - 4);
      expect(observed.first.reason, 'comparison_warming');
      expect(observed.first.features, isNull);
      expect(
        observed.first.observationFeatures!.keys,
        containsAll(['attention', 'relax']),
      );
      expect(
        windows
            .where((w) => w.reason == 'warming')
            .every((w) => !w.observationGood),
        true,
      );
      final gap = pipeline.push(signal(0), signal(0), 20)!;
      expect(gap.observationGood, false);
    },
  );

  test(
    'Game records from its own zero; partial first second, gaps and receipt jitter cannot inflate coverage',
    () {
      const w = AnalysisWindow(
        sequence: 1,
        start: 20,
        end: 21,
        reason: 'comparison_warming',
        observationReason: 'good',
        observationFeatures: {'attention': 60, 'relax': 40},
      );
      Map<String, dynamic>? sample(double game, double received) =>
          trainingSample(
            window: w,
            sampleAt: 121,
            receivedAt: received,
            gameSeconds: game,
            attempt: 'A',
          );
      expect(sample(.1, 121.2), isNull); // completed before game start
      final first = sample(.7, 121.2)!;
      expect(first['curveSeconds'], closeTo(.5, 1e-9));
      expect(first['scores'], isNotNull); // no five-second eligibility needed
      final duplicate = sample(.9, 121.4)!;
      final stale = sample(5, 124)!;
      expect(stale['scores'], isNull);
      final events = [
        {'type': 'prepared', 'elapsed': 0.0, 'wallSeconds': 0.0},
        {'type': 'game_start', 'elapsed': 0.0, 'wallSeconds': 100.0},
        {'type': 'sample', ...first},
        {'type': 'sample', ...duplicate},
        {'type': 'sample', ...stale},
        {'type': 'finish', 'elapsed': 5.0, 'wallSeconds': 130.0},
      ];
      final report = trainingObservation(events);
      expect(report['validSeconds'], closeTo(.5, 1e-9));
      final curve = trainingCurveEvents(events);
      expect(curve.first['type'], 'game_start');
      expect(curveTime(curve.first), 0);
      expect(curveTime(curve.last), 5);
    },
  );

  testWidgets(
    'Valid game scores paint colored solid lines even without baseline classification',
    (tester) async {
      final events = <Map<String, dynamic>>[
        {
          'type': 'sample',
          'curveSeconds': 1.0,
          'scores': {'attention': 50.0, 'relax': 40.0},
        },
        {
          'type': 'sample',
          'curveSeconds': 2.0,
          'scores': {'attention': 60.0, 'relax': 30.0},
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SceneCurve(events: events, observationOnly: true),
          ),
        ),
      );
      expect(find.text('绿色范围：专注'), findsNothing);
      final paint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((w) => w.painter != null);
      void draw(Canvas canvas) =>
          paint.painter!.paint(canvas, const Size(300, 180));
      expect(
        draw,
        paints
          ..line()
          ..line()
          ..line()
          ..circle()
          ..line(color: Colors.blue)
          ..circle()
          ..line(color: Colors.purple),
      );
      // Valid observations remain colored even if the general scene state is unknown.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SceneCurve(events: events)),
        ),
      );
      final general = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((w) => w.painter != null);
      expect(
        (Canvas c) => general.painter!.paint(c, const Size(300, 180)),
        paints
          ..line()
          ..line()
          ..line()
          ..circle()
          ..line(color: Colors.blue),
      );
    },
  );
}
