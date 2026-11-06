import 'learning_flow_widgets.dart';
import 'record_display_name.dart';
import 'scene_widgets.dart';
import 'scene_protocol.dart';
import 'detail_widgets.dart';
import 'scene_detail_results.dart';
import 'monitoring_engine.dart';
import 'package:flutter/material.dart';
import '../account/local_account.dart';
import '../device/device_page.dart';
import '../../l10n/app_language.dart';
import 'task_controller.dart';
import 'reference_metrics.dart';

Map<String, dynamic> decodeTaskMap(Object? value) {
  try {
    return detailMap(value);
  } catch (_) {
    return {};
  }
}

String taskTime(Object? seconds) {
  final value = seconds is num && seconds.isFinite
      ? seconds.floor().clamp(0, 86400)
      : 0;
  return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
}

String eventDetailLabel(String value) => trSource(switch (value) {
  'rest' => '已休息',
  'posture' => '调整姿势',
  'breathing' => '呼吸调整',
  'none' => '未调整',
  'wearing' => '调整佩戴',
  'target_reached' => '达到目标时长',
  'user_ended' => '用户提前结束',
  'user_completed' => '用户结束任务',
  'game_completed' => '完成全部游戏目标',
  'protocol_finished' => '完成预设训练时间',
  'interrupted' => '任务中断',
  'background' => '后台中断',
  'restart' => 'App重启中断',
  'storage' => '保存异常',
  'disconnected' => '设备断连',
  'haptic_requested' => '已请求短震动',
  'pending' => '提醒未执行',
  'rebaseline' => '重新建立基线',
  'preparing_data' => '重新准备数据',
  'baseline_invalid' => '基线已失效',
  _ => value,
});
String monitorStateLabel(String? state) => trSource(switch (state) {
  'stable' => '暂无持续偏离',
  'deviation' => '相对参考偏离',
  _ => '暂无法判断',
});
String monitorPhaseLabel(String? phase) => trSource(switch (phase) {
  'running' => '监测中',
  'paused' => '已暂停',
  'rebuilding' => '重新准备数据',
  'recovery' => '恢复练习中',
  'preparing' => '准备实时信号',
  'finished' => '已结束',
  _ => '监测已中断',
});

