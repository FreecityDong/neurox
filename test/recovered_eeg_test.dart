import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/data/algorithms/recovered_eeg.dart';

void compare(Object? actual, Object? expected, [String path = 'result']) {
  if (expected is num) {
    expect(actual, isA<num>(), reason: path);
    final tolerance = 1e-9 * (1 + expected.abs());
    expect(
      (actual as num).toDouble(),
      closeTo(expected.toDouble(), tolerance),
      reason: path,
    );
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    final list = actual as List;
    expect(list.length, expected.length, reason: path);
    for (var i = 0; i < expected.length; i++) {
      compare(list[i], expected[i], '$path[$i]');
    }
  } else if (expected is Map) {
    final map = actual as Map;
    for (final key in expected.keys) {
      compare(map[key], expected[key], '$path.$key');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

void main() {
  final reference =
      jsonDecode(
            File(
              'test/fixtures/python_portable_mobile.json',
            ).readAsStringSync(),
          )
          as Map;
  final a = (reference['channel_1'] as List)
      .cast<num>()
      .map((x) => x.toDouble())
      .toList();
  final b = (reference['channel_2'] as List)
      .cast<num>()
      .map((x) => x.toDouble())
      .toList();
  for (final blockSize in [16, 13]) {
    test(
      'Python cross-reference: filters, entropy, FFT, scores, blink/gnash; packets $blockSize',
      () {
        final algorithm = RecoveredEegAlgorithms(
          randomInteger: () => 7,
          emotionRandom: () => 7,
        );
        final result = <String, List<dynamic>>{
          for (final key in [
            'filtered_1',
            'filtered_2',
            'updates',
            'blink',
            'gnash',
          ])
            key: [],
        };
        for (var start = 0; start < a.length; start += blockSize) {
          final end = (start + blockSize).clamp(0, a.length);
          final block = algorithm.process(
            a.sublist(start, end),
            b.sublist(start, end),
          );
          for (final key in result.keys) {
            result[key]!.addAll(block[key] as List);
          }
        }
        compare(result, reference['expected']);
      },
    );
  }
  test(
    'zero variance preserves Python NaN; invalid input does not consume state',
    () {
      expect(RecoveredEegAlgorithms.fuzzyEntropy(List.filled(256, 0)), isNaN);
      final a = RecoveredEegAlgorithms(), b = RecoveredEegAlgorithms();
      expect(() => a.process([3, double.nan], [3, 3]), throwsArgumentError);
      expect(() => a.process([3], []), throwsArgumentError);
      expect(a.process([3], [3]), b.process([3], [3]));
    },
  );
}
