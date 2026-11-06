import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'messages_en.dart';

/// App-wide preference: available before login and independent of account data.
class AppLanguage extends ChangeNotifier {
  AppLanguage({this.channel = const MethodChannel('neurox/preferences')});
  static final instance = AppLanguage();
  final MethodChannel channel;
  String code = 'zh';
  bool busy = false;
  Locale get locale => Locale(code);
  bool get english => code == 'en';

  Future<void> load() async {
    try {
      final saved = await channel.invokeMethod<String>('getLanguage');
      if (saved == 'en' || saved == 'zh') code = saved!;
    } on MissingPluginException {
      // Legacy unsupported hosts retain the current in-memory/default language.
    } on PlatformException {
      // A read failure never overwrites the saved preference.
    }
    notifyListeners();
  }

  Future<void> select(String value) async {
    if (busy || !['zh', 'en'].contains(value) || value == code) return;
    busy = true;
    notifyListeners();
    try {
      await channel.invokeMethod<void>('setLanguage', {'language': value});
      code = value;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  void resetForTest([String language = 'zh']) {
    code = language;
    busy = false;
  }
}

String tr(String key, [Map<String, Object?> values = const {}]) {
  final text = AppLanguage.instance.english ? englishMessages[key] ?? key : key;
  return text.replaceAllMapped(
    RegExp(r'\{(p\d+)\}'),
    (m) => values[m[1]]?.toString() ?? m[0]!,
  );
}

final _templates = englishMessages.entries
    .where((e) => e.key.contains(RegExp(r'\{p\d+\}')))
    .map((entry) {
      final names = RegExp(
        r'\{p\d+\}',
      ).allMatches(entry.key).map((m) => m[0]!).toList();
      RegExp pattern(String value) {
        final segments = value.split(RegExp(r'\{p\d+\}'));
        return RegExp(
          '^${segments.map(RegExp.escape).join('(.*?)')}\$',
          dotAll: true,
        );
      }

      final englishOrder = RegExp(
        r'\{p\d+\}',
      ).allMatches(entry.value).map((m) => m[0]!).toList();
      return (
        entry: entry,
        names: names,
        enNames: englishOrder,
        zh: pattern(entry.key),
        en: pattern(entry.value),
      );
    })
    .toList();
final _englishKeys = {
  for (final entry in englishMessages.entries) entry.value: entry.key,
};

/// Only for app-generated status/error/metadata. Never pass user-entered content.
/// Canonical source messages remain stored as written; changing locale only affects presentation.
String trSource(String text) {
  final key = englishMessages.containsKey(text) ? text : _englishKeys[text];
  if (key != null) return tr(key);
  final stamp = RegExp(
    r'^(\d\d:\d\d:\d\d  )(.*)$',
    dotAll: true,
  ).firstMatch(text);
  if (stamp != null) return '${stamp[1]}${trSource(stamp[2]!)}';
  for (final template in _templates) {
    final zh = template.zh.firstMatch(text);
    final en = zh == null ? template.en.firstMatch(text) : null;
    final match = zh ?? en;
    if (match == null) continue;
    final names = zh != null ? template.names : template.enNames;
    final values = <String, Object?>{};
    for (var i = 0; i < names.length; i++) {
      values[names[i].substring(1, names[i].length - 1)] = match.group(i + 1);
    }
    return tr(template.entry.key, values);
  }
  if (text.contains('\n')) return text.split('\n').map(trSource).join('\n');
  return text; // Preserve opaque system/SDK diagnostics.
}

mixin LanguageAware<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    AppLanguage.instance.addListener(_languageChanged);
  }

  void _languageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppLanguage.instance.removeListener(_languageChanged);
    super.dispose();
  }
}
