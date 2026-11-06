import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_language.dart';
import 'notification_settings.dart';

class FeedbackOptions {
  const FeedbackOptions({
    this.sound = false,
    this.vibration = false,
    this.notice = false,
    this.muted = false,
  });
  final bool sound, vibration, notice, muted;
  bool get enabled => !muted && (sound || vibration || notice);
  Map<String, dynamic> toMap() => {
    'sound': sound,
    'vibration': vibration,
    'notice': notice,
    'muted': muted,
  };
  factory FeedbackOptions.fromMap(Map value) => FeedbackOptions(
    sound: value['sound'] == true,
    vibration: value['vibration'] == true,
    notice: value['notice'] == true,
    muted: value['muted'] == true,
  );
  FeedbackOptions change(String key, bool value) =>
      FeedbackOptions.fromMap({...toMap(), key: value});
}

class FeedbackControls extends StatefulWidget {
  const FeedbackControls({
    super.key,
    required this.value,
    required this.onChanged,
    this.concise = false,
  });
  final bool concise;
  final FeedbackOptions value;
  final ValueChanged<FeedbackOptions>? onChanged;
  @override
  State<FeedbackControls> createState() => _FeedbackControlsState();
}

class _FeedbackControlsState extends State<FeedbackControls> {
  FeedbackOptions get value => widget.value;
  ValueChanged<FeedbackOptions>? get onChanged => widget.onChanged;
  int permissionRevision = 0;
  bool requesting = false;
  Future<void> change(String key, bool enabled) async {
    final next = value.change(key, enabled);
    onChanged?.call(next);
    if (key == 'notice' && enabled) {
      setState(() => requesting = true);
      try {
        await const MethodChannel(
          'neurox/notifications',
        ).invokeMapMethod<String, dynamic>('request');
      } catch (_) {
        /* Permission state remains visible in NotificationSettings. */
      } finally {
        if (mounted) {
          setState(() {
            permissionRevision++;
            requesting = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (!widget.concise)
        Text(tr('提醒方式'), style: Theme.of(context).textTheme.titleMedium),
      SwitchListTile(
        key: const Key('muteAllFeedback'),
        contentPadding: EdgeInsets.zero,
        title: Text(tr('一键静默')),
        subtitle: Text(tr('暂时关闭所有提醒，关闭静默后恢复原设置。')),
        value: value.muted,
        onChanged: onChanged == null || requesting
            ? null
            : (v) => change('muted', v),
      ),
      if (!widget.concise && !value.muted)
        Text(tr('可独立组合或全部关闭；曲线事件与实时文字始终保留。')),
      for (final (key, label) in [
        ('sound', '声音'),
        ('vibration', '震动'),
        ('notice', '通知信息'),
      ])
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(trSource(label)),
          value: value.toMap()[key] == true,
          onChanged: onChanged == null || requesting || value.muted
              ? null
              : (v) => change(key, v),
        ),
      if (!widget.concise && !value.enabled) Text(tr('当前所有提醒已关闭，曲线与实时状态仍会更新。')),
      if (value.notice && !widget.concise)
        NotificationSettings(key: ValueKey(permissionRevision)),
      if (widget.concise) const SizedBox(height: 16),
      FeedbackTrial(options: value, concise: widget.concise),
      if (widget.concise) const SizedBox(height: 12),
    ],
  );
}

class FeedbackTrial extends StatefulWidget {
  const FeedbackTrial({super.key, required this.options, this.concise = false});
  final bool concise;
  final FeedbackOptions options;
  @override
  State<FeedbackTrial> createState() => _FeedbackTrialState();
}

class _FeedbackTrialState extends State<FeedbackTrial>
    with LanguageAware<FeedbackTrial> {
  bool busy = false;
  String? message;
  Future<void> test() async {
    setState(() => busy = true);
    try {
      final result =
          await const MethodChannel(
            'neurox/notifications',
          ).invokeMapMethod<String, dynamic>('testFeedback', {
            ...widget.options.toMap(),
            'title': tr('提醒测试'),
            'body': tr('这是当前所选提醒方式的测试。'),
          }) ??
          {};
      String status(String key) => trSource(switch (result[key]) {
        'requested' => '已请求',
        'not_authorized' => '未授权',
        'disabled' => '已关闭',
        _ => '不可用',
      });
      if (mounted) {
        setState(
          () => message =
              '${tr('声音')}：${status('sound')} · ${tr('震动')}：${status('vibration')} · ${tr('通知信息')}：${status('notice')}',
        );
      }
    } catch (_) {
      if (mounted) setState(() => message = tr('提醒测试不可用，请检查系统权限。'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton(
        onPressed: busy || !widget.options.enabled ? null : test,
        child: Text(tr('测试当前提醒')),
      ),
      if (message != null) ...[const SizedBox(height: 12), Text(message!)],
      if (!widget.concise) Text(tr('测试不会伪造专注异常；实际声震仍受设备与系统设置影响。')),
    ],
  );
}

/// Saved per signed-in account; task-local copies do not modify defaults.
class FeedbackDefaults extends StatefulWidget {
  const FeedbackDefaults({super.key, this.concise = false, this.onSaved});
  final bool concise;
  final ValueChanged<FeedbackOptions>? onSaved;
  @override
  State<FeedbackDefaults> createState() => _FeedbackDefaultsState();
}

class _FeedbackDefaultsState extends State<FeedbackDefaults>
    with LanguageAware<FeedbackDefaults> {
  static const channel = MethodChannel('neurox/local');
  FeedbackOptions value = const FeedbackOptions();
  bool busy = true;
  bool loaded = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final map = await channel.invokeMapMethod<String, dynamic>(
        'feedbackSettings',
      );
      if (mounted) {
        setState(() {
          value = FeedbackOptions.fromMap(map ?? {});
          loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = tr('提醒设置读取失败，请重试。'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save(FeedbackOptions next) async {
    setState(() => busy = true);
    try {
      await channel.invokeMethod('setFeedbackSettings', next.toMap());
      try {
        await const MethodChannel(
          'neurox/notifications',
        ).invokeMethod('configure', next.toMap());
      } on MissingPluginException {
        /* unsupported host */
      }
      widget.onSaved?.call(next);
      if (mounted) {
        setState(() {
          value = next;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = tr('提醒设置保存失败，请重试。'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          FeedbackControls(
            value: value,
            onChanged: busy || !loaded ? null : save,
            concise: widget.concise,
          ),
          if (error != null) Text(error!),
        ],
      ),
    ),
  );
}
