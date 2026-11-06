import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/main.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'support/fake_eeg_transport.dart';

void main() {
  for (final language in ['zh', 'en']) {
    for (final (width, pythonBridge, localAlgorithms, platform) in [
      (320.0, false, false, 'android'),
      (800.0, false, false, 'android'),
      (320.0, true, false, 'web'),
      (800.0, true, false, 'web'),
      (320.0, false, true, 'ios'),
      (800.0, false, true, 'ios'),
      (320.0, false, true, 'android'),
      (800.0, false, true, 'android'),
    ]) {
      testWidgets(
        '$language device page width $width Python=$pythonBridge local=$localAlgorithms platform=$platform with large text',
        (tester) async {
          AppLanguage.instance.resetForTest(language);
          addTearDown(() => AppLanguage.instance.resetForTest());
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 1.5;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final transport = FakeEegTransport();
          transport.status['pythonBridge'] = pythonBridge;
          transport.status['localAlgorithms'] = localAlgorithms;
          transport.status['platform'] = platform;
          final controller = EegController(transport);
          await tester.pumpWidget(NeuroxApp(controller: controller));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await controller.connect(
            const EegDevice(
              address: testDeviceAddress,
              name: 'KSEEG102',
              rssi: -50,
              advertisesService: true,
            ),
          );
          transport.packet('raw', rawPacket(), DateTime.now());
          await tester.pump(const Duration(milliseconds: 120));
          expect(find.text(tr('还原滤波波形')), findsNothing);
          expect(
            find.byKey(const Key('toggleDiagnosticRecording')),
            findsNothing,
          );
          expect(find.byKey(const Key('copyDiagnostics')), findsNothing);
          await tester.drag(find.byType(ListView), const Offset(0, -650));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
          await transport.close();
        },
      );
    }
  }
}
