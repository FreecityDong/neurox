import 'package:neurox/l10n/app_language.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Pages never receive credential material; identity is also checked natively.
class LocalAccount extends ChangeNotifier {
  static const channel = MethodChannel('neurox/local');
  String state = 'loading';
  String? _error;
  String? get error => _error == null ? null : trSource(_error!);
  set error(String? value) => _error = value;
  String name = '';
  bool busy = false;
  bool recordingActive = false;
  Map<String, dynamic>? profile;
  int _generation = 0;

  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) =>
      channel.invokeMethod<T>(method, args);

  Future<void> check() async {
    state = 'loading';
    error = null;
    notifyListeners();
    try {
      final value = Map<String, dynamic>.from(await call<Map>('check') ?? {});
      state = value['state'] as String;
      name = value['name'] as String? ?? '';
      recordingActive = value['recordingActive'] == true;
    } catch (e) {
      state = 'error';
      error = describe(e);
    }
    notifyListeners();
  }

  Future<bool> authenticate(String name, String password) async {
    if (busy) return false;
    final generation = _generation;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final value = await call<Map>(
        state == 'register' ? 'register' : 'login',
        {'name': name.trim(), 'password': password},
      );
      if (generation != _generation) return false;
      profile = Map<String, dynamic>.from(value!);
      state = 'authenticated';
      return true;
    } catch (e) {
      if (generation == _generation) error = describe(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Immediate route guard, before asynchronous stop/save completes.
  void lock({bool? recording}) {
    recordingActive = recording ?? recordingActive;
    _generation++;
    name = profile?['name'] as String? ?? name;
    profile = null;
    state = 'login';
    error = null;
    notifyListeners();
  }

  void showRegistration(bool register) {
    if (busy) return;
    state = register ? 'register' : 'login';
    error = null;
    notifyListeners();
  }

  Future<void> logout() async {
    await call<void>('logout');
    lock();
    await check();
  }

  static String describe(Object e) => e is PlatformException
      ? e.message ?? '本机操作失败，请重试。'
      : e is MissingPluginException
      ? '当前平台未接入本机账号服务。请使用 iOS 版本。'
      : e.toString();
}
