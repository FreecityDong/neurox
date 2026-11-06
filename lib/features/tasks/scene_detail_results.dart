import 'report_insights.dart';
import 'report_insight_widgets.dart';
import 'learning_report.dart';
import 'learning_trend.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import 'detail_widgets.dart';
import 'scene_protocol.dart';
import 'scene_widgets.dart';
import 'training_widgets.dart';

class SceneDetailResults extends StatelessWidget {
  const SceneDetailResults({
    super.key,
    required this.summary,
    required this.events,
  });
  final Map<String, dynamic> summary;
  final List<Map<String, dynamic>> events;
  @override
  Widget build(BuildContext context) {
    final scene = summary['scene'];
    if (isFocusScene(scene as String?)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LearningSessionContent(data: LearningTrend(summary, events)),
          if (scene != 'learning')
            ExpansionTile(
              title: Text(tr('阶段记录')),
              children: [
                if (summary['isReplay'] == true)
                  Chip(label: Text(tr('测试回放 · 学习记录数据'))),
                for (final item in detailStageTimeline(summary, events))
                  ListTile(
                    leading: SizedBox(
                      width: 68,
                      child: Text(
                        item['at'] == null ? '—' : detailTime(item['at']),
                      ),
                    ),
                    title: Text(stageTimelineLabel(item)),
                    subtitle: item['at'] == null ? Text(tr('时间点未记录')) : null,
                  ),
              ],
            ),
        ],
      );
    }
    final training = scene == 'training', recovery = scene == 'recovery';
    if (training || recovery) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailSection(
            title: tr('过程曲线'),
            child: SceneCurve(
              title: tr(training ? '专注度' : '放松度'),
              metric: training ? 'attention' : 'relax',
              events: training ? trainingCurveEvents(events) : events,
              interactive: true,
              showEventLog: false,
              observationOnly: true,
              observationHint: training
                  ? tr('从游戏计时开始记录专注度，灰色虚线连接缺失数据。')
                  : tr('显示恢复过程中的放松度，灰色虚线连接缺失数据。'),
            ),
          ),
          if (training) TrainingReport(summary: summary, events: events),
          if (recovery) _recovery(detailMap(summary['recoveryTeaching'])),
        ],
      );
    }
    final competitive = ['esports', 'go', 'archery'].contains(scene);
    final durations = detailMap(summary['durations']);
    final complete = detailEventsComplete(summary, events);
    final deviations = complete
        ? '${events.where((e) => e['type'] == 'deviation').length}'
        : '—';
    final stages = detailStageTimeline(summary, events);
    final flow = detailMap(summary['recoveryTeaching']);
    final hasRecovery = recovery || flow.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (summary['checkpointOnly'] == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(tr('曾发生中断，部分时长只保留最近落盘检查点，不补造缺失区间。')),
          ),
        if (training)
          TrainingReport(summary: summary, events: events)
        else if (!recovery) ...[
          DetailSection(
            title: tr(competitive ? '连续保持' : '学习概况'),
            child: DetailFacts(
              values: [
                (tr('可判断时长'), detailTime(summary['validSeconds'])),
                (
                  tr('可判断比例'),
                  detailRatio(summary['validSeconds'], summary['elapsed']),
                ),
                if (competitive) ...[
                  (tr('连续参考范围保持'), detailLongest(summary, events)),
                  (tr('确认偏离次数'), deviations),
                ] else ...[
                  (tr('未确认持续偏离'), detailTime(durations['stable'])),
                  (tr('确认偏离'), detailTime(durations['deviation'])),
                ],
              ],
            ),
          ),
          if (competitive)
            DetailSection(
              title: tr('状态分布'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DetailFacts(
                    values: [
                      (tr('未确认持续偏离'), detailTime(durations['stable'])),
                      (tr('确认偏离'), detailTime(durations['deviation'])),
                      (tr('暂无法判断'), detailTime(durations['unknown'])),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(tr('绿色表示未确认持续偏离，灰色区间不计为专注。')),
                ],
              ),
            ),
          if (competitive)
            DetailSection(
              title: tr('分阶段记录'),
              child: Column(
                children: [
                  for (final stage in stages)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Text(
                        stage['at'] == null ? '—' : detailTime(stage['at']),
                      ),
                      title: Text(stageTimelineLabel(stage)),
                    ),
                  Text(tr('仅汇总已保存阶段；条件不符时不进行比较。')),
                ],
              ),
            ),
        ],
        if (hasRecovery) _recovery(flow),
        DetailSection(
          title: tr('过程曲线'),
          child: scene == 'learning'
              ? LearningAttentionCurve(data: LearningTrend(summary, events))
              : SceneCurve(
                  title: tr('历史指标曲线'),
                  interactive: scene == 'learning',
                  showEventLog: scene != 'learning',
                  events: training ? trainingCurveEvents(events) : events,
                  observationOnly: training,
                  reference: training
                      ? const {}
                      : detailMap(summary['reference']),
                ),
        ),
        if (scene == 'learning')
          ExpansionTile(
            title: Text(tr('趋势解释')),
            children: [
              for (final line in LearningTrend(summary, events).explanations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(line),
                ),
            ],
          ),
      ],
    );
  }

  Widget _recovery(Map<String, dynamic> flow) {
    final simple =
        flow['version'] == 'recovery-teaching-v2' && flow['linked'] == false;
    final lastStart = events.lastIndexWhere(
      (e) => e['type'] == 'recovery_start',
    );
    final recent = simple
        ? events
        : lastStart < 0
        ? <Map<String, dynamic>>[]
        : events.skip(lastStart);
    final observed = <String>{
      for (final e in recent)
        if ([
              'recovery_start',
              'recovery_step',
              'recovery_end',
            ].contains(e['type']) &&
            e['stage'] is String)
          e['stage'] as String,
    };
    final method = switch (flow['method']) {
      'breathing' => '呼吸调整',
      'attention' => '注意返回',
      'body' || 'release' => '身体放松',
      null => '未记录',
      'posture' => '身体放松',
      _ => '未记录',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailSection(
          title: tr('恢复概况'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DetailFacts(
                values: [
                  (tr('恢复方法'), trSource(method)),
                  (
                    tr('练习类型'),
                    flow['linked'] == true
                        ? tr('任务内恢复')
                        : flow['linked'] == false
                        ? tr('独立恢复')
                        : '—',
                  ),
                  (
                    tr('练习累计时长'),
                    detailTime(summary['recoveryActivitySeconds']),
                  ),
                  (
                    tr('练习前准备度'),
                    detailNumber(flow['readinessBefore'], decimals: 0),
                  ),
                  (
                    tr(simple ? '练习中准备度' : '练习后准备度'),
                    detailNumber(flow['readinessAfter'], decimals: 0),
                  ),
                ],
              ),
              if (!simple) ...[
                const SizedBox(height: 12),
                Text(
                  trSource(switch (summary['recheckResult']) {
                    'returned' => '已观察到持续回到参考范围',
                    'not_observed' => '本次复查暂未观察到回到参考范围',
                    'insufficient' => '复查数据不足',
                    _ => '复查未完成',
                  }),
                ),
              ],
            ],
          ),
        ),
        ReportInsights(
          lines: recoveryInsights(summary, events),
          notes: recoveryNotes(),
        ),
        ExpansionTile(
          title: Text(tr('练习阶段')),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Column(
              children: [
                for (final stage in [
                  'demonstration',
                  'guided',
                  'independent',
                  if (!simple) 'recheck',
                ])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      observed.contains(stage)
                          ? Icons.circle
                          : Icons.radio_button_unchecked,
                      size: 16,
                    ),
                    title: Text(stageLabel(stage)),
                  ),
              ],
            ),
            Text(tr('步骤标记表示记录到该阶段，不代表已完成。')),
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }
}

