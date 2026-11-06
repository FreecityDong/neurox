import 'scene_protocol.dart';
import 'competition_guidance.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../shell/feedback_preferences.dart';
import 'detail_widgets.dart';
import 'learning_report.dart';
import 'learning_trend.dart';
import 'scene_detail_results.dart';
import 'task_controller.dart';

class LearningStageGuide extends StatelessWidget {
  const LearningStageGuide({
    super.key,
    required this.stage,
    this.scene = TaskScene.learning,
  });
  final int stage;
  final TaskScene scene;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 3; i++)
          Expanded(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: i <= stage
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  foregroundColor: i <= stage
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  child: Text('${i + 1}', style: const TextStyle(fontSize: 14)),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    trSource(
                      [
                        scene == TaskScene.learning
                            ? '准备学习'
                            : scene == TaskScene.recovery
                            ? '准备恢复'
                            : '准备训练',
                        '信号检查',
                        scene == TaskScene.recovery
                            ? '恢复练习'
                            : scene == TaskScene.training
                            ? '专注练习'
                            : '实时监测',
                      ][i],
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: i == stage
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class LearningSection extends StatelessWidget {
  const LearningSection({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class LearningReferencePreview extends StatelessWidget {
  const LearningReferencePreview({
    super.key,
    required this.task,
    this.frozen = false,
  });
  final TaskController task;
  final bool frozen;
  @override
  Widget build(BuildContext context) {
    final saved = detailMap(task.savedReference['snapshot']);
    return LearningSection(
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(tr('本次参考基线')),
        children: [
          LearningReference(
            metric: task.scene == TaskScene.recovery ? 'relax' : 'attention',
            framed: false,
            summary: frozen && task.monitor != null
                ? task.monitor!.snapshot(task.now)
                : {
                    'reference': saved['statistics'],
                    'referenceOrigin': {
                      'collectedAt': task.savedReference['started'],
                    },
                  },
          ),
        ],
      ),
    );
  }
}

class LearningFeedbackSettings extends StatelessWidget {
  const LearningFeedbackSettings({super.key, required this.task});
  final TaskController task;
  @override
  Widget build(BuildContext context) => LearningSection(
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(tr('提醒方式')),
      childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
      children: [
        FeedbackControls(
          concise: true,
          value: task.feedback,
          onChanged: task.busy ? null : task.setFeedback,
        ),
      ],
    ),
  );
}

String learningSignalHint(TaskController task) {
  if (!task.eeg.connected) return tr('请连接头带后重新检查。');
  if (!task.eeg.receiving) return tr('正在等待脑电数据，请保持设备连接。');
  if (task.eeg.lead == false) return tr('接触不稳定，请调整头带后重试。');
  if (task.canMonitor) {
    return tr(
      task.scene == TaskScene.learning
          ? '信号已就绪，可以开始学习。'
          : task.scene == TaskScene.recovery
          ? '信号已就绪，可以开始恢复练习。'
          : task.scene == TaskScene.training
          ? '信号已就绪，可以开始游戏。'
          : '信号已就绪，可以开始训练。',
    );
  }
  if (task.learningPreparing && task.learningPreparationSeconds >= 30) {
    return tr('信号检查尚未通过，请调整佩戴或检查连接后重试。');
  }
  return trSource(switch (task.qualityReason) {
    'flat' ||
    'saturation' ||
    'raw_range' ||
    'amplitude' ||
    'step' => '信号暂不稳定，请坐稳并检查头带佩戴。',
    'data' || 'gap' || 'coverage' => '数据不连续，请检查设备连接。',
    'storage' => '记录暂时无法保存，请重试。',
    _ =>
      task.scene == TaskScene.recovery
          ? '正在准备放松数据，请保持自然坐姿…'
          : '正在准备专注数据，请保持自然坐姿…',
  });
}

class LearningSignalCheck extends StatelessWidget {
  const LearningSignalCheck({super.key, required this.task});
  final TaskController task;
  @override
  Widget build(BuildContext context) {
    final goodRaw = task.quality?.source['rawQuality'] == 'good';
    return LearningSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('佩戴与采集检查'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: task.canMonitor
                ? 1
                : !task.eeg.connected
                ? 0
                : !task.eeg.receiving
                ? .25
                : goodRaw
                ? .75
                : .5,
          ),
          const SizedBox(height: 12),
          Text(learningSignalHint(task)),
        ],
      ),
    );
  }
}

class LearningLivePanel extends StatefulWidget {
  const LearningLivePanel({super.key, required this.task, required this.onEnd});
  final TaskController task;
  final VoidCallback onEnd;
  @override
  State<LearningLivePanel> createState() => _LearningLivePanelState();
}

