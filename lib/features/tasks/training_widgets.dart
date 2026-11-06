import 'report_insights.dart';
import 'report_insight_widgets.dart';
import 'learning_flow_widgets.dart' show LearningStageGuide;
import 'scene_protocol.dart';
import 'detail_widgets.dart';
export 'training_observation.dart';
import 'training_observation.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../l10n/app_language.dart';
import 'training_game.dart';
import 'task_controller.dart';
import 'monitoring_widgets.dart' show taskTime;

class TrainingPanel extends StatefulWidget {
  const TrainingPanel({super.key, required this.task, required this.onEnd});
  final TaskController task;
  final VoidCallback onEnd;
  @override
  State<TrainingPanel> createState() => _TrainingPanelState();
}

class _TrainingPanelState extends State<TrainingPanel>
    with SingleTickerProviderStateMixin {
  late final Ticker ticker;
  @override
  void initState() {
    super.initState();
    ticker = createTicker((_) {
      if (mounted) {
        widget.task.driveTraining();
        setState(() {});
      }
    })..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.task.trainingGame;
    if (game == null) return const SizedBox.shrink();
    final task = widget.task;
    final active = task.monitor?.phase == 'running' && !task.busy;
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.min(math.max(200.0, box.maxWidth - 24), 650.0);
        final height = math.max(200.0, math.min(width, box.maxHeight * .67));
        final size = math.min(width, height);
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LearningStageGuide(stage: 2, scene: TaskScene.training),
                Text(
                  game.kind.label,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    Text(
                      game.kind == TrainingKind.tracking
                          ? tr('已找到 {p0}/{p1} 个目标', {
                              'p0': game.correct,
                              'p1': game.goal,
                            })
                          : tr('下一个：{p0}', {
                              'p0': math.min(game.next, game.goal),
                            }),
                    ),
                    Text(
                      game.kind.limit > 0
                          ? tr('剩余 {p0}', {'p0': taskTime(game.remaining)})
                          : tr('用时 {p0}', {'p0': taskTime(game.elapsed)}),
                    ),
                    Text(tr('失误 {p0} 次', {'p0': game.mistakes})),
                  ],
                ),
                if (game.kind == TrainingKind.tracking)
                  Text(
                    trSource(switch (game.phase) {
                      'memorize' => '记住画圈的小球',
                      'moving' => '跟踪原来的目标，暂时不要点击',
                      _ => '小球已停止，请点击原来的目标',
                    }),
                  ),
                Text(tr('游戏期间无声音、震动、通知或脑波提醒。')),
                Text(
                  task.eeg.recording && task.quality?.observationGood == true
                      ? tr('脑波采集中')
                      : tr('脑波数据暂不可用，游戏记录继续保留'),
                ),
                Center(
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: !active
                          ? null
                          : (details) {
                              final x = details.localPosition.dx / size * 600,
                                  y = details.localPosition.dy / size * 600;
                              final candidates =
                                  game.tokens.where((t) {
                                    if (game.kind == TrainingKind.hexagons) {
                                      final dx = (x - t.x).abs(),
                                          dy = (y - t.y).abs(),
                                          r = t.radius;
                                      return dx <= r &&
                                          dy <= math.sqrt(3) * r / 2 &&
                                          math.sqrt(3) * dx + dy <=
                                              math.sqrt(3) * r;
                                    }
                                    return math.sqrt(
                                          (t.x - x) * (t.x - x) +
                                              (t.y - y) * (t.y - y),
                                        ) <=
                                        math.max(t.radius, 16 / size * 600);
                                  }).toList()..sort(
                                    (a, b) =>
                                        ((a.x - x) * (a.x - x) +
                                                (a.y - y) * (a.y - y))
                                            .compareTo(
                                              (b.x - x) * (b.x - x) +
                                                  (b.y - y) * (b.y - y),
                                            ),
                                  );
                              if (candidates.isNotEmpty) {
                                task.tapTraining(candidates.first.value);
                              }
                            },
                      child: Semantics(
                        label: game.kind.instructions,
                        child: CustomPaint(painter: _TrainingPainter(game)),
                      ),
                    ),
                  ),
                ),
                if (!active && task.monitor?.finished != true) ...[
                  Text(tr('游戏已暂停，重新准备数据后继续。')),
                  FilledButton(
                    onPressed: task.busy ? null : task.prepareLearning,
                    child: Text(tr('重新准备数据')),
                  ),
                ],
                if (task.error != null) Text(trSource(task.error!)),
                if (task.monitor?.finished == true)
                  FilledButton(
                    onPressed: task.busy ? null : task.finish,
                    child: Text(task.busy ? tr('正在保存…') : tr('重试保存任务')),
                  ),
                TextButton(
                  onPressed: task.busy ? null : widget.onEnd,
                  child: Text(tr('提前结束并保存为未完成')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TrainingPainter extends CustomPainter {
  _TrainingPainter(this.game);
  final TrainingGame game;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 600, size.height / 600);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 600, 600),
      Paint()..color = const Color(0xfff1f7f4),
    );
    if (game.kind == TrainingKind.rings) {
      const colors = [
        Color(0xffdbead5),
        Color(0xffdcecf3),
        Color(0xffd4e8e3),
        Color(0xffedf3e8),
      ];
      for (var i = 3; i >= 0; i--) {
        canvas.drawCircle(
          const Offset(300, 300),
          [84.0, 144.0, 204.0, 264.0][i],
          Paint()..color = colors[i],
        );
      }
    }
    for (final obstacle in game.obstacles) {
      canvas.drawCircle(
        Offset(obstacle.x, obstacle.y),
        obstacle.radius,
        Paint()..color = Colors.teal.shade500,
      );
      canvas.drawCircle(
        Offset(obstacle.x, obstacle.y),
        obstacle.radius / 2,
        Paint()..color = Colors.teal.shade200,
      );
    }
    for (final token in game.tokens) {
      final wrong =
          token.wrongUntil > game.elapsed ||
          game.kind == TrainingKind.tracking && token.selected && !token.target;
      final correct =
          token.flashUntil > game.elapsed ||
          game.kind == TrainingKind.tracking && token.selected && token.target;
      final color = wrong
          ? Colors.red.shade200
          : correct
          ? Colors.green.shade300
          : Colors.white;
      final border = Paint()
        ..color = game.kind == TrainingKind.hexagons && token.value == game.next
            ? Colors.red
            : Colors.blueGrey
        ..style = PaintingStyle.stroke
        ..strokeWidth =
            game.kind == TrainingKind.hexagons && token.value == game.next
            ? 3
            : 1.5;
      final center = Offset(token.x, token.y);
      if (game.kind == TrainingKind.hexagons) {
        final path = Path();
        for (var i = 0; i < 6; i++) {
          final angle = i * math.pi / 3,
              p = Offset(
                center.dx + math.cos(angle) * token.radius,
                center.dy + math.sin(angle) * token.radius,
              );
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        path.close();
        canvas.drawPath(path, Paint()..color = color);
        canvas.drawPath(path, border);
      } else {
        canvas.drawCircle(
          center,
          token.radius,
          Paint()
            ..color = game.kind == TrainingKind.tracking && !token.selected
                ? Colors.blueGrey.shade400
                : color,
        );
        canvas.drawCircle(center, token.radius, border);
      }
      if (game.kind == TrainingKind.tracking) {
        if (game.phase == 'memorize' && token.target) {
          canvas.drawCircle(
            center,
            token.radius + 8,
            Paint()
              ..color = Colors.orange
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4,
          );
        }
      } else {
        final text = TextPainter(
          text: TextSpan(
            text: '${token.value}',
            style: TextStyle(
              color: Colors.black87,
              fontSize: game.kind == TrainingKind.hexagons
                  ? token.radius * .55
                  : game.kind == TrainingKind.rings
                  ? 24
                  : 26,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TrainingPainter oldDelegate) => true;
}

class TrainingReport extends StatelessWidget {
  const TrainingReport({
    super.key,
    required this.summary,
    required this.events,
  });
  final Map<String, dynamic> summary;
  final List<Map<String, dynamic>> events;
  @override
  Widget build(BuildContext context) {
    final game = detailMap(summary['game']);
    final observation = trainingObservation(trainingCurveEvents(events));
    final count = (observation['validSeconds'] as num).toDouble();
    final kinds = TrainingKind.values.where((v) => v.name == game['kind']);
    final kind = kinds.isEmpty ? null : kinds.first;
    final finished = summary['phase'] == 'finished';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailSection(
          title: tr('训练概况'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DetailFacts(
                values: [
                  (tr('训练项目'), kind?.label ?? '—'),
                  (
                    tr('完成目标'),
                    '${game['correct'] ?? '—'}/${game['goal'] ?? '—'}',
                  ),
                  (tr('失误次数'), detailNumber(game['mistakes'], decimals: 0)),
                  (tr('游戏用时'), detailTime(game['elapsed'])),
                  if (kind == TrainingKind.tracking &&
                      game['level'] is int &&
                      (game['level'] as int) >= 0 &&
                      (game['level'] as int) < TrackingLevel.values.length)
                    (
                      tr('难度'),
                      trSource(
                        TrackingLevel.values[game['level'] as int].label,
                      ),
                    ),
                  if (game['responseSeconds'] is num)
                    (
                      tr('目标选择用时'),
                      tr('{p0} 秒', {
                        'p0': detailNumber(game['responseSeconds']),
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                !finished
                    ? tr('训练进行中，完成后生成简报。')
                    : game.isEmpty
                    ? tr('未记录')
                    : trSource(switch (game['outcome']) {
                        'completed' => '已完成全部目标',
                        'timeout' => '训练时间到，已保存本轮成绩',
                        _ => '训练提前结束，记录为未完成',
                      }),
              ),
            ],
          ),
        ),
        DetailSection(
          title: tr('脑波观察'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('有效脑波观察 {p0} 秒', {'p0': count.toStringAsFixed(1)})),
              const SizedBox(height: 16),
              if (count >= 10)
                DetailFacts(
                  values: [
                    (
                      tr('专注均值 ± 标准差'),
                      '${detailNumber(observation['attention']['mean'])} ± ${detailNumber(observation['attention']['sd'])}',
                    ),
                  ],
                )
              else
                Text(tr('有效观察不足10秒，暂不生成脑波统计结论。')),
            ],
          ),
        ),
        ReportInsights(
          lines: trainingInsights(summary, events),
          notes: trainingNotes(),
        ),
      ],
    );
  }
}