/// Read only the task's saved baseline snapshot, never the current selection.
class LearningReference extends StatelessWidget {
  const LearningReference({
    super.key,
    required this.summary,
    this.savedBaseline = const {},
    this.framed = true,
    this.metric,
  });
  final Map<String, dynamic> summary;
  final Map<String, dynamic> savedBaseline;
  final bool framed;
  final String? metric;
  @override
  Widget build(BuildContext context) {
    final embedded = detailMap(summary['reference']);
    final reference = embedded.isNotEmpty
        ? embedded
        : detailMap(savedBaseline['statistics']);
    final origin = detailMap(
      summary['referenceOrigin'] ?? savedBaseline['referenceOrigin'],
    );
    final collected = origin['collectedAt'];
    final date =
        collected is num &&
            collected.isFinite &&
            collected >= 0 &&
            collected < 8640000000000
        ? DateTime.fromMillisecondsSinceEpoch(
            (collected * 1000).round(),
          ).toLocal().toString().substring(0, 19)
        : '—';
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailFacts(
          values: [
            for (final (key, label) in [
              ('attention', '专注基线'),
              ('relax', '放松基线'),
            ])
              if (metric == null || key == metric)
                (
                  trSource(label),
                  '${detailNumber(detailMap(reference[key])['mean'])} ± ${detailDeviation(detailMap(reference[key]))}',
                ),
            (tr('建立时间'), date),
          ],
        ),
        const SizedBox(height: 10),
        Text(tr('均值 ± 标准差，沿用本次任务开始时的基线。')),
      ],
    );
    return framed
        ? DetailSection(title: tr('本次参考基线'), child: content)
        : Padding(padding: const EdgeInsets.all(12), child: content);
  }
}

String stageTimelineLabel(Map<String, dynamic> event) =>
    trSource(switch (event['type']) {
      'pause' => '暂停任务',
      'prepare_data' => '重新检查信号',
      'interruption' => '任务中断',
      'resume' => '继续原任务',
      'finish' => '任务结束',
      _ => tr('进入{p0}', {'p0': stageLabel(event['stage'] as String? ?? '')}),
    });
