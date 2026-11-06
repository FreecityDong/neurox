import 'ui/neurox_brand.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, kReleaseMode, defaultTargetPlatform, TargetPlatform;
import 'data/devices/browser_eeg_transport.dart';
import 'data/devices/eeg_transport.dart';
import 'data/devices/local_algorithm_transport.dart';
import 'features/device/device_page.dart';
import 'features/device/eeg_controller.dart';
import 'features/account/local_account.dart';
import 'features/account/account_gate.dart';
import 'features/shell/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLanguage.instance.load();
  runApp(const NeuroxApp());
}

EegTransport _createTransport() => kIsWeb
    ? createBrowserEegTransport()
    : (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android)
    ? LocalAlgorithmTransport(AndroidEegTransport())
    : AndroidEegTransport();

class NeuroxApp extends StatefulWidget {
  const NeuroxApp({super.key, this.controller});
  final EegController? controller;

  @override
  State<NeuroxApp> createState() => _NeuroxAppState();
}

class _NeuroxAppState extends State<NeuroxApp> with WidgetsBindingObserver {
  final account = LocalAccount();
  String? _presentedUser;
  void _accountChanged() {
    if (account.state != 'authenticated') return;
    final id = account.profile?['id'] as String?;
    if (_presentedUser != null && id != _presentedUser) {
      controller.clearUserPresentation();
    }
    _presentedUser = id;
  }

  bool get localAccountEnabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        account.state == 'authenticated') {
      controller.refreshAccess();
    }
  }

  late EegController controller;
  @override
  void initState() {
    super.initState();
    if (kReleaseMode &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('NeuroX release: first Flutter frame ready');
        unawaited(
          const MethodChannel(
            'neurox/startup',
          ).invokeMethod<void>('firstFrameReady').catchError((Object _) {}),
        );
      });
    }
    WidgetsBinding.instance.addObserver(this);
    controller = widget.controller ?? EegController(_createTransport());
    account.addListener(_accountChanged);
    if (localAccountEnabled) account.check();
  }

  @override
  void didUpdateWidget(covariant NeuroxApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) controller.dispose();
      controller = widget.controller ?? EegController(_createTransport());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    account.removeListener(_accountChanged);
    account.dispose();
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([account, AppLanguage.instance]),
    builder: (context, _) => MaterialApp(
      key: ValueKey(localAccountEnabled && account.state == 'authenticated'),
      title: 'NeuroX',
      locale: AppLanguage.instance.locale,
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: localAccountEnabled
          ? account.state == 'authenticated'
                ? AppShell(account: account, controller: controller)
                : AccountGate(
                    key: ValueKey(account.state == 'register'),
                    account: account,
                  )
          : DevicePage(
              key: ObjectKey(controller),
              controller: controller,
              ownsController: false,
            ),
    ),
  );

  ThemeData _theme(Brightness brightness) => NeuroxBrand.theme(brightness);
}
