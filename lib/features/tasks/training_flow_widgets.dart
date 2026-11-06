import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import 'task_choice_cards.dart';
import 'task_controller.dart';
import 'training_game.dart';
import 'learning_flow_widgets.dart' show LearningSection;

class TrainingSetupOptions extends StatelessWidget {
  const TrainingSetupOptions({
    super.key,
    required this.task,
    required this.onChanged,
  });
  final TaskController task;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(tr('选择训练游戏'), style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      TaskChoiceCards<TrainingKind>(
        value: task.trainingKind,
        keyPrefix: 'training-game',
        optionKey: (v) => v.name,
        maxColumns: 2,
        enabled: !task.busy && !task.active,
        onChanged: (kind) {
          task.trainingKind = kind;
          onChanged();
        },
        options: const [
          (TrainingKind.obstacles, '动态障碍舒尔特', Icons.pin_outlined),
          (TrainingKind.tracking, '视觉追踪', Icons.visibility_outlined),
          (TrainingKind.rings, '旋转圆盘', Icons.rotate_right_rounded),
          (TrainingKind.hexagons, '六边形舒尔特', Icons.hexagon_outlined),
        ],
      ),
      const SizedBox(height: 16),
      LearningSection(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('玩法与目标'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(task.trainingKind.instructions),
            if (task.trainingKind == TrainingKind.tracking) ...[
              const SizedBox(height: 16),
              Text(tr('训练难度')),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (
                    var level = 0;
                    level < TrackingLevel.values.length;
                    level++
                  )
                    ChoiceChip(
                      label: Text(trSource(TrackingLevel.values[level].label)),
                      selected: task.trackingLevel == level,
                      onSelected: task.busy
                          ? null
                          : (_) {
                              task.trackingLevel = level;
                              onChanged();
                            },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tr('记住 {p0} 个目标，跟踪 {p1} 秒后选择。', {
                  'p0': TrackingLevel.values[task.trackingLevel].targets,
                  'p1': TrackingLevel.values[task.trackingLevel].move.toInt(),
                }),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}
