import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/features/device/acquisition_dashboard.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/features/shell/feedback_preferences.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/ui/neurox_brand.dart';
import 'support/fake_eeg_transport.dart';
import 'support/monitoring_fixture.dart';

void main() {
  testWidgets(
    'Task feedback survives start refresh and late defaults, while a new draft reloads defaults',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      await f.task.finish();
      f.task.clearDraft();
      const selected = FeedbackOptions(
        sound: true,
        vibration: true,
        notice: true,
      );
      f.task.setFeedback(selected);
      await f.task.refresh(prepareSignal: false);
      expect(f.task.feedback.toMap(), selected.toMap());
      f.task.clearDraft();
      final pending = Completer<Map<String, dynamic>>();
      f.backend.feedbackSettingsBarrier = pending.future;
      final loading = f.task.loadFeedbackPreferences();
      const changed = FeedbackOptions(notice: true);
      f.task.setFeedback(changed);
      pending.complete(const FeedbackOptions().toMap());
      await loading;
      expect(f.task.feedback.toMap(), changed.toMap());
      f.task.clearDraft();
      await f.task.refresh(prepareSignal: false);
      expect(f.task.feedback.toMap(), const FeedbackOptions().toMap());
      await f.close();
    },
  );

  test(
    'Mute preserves channel choices and ignores the former stage-only flag',
    () {
      const chosen = FeedbackOptions(
        sound: true,
        vibration: false,
        notice: true,
      );
      final mute = chosen.change('muted', true);
      expect(mute.enabled, false);
      expect(mute.sound, true);
      expect(mute.notice, true);
      expect(mute.vibration, false);
      expect(
        FeedbackOptions.fromMap(mute.toMap()).change('muted', false).toMap(),
        chosen.toMap(),
      );
      expect(FeedbackOptions.fromMap({'stageSilence': true}).muted, false);
    },
  );
  testWidgets(
    'Global mute reaches a running task without changing its channel override or reference',
    (tester) async {
      final f = MonitorFixture();
      await f.initialize();
      f.task.setFeedback(
        const FeedbackOptions(sound: true, vibration: false, notice: true),
      );
      f.task.applyFeedbackDefaults(
        const FeedbackOptions(
          sound: false,
          vibration: true,
          notice: false,
          muted: true,
        ),
      );
      expect(f.task.feedback.sound, true);
      expect(f.task.feedback.notice, true);
      expect(f.task.feedback.vibration, false);
      expect(f.task.feedback.enabled, false);
      expect(f.task.monitor!.stageSilenced, true);
      expect(f.task.monitor!.phase, 'running');
      expect(f.task.active, true);
      final baseline = f.task.monitor!.reference;
      f.task.applyFeedbackDefaults(
        const FeedbackOptions(sound: false, vibration: true, muted: false),
      );
      expect(f.task.feedback.enabled, true);
      expect(f.task.feedback.sound, true);
      expect(f.task.feedback.notice, true);
      expect(f.task.monitor!.stageSilenced, false);
      expect(f.task.monitor!.reference, same(baseline));
      await tester.pump();
      expect(f.backend.calls.where((m) => m == 'setFeedbackMute').length, 2);
      await f.close();
    },
  );
  testWidgets(
    'Charts hide stale/invalid values and never draw a missing raw stream',
    (tester) async {
      var now = DateTime(2026, 11, 4);
      final transport = FakeEegTransport();
      final eeg = EegController(transport, clock: () => now);
      await eeg.initialize();
      await eeg.connect(
        const EegDevice(
          address: testDeviceAddress,
          name: 'TEST',
          rssi: -40,
          advertisesService: true,
        ),
      );
      Widget page() => MaterialApp(
        theme: NeuroxBrand.theme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AcquisitionDashboard(controller: eeg),
          ),
        ),
      );
      await tester.pumpWidget(page());
      expect(
        tester
            .widget<CustomPaint>(find.byKey(const ValueKey('raw-chart-1')))
            .painter,
        isA<RawWavePainter>(),
      );
      expect(
        (tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('raw-chart-1')),
                    )
                    .painter!
                as RawWavePainter)
            .values,
        isEmpty,
      );
      transport.packet('raw', rawPacket(), now);
      transport.packet('feature', Uint8List.fromList([72, 48, 255, 15]), now);
      transport.packet(
        'frequency',
        Uint8List.fromList([15, 32, 80, 110, 9]),
        now,
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(
        (tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('raw-chart-1')),
                    )
                    .painter!
                as RawWavePainter)
            .values,
        hasLength(16),
      );
      expect(
        (tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('metric-gauge-tired')),
                    )
                    .painter!
                as MetricArcPainter)
            .progress,
        isNull,
      );
      expect(
        find.text('255'),
        findsOneWidget,
      ); // spectrum scale only; invalid fatigue not displayed
      now = now.add(const Duration(seconds: 6));
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(
        (tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('raw-chart-1')),
                    )
                    .painter!
                as RawWavePainter)
            .values,
        isEmpty,
      );
      expect(
        (tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('metric-gauge-attention')),
                    )
                    .painter!
                as MetricArcPainter)
            .progress,
        isNull,
      );
      expect(find.text('72'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      eeg.dispose();
      await transport.close();
    },
  );
  testWidgets(
    'Profile uses centered spaced columns and a settings page preserves mute choices without reload',
    (tester) async {
      var saved = <String, dynamic>{
        'sound': true,
        'vibration': false,
        'notice': true,
        'muted': false,
      };
      final writes = <Map<String, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalAccount.channel, (call) async {
            if (call.method == 'sessions') return [];
            if (call.method == 'feedbackSettings') return saved;
            if (call.method == 'setFeedbackSettings') {
              saved = Map<String, dynamic>.from(call.arguments as Map);
              writes.add(Map.from(saved));
              return null;
            }
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('neurox/notifications'),
            (call) async => {},
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('neurox/notifications'),
              null,
            );
      });
      final account = LocalAccount()
        ..profile = {'name': 'student', 'nickname': '同学'};
      final transport = FakeEegTransport();
      final eeg = EegController(transport);
      await tester.pumpWidget(
        MaterialApp(
          theme: NeuroxBrand.theme(Brightness.light),
          home: ProfilePage(
            account: account,
            controller: eeg,
            openHistory: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('场景任务与专注'), findsNothing);
      expect(find.textContaining('SQLite'), findsNothing);
      expect(
        tester.getTopLeft(find.text('修改密码')).dy,
        tester.getTopLeft(find.text('本机存储')).dy,
      );
      expect(
        tester.getTopLeft(find.text('本机存储')).dx,
        greaterThan(tester.getTopLeft(find.text('修改密码')).dx + 100),
      );
      await tester.ensureVisible(find.text('提醒方式'));
      await tester.tap(find.text('提醒方式'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('注册其他账号'), findsNothing);
      expect(find.text('重新读取反馈偏好'), findsNothing);
      expect(find.text('关键阶段静默'), findsNothing);
      await tester.tap(find.byKey(const Key('muteAllFeedback')));
      await tester.pumpAndSettle();
      expect(saved['muted'], true);
      expect(saved['sound'], true);
      expect(saved['notice'], true);
      await tester.tap(find.byKey(const Key('muteAllFeedback')));
      await tester.pumpAndSettle();
      expect(saved['muted'], false);
      expect(writes, hasLength(2));
      expect(saved['sound'], true);
      expect(saved['vibration'], false);
      expect(saved['notice'], true);
      await tester.pumpWidget(const SizedBox());
      eeg.dispose();
      account.dispose();
      await transport.close();
    },
  );
  testWidgets(
    'Unreadable preferences cannot overwrite the saved channel choices',
    (tester) async {
      var writes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalAccount.channel, (call) async {
            if (call.method == 'feedbackSettings') {
              throw PlatformException(
                code: 'disk',
                message: 'TEST read failed',
              );
            }
            if (call.method == 'setFeedbackSettings') writes++;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FeedbackDefaults(concise: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('muteAllFeedback')))
            .onChanged,
        isNull,
      );
      expect(writes, 0);
      expect(find.text('提醒设置读取失败，请重试。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Closing feedback settings during save still applies mute to the app',
    (tester) async {
      final pending = Completer<void>();
      FeedbackOptions? applied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalAccount.channel, (call) async {
            if (call.method == 'feedbackSettings') {
              return {'sound': true, 'notice': true};
            }
            if (call.method == 'setFeedbackSettings') await pending.future;
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('neurox/notifications'),
            (_) async => null,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalAccount.channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('neurox/notifications'),
              null,
            );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeedbackDefaults(concise: true, onSaved: (v) => applied = v),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('muteAllFeedback')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pumpAndSettle();
      expect(applied?.muted, true);
      expect(applied?.sound, true);
      expect(applied?.notice, true);
      expect(tester.takeException(), isNull);
    },
  );
}
