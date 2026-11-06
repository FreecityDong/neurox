import 'curve_reading.dart';
import 'detail_widgets.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../shell/feedback_preferences.dart';
import 'task_controller.dart';
import 'scene_protocol.dart';
import 'monitoring_widgets.dart' show taskTime;

String sceneEventLabel(Map event) => trSource(switch (event['type']) {
  'deviation' => '确认偏离',
  'recovery' => '确认恢复',
  'repeated_deviation' => '反复偏离',
  'recheck' => '恢复后复查',
  'state' => event['state'] == 'unknown' ? '状态未知' : '状态变化',
  'quality' => '数据质量变化',
  'interruption' => '采集中断',
  'stage' => '阶段切换',
  'pause' => '暂停',
  'resume' => '继续',
  'recovery_start' => '开始恢复练习',
  'recovery_step' => '恢复练习步骤',
  'recovery_end' => '返回任务复查',
  'reminder' => '反馈请求',
  'data_unavailable' => '数据不可用',
  'stage_summary' => '阶段小结',
  'recovery_complete' => '恢复练习结束',
  'recovery_rating' => '主观准备度',
  'finish' => '结束任务',
  _ => '任务事件',
});

/// Status is drawn as a time range; attention events remain in storage only.
class CurveStateSpan {
  const CurveStateSpan(this.start, this.end, this.state);
  final double start, end;
  final String state;
}

double curveTime(Map event) =>
    ((event['curveSeconds'] ?? event['wallSeconds'] ?? event['elapsed'])
            as num?)
        ?.toDouble() ??
    0;
List<CurveStateSpan> curveStateSpans(
  List<Map<String, dynamic>> events,
  double total,
) {
  final sorted = events.indexed.toList()
    ..sort((a, b) {
      final t = curveTime(a.$2).compareTo(curveTime(b.$2));
      return t == 0 ? a.$1.compareTo(b.$1) : t;
    });
  final result = <CurveStateSpan>[];
  var state = 'unknown';
  double start = 0;
  for (final (_, e) in sorted) {
    String? next;
    if (e['type'] == 'state') next = e['state'] as String?;
    if (e['type'] == 'deviation') next = 'deviation';
    if (e['type'] == 'recovery') next = 'stable';
    if ([
      'pause',
      'interruption',
      'stage',
      'recovery_start',
      'data_unavailable',
      'finish',
    ].contains(e['type'])) {
      next = 'unknown';
    }
    if (next == null || next == state) continue;
    final at = curveTime(e).clamp(0, total).toDouble();
    if (at > start) result.add(CurveStateSpan(start, at, state));
    start = at;
    state = next;
  }
  if (total > start) result.add(CurveStateSpan(start, total, state));
  return result;
}

class SceneCurve extends StatefulWidget {
  const SceneCurve({
    super.key,
    required this.events,
    this.reference = const {},
    this.observationOnly = false,
    this.observationHint,
    this.title,
    this.eventLogTitle,
    this.eventLabel,
    this.interactive = false,
    this.showEventLog = true,
    this.metric,
    this.standardDeviationReference = false,
  });
  final List<Map<String, dynamic>> events;
  final Map reference;
  final bool observationOnly;
  final String? observationHint;
  final String? title;
  final String? eventLogTitle;
  final String Function(Map<String, dynamic>)? eventLabel;
  final bool interactive;
  final bool showEventLog;
  final bool standardDeviationReference;

  /// Null retains both metrics for existing baseline and live views.
  final String? metric;
  @override
  State<SceneCurve> createState() => _SceneCurveState();
}

