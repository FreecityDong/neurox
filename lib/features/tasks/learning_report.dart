import 'report_insight_widgets.dart';
import 'record_display_name.dart';
import 'scene_protocol.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import 'detail_widgets.dart';
import 'learning_trend.dart';

class LearningAttentionCurve extends StatefulWidget {
  const LearningAttentionCurve({super.key, required this.data});
  final LearningTrend data;
  @override
  State<LearningAttentionCurve> createState() => _LearningAttentionCurveState();
}

class _LearningAttentionCurveState extends State<LearningAttentionCurve> {
  double? selected;
  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final point = selected == null
        ? null
        : data.at(selected!.clamp(0, data.total).toDouble());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final (color, label) in [
              (Colors.blue, '专注度'),
              (Colors.teal, '均值 ± 标准差'),
              (Colors.green, '正常区间'),
              (Colors.amber, '确认前观察区间'),
              (Colors.red, '确认偏离区间'),
              (Colors.grey, '未知区间'),
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 14, height: 3, color: color),
                  const SizedBox(width: 4),
                  Flexible(child: Text(trSource(label))),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            void select(double x) {
              if (data.total <= 0) return;
              setState(
                () => selected =
                    ((x - 42) / (box.maxWidth - 52)).clamp(0, 1) * data.total,
              );
            }

            return GestureDetector(
              key: const ValueKey('learning-attention-plot'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => select(d.localPosition.dx),
              onHorizontalDragStart: (d) => select(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => select(d.localPosition.dx),
              child: SizedBox(
                width: double.infinity,
                height: 250,
                child: CustomPaint(
                  painter: LearningPlotPainter(
                    data,
                    selected: point,
                    textScale: MediaQuery.textScalerOf(context).scale(1),
                    fontFamily: Theme.of(
                      context,
                    ).textTheme.bodySmall?.fontFamily,
                  ),
                ),
              ),
            );
          },
        ),
        if (point == null)
          Text(tr('点按或左右拖动曲线查看数值'))
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(tr('时间：{p0}', {'p0': detailTime(point.time)})),
                Text(tr('专注：{p0}', {'p0': detailNumber(point.value)})),
                Text(
                  point.value == null
                      ? tr('该时刻暂无有效指标，虚线不代表实测值')
                      : trSource(switch (data.stateAt(
                          math.max(0, point.time - .001),
                        )) {
                          'deviation' => '确认偏离',
                          'stable' => '正常（未形成偏离）',
                          'candidate' => '确认前观察（计入偏离）',
                          _ => '暂无法判断',
                        }),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text(tr('灰色虚线连接缺失数据，不参与趋势或偏离统计。')),
      ],
    );
  }
}

