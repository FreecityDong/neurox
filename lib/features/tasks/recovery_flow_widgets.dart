import 'task_choice_cards.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import 'detail_widgets.dart';
import 'learning_flow_widgets.dart';
import 'scene_protocol.dart';
import 'scene_widgets.dart';
import 'task_controller.dart';

class RecoveryLivePanel extends StatefulWidget {
  const RecoveryLivePanel({super.key, required this.task, required this.onEnd});
  final TaskController task;
  final VoidCallback onEnd;
  @override
  State<RecoveryLivePanel> createState() => _RecoveryLivePanelState();
}

class _RecoveryLivePanelState extends State<RecoveryLivePanel> {
  int _sequence = -1;
  Object? _monitor;
  List<Map<String, dynamic>> _events = [];
  @override
  Widget build(BuildContext context) {
    final task = widget.task, m = task.monitor!, flow = task.recoveryFlow;
    if (!identical(m, _monitor) || m.sequence != _sequence) {
      _monitor = m;
      _sequence = m.sequence;
      _events = [
        for (final e in m.events) {...e, 'curveSeconds': e['elapsed'] ?? 0},
      ];
    }
    final running = ['running', 'recovery'].contains(m.phase);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              const LearningStageGuide(stage: 2, scene: TaskScene.recovery),
              Text(
                task.name.isEmpty ? tr('主动恢复') : task.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(tr('已练习 {p0}', {'p0': detailTime(m.elapsed)})),
              const SizedBox(height: 16),
              if (!running) ...[
                Text(
                  tr(
                    m.phase == 'paused'
                        ? '练习已暂停，重新检查信号后继续。'
                        : '任务已中断，重新检查信号后可继续。',
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (flow != null)
                LearningSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < flow.steps.length; i++)
                            Chip(
                              label: Text(stageLabel(flow.steps[i])),
                              backgroundColor: i == flow.step
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        flow.instruction,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 12),
                      if (flow.step < flow.steps.length - 1)
                        FilledButton.tonal(
                          onPressed: task.busy || !running
                              ? null
                              : task.advanceRecovery,
                          child: Text(
                            tr(
                              flow.stage == 'demonstration'
                                  ? '开始跟随练习'
                                  : '尝试自主练习',
                            ),
                          ),
                        )
                      else
                        Text(tr('按自己的节奏继续练习，到时自动结束；也可以提前结束并保存。')),
                    ],
                  ),
                ),
              if (flow == null)
                LearningSection(child: Text(tr('准备好后开始所选方法，按自己的节奏完成练习。'))),
              const SizedBox(height: 16),
              LearningSection(
                child: SceneCurve(
                  title: tr('放松曲线'),
                  events: _events,
                  reference: m.reference,
                  metric: 'relax',
                  standardDeviationReference: true,
                  interactive: true,
                  showEventLog: false,
                  observationOnly: true,
                  observationHint: tr('观察放松变化，不必追求更高分数；灰色虚线连接缺失数据。'),
                ),
              ),
              const SizedBox(height: 16),
              LearningReferencePreview(task: task, frozen: true),
              if (flow != null &&
                  ['demonstration', 'independent'].contains(flow.stage)) ...[
                const SizedBox(height: 16),
                LearningSection(
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      tr(
                        flow.stage == 'independent' ? '练习感受（可选）' : '练习前感受（可选）',
                      ),
                    ),
                    children: [
                      Text(tr('当前准备度：1 较低，5 较高。')),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 1; i <= 5; i++)
                            ChoiceChip(
                              label: Text('$i'),
                              selected:
                                  (flow.stage == 'independent'
                                      ? flow.readinessAfter
                                      : flow.readinessBefore) ==
                                  i,
                              onSelected: task.busy || !running
                                  ? null
                                  : (_) => task.rateRecovery(
                                      i,
                                      after: flow.stage == 'independent',
                                    ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              if (task.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    trSource(task.error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: task.busy
                      ? null
                      : running
                      ? task.pauseMonitoring
                      : !m.finished
                      ? task.continueMonitoring
                      : null,
                  child: Text(tr(running ? '暂停任务' : '继续恢复')),
                ),
                FilledButton(
                  onPressed: task.busy ? null : widget.onEnd,
                  child: Text(tr(m.finished ? '重试保存任务' : '结束并保存')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class RecoveryMethodPicker extends StatelessWidget {
  const RecoveryMethodPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) => TaskChoiceCards<String>(
    value: value,
    onChanged: onChanged,
    enabled: enabled,
    keyPrefix: 'recovery-method',
    optionKey: (v) => v,
    options: const [
      ('breathing', '自然节奏呼吸', Icons.air_rounded),
      ('attention', '注意返回练习', Icons.center_focus_strong_rounded),
      ('release', '姿势与肌肉放松', Icons.self_improvement_rounded),
    ],
  );
}
