import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../tasks/scene_protocol.dart';
import '../tasks/task_controller.dart';

String savedTaskTypeLabel(TaskController task) {
  final kind = task.completedTaskScene;
  if (kind == 'baseline' || kind == null && task.completedBaseline != null) {
    return tr('基线任务');
  }
  for (final scene in TaskScene.values) {
    if (scene.name == kind) return scene.label;
  }
  return tr('任务记录');
}

class SavedTaskCard extends StatelessWidget {
  const SavedTaskCard({super.key, required this.task, required this.onOpen});
  final TaskController task;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: ListTile(
      leading: const Icon(Icons.check_circle_outline),
      title: Text(tr('本次记录已保存')),
      subtitle: Text('${savedTaskTypeLabel(task)} · ${tr('查看曲线与分析报告')}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: onOpen,
    ),
  );
}
