import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/data/devices/local_algorithm_transport.dart';
import 'support/fake_eeg_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real isolate computes a complete window while forwarding raw packets',
    () async {
      final native = FakeEegTransport();
      final transport = LocalAlgorithmTransport(native);
      final events = <Map<String, dynamic>>[];
      final sub = transport.events.listen(events.add);
      final result = transport.events.firstWhere(
        (e) => e['type'] == 'algorithm' && (e['updates'] as List).isNotEmpty,
      );
      await transport.connect(testDeviceAddress);
      for (var i = 0; i < 16; i++) {
        native.packet('raw', rawPacket(), DateTime.now());
      }
      final event = await result.timeout(const Duration(seconds: 10));
      expect(events.where((e) => e['type'] == 'packet').length, 16);
      expect(event['session'], native.session);
      expect(event['filtered_1'], hasLength(16));
      final update = (event['updates'] as List).single as Map;
      expect(update['scores'], containsPair('attention', isA<num>()));
      expect((await transport.access())['localAlgorithms'], true);
      await sub.cancel();
      await native.close();
    },
  );
  test(
    'disconnect/reconnect resets filter/windows and discards old work',
    () async {
      final native = FakeEegTransport();
      final transport = LocalAlgorithmTransport(native);
      final sub = transport.events.listen((_) {});
      await transport.connect(testDeviceAddress);
      for (var i = 0; i < 16; i++) {
        native.packet('raw', rawPacket(), DateTime.now());
      }
      await transport.disconnect();
      await transport.connect(testDeviceAddress);
      final results = <Map<String, dynamic>>[];
      final observer = transport.events
          .where((e) => e['type'] == 'algorithm')
          .listen(results.add);
      final full = transport.events.firstWhere(
        (e) => e['type'] == 'algorithm' && (e['updates'] as List).isNotEmpty,
      );
      for (var i = 0; i < 16; i++) {
        native.packet('raw', rawPacket(), DateTime.now());
      }
      final event = await full.timeout(const Duration(seconds: 10));
      expect(event['session'], 2);
      expect(results.every((e) => e['session'] == 2), true);
      expect(
        results.first['filtered_1'].first,
        closeTo(3 * 0.0008888818546827, 1e-12),
      );
      await observer.cancel();
      await sub.cancel();
      await native.close();
    },
  );
  test(
    'return from background starts a new algorithm window on the same connection',
    () async {
      final native = FakeEegTransport();
      final transport = LocalAlgorithmTransport(native);
      final sub = transport.events.listen((_) {});
      await transport.connect(testDeviceAddress);
      final before = transport.events.firstWhere(
        (e) => e['type'] == 'algorithm',
      );
      for (var i = 0; i < 8; i++) {
        native.packet('raw', rawPacket(), DateTime.now());
      }
      await before.timeout(const Duration(seconds: 10));
      native.emit({'type': 'algorithmReset'});
      final next = transport.events.firstWhere((e) => e['type'] == 'algorithm');
      native.packet('raw', rawPacket(), DateTime.now());
      final event = await next.timeout(const Duration(seconds: 10));
      expect(event['session'], 1);
      expect(event['updates'], isEmpty);
      expect(
        (event['filtered_1'] as List).first,
        closeTo(3 * 0.0008888818546827, 1e-12),
      );
      await sub.cancel();
      await native.close();
    },
  );
}
