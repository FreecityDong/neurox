import 'task_choice_cards.dart';
import '../shell/app_shell.dart' show confirm;
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import 'scene_protocol.dart';
import 'task_controller.dart';
import 'learning_flow_widgets.dart' show LearningSection;

List<String> competitionStages(TaskScene scene) => scene == TaskScene.archery
    ? ['preparation', 'shooting', 'interval']
    : scene.stages.where((s) => s != scene.postStage).toList();

String competitionNextStage(TaskScene scene, String stage) =>
    stage == 'preparation' || stage == 'interval'
    ? scene == TaskScene.esports
          ? 'match'
          : scene == TaskScene.go
          ? 'thinking'
          : 'shooting'
    : 'interval';

String competitionInstruction(TaskScene scene, String stage) =>
    trSource(switch ((scene, stage)) {
      (TaskScene.esports, 'preparation') => '调整到平时比赛的坐姿，确认头带稳定。准备好后进入比赛。',
      (TaskScene.esports, 'match') => '按平时节奏比赛，不必盯着分数；需要休息时记录间歇。',
      (TaskScene.go, 'preparation') => '保持平时对弈的坐姿，确认头带稳定。准备好后进入思考。',
      (TaskScene.go, 'thinking') => '正常思考与落子，无需每步操作；休息时再切换阶段。',
      (TaskScene.archery, 'preparation') => '先完成佩戴与场地准备。以一组箭为单位记录训练。',
      (TaskScene.archery, 'shooting') => '本组包含瞄准与释放，完成整组后再记录间歇。本阶段只记录曲线。',
      (TaskScene.archery, 'aiming') ||
      (TaskScene.archery, 'release') => '动作阶段只记录曲线，完成本组后再进入间歇。',
      (_, 'interval') => '按需要休息，准备好后继续。',
      (_, 'post_match') || (_, 'post_training') => '监测仍在继续，点击结束并保存才会停止。',
      (_, 'ended') => '本次任务已结束，请点击结束并保存。',
      (_, 'post') => '坐稳片刻，观察本次专注变化。结束后保存曲线与分析。',
      _ => '按自己的训练节奏操作，阶段由你手动切换。',
    });

String competitionAction(TaskScene scene, String stage) =>
    trSource(switch ((scene, stage)) {
      (TaskScene.esports, 'preparation') => '进入比赛',
      (TaskScene.esports, 'interval') => '继续比赛',
      (TaskScene.go, 'preparation') => '开始下棋',
      (TaskScene.go, 'interval') => '继续下棋',
      (TaskScene.archery, 'preparation') => '开始射箭',
      (TaskScene.archery, 'interval') => '继续射箭',
      _ => '开始间歇',
    });

class CompetitionConditionSettings extends StatelessWidget {
  const CompetitionConditionSettings({
    super.key,
    required this.task,
    this.collapsed = false,
  });
  final TaskController task;
  final bool collapsed;
  @override
  Widget build(BuildContext context) {
    final content = CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(tr('启用基线对比')),
      subtitle: Text(tr('开启：判断专注变化，按设置提醒。\n关闭：只记录曲线。')),
      value: task.conditionMatches,
      onChanged: task.busy ? null : (value) => task.setCondition(value == true),
    );
    return LearningSection(
      child: collapsed
          ? ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(tr('基线对比')),
              children: [content],
            )
          : content,
    );
  }
}

class CompetitionPhaseGuide extends StatelessWidget {
  const CompetitionPhaseGuide({super.key, required this.task});
  final TaskController task;
  @override
  Widget build(BuildContext context) {
    final stage = task.sceneStage;
    final blocked = task.busy || task.monitor?.phase != 'running';
    final stages = {...competitionStages(task.scene), stage};
    return LearningSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  stageLabel(stage),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (!task.competitionPostStage)
                PopupMenuButton<String>(
                  tooltip: tr('切换训练阶段'),
                  onSelected: blocked ? null : task.changeStage,
                  itemBuilder: (_) => [
                    for (final item in stages)
                      PopupMenuItem(value: item, child: Text(stageLabel(item))),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(competitionInstruction(task.scene, stage)),
          if (!task.competitionPostStage)
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: blocked
                      ? null
                      : () => task.changeStage(
                          competitionNextStage(task.scene, stage),
                        ),
                  child: Text(competitionAction(task.scene, stage)),
                ),
                TextButton(
                  onPressed: task.busy || task.monitor?.finished == true
                      ? null
                      : () async {
                          final id = task.sessionId;
                          if (await confirm(
                                context,
                                task.scene.endQuestion,
                                tr('确认后不能返回此前阶段，监测仍会继续，点击“结束并保存”才会停止。'),
                              ) &&
                              task.active &&
                              task.sessionId == id) {
                            task.endCompetitionStage();
                          }
                        },
                  child: Text(task.scene.endLabel),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class CompetitionProjectPicker extends StatelessWidget {
  const CompetitionProjectPicker({super.key, required this.task});
  final TaskController task;
  @override
  Widget build(BuildContext context) => TaskChoiceCards<TaskScene>(
    value: task.scene,
    onChanged: task.setScene,
    enabled: !task.busy && !task.active,
    keyPrefix: 'competition-project',
    optionKey: (v) => v.name,
    options: const [
      (TaskScene.esports, '电竞比赛', Icons.sports_esports_outlined),
      (TaskScene.go, '围棋对局', Icons.grid_on_rounded),
      (TaskScene.archery, '射箭训练', Icons.my_location_rounded),
    ],
  );
}
