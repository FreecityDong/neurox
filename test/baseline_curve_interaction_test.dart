import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/tasks/curve_reading.dart';
import 'package:neurox/features/tasks/scene_widgets.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/l10n/app_language.dart';
import 'support/fake_eeg_transport.dart';

final points = <Map<String, dynamic>>[
  {
    'type': 'sample',
    'wallSeconds': 0.0,
    'scores': {'attention': 40.0, 'relax': 50.0},
  },
  {
    'type': 'sample',
    'wallSeconds': 1.0,
    'scores': {'attention': 42.0, 'relax': 52.0},
  },
  {
    'type': 'sample',
    'wallSeconds': 4.0,
    'scores': {'attention': 48.0, 'relax': 58.0},
  },
];
void main() {
  test(
    'Read recorded values, reject missing intervals and invalid scores without interpolation',
    () {
      expect(readCurve(points, 1.1).attention, 42);
      expect(readCurve(points, 1.1).time, 1);
      expect(readCurve(points, 2.5).attention, isNull);
      expect(readCurve(points, 2.5).relax, isNull);
      final bad = readCurve([
        {
          'wallSeconds': 1,
          'scores': {'attention': double.nan, 'relax': 101},
        },
      ], 1);
      expect(bad.attention, isNull);
      expect(bad.relax, isNull);
      expect(readCurve([], 0).attention, isNull);
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language baseline tap and drag show exact readings and missing values at 320px',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        addTearDown(() => AppLanguage.instance.resetForTest());
        tester.view.physicalSize = const Size(320, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MediaQuery(
                  data: const MediaQueryData(
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SceneCurve(
                      events: points,
                      interactive: true,
                      observationOnly: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final plot = find.byKey(const ValueKey('baseline-interactive-plot'));
        final rect = tester.getRect(plot);
        await tester.tapAt(
          Offset(rect.left + rect.width * .25, rect.center.dy),
        );
        await tester.pump();
        expect(find.text(tr('专注：{p0}', {'p0': '42.0'})), findsOneWidget);
        expect(find.text(tr('放松：{p0}', {'p0': '52.0'})), findsOneWidget);
        await tester.tapAt(
          Offset(rect.left + rect.width * .625, rect.center.dy),
        );
        await tester.pump();
        expect(find.text(tr('专注：{p0}', {'p0': '—'})), findsOneWidget);
        expect(find.text(tr('该时刻暂无有效指标，虚线不代表实测值')), findsOneWidget);
        await tester.dragFrom(
          Offset(rect.left + rect.width * .25, rect.center.dy),
          Offset(rect.width * .8, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text(tr('专注：{p0}', {'p0': '48.0'})), findsOneWidget);
        expect(find.text('0:02'), findsOneWidget);
        expect(find.text('80'), findsOneWidget);
        expect(find.text('20'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('Other scene curves retain default display without interaction', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SceneCurve(events: points)),
      ),
    );
    expect(
      find.byKey(const ValueKey('baseline-interactive-plot')),
      findsNothing,
    );
    expect(find.text('80'), findsNothing);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('采集与调整记录'), findsOneWidget);
  });
  for (final kind in ['baseline', 'diagnostic']) {
    testWidgets('$kind technical details apply removal only to baseline', (
      tester,
    ) async {
      AppLanguage.instance.resetForTest();
      final account = LocalAccount();
      final transport = FakeEegTransport();
      final eeg = EegController(transport);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalAccount.channel, (call) async {
            if (call.method == 'detail') {
              return {
                'id': 'example',
                'kind': kind,
                'state': 'saved',
                'task_state': 'baseline_incomplete',
                'name': 'Example',
                'started': 1000,
                'ended': 1010,
                'device': 'Fake',
                'exists': true,
                'packets': 10,
                'samples': 20,
                'bytes': 30,
                'reason': '测试停止原因',
                'source': '测试来源',
                'baseline_json': {},
                'attempts': [],
                'windows': [],
              };
            }
            return <String, dynamic>{};
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
        account.dispose();
        eeg.dispose();
        await transport.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RecordDetail(account: account, controller: eeg, id: 'example'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('技术详情'), 200);
      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.text('保存状态'), findsOneWidget);
      expect(
        find.text('测试停止原因'),
        kind == 'baseline' ? findsNothing : findsOneWidget,
      );
      expect(
        find.textContaining('测试来源'),
        kind == 'baseline' ? findsNothing : findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
