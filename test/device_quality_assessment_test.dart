import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/device/device_quality_assessment.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'stage3_signal_test.dart' show fixtureProfile;
import 'support/fake_eeg_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'One quality pass requires stable real samples; no recording starts and reconnect checks afresh',
    () async {
      double clock = 0;
      final base = DateTime(2026, 11, 4);
      DateTime now() => base.add(Duration(microseconds: (clock * 1e6).round()));
      final transport = FakeEegTransport();
      final eeg = EegController(transport, clock: now);
      await eeg.initialize();
      int profileCalls = 0;
      final quality = DeviceQualityAssessment(
        eeg,
        clock: () => clock,
        profileLoader: () async {
          profileCalls++;
          return fixtureProfile();
        },
      );
      const device = EegDevice(
        address: testDeviceAddress,
        name: 'SYNTHETIC',
        rssi: -40,
        advertisesService: true,
      );
      await eeg.connect(device);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(quality.state, DeviceQualityState.checking);
      final passed = Completer<void>();
      quality.addListener(() {
        if (quality.state == DeviceQualityState.passed && !passed.isCompleted) {
          passed.complete();
        }
      });
      for (var packet = 0; packet < 400; packet++) {
        clock = packet / 32;
        final bytes = Uint8List(69), data = ByteData(69);
        for (var j = 0; j < 16; j++) {
          final at = (packet * 16 + j) / 512;
          final v =
              ((2 +
                          math.sin(2 * math.pi * 10 * at) +
                          .3 * math.sin(2 * math.pi * 6 * at)) *
                      10000)
                  .round();
          data.setUint16(4 + j * 4, v);
          data.setUint16(6 + j * 4, v);
        }
        bytes.setAll(0, data.buffer.asUint8List());
        transport.packet('raw', bytes, now());
        if (packet % 8 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      await passed.future.timeout(const Duration(seconds: 3));
      expect(profileCalls, 1);
      expect(transport.calls, isNot(contains('startRecording')));
      final previous = transport.session;
      await eeg.disconnect();
      expect(quality.state, DeviceQualityState.disconnected);
      await eeg.connect(device);
      transport.packet('raw', rawPacket(), now(), fromSession: previous);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(quality.state, DeviceQualityState.checking);
      expect(profileCalls, 2);
      quality.dispose();
      eeg.dispose();
      await transport.close();
    },
  );
  test('Missing metadata never produces a normal result', () async {
    final transport = FakeEegTransport();
    final eeg = EegController(transport);
    await eeg.initialize();
    final quality = DeviceQualityAssessment(
      eeg,
      profileLoader: () async => throw StateError('unavailable'),
    );
    await eeg.connect(
      const EegDevice(
        address: testDeviceAddress,
        name: 'TEST',
        rssi: -40,
        advertisesService: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    transport.packet('raw', rawPacket(), DateTime.now());
    expect(quality.state, DeviceQualityState.unavailable);
    quality.dispose();
    eeg.dispose();
    await transport.close();
  });
}
