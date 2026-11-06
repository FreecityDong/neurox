import 'dart:convert';
import 'dart:io';
import 'package:neurox/data/algorithms/recovered_eeg.dart';

void check(Object? actual, Object? expected, String path) {
  if (expected is num) {
    if (actual is! num ||
        !actual.isFinite ||
        (actual - expected).abs() > 1e-9 * (1 + expected.abs())) {
      throw StateError('$path: $actual differs from Python $expected');
    }
  } else if (expected is List) {
    final list = actual as List;
    if (list.length != expected.length) throw StateError('$path length');
    for (var i = 0; i < list.length; i++) {
      check(list[i], expected[i], '$path[$i]');
    }
  } else if (expected is Map) {
    for (final key in expected.keys) {
      check((actual as Map)[key], expected[key], '$path.$key');
    }
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
      .map((x) => (x as num).toDouble())
      .toList();
  final b = (reference['channel_2'] as List)
      .map((x) => (x as num).toDouble())
      .toList();
  final algorithm = RecoveredEegAlgorithms(
    randomInteger: () => 7,
    emotionRandom: () => 7,
  );
  final result = <String, List<dynamic>>{
    for (final key in ['filtered_1', 'filtered_2', 'updates', 'blink', 'gnash'])
      key: [],
  };
  for (var i = 0; i < a.length; i += 16) {
    final block = algorithm.process(a.sublist(i, i + 16), b.sublist(i, i + 16));
    for (final key in result.keys) {
      result[key]!.addAll(block[key] as List);
    }
  }
  check(result, reference['expected'], 'result');
  stdout.writeln(
    'Native AOT Python reference verification passed: ${a.length} samples/channel, ${result['updates']!.length} complete algorithm windows. No BLE or simulated GUI.',
  );
}