class _SceneCurveState extends State<SceneCurve> {
  double? selectedSeconds;
  List<Map<String, dynamic>> get events => widget.events;
  Map get reference => widget.reference;
  bool get observationOnly => widget.observationOnly;
  String? get observationHint => widget.observationHint;
  String? get title => widget.title;
  String? get eventLogTitle => widget.eventLogTitle;
  String Function(Map<String, dynamic>)? get eventLabel => widget.eventLabel;
  @override
  Widget build(BuildContext context) {
    final samples = events.where((e) => e['type'] == 'sample').toList();
    final total = events.fold<double>(0, (v, e) => math.max(v, curveTime(e)));
    final reading = widget.interactive && selectedSeconds != null
        ? readCurve(samples, selectedSeconds!.clamp(0, total).toDouble())
        : null;
    final spans = observationOnly
        ? <CurveStateSpan>[]
        : curveStateSpans(events, total);
    Widget legend(Color color, String label, {bool area = false}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 18, height: area ? 12 : 3, color: color),
        const SizedBox(width: 5),
        Flexible(child: Text(trSource(label))),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title ?? tr('实时指标曲线'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          children: [
            if (widget.metric != 'relax') legend(Colors.blue, '专注度'),
            if (widget.metric != 'attention') legend(Colors.purple, '放松度'),
          ],
        ),
        const SizedBox(height: 8),
        if (!observationOnly)
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              legend(
                Colors.green.withValues(alpha: .35),
                '绿色范围：专注',
                area: true,
              ),
              legend(Colors.red.withValues(alpha: .35), '红色范围：偏离', area: true),
              legend(
                Colors.grey.withValues(alpha: .35),
                '灰色范围：未知／暂停',
                area: true,
              ),
            ],
          ),
        Text(
          observationOnly
              ? observationHint ??
                    tr('从游戏开始计时记录；蓝线为专注、紫线为放松。灰色虚线连接缺数据区间，本图不做基线状态判断。')
              : tr('红绿范围表示相对个人基线的状态；灰色虚线仅连接缺数据区间，不参与判断。'),
        ),
        if (reference.isNotEmpty)
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              legend(Colors.black54, '基线均值：灰色实线'),
              if (widget.standardDeviationReference)
                legend(Colors.teal, '均值 ± 标准差')
              else ...[
                legend(Colors.orange, '下降边界：橙色虚线'),
                legend(Colors.brown, '恢复边界：棕色虚线'),
              ],
            ],
          ),
        if (samples.isEmpty) Text(tr('暂无可显示的指标数据')),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 42,
              height: 180,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final v
                      in widget.interactive
                          ? [100, 80, 60, 40, 20, 0]
                          : [100, 50, 0])
                    Text(
                      '$v',
                      style: widget.interactive
                          ? Theme.of(context).textTheme.bodySmall
                          : null,
                    ),
                ],
              ),
            ),
            Expanded(
              child: Semantics(
                label: observationOnly
                    ? widget.metric == 'attention'
                          ? tr('专注度')
                          : widget.metric == 'relax'
                          ? tr('放松度')
                          : tr('专注与放松观察曲线')
                    : tr('蓝色专注、紫色放松；绿色专注范围、红色偏离范围、灰色未知范围。'),
                child: LayoutBuilder(
                  builder: (context, box) {
                    void select(double x) {
                      if (box.maxWidth <= 0 || total <= 0) return;
                      setState(
                        () => selectedSeconds =
                            (x / box.maxWidth).clamp(0, 1) * total,
                      );
                    }

                    return GestureDetector(
                      key: widget.interactive
                          ? const ValueKey('baseline-interactive-plot')
                          : null,
                      behavior: HitTestBehavior.opaque,
                      onTapDown: widget.interactive
                          ? (d) => select(d.localPosition.dx)
                          : null,
                      onHorizontalDragStart: widget.interactive
                          ? (d) => select(d.localPosition.dx)
                          : null,
                      onHorizontalDragUpdate: widget.interactive
                          ? (d) => select(d.localPosition.dx)
                          : null,
                      child: Stack(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            height: 180,
                            child: CustomPaint(
                              painter: _ScenePainter(
                                samples,
                                spans,
                                total,
                                reference,
                                events
                                    .where(
                                      (e) => [
                                        'pause',
                                        'interruption',
                                        'data_unavailable',
                                        'prepare_data',
                                        'rebaseline',
                                      ].contains(e['type']),
                                    )
                                    .map(curveTime)
                                    .toList(),
                                detailedAxes: widget.interactive,
                                metric: widget.metric,
                                standardDeviationReference:
                                    widget.standardDeviationReference,
                              ),
                            ),
                          ),
                          if (reading != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _CurveCursorPainter(
                                    reading,
                                    total,
                                    metric: widget.metric,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        if (widget.interactive) ...[
          Padding(
            padding: const EdgeInsets.only(left: 42),
            child: LayoutBuilder(
              builder: (context, box) {
                final measure = TextPainter(
                  text: TextSpan(
                    text: detailTime(total),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout();
                final count = ((box.maxWidth + 12) / (measure.width + 12))
                    .floor()
                    .clamp(2, 6);
                measure.dispose();
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 0; i < count; i++)
                      Text(
                        detailTime(total * i / (count - 1)),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          if (reading == null)
            Text(tr('点按或左右拖动曲线查看数值'))
          else
            Container(
              key: const ValueKey('baseline-curve-reading'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      Text(tr('时间：{p0}', {'p0': detailTime(reading.time)})),
                      if (widget.metric != 'relax')
                        Text(
                          tr('专注：{p0}', {
                            'p0': detailNumber(reading.attention),
                          }),
                        ),
                      if (widget.metric != 'attention')
                        Text(
                          tr('放松：{p0}', {'p0': detailNumber(reading.relax)}),
                        ),
                    ],
                  ),
                  if (widget.metric == 'attention'
                      ? reading.attention == null
                      : widget.metric == 'relax'
                      ? reading.relax == null
                      : reading.attention == null && reading.relax == null)
                    Text(tr('该时刻暂无有效指标，虚线不代表实测值')),
                  if (eventLabel != null) ...[
                    for (final event
                        in events
                            .where(
                              (e) =>
                                  e['type'] == 'quality' &&
                                  curveTime(e) <= reading.time,
                            )
                            .toList()
                            .reversed
                            .take(1))
                      Text(eventLabel!(event)),
                  ],
                ],
              ),
            ),
        ] else
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(taskTime(0)), Text(taskTime(total))],
          ),
        if (widget.showEventLog)
          ExpansionTile(
            title: Text(eventLogTitle ?? tr('采集与调整记录')),
            children: [
              for (final event
                  in events
                      .where(
                        (e) => [
                          'quality',
                          'interruption',
                          'pause',
                          'resume',
                          'stage',
                          'data_unavailable',
                          'recovery_start',
                          'recovery_end',
                        ].contains(e['type']),
                      )
                      .toList()
                      .reversed
                      .take(50))
                ListTile(
                  dense: true,
                  title: Text(
                    eventLabel?.call(event) ?? sceneEventLabel(event),
                  ),
                  subtitle: Text(taskTime(curveTime(event))),
                ),
            ],
          ),
      ],
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(
    this.samples,
    this.spans,
    this.total,
    this.reference,
    this.breaks, {
    this.detailedAxes = false,
    this.metric,
    this.standardDeviationReference = false,
  });
  final bool detailedAxes;
  final String? metric;
  final bool standardDeviationReference;
  final List<double> breaks;
  final List<Map<String, dynamic>> samples;
  final List<CurveStateSpan> spans;
  final double total;
  final Map reference;
  void dashed(Canvas c, Offset a, Offset b, Paint paint) {
    final d = (b - a).distance;
    if (d == 0) return;
    for (double at = 0; at < d; at += 8) {
      c.drawLine(
        Offset.lerp(a, b, at / d)!,
        Offset.lerp(a, b, math.min(at + 4, d) / d)!,
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    double y(double value) => size.height * (1 - value.clamp(0, 100) / 100);
    if (total > 0) {
      for (final span in spans) {
        final color = span.state == 'deviation'
            ? Colors.red
            : span.state == 'stable'
            ? Colors.green
            : Colors.grey;
        canvas.drawRect(
          Rect.fromLTRB(
            span.start / total * size.width,
            0,
            span.end / total * size.width,
            size.height,
          ),
          Paint()..color = color.withValues(alpha: .13),
        );
      }
    }
    final grid = Paint()
      ..color = (detailedAxes
          ? Colors.grey.withValues(alpha: .22)
          : Colors.grey.shade300)
      ..strokeWidth = detailedAxes ? .5 : 1;
    for (final line
        in detailedAxes ? [0.0, .2, .4, .6, .8, 1.0] : [0.0, .5, 1.0]) {
      canvas.drawLine(
        Offset(0, size.height * line),
        Offset(size.width, size.height * line),
        grid,
      );
    }
    if (detailedAxes) {
      canvas.drawLine(Offset.zero, Offset(0, size.height), grid);
    }
    if (total <= 0) return;
    final referenceKey = metric == 'relax' ? 'relax' : 'attention';
    final mean = (reference[referenceKey] as Map?)?['mean'] as num?,
        variance = (reference[referenceKey] as Map?)?['variance'] as num?;
    if (mean != null) {
      canvas.drawLine(
        Offset(0, y(mean.toDouble())),
        Offset(size.width, y(mean.toDouble())),
        Paint()..color = Colors.black54,
      );
      if (standardDeviationReference) {
        final sd = math.sqrt(math.max(0, variance?.toDouble() ?? 0));
        final upper = y(mean.toDouble() + sd), lower = y(mean.toDouble() - sd);
        canvas.drawRect(
          Rect.fromLTRB(0, upper, size.width, lower),
          Paint()..color = Colors.teal.withValues(alpha: .10),
        );
        for (final value in [mean.toDouble() - sd, mean.toDouble() + sd]) {
          dashed(
            canvas,
            Offset(0, y(value)),
            Offset(size.width, y(value)),
            Paint()..color = Colors.teal,
          );
        }
      } else {
        for (final (value, color) in [
          (
            mean.toDouble() - math.max(math.sqrt(variance?.toDouble() ?? 0), 5),
            Colors.orange,
          ),
          (
            mean.toDouble() -
                math.max(.5 * math.sqrt(variance?.toDouble() ?? 0), 3),
            Colors.brown,
          ),
        ]) {
          dashed(
            canvas,
            Offset(0, y(value)),
            Offset(size.width, y(value)),
            Paint()..color = color,
          );
        }
      }
    }
    for (final (key, color) in [
      ('attention', Colors.blue),
      ('relax', Colors.purple),
    ]) {
      if (metric != null && key != metric) continue;
      Offset? prior;
      double? last;
      bool missing = false;
      for (final event in samples) {
        final value = (event['scores'] as Map?)?[key] as num?,
            time = curveTime(event);
        if (value == null || !value.isFinite) {
          missing = true;
          continue;
        }
        final current = Offset(time / total * size.width, y(value.toDouble()));
        if (prior != null && last != null) {
          if (missing ||
              time - last > 2.5 ||
              breaks.any((t) => t >= last! && t < time)) {
            dashed(
              canvas,
              prior,
              current,
              Paint()
                ..color = Colors.grey
                ..strokeWidth = 1.5,
            );
          } else {
            canvas.drawLine(
              prior,
              current,
              Paint()
                ..color = color
                ..strokeWidth = 2,
            );
          }
        } else {
          canvas.drawCircle(current, 2, Paint()..color = color);
        }
        prior = current;
        last = time;
        missing = false;
      }
      if (prior != null && last != null && total > last) {
        dashed(
          canvas,
          prior,
          Offset(size.width, prior.dy),
          Paint()
            ..color = Colors.grey
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => true;
}

class _CurveCursorPainter extends CustomPainter {
  _CurveCursorPainter(this.reading, this.total, {this.metric});
  final String? metric;
  final CurveReading reading;
  final double total;
  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final x = (reading.time / total).clamp(0, 1) * size.width;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = Colors.teal
        ..strokeWidth = 1,
    );
    for (final (value, color) in [
      if (metric != 'relax') (reading.attention, Colors.blue),
      if (metric != 'attention') (reading.relax, Colors.purple),
    ]) {
      if (value == null) continue;
      final p = Offset(x, size.height * (1 - value / 100));
      canvas.drawCircle(p, 5, Paint()..color = Colors.white);
      canvas.drawCircle(p, 3.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _CurveCursorPainter oldDelegate) => true;
}

class SceneControls extends StatelessWidget {
  const SceneControls({super.key, required this.task});
  final TaskController task;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (task.scene.competitive) ...[
        Text(task.scene.label, style: Theme.of(context).textTheme.titleMedium),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final stage in task.scene.stages)
              ChoiceChip(
                label: Text(stageLabel(stage)),
                selected: task.sceneStage == stage,
                onSelected: task.busy ? null : (_) => task.changeStage(stage),
              ),
          ],
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('当前观察条件与基线一致')),
          subtitle: Text(tr('相同睁眼坐姿与阅读／观察条件；动作阶段只记录。')),
          value: task.conditionMatches,
          onChanged: task.busy ? null : (v) => task.setCondition(v == true),
        ),
        if (!task.stageSupportsComparison) Text(tr('本阶段不提供专注判断，保留原始记录和采集事件。')),
        Text(tr('竞技10秒偏离／15秒恢复为工程初值，按项目记录协议，不代表表现评估。')),
      ],
      FeedbackControls(
        value: task.feedback,
        onChanged: task.busy ? null : task.setFeedback,
      ),
    ],
  );
}

class RecoveryPanel extends StatelessWidget {
  const RecoveryPanel({super.key, required this.task, required this.onEnd});
  final TaskController task;
  final VoidCallback onEnd;
  @override
  Widget build(BuildContext context) {
    final flow = task.recoveryFlow;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(tr('主动恢复'), style: Theme.of(context).textTheme.headlineSmall),
        if (task.monitor?.phase == 'interrupted')
          FilledButton(
            onPressed: task.busy ? null : task.prepareLearning,
            child: Text(tr('重新准备数据')),
          ),
        if (flow == null) ...[
          Text(tr('选择方法，学习调整，再逐步减少引导。放松高分不等于恢复成功。')),
          if (task.recoveryChoosing)
            TextButton(
              onPressed: task.busy ? null : task.leaveRecovery,
              child: Text(tr('取消并返回任务')),
            ),
          for (final (method, label) in [
            ('breathing', '自然节奏呼吸'),
            ('attention', '注意返回练习'),
            ('release', '姿势与肌肉放松'),
          ])
            ListTile(
              title: Text(trSource(label)),
              trailing: const Icon(Icons.chevron_right),
              onTap: task.busy ? null : () => task.startRecovery(method),
            ),
        ] else ...[
          Text(
            stageLabel(flow.stage),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(flow.instruction),
          Text('${tr('本步骤用时')} ${taskTime(task.now - flow.stepStartedAt)}'),
          Text(tr('按自己的舒适节奏操作，准备好再进入下一步。')),
          Text(flow.stage == 'recheck' ? tr('练习后准备度（主观）') : tr('练习前准备度（主观）')),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 1; i <= 5; i++)
                ChoiceChip(
                  label: Text('$i'),
                  selected:
                      (flow.stage == 'recheck'
                          ? flow.readinessAfter
                          : flow.readinessBefore) ==
                      i,
                  onSelected: task.busy
                      ? null
                      : (_) => task.rateRecovery(
                          i,
                          after: flow.stage == 'recheck',
                        ),
                ),
            ],
          ),
          if (flow.stage != 'recheck')
            FilledButton(
              onPressed: task.busy ? null : task.advanceRecovery,
              child: Text(tr('下一步')),
            )
          else ...[
            CheckboxListTile(
              title: Text(tr('当前观察条件与基线一致')),
              value: task.conditionMatches,
              onChanged: task.busy ? null : (v) => task.setCondition(v == true),
            ),
            Text(
              trSource(switch (task.monitor?.checkResult) {
                'returned' => '已观察到持续回到参考范围',
                'not_observed' => '本次复查暂未观察到回到参考范围',
                'insufficient' => '复查数据不足',
                _ => '正在复查，等待有效数据',
              }),
            ),
            Text(tr('指标复查、主观准备度和自主完成情况分别记录，不判定治疗效果。')),
            if (flow.linked)
              FilledButton(
                onPressed: task.busy ? null : task.leaveRecovery,
                child: Text(tr('继续原任务')),
              ),
          ],
          TextButton(
            onPressed: task.busy
                ? null
                : flow.linked
                ? task.leaveRecovery
                : onEnd,
            child: Text(tr('结束本次练习')),
          ),
        ],
        Text(
          trSource(
            task.monitor?.phase == 'interrupted'
                ? '任务已中断，请重新准备数据'
                : '采集与原始记录状态以设备连接和保存状态为准。',
          ),
        ),
        Text(
          task.eeg.receiving && task.quality?.good == true
              ? tr('当前数据有效')
              : tr('数据不足／状态未知'),
        ),
        Text(task.eeg.recording ? tr('原始记录保存中') : tr('当前未在保存原始记录')),
        SceneCurve(
          events: task.monitor?.events ?? [],
          reference: task.monitor?.comparisonAllowed == true
              ? task.monitor!.reference
              : const {},
        ),
        FeedbackControls(
          value: task.feedback,
          onChanged: task.busy ? null : task.setFeedback,
        ),
        if (task.error != null) Text(trSource(task.error!)),
        OutlinedButton(
          onPressed: task.busy ? null : onEnd,
          child: Text(tr('结束任务并保存')),
        ),
      ],
    );
  }
}