class LearningPlotPainter extends CustomPainter {
  LearningPlotPainter(
    this.data, {
    this.selected,
    this.textScale = 1,
    this.fontFamily,
  });
  final LearningTrend data;
  final LearningPoint? selected;
  final double textScale;
  final String? fontFamily;
  void text(
    Canvas canvas,
    String text,
    Offset offset, {
    double size = 11,
    Color color = Colors.blueGrey,
  }) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: size * textScale,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, offset);
    p.dispose();
  }

  void dash(Canvas c, Offset a, Offset b, Color color) {
    final d = (b - a).distance;
    if (d == 0) return;
    for (double i = 0; i < d; i += 8) {
      c.drawLine(
        Offset.lerp(a, b, i / d)!,
        Offset.lerp(a, b, math.min(i + 4, d) / d)!,
        Paint()
          ..color = color
          ..strokeWidth = 1,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      42,
      12,
      math.max(1, size.width - 52),
      size.height - 42,
    );
    double x(double at) =>
        plot.left + (data.total > 0 ? at / data.total : 0) * plot.width;
    double y(double v) => plot.bottom - v.clamp(0, 100) / 100 * plot.height;
    canvas.drawRect(plot, Paint()..color = Colors.grey.withValues(alpha: .07));
    if (data.lower != null && data.upper != null) {
      canvas.drawRect(
        Rect.fromLTRB(plot.left, y(data.upper!), plot.right, y(data.lower!)),
        Paint()..color = Colors.teal.withValues(alpha: .12),
      );
    }
    if (data.timelineComplete) {
      for (final s in data.displaySpans) {
        canvas.drawRect(
          Rect.fromLTRB(x(s.start), plot.top, x(s.end), plot.bottom),
          Paint()
            ..color =
                (s.state == 'deviation'
                        ? Colors.red
                        : s.state == 'candidate'
                        ? Colors.amber
                        : s.state == 'stable'
                        ? Colors.green
                        : Colors.grey)
                    .withValues(
                      alpha: s.state == 'stable' || s.state == 'deviation'
                          ? .30
                          : .16,
                    ),
        );
      }
    }
    for (final v in [0, 20, 40, 60, 80, 100]) {
      canvas.drawLine(
        Offset(plot.left, y(v.toDouble())),
        Offset(plot.right, y(v.toDouble())),
        Paint()
          ..color = Colors.grey.withValues(alpha: .25)
          ..strokeWidth = .5,
      );
      text(canvas, '$v', Offset(0, y(v.toDouble()) - 6 * textScale));
    }
    final measure = TextPainter(
      text: TextSpan(
        text: detailTime(data.total),
        style: TextStyle(fontFamily: fontFamily, fontSize: 11 * textScale),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final count = ((plot.width + 12) / (measure.width + 12)).floor().clamp(
      2,
      6,
    );
    measure.dispose();
    for (var i = 0; i < count; i++) {
      final at = data.total * i / (count - 1),
          label = detailTime(data.total * i / (count - 1));
      text(
        canvas,
        label,
        Offset(
          (x(at) - label.length * 2.8 * textScale).clamp(
            plot.left,
            math.max(plot.left, plot.right - label.length * 6 * textScale),
          ),
          plot.bottom + 8,
        ),
      );
    }
    if (data.mean != null) {
      dash(
        canvas,
        Offset(plot.left, y(data.mean!)),
        Offset(plot.right, y(data.mean!)),
        Colors.teal,
      );
    }
    if (data.lower != null && data.upper != null) {
      for (final v in [data.lower!, data.upper!]) {
        dash(
          canvas,
          Offset(plot.left, y(v)),
          Offset(plot.right, y(v)),
          Colors.teal.withValues(alpha: .6),
        );
      }
    }
    LearningPoint? prior;
    var gap = false;
    for (final p in data.points) {
      if (p.value == null) {
        gap = true;
        continue;
      }
      final current = Offset(x(p.time), y(p.value!));
      if (prior != null) {
        final a = Offset(x(prior.time), y(prior.value!));
        if (gap || p.time - prior.time > 1.5) {
          dash(canvas, a, current, Colors.grey);
        } else {
          final cuts = <double>[0, 1];
          if (p.value != prior.value &&
              data.lower != null &&
              data.upper != null) {
            for (final b in [data.lower!, data.upper!]) {
              final f = (b - prior.value!) / (p.value! - prior.value!);
              if (f > 0 && f < 1) cuts.add(f);
            }
          }
          cuts.sort();
          for (var i = 1; i < cuts.length; i++) {
            final mid =
                prior.value! +
                (p.value! - prior.value!) * (cuts[i - 1] + cuts[i]) / 2;
            final color = data.lower != null && mid < data.lower!
                ? Colors.red
                : data.upper != null && mid > data.upper!
                ? Colors.orange
                : Colors.blue;
            canvas.drawLine(
              Offset.lerp(a, current, cuts[i - 1])!,
              Offset.lerp(a, current, cuts[i])!,
              Paint()
                ..color = color
                ..strokeWidth = 2.3,
            );
          }
        }
      } else {
        canvas.drawCircle(current, 2, Paint()..color = Colors.blue);
      }
      prior = p;
      gap = false;
    }
    if (selected != null && data.total > 0) {
      final at = x(selected!.time);
      canvas.drawLine(
        Offset(at, plot.top),
        Offset(at, plot.bottom),
        Paint()
          ..color = Colors.teal
          ..strokeWidth = 1,
      );
      if (selected!.value != null) {
        canvas.drawCircle(
          Offset(at, y(selected!.value!)),
          5,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          Offset(at, y(selected!.value!)),
          3.5,
          Paint()..color = Colors.blue,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant LearningPlotPainter oldDelegate) => true;
}

LearningTrend learningTrendFromRow(Map<String, dynamic> row) {
  final summary = detailMap(row['monitor_json']);
  final frozen = detailMap(row['baseline_json']);
  if (detailMap(summary['reference']).isEmpty) {
    summary['reference'] = frozen['statistics'];
  }
  return LearningTrend(summary, [
    for (final e in row['events'] as List? ?? [])
      detailMap((e as Map)['payload']),
  ]);
}

/// Standalone PNG composition; independent of scroll position or screen size.
Future<Uint8List> renderLearningReport(
  Map<String, dynamic> row, {
  String? fontFamily,
}) async {
  final data = learningTrendFromRow(row), recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const width = 1100.0, margin = 56.0;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, 7000),
    Paint()..color = const Color(0xfff5f9f7),
  );
  var top = 52.0;
  void paragraph(
    String value, {
    double size = 25,
    FontWeight weight = FontWeight.normal,
  }) {
    final p = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: size,
          fontWeight: weight,
          color: const Color(0xff234448),
          height: 1.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width - margin * 2);
    p.paint(canvas, Offset(margin, top));
    top += p.height + 20;
    p.dispose();
  }

  paragraph(
    'NeuroX · ${tr(data.summary['scene'] == 'learning' ? '学习趋势报告' : '竞技／运动趋势报告')}',
    size: 36,
    weight: FontWeight.bold,
  );
  paragraph(recordDisplayName(row), size: 30);
  if (data.summary['scene'] != 'learning') {
    paragraph(
      TaskScene.values.firstWhere((s) => s.name == data.summary['scene']).label,
    );
  }
  if (data.summary['isReplay'] == true ||
      detailMap(row['task_json'])['isReplay'] == true) {
    paragraph(tr('测试回放：来源为学习记录，不代表实际竞技／运动采集。'), weight: FontWeight.bold);
  }
  if (data.summary['isReplay'] == true && data.summary['scene'] == 'archery') {
    paragraph(tr('射箭回放仅含静态准备，不含瞄准／释放数据。'));
  }
  final started = LearningTrend.number(row['started']);
  if (started != null && started >= 0 && started < 8640000000000) {
    paragraph(
      tr('开始时间：{p0}', {
        'p0': DateTime.fromMillisecondsSinceEpoch(
          (started * 1000).round(),
        ).toLocal().toString().substring(0, 19),
      }),
    );
  }
  paragraph(
    tr('任务状态：{p0}', {
      'p0': row['task_state'] == 'task_complete' ? tr('已完成') : tr('未完成'),
    }),
  );
  paragraph(
    tr('记录时长 {p0} · 可判断 {p1} · 覆盖 {p2}', {
      'p0': detailTime(data.total),
      'p1': detailTime(data.summary['validSeconds']),
      'p2': detailRatio(data.summary['validSeconds'], data.total),
    }),
  );
  paragraph(
    tr('专注基线 {p0} ± {p1}', {
      'p0': detailNumber(data.mean),
      'p1': detailNumber(data.sd),
    }),
  );
  canvas.save();
  canvas.translate(margin, top);
  LearningPlotPainter(
    data,
    textScale: 1.8,
    fontFamily: fontFamily,
  ).paint(canvas, const Size(width - margin * 2, 420));
  canvas.restore();
  top += 440;
  paragraph(
    tr('蓝色线段在参考范围内，红/橙线段分别低/高于范围；背景绿/黄/红/灰分别表示正常/确认前观察/确认后偏离/未知。'),
    size: 22,
  );
  paragraph(tr('趋势解释'), size: 30, weight: FontWeight.bold);
  for (final line in data.explanations) {
    paragraph(line);
  }
  final intervals = data.displaySpans
      .where((s) => s.state == 'deviation' || s.state == 'candidate')
      .toList();
  if (intervals.isNotEmpty) {
    paragraph(tr('偏离区间明细'), size: 28, weight: FontWeight.bold);
    paragraph(
      intervals
          .take(12)
          .map(
            (s) =>
                '${s.state == 'candidate' ? tr('确认前观察') : tr('确认后偏离')} ${detailTime(s.start)}–${detailTime(s.end)}',
          )
          .join('  ·  '),
    );
    if (intervals.length > 12) {
      paragraph(tr('另有 {p0} 个区间，完整状态已体现在曲线上。', {'p0': intervals.length - 12}));
    }
  }
  if (data.summary['checkpointOnly'] == true) {
    paragraph(tr('中断记录仅包含已保存数据，缺失部分未补算。'));
  }
  if (top > 6500) throw StateError('Report too tall');
  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), (top + 36).ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (bytes == null) throw StateError('PNG encoding failed');
  return bytes.buffer.asUint8List();
}

/// Chart first; saved baseline and detailed provenance are shown below it.
class LearningSessionContent extends StatelessWidget {
  const LearningSessionContent({super.key, required this.data});
  final LearningTrend data;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (data.summary['checkpointOnly'] == true)
        Text(tr('中断记录仅包含已保存数据，缺失部分未补算。')),
      DetailSection(
        title: tr('过程曲线'),
        child: LearningAttentionCurve(data: data),
      ),
      DetailSection(
        title: tr(data.summary['scene'] == 'learning' ? '学习概况' : '训练概况'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DetailFacts(
              values: [
                for (final (key, label) in [
                  ('stable', '正常（未形成偏离）'),
                  ('candidate', '确认前观察'),
                  ('deviation', '确认后偏离'),
                  ('unknown', '暂无法判断'),
                ])
                  (
                    trSource(label),
                    '${detailTime(data.durations[key])} · ${data.share(key)}',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('偏离合计 {p0} · 占比 {p1}', {
                'p0': detailTime(data.combinedDeviation),
                'p1': data.share('combined'),
              }),
            ),
            const SizedBox(height: 8),
            Text(
              tr('可判断 {p0} · 比例 {p1}', {
                'p0': detailTime(data.summary['validSeconds']),
                'p1': detailRatio(data.summary['validSeconds'], data.total),
              }),
            ),
          ],
        ),
      ),
      ReportInsights(lines: data.explanations, notes: data.statisticalNotes),
    ],
  );
}