class _LearningLivePanelState extends State<LearningLivePanel> {
  TaskController get task => widget.task;
  VoidCallback get onEnd => widget.onEnd;
  LearningTrend? _trend;
  Object? _monitor;
  int _sequence = -1;
  double _elapsed = -1;
  @override
  Widget build(BuildContext context) {
    final m = task.monitor!;
    if (!identical(_monitor, m) ||
        _sequence != m.sequence ||
        _elapsed != m.elapsed) {
      _monitor = m;
      _sequence = m.sequence;
      _elapsed = m.elapsed;
      _trend = LearningTrend(m.snapshot(task.now), m.events);
    }
    final trend = _trend!;
    final running = m.phase == 'running';
    final state = !running
        ? (m.phase == 'paused' ? '已暂停' : '需要检查信号')
        : task.scene.competitive && !task.stageSupportsComparison
        ? '仅记录曲线'
        : m.state == 'unknown'
        ? '暂无法判断'
        : m.state == 'deviation'
        ? (m.reason == 'recovering' ? '正在确认恢复' : '专注持续偏离')
        : m.reason == 'candidate'
        ? '正在观察专注变化'
        : '专注状态正常';
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              LearningStageGuide(stage: 2, scene: task.scene),
              Text(
                task.name.isEmpty ? task.scene.label : task.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  Text(
                    tr(task.scene.competitive ? '已训练 {p0}' : '已学习 {p0}', {
                      'p0': detailTime(m.elapsed),
                    }),
                  ),
                  Text(
                    tr('当前专注：{p0}', {
                      'p0': running && task.quality?.good == true
                          ? detailNumber(
                              task.scene.competitive && trend.points.isNotEmpty
                                  ? trend.points.last.value
                                  : m.scores?['attention'],
                            )
                          : '—',
                    }),
                  ),
                ],
              ),
              if (task.scene.competitive) ...[
                const SizedBox(height: 16),
                CompetitionPhaseGuide(task: task),
              ],
              const SizedBox(height: 16),
              Text(
                trSource(state),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: m.state == 'deviation'
                      ? Colors.red.shade700
                      : m.state == 'stable' && running
                      ? Colors.green.shade800
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (m.state == 'unknown' || !running) ...[
                const SizedBox(height: 8),
                Text(
                  m.phase == 'paused'
                      ? tr(
                          task.competitionPostStage
                              ? '监测已暂停，准备好后点击继续监测。'
                              : task.scene.competitive
                              ? '训练已暂停，准备好后点击继续训练。'
                              : '学习已暂停，准备好后点击继续学习。',
                        )
                      : m.phase == 'interrupted'
                      ? tr('任务已中断，重新检查信号后可继续。')
                      : task.scene.competitive && !task.stageSupportsComparison
                      ? tr('当前阶段只记录曲线，符合对比条件后才判断专注状态。')
                      : learningSignalHint(task),
                ),
              ],
              const SizedBox(height: 20),
              LearningSection(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('专注曲线'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    LearningAttentionCurve(data: trend),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              LearningSection(
                child: Wrap(
                  spacing: 24,
                  runSpacing: 12,
                  children: [
                    for (final (key, label) in [
                      ('stable', '正常'),
                      ('candidate', '确认前观察'),
                      ('deviation', '确认偏离'),
                      ('unknown', '未知'),
                    ])
                      Text(
                        '${trSource(label)} ${detailTime(trend.durations[key])}',
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              LearningReferencePreview(task: task, frozen: true),
              if (task.scene.competitive) ...[
                const SizedBox(height: 16),
                CompetitionConditionSettings(task: task, collapsed: true),
              ],
              const SizedBox(height: 16),
              LearningSection(
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(tr('记录调整')),
                  children: [
                    Text(tr('手动标记已做的调整，方便回看；不会修改专注分数或个人基线。')),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (kind, label) in [
                          ('rest', '已休息'),
                          ('posture', '调整姿势'),
                          ('breathing', '呼吸调整'),
                          ('none', '未调整'),
                          ('wearing', '调整佩戴'),
                        ])
                          ActionChip(
                            label: Text(trSource(label)),
                            onPressed: task.busy || m.finished
                                ? null
                                : () async {
                                    await task.adjust(kind);
                                  },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        task.scene.competitive
                            ? '调整佩戴后需重新检查信号，再继续训练。'
                            : '调整佩戴后需重新检查信号，再继续学习。',
                      ),
                    ),
                    for (final event
                        in m.events
                            .where((e) => e['type'] == 'adjustment')
                            .toList()
                            .reversed
                            .take(3))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          trSource(switch (event['kind']) {
                            'rest' => '已休息',
                            'posture' => '调整姿势',
                            'breathing' => '呼吸调整',
                            'wearing' => '调整佩戴',
                            _ => '未调整',
                          }),
                        ),
                        trailing: Text(detailTime(event['elapsed'])),
                      ),
                  ],
                ),
              ),
              if (m.state == 'unknown' || !running)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextButton(
                    onPressed: task.busy ? null : task.prepareLearning,
                    child: Text(tr('重新检查信号')),
                  ),
                ),
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
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: task.busy
                      ? null
                      : running
                      ? task.pauseMonitoring
                      : !m.finished
                      ? task.continueMonitoring
                      : null,
                  child: Text(
                    tr(
                      running
                          ? '暂停任务'
                          : task.competitionPostStage
                          ? '继续监测'
                          : task.scene.competitive
                          ? '继续训练'
                          : '继续学习',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: task.busy ? null : onEnd,
                  child: Text(
                    tr(m.finished && task.error != null ? '重试保存任务' : '结束并保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

Future<bool> offerLearningRecovery(
  BuildContext context,
  TaskController task,
  String id,
) async {
  if (!task.claimLearningRecoveryPrompt(id)) return false;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            tr(task.completedTaskScene == 'learning' ? '学习记录已保存' : '训练记录已保存'),
          ),
          content: Text(tr('要进行一次主动恢复吗？')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('稍后再说')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('前往主动恢复')),
            ),
          ],
        ),
      ) ??
      false;
}
