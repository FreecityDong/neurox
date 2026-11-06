import '../tasks/record_display_name.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import 'history_models.dart';

extension HistoryTypePresentation on HistoryTaskType {
  String get label => trSource(switch (this) {
    HistoryTaskType.baseline => '基线任务',
    HistoryTaskType.learning => '学习场景',
    HistoryTaskType.training => '专注训练',
    HistoryTaskType.competition => '竞技运动',
    HistoryTaskType.recovery => '主动恢复',
    HistoryTaskType.other => '历史记录',
  });
  Color get accent => switch (this) {
    HistoryTaskType.baseline => const Color(0xff7f9852),
    HistoryTaskType.learning => const Color(0xff598eb6),
    HistoryTaskType.training => const Color(0xff8973b1),
    HistoryTaskType.competition => const Color(0xffab8543),
    HistoryTaskType.recovery => const Color(0xff489880),
    HistoryTaskType.other => const Color(0xff75838c),
  };
  Color get tint => switch (this) {
    HistoryTaskType.baseline => const Color(0xfff0f4e8),
    HistoryTaskType.learning => const Color(0xffeaf3f9),
    HistoryTaskType.training => const Color(0xfff0edf8),
    HistoryTaskType.competition => const Color(0xfffaf1e2),
    HistoryTaskType.recovery => const Color(0xffe8f4ef),
    HistoryTaskType.other => const Color(0xffeff3f4),
  };
  IconData get icon => switch (this) {
    HistoryTaskType.baseline => Icons.tune_rounded,
    HistoryTaskType.learning => Icons.menu_book_outlined,
    HistoryTaskType.training => Icons.psychology_outlined,
    HistoryTaskType.competition => Icons.sports,
    HistoryTaskType.recovery => Icons.spa_outlined,
    HistoryTaskType.other => Icons.history,
  };
}

extension HistoryStatusPresentation on HistoryTaskStatus {
  String get label => trSource(switch (this) {
    HistoryTaskStatus.completed => '已完成',
    HistoryTaskStatus.incomplete => '未完成',
    HistoryTaskStatus.running => '进行中',
    HistoryTaskStatus.paused => '已暂停',
    HistoryTaskStatus.interrupted => '已中断',
    HistoryTaskStatus.saveFailed => '保存异常',
    HistoryTaskStatus.saved => '已保存',
    HistoryTaskStatus.unknown => '状态待确认',
  });
}

class HistoryTaskCard extends StatelessWidget {
  const HistoryTaskCard({
    super.key,
    required this.entry,
    required this.onTap,
    this.liveSeconds,
    this.selecting = false,
    this.selected = false,
    this.selectionEnabled = true,
  });
  final HistoryEntry entry;
  final VoidCallback onTap;
  final num? liveSeconds;
  final bool selecting, selected, selectionEnabled;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme, type = entry.type;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark
        ? Color.alphaBlend(type.accent.withValues(alpha: .16), colors.surface)
        : type.tint;
    final start = entry.started;
    final startText = start == null
        ? '—'
        : start.toLocal().toString().substring(0, 16);
    final name = entry.type == HistoryTaskType.other
        ? (entry.name.isEmpty ? tr('未命名任务') : trSource(entry.name))
        : recordDisplayName(entry.data);
    final scene = type == HistoryTaskType.competition
        ? trSource(switch (entry.scene) {
            'esports' => '电竞比赛',
            'go' => '围棋对局',
            'archery' => '射箭训练',
            _ => '',
          })
        : '';
    return Material(
      key: ValueKey('history-card-${entry.id}'),
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
          color: selected ? type.accent : type.accent.withValues(alpha: .22),
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: type.accent),
              if (selecting)
                Center(
                  child: Checkbox(
                    key: ValueKey('history-select-${entry.id}'),
                    value: selected,
                    onChanged: selectionEnabled ? (_) => onTap() : null,
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Icon(
                            type.icon,
                            size: 19,
                            color: dark
                                ? Color.lerp(type.accent, Colors.white, .35)
                                : type.accent,
                          ),
                          Text(
                            type.label,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: colors.onSurface,
                              fontSize: 13,
                            ),
                          ),
                          if (entry.metadata['isReplay'] == true)
                            Text(
                              tr('测试回放'),
                              style: TextStyle(
                                color: colors.tertiary,
                                fontSize: 12,
                              ),
                            ),
                          if (scene.isNotEmpty)
                            Text(
                              scene,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surface.withValues(alpha: .65),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              entry.status.label,
                              style: TextStyle(
                                color:
                                    entry.status == HistoryTaskStatus.saveFailed
                                    ? colors.error
                                    : colors.onSurfaceVariant,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right,
                            color: colors.onSurfaceVariant,
                            size: 20,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 18,
                        runSpacing: 8,
                        children: [
                          _HistoryInfo(
                            icon: Icons.calendar_today_outlined,
                            label: tr('开始时间'),
                            value: startText,
                          ),
                          _HistoryInfo(
                            icon: Icons.schedule_outlined,
                            label: tr('持续时间'),
                            value: historyDuration(
                              liveSeconds ?? entry.durationSeconds,
                            ),
                          ),
                        ],
                      ),
                      if (entry.data['exists'] == false) ...[
                        const SizedBox(height: 10),
                        Text(
                          tr('原始文件缺失'),
                          style: TextStyle(color: colors.error, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryInfo extends StatelessWidget {
  const _HistoryInfo({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Icon(
        icon,
        size: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      Text(
        '$label  $value',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    ],
  );
}