class MonitorTimeline extends StatelessWidget {
  const MonitorTimeline({super.key, required this.summary});
  final Map<String, dynamic> summary;
  @override
  Widget build(BuildContext context) {
    final durations = summary['durations'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('状态时间线'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Semantics(
          label: tr('绿色为稳定，橙色为轻度偏离，灰色为暂无法判断。'),
          child: SizedBox(
            height: 28,
            width: double.infinity,
            child: CustomPaint(painter: _TimelinePainter(summary)),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          children: [
            for (final key in ['stable', 'deviation', 'unknown'])
              Text('${monitorStateLabel(key)} ${taskTime(durations[key])}'),
          ],
        ),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.summary);
  final Map<String, dynamic> summary;
  @override
  void paint(Canvas canvas, Size size) {
    final total = (summary['elapsed'] as num?)?.toDouble() ?? 0;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.grey.shade300);
    if (total <= 0 || !total.isFinite) return;
    for (final raw in summary['timeline'] as List? ?? []) {
      final segment = raw as Map,
          start = (segment['start'] as num).toDouble(),
          end = (segment['end'] as num).toDouble();
      final color = segment['state'] == 'stable'
          ? Colors.teal
          : segment['state'] == 'deviation'
          ? Colors.orange
          : Colors.grey;
      canvas.drawRect(
        Rect.fromLTRB(
          (start / total).clamp(0, 1) * size.width,
          0,
          (end / total).clamp(0, 1) * size.width,
          size.height,
        ),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) => true;
}

class MonitoringPanel extends StatelessWidget {
  const MonitoringPanel({
    super.key,
    required this.task,
    required this.onEnd,
    required this.qualityText,
  });
  final TaskController task;
  final VoidCallback onEnd;
  final String qualityText;
  @override
  Widget build(BuildContext context) {
    if (task.scene == TaskScene.learning || task.scene.competitive) {
      return LearningLivePanel(task: task, onEnd: onEnd);
    }
    final monitor = task.monitor!;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          task.name.isEmpty ? task.scene.label : task.name,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(monitorPhaseLabel(monitor.phase)),
        Text(
          monitor.openEnded
              ? tr('已记录 {p0}，手动结束', {'p0': taskTime(monitor.elapsed)})
              : tr('已监测 {p0} · 剩余 {p1}', {
                  'p0': taskTime(monitor.elapsed),
                  'p1': taskTime(monitor.remaining),
                }),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        Text(
          monitorStateLabel(monitor.state),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Text(
          trSource(switch (monitor.reason) {
            'candidate' => '正在观察变化',
            'recovering' => '正在观察恢复',
            'unsupported_stage' => '本阶段不提供专注判断，保留原始记录和采集事件。',
            _ => qualityText,
          }),
        ),
        Text(
          '${tr('连续保持')} ${taskTime(monitor.currentKeep)} · ${tr('最长连续保持')} ${taskTime(monitor.longestKeep)}',
        ),
        if (monitor.reason == 'recovered') Text(tr('已观察到持续回到参考范围')),
        SceneCurve(
          events: monitor.events,
          reference: monitor.comparisonAllowed ? monitor.reference : const {},
        ),
        Text(
          trSource(switch (monitor.relaxDirection) {
            'above' => '放松指标高于个人参考',
            'below' => '放松指标低于个人参考',
            'near' => '放松指标接近个人参考',
            _ => '放松指标正在观察',
          }),
        ),
        Text(tr('状态表示相对本次个人基线的变化，采用可调工程阈值。')),
        const SizedBox(height: 20),
        if (monitor.scores != null)
          ReferenceMetrics(features: monitor.scores, comparison: true),
        const SizedBox(height: 20),
        MonitorTimeline(summary: monitor.snapshot(task.now)),
        const SizedBox(height: 12),
        SceneControls(task: task),
        if (task.latestReminderSequence != null &&
            task.feedback.notice &&
            monitor.state == 'deviation')
          Text(tr('提示：专注指标持续偏离个人参考，可选择调整或恢复练习。')),
        FilledButton.tonal(
          onPressed: task.busy ? null : task.chooseRecovery,
          child: Text(tr('进入主动恢复')),
        ),
        const SizedBox(height: 12),
        if (task.error != null)
          Text(
            trSource(task.error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (monitor.phase == 'running')
          OutlinedButton(
            onPressed: task.busy ? null : task.pauseMonitoring,
            child: Text(tr('暂停任务')),
          )
        else if (!monitor.finished)
          FilledButton(
            onPressed: task.busy || (!task.needsRebaseline && !task.canMonitor)
                ? null
                : task.continueMonitoring,
            child: Text(
              task.needsRebaseline
                  ? task.usingSavedReference
                        ? tr('重新准备数据')
                        : tr('重新建立基线')
                  : tr('继续监测'),
            ),
          ),
        if (monitor.state == 'unknown' && !monitor.finished)
          TextButton(
            onPressed: task.busy
                ? null
                : () async {
                    await task.rebuildMonitoring();
                    if (context.mounted) {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DevicePage(
                            controller: task.eeg,
                            ownsController: false,
                            overview: true,
                          ),
                        ),
                      );
                    }
                  },
            child: Text(tr('检查或恢复设备连接')),
          ),
        if (!monitor.finished) ...[
          Text(tr('调整记录'), style: Theme.of(context).textTheme.titleMedium),
          Wrap(
            spacing: 8,
            children: [
              for (final (kind, label) in [
                ('rest', '已休息'),
                ('posture', '调整姿势'),
                ('breathing', '呼吸调整'),
                ('none', '未调整'),
                (
                  'wearing',
                  task.usingSavedReference ? '调整佩戴（重新准备数据）' : '调整佩戴（重建基线）',
                ),
              ])
                ActionChip(
                  label: Text(trSource(label)),
                  onPressed: task.busy ? null : () => task.adjust(kind),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: task.busy ? null : onEnd,
          child: Text(monitor.finished ? tr('重试保存任务') : tr('结束任务并保存')),
        ),
        ExpansionTile(
          title: Text(tr('本次判断规则')),
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                tr(
                  '专注与固定个人参考比较；学习25秒偏离／10秒恢复，竞技10／15秒为工程初值。声音、震动、通知独立选择；无效数据不判状态。',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class TaskReview extends StatefulWidget {
  const TaskReview({
    super.key,
    required this.row,
    required this.account,
    this.showName = true,
  });
  final Map<String, dynamic> row;
  final LocalAccount account;
  final bool showName;
  @override
  State<TaskReview> createState() => _TaskReviewState();
}

class _TaskReviewState extends State<TaskReview>
    with LanguageAware<TaskReview> {
  late TextEditingController note;
  int rating = 0;
  bool saving = false;
  String? feedbackMessage;
  @override
  void initState() {
    super.initState();
    final old = decodeTaskMap(widget.row['feedback_json']);
    rating = old['rating'] as int? ?? 0;
    note = TextEditingController(text: old['note'] as String? ?? '');
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> saveFeedback() async {
    setState(() => saving = true);
    try {
      await widget.account.call<void>('taskFeedback', {
        'id': widget.row['id'],
        'feedback': {'rating': rating, 'note': note.text},
      });
      if (mounted) setState(() => feedbackMessage = tr('主观反馈已保存'));
    } catch (e) {
      if (mounted) setState(() => feedbackMessage = LocalAccount.describe(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = decodeTaskMap(widget.row['monitor_json']);
    if (![
      monitoringVersion,
      'sdk-personal-monitor-v1',
    ].contains(summary['version'])) {
      return Text(tr('任务摘要缺失或无法读取，请保留记录并重试。'));
    }
    final learning = hasCompactTaskDetails(summary['scene'] as String?);
    if (learning && detailMap(summary['reference']).isEmpty) {
      summary['reference'] = detailMap(
        widget.row['baseline_json'],
      )['statistics'];
    }
    final events = (widget.row['events'] as List? ?? [])
        .map((e) => decodeTaskMap((e as Map)['payload']))
        .toList();
    final issued = events
        .where(
          (e) =>
              e['type'] == 'reminder' &&
              [
                'haptic_requested',
                'feedback_requested',
              ].contains(e['delivery']),
        )
        .length;
    final saved = ![
      'active',
      'interrupted_pending',
    ].contains(widget.row['task_state']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showName)
          Text(
            recordDisplayName(widget.row),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        const SizedBox(height: 12),
        SceneDetailResults(summary: summary, events: events),
        if (learning)
          ExpansionTile(
            title: Text(tr('本次参考基线')),
            children: [
              LearningReference(
                summary: summary,
                metric:
                    isFocusScene(summary['scene'] as String?) ||
                        summary['scene'] == 'training'
                    ? 'attention'
                    : summary['scene'] == 'recovery'
                    ? 'relax'
                    : null,
                savedBaseline: detailMap(widget.row['baseline_json']),
                framed: false,
              ),
            ],
          ),
        if (summary['scene'] == 'learning' &&
            events.any((e) => e['type'] == 'adjustment'))
          ExpansionTile(
            title: Text(tr('调整记录')),
            children: [
              for (final event in events.where(
                (e) => e['type'] == 'adjustment',
              ))
                ListTile(
                  title: Text(
                    eventDetailLabel(event['kind'] as String? ?? 'none'),
                  ),
                  trailing: Text(taskTime(event['elapsed'])),
                ),
            ],
          ),
        if (!learning)
          ExpansionTile(
            title: Text(tr('过程记录')),
            children: [
              if (summary['scene'] != 'training')
                Text(tr('反馈请求 {p0} 次', {'p0': issued})),
              for (final event in events.where(
                (e) => [
                  'reminder',
                  'adjustment',
                  'interruption',
                  'pause',
                  'resume',
                  'rebaseline',
                  'stage',
                  'recovery_start',
                  'recovery_step',
                  'recovery_end',
                  'recovery_complete',
                  'recovery_rating',
                  'recheck',
                  'data_unavailable',
                  'feedback_delivery',
                ].contains(e['type']),
              ))
                ListTile(
                  title: Text(
                    trSource(switch (event['type']) {
                      'reminder' => '状态提醒',
                      'adjustment' => '调整记录',
                      'pause' => '主动暂停',
                      'resume' => '继续监测',
                      'rebaseline' => '重新建立基线',
                      'preparing_data' => '重新准备数据',
                      'recovery_start' => '开始恢复练习',
                      'recovery_step' => '恢复练习步骤',
                      'recovery_end' => '返回任务复查',
                      'recovery_complete' => '恢复练习结束',
                      'recovery_rating' => '主观准备度',
                      'recheck' => '恢复后复查',
                      'stage' => '阶段切换',
                      'feedback_delivery' => '反馈请求',
                      'data_unavailable' => '数据不可用',
                      _ => '监测已中断',
                    }),
                  ),
                  subtitle: Text(
                    '${taskTime(event['elapsed'])} · ${eventDetailLabel(event['kind'] as String? ?? event['reason'] as String? ?? event['delivery'] as String? ?? '')}',
                  ),
                ),
            ],
          ),
        if (!learning)
          ExpansionTile(
            title: Text(tr('个人基线与算法')),
            children: [
              DetailFacts(
                values: [
                  (tr('暂停时长'), detailTime(summary['pauseSeconds'])),
                  (tr('重新准备'), detailTime(summary['rebuildSeconds'])),
                  (tr('经过时长'), detailTime(summary['wallSeconds'])),
                ],
              ),
              Text(
                tr('结束原因：{p0}', {
                  'p0': eventDetailLabel(summary['endReason'] as String? ?? ''),
                }),
              ),
              if ((summary['referenceOrigin'] as Map?)?['collectedAt'] is num)
                Text(
                  tr('基线建立于 {p0}', {
                    'p0': DateTime.fromMillisecondsSinceEpoch(
                      (((summary['referenceOrigin'] as Map)['collectedAt']
                                  as num) *
                              1000)
                          .round(),
                    ).toLocal().toString().substring(0, 19),
                  }),
                ),
              Text(tr('分母包含监测中的未知/受阻，排除实时准备、暂停和后台中断。')),
              Text(tr('没有独立效果验证，不把提醒或调整后的变化解释为训练改善。')),
              Text(
                tr('SDK算法 {p0} · 状态规则 {p1}', {
                  'p0': summary['algorithm'] ?? '—',
                  'p1': summary['version'] ?? '—',
                }),
              ),
              if (summary['reference'] is Map)
                ReferenceMetrics(
                  statistics: Map<String, dynamic>.from(
                    summary['reference'] as Map,
                  ),
                ),
              if ((summary['context'] as Map?)?['sampleRateAssumed'] == true)
                Text(tr('临时raw比值模式：512Hz为假设，未换算物理单位；结果仅供相对变化观察。')),
            ],
          ),
        if (saved) ...[
          if (learning) const SizedBox(height: 24),
          Text(tr('主观反馈（可选）'), style: Theme.of(context).textTheme.titleMedium),
          if (learning) const SizedBox(height: 8),
          Text(tr('本次体验：1很差，5很好（主观）')),
          if (learning) const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: learning ? 8 : 0,
            children: [
              for (var i = 1; i <= 5; i++)
                ChoiceChip(
                  label: Text('$i'),
                  selected: rating == i,
                  onSelected: saving ? null : (_) => setState(() => rating = i),
                ),
            ],
          ),
          if (learning) const SizedBox(height: 16),
          TextField(
            controller: note,
            maxLength: 300,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(labelText: tr('记录本次体验')),
          ),
          if (learning) const SizedBox(height: 12),
          TextButton(
            onPressed: saving ? null : saveFeedback,
            child: Text(tr('保存主观反馈')),
          ),
          if (feedbackMessage != null) ...[
            if (learning) const SizedBox(height: 8),
            Text(feedbackMessage!),
          ],
        ],
      ],
    );
  }
}
