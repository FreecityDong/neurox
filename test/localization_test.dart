import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'package:neurox/features/shell/language_settings.dart';
import 'package:neurox/main.dart';
import 'support/fake_eeg_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preferences = MethodChannel('neurox/preferences');
  const notifications = MethodChannel('neurox/notifications');
  String saved = 'zh';
  bool failSave = false;
  final channelCalls = <String>[];
  setUp(() {
    saved = 'zh';
    failSave = false;
    channelCalls.clear();
    AppLanguage.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preferences, (call) async {
          if (call.method == 'getLanguage') return saved;
          if (failSave) {
            throw PlatformException(code: 'disk', message: 'save failed');
          }
          saved = (call.arguments as Map)['language'] as String;
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          notifications,
          (_) async => {'enabled': false, 'authorization': 0},
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalAccount.channel, (call) async {
          channelCalls.add(call.method);
          switch (call.method) {
            case 'check':
              return {'state': 'login', 'name': 'student'};
            case 'login':
              return {
                'id': 'test-user',
                'name': 'student',
                'nickname': '中文昵称',
                'reminders': 0,
              };
            case 'sessions':
              return [
                {
                  'id': 'record',
                  'name': '采集诊断',
                  'state': 'saved',
                  'packets': 2,
                  'samples': 32,
                  'started': 1000,
                  'exists': true,
                  'bytes': 300,
                },
              ];
            case 'detail':
              return {
                'id': 'record',
                'name': '采集诊断',
                'state': 'saved',
                'packets': 2,
                'samples': 32,
                'started': 1000,
                'ended': 1002,
                'device': '设备原名',
                'exists': true,
                'bytes': 300,
                'path': 'test.jsonl',
                'reason': '用户停止记录',
                'source': '旧版文件；来源、算法与采集配置尚未核验',
              };
            case 'legacy':
              return [];
            default:
              return null;
          }
        });
  });
  tearDown(() {
    AppLanguage.instance.resetForTest();
    for (final channel in [preferences, notifications, LocalAccount.channel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  for (final register in [false, true]) {
    testWidgets(
      'Pre-login language switch persists and preserves ${register ? 'registration' : 'login'} input',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final transport = FakeEegTransport();
        final controller = EegController(transport);
        await tester.pumpWidget(NeuroxApp(controller: controller));
        await tester.pumpAndSettle();
        if (register) {
          await tester.ensureVisible(
            find.byKey(const Key('switchAccountMode')),
          );
          await tester.tap(find.byKey(const Key('switchAccountMode')));
          await tester.pumpAndSettle();
        }
        await tester.enterText(
          find.byKey(const Key('accountName')),
          'student_2',
        );
        await tester.enterText(
          find.byKey(const Key('accountPassword')),
          '123456',
        );
        if (register) {
          await tester.enterText(find.byType(TextFormField).last, '123456');
        }
        await tester.ensureVisible(find.byKey(const Key('accountLanguage')));
        await tester.tap(find.byKey(const Key('accountLanguage')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('English').last);
        await tester.pumpAndSettle();
        expect(saved, 'en');
        expect(AppLanguage.instance.code, 'en');
        expect(find.byKey(const Key('accountName')), findsOneWidget);
        expect(find.text(tr('登录本机账号')), findsNothing);
        if (register) {
          expect(find.text(tr('创建本机账号')), findsOneWidget);
        }
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('accountName')))
              .controller!
              .text,
          'student_2',
        );
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('accountPassword')))
              .controller!
              .text,
          '123456',
        );
        if (register) {
          expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField).last)
                .controller!
                .text,
            '123456',
          );
        }
        expect(channelCalls, isNot(contains('login')));
        expect(channelCalls, isNot(contains('register')));
        await AppLanguage.instance.load();
        expect(AppLanguage.instance.code, 'en');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await transport.close();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  testWidgets(
    'Pre-login language save failure keeps the current language and can retry',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final transport = FakeEegTransport();
      final controller = EegController(transport);
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pumpAndSettle();
      failSave = true;
      await tester.tap(find.byKey(const Key('accountLanguage')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(saved, 'zh');
      expect(AppLanguage.instance.code, 'zh');
      expect(find.text('语言设置未保存，请重试。'), findsOneWidget);
      failSave = false;
      await tester.tap(find.byKey(const Key('accountLanguage')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(saved, 'en');
      expect(find.text('语言设置未保存，请重试。'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await transport.close();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  test(
    'language persists, rejects unsupported input and reports save failure without changing language',
    () async {
      await AppLanguage.instance.select('en');
      expect(saved, 'en');
      expect(tr('两次密码不一致'), 'The passwords do not match');
      final restarted = AppLanguage();
      await restarted.load();
      expect(restarted.code, 'en');
      restarted.dispose();
      await AppLanguage.instance.select('unsupported');
      expect(saved, 'en');
      failSave = true;
      await expectLater(
        AppLanguage.instance.select('zh'),
        throwsA(isA<PlatformException>()),
      );
      expect(AppLanguage.instance.code, 'en');
      expect(AppLanguage.instance.busy, false);
      expect(
        trSource('连续验证失败，请等待12秒后重试。'),
        'Too many failed attempts. Wait 12 seconds and retry.',
      );
      expect(trSource('连接失败：TEST'), 'Connection failed: TEST');
      expect(tr('你好，{p0}', {'p0': '设备'}), 'Hello, 设备');
    },
  );
  testWidgets(
    'Me language switch retains active capture, translates history and survives logout',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final transport = FakeEegTransport();
      final controller = EegController(transport);
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('accountPassword')),
        '123456',
      );
      await tester.ensureVisible(find.byKey(const Key('submitAccount')));
      await tester.tap(find.byKey(const Key('submitAccount')));
      await tester.pumpAndSettle();
      await controller.connect(
        const EegDevice(
          address: testDeviceAddress,
          name: '设备原名',
          rssi: -50,
          advertisesService: true,
        ),
      );
      await controller.toggleRecording();
      await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(tr('语言设置')), 250);
      await tester.tap(find.text(tr('语言设置')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(saved, 'en');
      expect(find.text('Language settings'), findsWidgets);
      expect(controller.recording, true);
      expect(transport.calls.where((e) => e == 'connect').length, 1);
      expect(transport.calls, isNot(contains('disconnect')));
      expect(controller.selected!.label, '设备原名');
      await tester.tap(find.text(tr('完成')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NavigationDestination, 'Me'), findsOneWidget);
      await tester.tap(find.widgetWithText(NavigationDestination, 'History'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history-card-record')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-card-record')));
      await tester.pumpAndSettle();
      expect(find.text('Diagnostic record details'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Technical details'), 200);
      await tester.tap(find.text('Technical details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Recording stopped by user'), findsOneWidget);
      expect(find.textContaining('设备原名'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, 'Me'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Log out'), 250);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(find.text('Log out?'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('accountName')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, tr('登录')), findsOneWidget);
      expect(find.text('Log in to a local account'), findsNothing);
      expect(saved, 'en');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await transport.close();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('failed language save keeps the displayed selection consistent', (
    tester,
  ) async {
    failSave = true;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LanguageSettings())),
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(find.text('语言设置未保存，请重试。'), findsOneWidget);
    expect(AppLanguage.instance.code, 'zh');
    expect(find.text('简体中文'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'English device page and account forms fit 320px with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      AppLanguage.instance.resetForTest('en');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final transport = FakeEegTransport();
      final controller = EegController(transport);
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const Key('accountPassword')),
        '123456',
      );
      await tester.ensureVisible(find.byKey(const Key('submitAccount')));
      await tester.tap(find.byKey(const Key('submitAccount')));
      await tester.pumpAndSettle();
      for (final name in ['Device', 'History', 'Me']) {
        await tester.tap(find.widgetWithText(NavigationDestination, name));
        await tester.pumpAndSettle();
        final exception = tester.takeException();
        if (exception != null) debugPrint('Overflow on $name: $exception');
        expect(exception, isNull);
      }
      await tester.scrollUntilVisible(find.text(tr('语言设置')), 250);
      await tester.tap(find.text(tr('语言设置')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await transport.close();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
