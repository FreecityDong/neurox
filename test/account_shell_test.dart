import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/main.dart';
import 'package:neurox/features/shell/app_shell.dart';
import 'package:neurox/features/account/local_account.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'support/fake_eeg_transport.dart';

void main() {
  final calls = <String>[];
  late FakeEegTransport transport;
  late EegController controller;
  var initial = 'register';
  var failure = false;
  setUp(() {
    calls.clear();
    initial = 'register';
    failure = false;
    transport = FakeEegTransport();
    controller = EegController(transport);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalAccount.channel, (call) async {
          calls.add(call.method);
          if (failure) {
            throw PlatformException(code: 'storage', message: '存储不可用');
          }
          switch (call.method) {
            case 'check':
              return {'state': initial};
            case 'register':
            case 'login':
              return {
                'id': 'test-user',
                'name': 'student',
                'nickname': '同学',
                'reminders': 0,
              };
            case 'sessions':
            case 'legacy':
              return [];
            default:
              return null;
          }
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalAccount.channel, null);
    await transport.close();
  });
  Future<void> enter(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('accountName')), 'student');
    await tester.enterText(
      find.byKey(const Key('accountPassword')),
      'password-1234',
    );
    if (initial == 'register') {
      await tester.enterText(
        find.byKey(const Key('confirmPassword')),
        'password-1234',
      );
    }
    await tester.ensureVisible(find.byKey(const Key('submitAccount')));
    await tester.tap(find.byKey(const Key('submitAccount')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'register gates BLE and exposes five task modules with four navigation tabs',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('创建本机账号'), findsOneWidget);
      expect(transport.calls, isEmpty);
      await enter(tester);
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.text('基线任务'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('学习场景'), 120);
      expect(find.text('学习场景'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('主动恢复'), 200);
      expect(find.text('竞技／运动训练'), findsOneWidget);
      expect(find.text('主动恢复'), findsOneWidget);
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(find.text('还没有记录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('password confirmation rejects mismatched registration', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(NeuroxApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('accountName')), 'student');
    await tester.enterText(
      find.byKey(const Key('accountPassword')),
      'password-1234',
    );
    await tester.enterText(
      find.byKey(const Key('confirmPassword')),
      'mismatch',
    );
    expect(find.text('两次密码不一致'), findsNothing);
    await tester.tap(find.byKey(const Key('accountName')));
    await tester.pumpAndSettle();
    expect(find.text('两次密码不一致'), findsOneWidget);
    expect(calls, isNot(contains('register')));
    await tester.ensureVisible(find.byKey(const Key('submitAccount')));
    await tester.tap(find.byKey(const Key('submitAccount')));
    await tester.pumpAndSettle();
    expect(find.text('两次密码不一致'), findsOneWidget);
    expect(calls, isNot(contains('register')));
    await tester.enterText(
      find.byKey(const Key('confirmPassword')),
      'password-1234',
    );
    await tester.tap(find.byKey(const Key('accountName')));
    await tester.pumpAndSettle();
    expect(find.text('两次密码不一致'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('accountPassword')),
      'changed-password',
    );
    await tester.tap(find.byKey(const Key('accountName')));
    await tester.pumpAndSettle();
    expect(find.text('两次密码不一致'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'storage errors are not interpreted as no account or empty history',
    (tester) async {
      failure = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('本机存储需要处理'), findsOneWidget);
      expect(find.byKey(const Key('submitAccount')), findsNothing);
      expect(transport.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('app switching preserves login, current page and input', (
    tester,
  ) async {
    initial = 'login';
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(NeuroxApp(controller: controller));
    await tester.pumpAndSettle();
    await enter(tester);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改密码'));
    await tester.pumpAndSettle();
    expect(find.text('旧密码'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('旧密码'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('旧密码'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('accountName')), findsNothing);
    expect(find.text('旧密码'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('compact iOS shell has no overflow with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    initial = 'login';
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(NeuroxApp(controller: controller));
    await tester.pumpAndSettle();
    await enter(tester);
    for (final title in ['设备', '历史', '我的', '首页']) {
      await tester.tap(find.widgetWithText(NavigationDestination, title));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'six-character registration remains available before login; Me has no extra registration entry',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      initial = 'login';
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('switchAccountMode')));
      await tester.tap(find.byKey(const Key('switchAccountMode')));
      await tester.pumpAndSettle();
      expect(find.text('创建本机账号'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('accountName')), 'another');
      await tester.enterText(find.byKey(const Key('accountPassword')), '12345');
      await tester.enterText(find.byKey(const Key('confirmPassword')), '12345');
      await tester.ensureVisible(find.byKey(const Key('submitAccount')));
      await tester.tap(find.byKey(const Key('submitAccount')));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('register')));
      await tester.enterText(
        find.byKey(const Key('accountPassword')),
        '123456',
      );
      await tester.enterText(
        find.byKey(const Key('confirmPassword')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('submitAccount')));
      await tester.pumpAndSettle();
      expect(calls, contains('register'));
      await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
      await tester.pumpAndSettle();
      expect(find.text('注册其他账号'), findsNothing);
      expect(find.text('注册其他本机账号'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'device overview opens simplified checks without standalone recording and keeps BLE connected',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(NeuroxApp(controller: controller));
      await tester.pumpAndSettle();
      await enter(tester);
      await controller.connect(
        const EegDevice(
          address: testDeviceAddress,
          name: 'TEST INPUT',
          rssi: -50,
          advertisesService: true,
        ),
      );
      await tester.tap(find.widgetWithText(NavigationDestination, '设备'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggleDiagnosticRecording')), findsNothing);
      await tester.ensureVisible(find.text('采集诊断'));
      await tester.tap(find.text('采集诊断'));
      await tester.pumpAndSettle();
      expect(find.text('实时脑电'), findsOneWidget);
      expect(find.text('设备侧指标'), findsOneWidget);
      expect(find.text('连接与数据详情'), findsNothing);
      expect(find.byKey(const Key('disconnect')), findsNothing);
      expect(find.byKey(const Key('toggleDiagnosticRecording')), findsNothing);
      expect(transport.calls, isNot(contains('startRecording')));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(controller.connected, true);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'change password checks confirmation when focus leaves before saving',
    (tester) async {
      final account = LocalAccount()
        ..profile = {'name': 'student', 'nickname': '同学'};
      await tester.pumpWidget(
        MaterialApp(
          home: AccountEdit(account: account, mode: 'password'),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, '新密码（6–128个字符）'),
        '123456',
      );
      await tester.enterText(
        find.byKey(const Key('confirmNewPassword')),
        '654321',
      );
      await tester.tap(find.widgetWithText(TextField, '旧密码'));
      await tester.pumpAndSettle();
      expect(find.text('两次密码不一致'), findsOneWidget);
      expect(calls, isNot(contains('changePassword')));
      await tester.enterText(
        find.byKey(const Key('confirmNewPassword')),
        '123456',
      );
      await tester.tap(find.widgetWithText(TextField, '旧密码'));
      await tester.pumpAndSettle();
      expect(find.text('两次密码不一致'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      account.dispose();
      controller.dispose();
    },
  );
}
