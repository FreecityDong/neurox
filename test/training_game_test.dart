import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/training_game.dart';
import 'package:neurox/features/tasks/training_widgets.dart';

void main() {
  test(
    'Dynamic obstacles use 30 numbered moving tokens and 3 fixed obstacles; only ordered clicks advance',
    () {
      final game = TrainingGame(kind: TrainingKind.obstacles, seed: 17);
      expect(game.tokens.map((t) => t.value).toSet(), {
        for (var i = 1; i <= 30; i++) i,
      });
      expect(game.obstacles.length, 3);
      final positions = game.tokens.map((t) => (t.x, t.y)).toList();
      expect(game.tap(3), false);
      expect(game.next, 1);
      expect(game.mistakes, 1);
      game.advanceTo(10);
      expect(
        game.tokens.indexed.any((v) => v.$2.x != positions[v.$1].$1),
        true,
      );
      for (final token in game.tokens) {
        expect(token.x, isNonNegative);
        expect(token.x, lessThanOrEqualTo(600));
        expect(token.y, isNonNegative);
        expect(token.y, lessThanOrEqualTo(600));
      }
      for (var value = 1; value <= 30; value++) {
        expect(game.tap(value), true);
      }
      expect(game.finished, true);
      expect(game.outcome, 'completed');
      expect(game.correct, 30);
    },
  );
  test(
    'Rotating rings distribute 5/8/10/13 digits and rotate neighboring rings in opposite directions',
    () {
      final game = TrainingGame(kind: TrainingKind.rings, seed: 9);
      expect(
        [
          for (var ring = 0; ring < 4; ring++)
            game.tokens.where((t) => t.ring == ring).length,
        ],
        [5, 8, 10, 13],
      );
      final angles = List<double>.from(game.ringAngles);
      game.advanceTo(1);
      expect(game.ringAngles[0], greaterThan(angles[0]));
      expect(game.ringAngles[1], lessThan(angles[1]));
      expect(game.tap(1), true);
      expect(game.tap(1), isNull);
      for (var value = 2; value <= 36; value++) {
        game.tap(value);
      }
      expect(game.outcome, 'completed');
    },
  );
  test(
    'Hexagons contain exactly 48 unique numbered cells; expiry preserves score instead of inventing success',
    () {
      final game = TrainingGame(kind: TrainingKind.hexagons, seed: 4);
      expect(game.tokens.length, 48);
      expect(game.tokens.map((t) => (t.x, t.y)).toSet().length, 48);
      game.tap(1);
      game.advanceTo(180);
      expect(game.finished, true);
      expect(game.outcome, 'timeout');
      expect(game.correct, 1);
      expect(game.tap(2), isNull);
    },
  );
  for (var level = 0; level < 4; level++) {
    test(
      'Tracking difficulty $level remembers, moves, then freezes for selection; hidden targets cannot be selected early',
      () {
        final game = TrainingGame(
              kind: TrainingKind.tracking,
              level: level,
              seed: level + 1,
            ),
            spec = TrackingLevel.values[level];
        expect(game.tokens.length, spec.count);
        expect(game.tokens.where((t) => t.target).length, spec.targets);
        final target = game.tokens.firstWhere((t) => t.target);
        expect(game.tap(target.value), isNull);
        game.advanceTo(spec.show + .1);
        expect(game.phase, 'moving');
        expect(game.tap(target.value), isNull);
        game.advanceTo(spec.show + spec.move);
        expect(game.phase, 'select');
        final frozen = game.tokens.map((t) => (t.x, t.y)).toList();
        game.advanceTo(game.elapsed + 10);
        expect(game.tokens.map((t) => (t.x, t.y)), frozen);
        final wrong = game.tokens.firstWhere((t) => !t.target);
        expect(game.tap(wrong.value), false);
        expect(game.tap(wrong.value), isNull);
        for (final token in game.tokens.where((t) => t.target)) {
          expect(game.tap(token.value), true);
        }
        expect(game.outcome, 'completed');
        expect(game.mistakes, 1);
      },
    );
  }
  test(
    'Training report excludes missing/nonfinite data and counts one sample per completed second',
    () {
      final report = trainingObservation([
        {
          'type': 'sample',
          'wallSeconds': 1.1,
          'scores': {'attention': 40.0, 'relax': 30.0},
        },
        {
          'type': 'sample',
          'wallSeconds': 1.9,
          'scores': {'attention': 60.0, 'relax': 50.0},
        },
        {'type': 'sample', 'wallSeconds': 2.0, 'scores': null},
        {
          'type': 'sample',
          'wallSeconds': 3.0,
          'scores': {'attention': double.nan, 'relax': 40.0},
        },
      ]);
      expect(report['validSeconds'], 1);
      expect(report['attention']['mean'], 60);
    },
  );
}
