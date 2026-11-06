import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/main.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'support/fake_eeg_transport.dart';

void main() {
  testWidgets(
    'scan, connect, show real packet state, disconnect and reconnect',
    (tester) async {
      final transport = FakeEegTransport();
      final controller = EegController(transport);
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pump();
      expect(find.text('连接你的脑电设备'), findsOneWidget);
      await tester.tap(find.byKey(const Key('scan')));
      await tester.pump();
      transport.emit({
        'type': 'device',
        'address': testDeviceAddress,
        'name': 'KSEEG102',
        'rssi': -45,
        'advertisesService': true,
      });
      transport.emit({'type': 'scan', 'scanning': false});
      await tester.pump();
      await tester.ensureVisible(find.text('连接'));
      await tester.tap(find.text('连接'));
      await tester.pump();
      expect(controller.connected, true);
      expect(controller.receiving, false);
      transport.packet('raw', rawPacket(), DateTime.now());
      await tester.pump(const Duration(milliseconds: 120));
      expect(controller.receiving, true);
      expect(find.text('解析正常'), findsWidgets);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('disconnect')));
      await tester.tap(find.byKey(const Key('disconnect')));
      await tester.pump();
      expect(controller.receiving, false);
      expect(find.byKey(const Key('reconnect')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await transport.close();
    },
  );
  testWidgets('permission denial is shown with a recovery action', (
    tester,
  ) async {
    final transport = FakeEegTransport()..grantPermission = false;
    final controller = EegController(transport);
    await tester.pumpWidget(NeuroxApp(controller: controller));
    await tester.pump();
    await tester.tap(find.byKey(const Key('scan')));
    await tester.pump();
    expect(find.textContaining('需要蓝牙权限'), findsOneWidget);
    expect(transport.calls, isNot(contains('scan')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transport.close();
  });
}
