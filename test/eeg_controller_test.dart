import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'support/fake_eeg_transport.dart';

void main() {
  late FakeEegTransport transport;
  late EegController controller;
  late DateTime now;
  const device = EegDevice(
    address: testDeviceAddress,
    name: 'KSEEG102',
    rssi: -45,
    advertisesService: true,
  );
  setUp(() async {
    now = DateTime(2026, 11, 2, 12);
    transport = FakeEegTransport();
    controller = EegController(transport, clock: () => now);
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await transport.close();
  });
  test('denied permission prevents scanning and remains recoverable', () async {
    transport.grantPermission = false;
    await controller.scan();
    expect(transport.calls, isNot(contains('scan')));
    expect(controller.error, contains('权限'));
    transport.grantPermission = true;
    await controller.scan();
    expect(transport.calls, contains('scan'));
    expect(controller.scanning, true);
  });
  test('Android local algorithms retain Android lead convention', () async {
    transport.status.addAll({'localAlgorithms': true, 'platform': 'android'});
    await controller.refreshAccess();
    await controller.connect(device);
    transport.packet('raw', rawPacket(lead: 2), now);
    expect(controller.localAlgorithms, true);
    expect(controller.lead, false);
    expect(controller.leadByte, 2);
  });
  test('iOS local algorithms retain Python Windows lead convention', () async {
    transport.status.addAll({'localAlgorithms': true, 'platform': 'ios'});
    await controller.refreshAccess();
    await controller.connect(device);
    transport.packet('raw', rawPacket(lead: 2), now);
    expect(controller.lead, true);
    expect(controller.leadByte, 2);
  });
  test(
    'Per-stream health never reuses missing, malformed, stale or previous-session values',
    () async {
      expect(
        controller.notificationHealth('frequency'),
        NotificationHealth.disconnected,
      );
      await controller.connect(device);
      expect(
        controller.notificationHealth('frequency'),
        NotificationHealth.waiting,
      );
      transport.packet('frequency', Uint8List.fromList([1, 2, 3, 4, 5]), now);
      expect(
        controller.notificationHealth('frequency'),
        NotificationHealth.normal,
      );
      expect(controller.notificationValue('frequency', 'gamma'), 5);
      transport.packet('frequency', Uint8List(2), now);
      expect(
        controller.notificationHealth('frequency'),
        NotificationHealth.invalid,
      );
      expect(controller.notificationValue('frequency', 'gamma'), isNull);
      transport.packet('frequency', Uint8List.fromList([5, 4, 3, 2, 1]), now);
      expect(
        controller.notificationHealth('frequency'),
        NotificationHealth.normal,
      );
      now = now.add(const Duration(seconds: 5));
      expect(
        controller.notificationHealth('frequency'),
        NotificationHealth.stale,
      );
      expect(controller.notificationValue('frequency', 'gamma'), isNull);
      await controller.disconnect();
      await controller.connect(device);
      expect(
        controller.notificationHealth('frequency'),
        NotificationHealth.waiting,
      );
      expect(controller.hasNotification('frequency'), false);
    },
  );
  test(
    'Optional sensor and blink/gnash notifications retain actual parsed results including zero',
    () async {
      await controller.connect(device);
      transport.packet('other', Uint8List(90), now);
      final flags = Uint8List(32)..[30] = 1;
      transport.packet('blink_gnash', flags, now);
      expect(controller.notificationHealth('other'), NotificationHealth.normal);
      expect(controller.notificationValue('other', 'acc_x'), 0);
      expect(controller.notificationValue('blink_gnash', 'gnash'), 1);
      expect(controller.notificationValue('blink_gnash', 'blink'), 0);
    },
  );
  test(
    'Python values are isolated by session and cleared on disconnect',
    () async {
      await controller.connect(device);
      transport.emit({
        'type': 'algorithm',
        'session': transport.session,
        'address': testDeviceAddress,
        'filtered_1': [0.1, 0.2],
        'filtered_2': [0.3, 0.4],
        'updates': [
          {'fuzzy_entropy_1': 0.5, 'fuzzy_entropy_2': null, 'emotion': 0.8},
        ],
        'receivedAt': now.millisecondsSinceEpoch,
      });
      controller.setFiltered(true);
      expect(controller.channel1, [0.1, 0.2]);
      expect(controller.algorithmValues['emotion'], 0.8);
      expect(controller.algorithmValues['fuzzy_entropy_2'], isNull);
      expect(controller.algorithmStale, false);
      now = now.add(const Duration(seconds: 5));
      expect(controller.algorithmStale, true);
      await controller.disconnect();
      expect(controller.channel1, isEmpty);
      expect(controller.algorithmValues, isEmpty);
    },
  );
  test(
    'scan keeps unnamed devices, deduplicates addresses and prioritizes EEG',
    () async {
      await controller.scan();
      transport.emit({
        'type': 'device',
        'address': '00:00:00:00:00:01',
        'name': '',
        'rssi': -30,
      });
      transport.emit({
        'type': 'device',
        'address': testDeviceAddress,
        'name': 'KSEEG102',
        'rssi': -80,
      });
      transport.emit({
        'type': 'device',
        'address': testDeviceAddress,
        'name': 'KSEEG102',
        'rssi': -60,
      });
      expect(controller.devices, hasLength(2));
      expect(controller.devices.first.address, testDeviceAddress);
      expect(controller.devices.last.label, '未命名蓝牙设备');
      expect(controller.devices.first.rssi, -60);
    },
  );
  test(
    'ready is distinct from real data, malformed packets cannot indicate receiving',
    () async {
      await controller.connect(device);
      expect(controller.connected, true);
      expect(controller.receiving, false);
      transport.packet('raw', Uint8List(20), now);
      expect(controller.parseErrors, 1);
      expect(controller.sampleCount, 0);
      expect(controller.receiving, false);
      expect(controller.lastPacketLength, 20);
      expect(controller.diagnosticReport, contains('解析失败：1'));
      expect(controller.lastHex, isNotEmpty);
      transport.packet('raw', rawPacket(), now);
      expect(controller.receiving, true);
      expect(controller.sampleCount, 16);
      expect(controller.power, 111);
      now = now.add(const Duration(seconds: 3));
      expect(controller.stale, true);
      expect(controller.dataStatus, '数据已停滞');
    },
  );
  test(
    'disconnect clears metrics, reconnect excludes previous session callbacks',
    () async {
      await controller.connect(device);
      final previous = transport.session;
      transport.packet('raw', rawPacket(), now);
      transport.packet('feature', Uint8List.fromList([80, 60, 20, 70]), now);
      await controller.disconnect();
      expect(controller.features, isEmpty);
      expect(controller.power, isNull);
      await controller.connect(device);
      transport.packet('raw', rawPacket(), now, fromSession: previous);
      expect(controller.sampleCount, 0);
      transport.packet('raw', rawPacket(), now);
      expect(controller.sampleCount, 16);
    },
  );
  test(
    'waveform display pause does not stop acquisition, buffers are bounded',
    () async {
      await controller.connect(device);
      controller.toggleDisplay();
      for (var i = 0; i < 100; i++) {
        transport.packet('raw', rawPacket(), now);
      }
      expect(controller.sampleCount, 1600);
      expect(controller.channel1, isEmpty);
      controller.toggleDisplay();
      expect(controller.channel1, hasLength(1024));
      expect(controller.channel2, hasLength(1024));
    },
  );
  test(
    'device metrics expire and recording export requires closing first',
    () async {
      await controller.connect(device);
      transport.packet('feature', Uint8List.fromList([80, 60, 20, 70]), now);
      expect(controller.metricsStale, false);
      now = now.add(const Duration(seconds: 5));
      expect(controller.metricsStale, true);
      await controller.toggleRecording();
      expect(controller.recording, true);
      await controller.exportRecording();
      expect(transport.calls, isNot(contains('exportRecording')));
      await controller.toggleRecording();
      await controller.exportRecording();
      expect(controller.recordingName, 'test.jsonl');
      expect(transport.calls, contains('exportRecording'));
    },
  );
  test(
    'local reception rate excludes first packet and is not inferred from a single packet',
    () async {
      await controller.connect(device);
      transport.packet('raw', rawPacket(), now);
      expect(controller.receivedSamplesPerSecond, isNull);
      now = now.add(const Duration(milliseconds: 100));
      transport.packet('raw', rawPacket(), now);
      expect(controller.receivedSamplesPerSecond, 160);
    },
  );
  test(
    'a ready connection without any raw notification times out visibly',
    () async {
      await controller.connect(device);
      expect(controller.waitingTimedOut, false);
      now = now.add(const Duration(seconds: 5));
      expect(controller.waitingTimedOut, true);
      expect(controller.dataStatus, '未收到原始数据');
      expect(controller.receiving, false);
      transport.packet('raw', rawPacket(), now);
      expect(controller.waitingTimedOut, false);
      expect(controller.receiving, true);
    },
  );
  test('recording failure event never reports a completed save', () async {
    await controller.connect(device);
    await controller.toggleRecording();
    transport.emit({
      'type': 'recording',
      'active': false,
      'state': 'saving',
      'name': 'partial.jsonl',
    });
    expect(controller.recordingState, 'saving');
    transport.emit({
      'type': 'recording',
      'active': false,
      'state': 'save_failed',
      'name': 'partial.jsonl',
    });
    transport.emit({'type': 'error', 'message': '测试写入失败'});
    expect(controller.recordingState, 'save_failed');
    expect(controller.recording, false);
    expect(controller.error, contains('写入失败'));
  });
  test(
    'foreground reset clears stale signal and requires a fresh notification',
    () async {
      await controller.connect(device);
      transport.packet('raw', rawPacket(), now);
      expect(controller.receiving, true);
      transport.emit({'type': 'algorithmReset'});
      expect(controller.connected, true);
      expect(controller.receiving, false);
      expect(controller.channel1, isEmpty);
      transport.packet('raw', rawPacket(), now);
      expect(controller.receiving, true);
    },
  );
  test(
    'switching local user removes previous device, waveform and file presentation',
    () async {
      await controller.connect(device);
      transport.packet('raw', rawPacket(), now);
      await controller.toggleRecording();
      await controller.toggleRecording();
      expect(controller.recordingName, isNotNull);
      await controller.disconnect();
      controller.clearUserPresentation();
      expect(controller.recordingName, isNull);
      expect(controller.selected, isNull);
      expect(controller.sampleCount, 0);
      expect(controller.logs, isEmpty);
      expect(controller.recordingState, 'idle');
    },
  );
}
