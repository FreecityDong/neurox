import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';

class LanguageSettings extends StatefulWidget {
  const LanguageSettings({super.key, this.concise = false});
  final bool concise;
  @override
  State<LanguageSettings> createState() => _LanguageSettingsState();
}

class _LanguageSettingsState extends State<LanguageSettings> {
  String? error;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppLanguage.instance,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.concise)
              Text(tr('语言设置'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (!widget.concise) Text(tr('语言选择保存在本机，登录页和下次启动均生效。')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'language-${AppLanguage.instance.code}-${error ?? ''}',
              ),
              initialValue: AppLanguage.instance.code,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('选择界面语言')),
              items: const [
                DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: AppLanguage.instance.busy
                  ? null
                  : (value) async {
                      setState(() => error = null);
                      try {
                        await AppLanguage.instance.select(value!);
                      } catch (_) {
                        if (mounted) setState(() => error = '语言设置未保存，请重试。');
                      }
                    },
            ),
            if (AppLanguage.instance.busy) Text(tr('正在保存语言…')),
            if (error != null)
              Text(
                tr(error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
  );
}
