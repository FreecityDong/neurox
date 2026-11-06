import 'package:neurox/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../account/local_account.dart';

class NotificationSettings extends StatefulWidget {
  const NotificationSettings({super.key, this.concise = false});
  final bool concise;
  @override
  State<NotificationSettings> createState() => _NotificationSettingsState();
}

class _NotificationSettingsState extends State<NotificationSettings>
    with LanguageAware<NotificationSettings> {
  static const channel = MethodChannel('neurox/notifications');
  bool busy = false;
  bool enabled = false;
  int authorization = 0;
  String? error;
  @override
  void initState() {
    super.initState();
    update('status');
  }

  Future<void> update(String method) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value =
          await channel.invokeMapMethod<String, dynamic>(method) ?? {};
      if (mounted) {
        setState(() {
          enabled = value['enabled'] == true;
          authorization = value['authorization'] as int? ?? 0;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = LocalAccount.describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.concise)
            Text(tr("系统通知权限"), style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: 8),
          if (widget.concise)
            Text(
              authorization == 1
                  ? tr('请在系统设置中开启通知。')
                  : enabled
                  ? tr('已启用')
                  : tr('未启用'),
            )
          else ...[
            Text(
              authorization == 1
                  ? tr("系统通知权限已关闭，请在系统设置中允许。")
                  : enabled
                  ? tr("已授权系统通知；实际反馈遵循声音、震动和通知开关。")
                  : tr("尚未授权系统通知；曲线事件和实时文字不受影响。"),
            ),
            Text(tr("通知用于场景状态与采集异常。是否显示、播放声音或震动取决于反馈选择与系统能力。")),
          ],
          if (error != null) Text(trSource(error!)),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => update(enabled ? 'disable' : 'request'),
                child: Text(enabled ? tr("停用系统通知") : tr("授权系统通知")),
              ),
              TextButton(
                onPressed: busy ? null : () => update('status'),
                child: Text(tr("刷新权限")),
              ),
              if (authorization == 1)
                TextButton(
                  onPressed: () => MethodChannel(
                    'neurox/eeg/methods',
                  ).invokeMethod<void>('openSettings'),
                  child: Text(tr("系统设置")),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
