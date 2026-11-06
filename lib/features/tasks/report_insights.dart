import 'dart:math' as math;
import '../../l10n/app_language.dart';
import 'detail_widgets.dart';
import 'learning_trend.dart';
import 'scene_protocol.dart';
import 'training_observation.dart';

double? _n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
double? _sd(Map value) {
  final direct = _n(value['standardDeviation']);
  if (direct != null && direct >= 0) return direct;
  final variance = _n(value['variance']);
  return variance != null && variance >= 0 ? math.sqrt(variance) : null;
}

class _Range {
  const _Range(this.stage, this.start, this.end);
  final String stage;
  final double start, end;
}

class _Stats {
  const _Stats(this.seconds, this.mean, this.sd);
  final double seconds, mean, sd;
}

List<_Range> _phases(
  Map<String, dynamic> summary,
  List<Map<String, dynamic>> events,
) {
  final total = _n(summary['elapsed']) ?? 0;
  final marks = detailStageTimeline(
    summary,
    events,
  ).where((e) => e['type'] == 'stage' && _n(e['at']) != null).toList();
  final ranges = <_Range>[];
  for (var i = 0; i < marks.length; i++) {
    var name = marks[i]['stage'] as String? ?? '';
    if (summary['scene'] == 'recovery' && name == 'study') {
      name = 'demonstration';
    }
    final start = _n(marks[i]['at'])!,
        end = i + 1 < marks.length ? _n(marks[i + 1]['at'])! : total;
    if (start >= 0 && end > start && end <= total + .01) {
      ranges.add(_Range(name, start, end));
    }
  }
  return ranges;
}

double _length(List<_Range> ranges) =>
    ranges.fold(0.0, (sum, r) => sum + r.end - r.start);
_Stats _stats(
  List<Map<String, dynamic>> events,
  String metric,
  List<_Range> ranges,
) {
  final samples = <double, Map<String, dynamic>>{};
  for (final e in events) {
    if (e['type'] != 'sample') continue;
    final t = _n(e['curveSeconds'] ?? e['elapsed'] ?? e['wallSeconds']);
    if (t != null) samples[t] = e;
  }
  double weight = 0, sum = 0, squares = 0;
  for (final item in samples.entries) {
    final value = _n(detailMap(item.value['scores'])[metric]);
    final duration = _n(item.value['observationDuration']) ?? 1;
    if (value == null ||
        value < 0 ||
        value > 100 ||
        duration <= 0 ||
        duration > 1) {
      continue;
    }
    for (final range in ranges) {
      final w = math.max(
        0.0,
        math.min(item.key, range.end) -
            math.max(item.key - duration, range.start),
      );
      weight += w;
      sum += value * w;
      squares += value * value * w;
    }
  }
  if (weight == 0) return const _Stats(0, 0, 0);
  final mean = sum / weight;
  return _Stats(
    weight,
    mean,
    math.sqrt(math.max(0, squares / weight - mean * mean)),
  );
}

bool _enough(_Stats stats, List<_Range> ranges) =>
    stats.seconds >= 10 && stats.seconds >= _length(ranges) * .5;
String _change(double delta, double threshold, String label) => tr(
  delta > threshold
      ? '{p0}有所升高，变化约 {p1} 分。'
      : delta < -threshold
      ? '{p0}有所降低，变化约 {p1} 分。'
      : '{p0}变化较小，前后相差约 {p1} 分。',
  {'p0': label, 'p1': delta.abs().toStringAsFixed(1)},
);

List<String> baselineInsights(Map<String, dynamic> result) {
  final stats = detailMap(result['statistics']);
  final lines = <String>[
    tr(
      result['state'] == 'ready'
          ? '本次数据已形成可用的个人参考，专注与放松分别建立基线。'
          : '本次记录未形成可用的个人参考。',
    ),
  ];
  for (final item in [('attention', '专注'), ('relax', '放松')]) {
    final value = detailMap(stats[item.$1]),
        sd = _sd(value),
        drift = _n(value['drift']);
    if (sd == null) continue;
    lines.add(
      tr('{p0}指标的波动幅度约 {p1} 分（标准差）。', {
        'p0': trSource(item.$2),
        'p1': detailNumber(sd),
      }),
    );
    if (drift != null && drift >= 0) {
      lines[lines.length - 1] +=
          ' ${tr('起始与末段参考水平相差约 {p0} 分。', {'p0': detailNumber(drift)})}';
    }
  }
  if (lines.length == 1) lines.add(tr('保存的参考统计不足，暂不解释波动与前后变化。'));
  return lines;
}

List<String> baselineNotes() => [
  tr('均值代表本次参考水平，标准差描述波动，不是测量误差或能力评分。'),
  tr('前后差使用保存的起始与末段有效数据；只记录差值时不推断上升或下降。'),
  tr('有效覆盖不含开始适应时间。后续任务使用其开始时绑定的基线，旧任务不会随新基线重算。'),
];

class _Run {
  const _Run(this.start, this.end);
  final double start, end;
  double get seconds => end - start;
}

_Run _longest(LearningTrend data, List<_Range> ranges) {
  var best = const _Run(0, 0);
  final breaks = data.events
      .where(
        (e) => ['pause', 'interruption', 'prepare_data'].contains(e['type']),
      )
      .map((e) => _n(e['elapsed']))
      .whereType<double>()
      .toList();
  for (final s in data.displaySpans.where((s) => s.state == 'stable')) {
    for (final r in ranges) {
      final a = math.max(s.start, r.start), b = math.min(s.end, r.end);
      if (b <= a) continue;
      final points = [a, ...breaks.where((t) => t > a && t < b), b]..sort();
      for (var i = 1; i < points.length; i++) {
        final run = _Run(points[i - 1], points[i]);
        if (run.seconds > best.seconds) best = run;
      }
    }
  }
  return best;
}

List<String> _learningInsights(LearningTrend data) {
  final delta = data.trendDelta;
  final lines = <String>[
    delta == null
        ? tr('前后段有效数据不足，暂不解释专注趋势。')
        : _change(delta, math.max(3, (data.sd ?? 0) * .5), tr('后段专注较前段')),
  ];
  if (!data.timelineComplete) return [...lines, tr('保存的状态区间不完整，暂不解释偏离分布和连续性。')];
  final runs = <_Run>[];
  for (final s in data.displaySpans.where(
    (s) => ['candidate', 'deviation'].contains(s.state),
  )) {
    if (runs.isNotEmpty && (runs.last.end - s.start).abs() < .01) {
      final old = runs.removeLast();
      runs.add(_Run(old.start, s.end));
    } else {
      runs.add(_Run(s.start, s.end));
    }
  }
  final deviations = data.events.where((e) => e['type'] == 'deviation').length;
  if (runs.isNotEmpty) {
    final longest = runs.reduce((a, b) => a.seconds >= b.seconds ? a : b);
    lines.add(
      tr('本次确认偏离 {p0} 次，最长一段位于 {p1}–{p2}。', {
        'p0': deviations,
        'p1': detailTime(longest.start),
        'p2': detailTime(longest.end),
      }),
    );
  } else {
    lines.add(
      tr(
        (_n(data.summary['validSeconds']) ?? 0) > 0
            ? '已保存的可判断区间内，未确认持续偏离。'
            : '本次缺少可判断区间，不能据此评价专注状态。',
      ),
    );
  }
  final run = _longest(data, [_Range('all', 0, data.total)]);
  if (run.seconds > 0) {
    lines.add(
      tr('最长连续正常区间为 {p0}–{p1}，持续 {p2}。', {
        'p0': detailTime(run.start),
        'p1': detailTime(run.end),
        'p2': detailTime(run.seconds),
      }),
    );
  }
  double? pending;
  double recoveryTotal = 0;
  var recovered = 0;
  for (final e in data.events) {
    final t = _n(e['elapsed']);
    if (t == null) continue;
    if (e['type'] == 'deviation') pending = t;
    if (e['type'] == 'recovery' && pending != null && t >= pending) {
      recoveryTotal += t - pending;
      recovered++;
      pending = null;
    }
  }
  if (recovered > 0) {
    lines.add(
      tr('有 {p0} 段记录到确认恢复，平均监测用时 {p1}；另有 {p2} 段未记录到确认恢复。', {
        'p0': recovered,
        'p1': detailTime(recoveryTotal / recovered),
        'p2': math.max(0, deviations - recovered),
      }),
    );
  } else if (deviations > 0) {
    lines.add(tr('本次偏离后未记录到确认恢复，未把任务结束或数据缺失当作恢复。'));
  }
  return lines.take(4).toList();
}

List<String> _competitionInsights(LearningTrend data) {
  final ranges = _phases(data.summary, data.events),
      scene = data.summary['scene'];
  final main = scene == 'esports'
      ? 'match'
      : scene == 'go'
      ? 'thinking'
      : 'shooting';
  final selected = ranges.where((r) => r.stage == main).toList();
  final lines = <String>[];
  if (scene == 'archery') {
    lines.add(tr('射箭动作阶段只观察曲线，不进行专注偏离判断。'));
  } else if (selected.isEmpty) {
    lines.add(tr('未记录到比赛或思考阶段，暂不生成赛中结论。'));
  } else {
    double compared = 0;
    for (final r in selected) {
      for (final s in data.spans.where((s) => s.state != 'unknown')) {
        compared += math.max(
          0,
          math.min(r.end, s.end) - math.max(r.start, s.start),
        );
      }
    }
    if (!data.timelineComplete || compared <= 0) {
      lines.add(tr('赛中未形成可用的基线对比结果，本次只描述指标观察。'));
    } else {
      final run = _longest(data, selected);
      final count = data.events
          .where(
            (e) =>
                e['type'] == 'deviation' &&
                _n(e['elapsed']) != null &&
                selected.any(
                  (r) =>
                      _n(e['elapsed'])! >= r.start &&
                      _n(e['elapsed'])! <= r.end,
                ),
          )
          .length;
      lines.add(
        tr('赛中确认偏离 {p0} 次，最长连续正常时间 {p1}。', {
          'p0': count,
          'p1': detailTime(run.seconds),
        }),
      );
    }
  }
  final groups = scene == 'archery'
      ? ['preparation', 'interval', 'post_training']
      : [main, 'interval', 'post_match'];
  final prepare = ranges.where((r) => r.stage == 'preparation').toList();
  final reference = _stats(data.events, 'attention', prepare);
  for (final key in groups) {
    final parts = ranges.where((r) => r.stage == key).toList();
    if (parts.isEmpty) continue;
    final stat = _stats(data.events, 'attention', parts);
    if (!_enough(stat, parts)) {
      lines.add(tr('{p0}有效数据不足，暂不解释该阶段变化。', {'p0': stageLabel(key)}));
      continue;
    }
    var text = tr('{p0}的专注指标均值为 {p1}，波动约 {p2} 分。', {
      'p0': stageLabel(key),
      'p1': detailNumber(stat.mean),
      'p2': detailNumber(stat.sd),
    });
    if (key == main && _enough(reference, prepare)) {
      text +=
          ' ${tr('与静态准备相比，均值变化 {p0} 分。', {'p0': detailNumber(stat.mean - reference.mean)})}';
    }
    lines.add(text);
  }
  if (lines.length == 1) lines.add(tr('其他阶段尚无足够数据，不把缺失数据解释为状态变化。'));
  return lines.take(4).toList();
}

List<String> focusInsights(LearningTrend data) =>
    data.summary['scene'] == 'learning'
    ? _learningInsights(data)
    : _competitionInsights(data);
List<String> focusNotes(LearningTrend data) {
  final rules = detailMap(data.summary['rules']);
  return [
    tr('沿用本任务保存的基线与状态判断，不使用后来建立的基线重算。'),
    tr('占比以监测时长为分母，包含未知；不含准备、暂停、重检等待和中断。未知不等于不专注。'),
    tr('黄色是最终确认偏离前的观察区间，红色包含恢复确认过程；未形成偏离的观察仍为绿色。'),
    if (data.mean != null &&
        data.sd != null &&
        _n(rules['sustainedSeconds']) != null)
      tr(
        '本次下降线 {p0}、恢复线 {p1}；下降后未回到恢复线，持续 {p2} 个有效秒确认偏离，达到恢复线持续 {p3} 个有效秒确认恢复。',
        {
          'p0': detailNumber(data.mean! - math.max(data.sd!, 5)),
          'p1': detailNumber(data.mean! - math.max(data.sd! * .5, 3)),
          'p2': detailNumber(rules['sustainedSeconds'], decimals: 0),
          'p3': detailNumber(rules['recoverySeconds'], decimals: 0),
        },
      ),
    tr('关闭基线对比或动作仅记录的区间，只描述指标，不判断正常或偏离。阶段差异不等于学习、竞技或运动表现。'),
  ];
}

List<String> trainingInsights(
  Map<String, dynamic> summary,
  List<Map<String, dynamic>> events,
) {
  final game = detailMap(summary['game']);
  final tracking = game['kind'] == 'tracking';
  final lines = <String>[];
  final correct = _n(game['correct']),
      goal = _n(game['goal']),
      mistakes = _n(game['mistakes']);
  if (correct != null && goal != null && goal > 0 && mistakes != null) {
    lines.add(
      tr(
        tracking
            ? '本轮识别出 {p0}/{p1} 个目标，误选 {p2} 次。'
            : '本轮完成 {p0}/{p1} 个目标，错误选择 {p2} 次。',
        {
          'p0': detailNumber(correct, decimals: 0),
          'p1': detailNumber(goal, decimals: 0),
          'p2': detailNumber(mistakes, decimals: 0),
        },
      ),
    );
  }
  if (tracking && _n(game['responseSeconds']) != null) {
    lines.add(
      tr('目标停止移动后，选择用时 {p0} 秒。', {'p0': detailNumber(game['responseSeconds'])}),
    );
  } else if (!tracking &&
      correct != null &&
      correct > 0 &&
      _n(game['elapsed']) != null) {
    lines.add(
      tr('按本轮用时计算，平均每个正确目标用时 {p0} 秒，包含搜索及错误选择时间。', {
        'p0': detailNumber((_n(game['elapsed'])!) / correct),
      }),
    );
  }
  final total = _n(game['elapsed']) ?? _n(summary['elapsed']) ?? 0,
      third = total / 3;
  final curve = trainingCurveEvents(events);
  final early = [_Range('early', 0, third)],
      late = [_Range('late', total - third, total)];
  final a = _stats(curve, 'attention', early),
      b = _stats(curve, 'attention', late);
  lines.add(
    _enough(a, early) && _enough(b, late)
        ? _change(b.mean - a.mean, 3, tr('游戏后段专注较前段'))
        : tr('游戏前后段有效脑波不足，暂不解释专注趋势。'),
  );
  if (game['outcome'] != 'completed') {
    lines.add(tr('本轮未完成全部目标，结果按本轮进度解读，不与完整训练直接比较。'));
  }
  return lines.take(4).toList();
}

List<String> trainingNotes() => [
  tr('游戏时间与有效脑波观察时间分别统计；只使用游戏开始后实际收到的有效指标，不填补缺失区间。'),
  tr('前后趋势比较游戏前1/3与后1/3，各段至少10秒有效观察且覆盖过半。'),
  tr('游戏表现与脑波分别观察，只适合相同玩法和难度下理解，不由单次结果推断能力提升。'),
];

List<String> recoveryInsights(
  Map<String, dynamic> summary,
  List<Map<String, dynamic>> events,
) {
  final flow = detailMap(summary['recoveryTeaching']),
      ranges = _phases(summary, events);
  final before = ranges.where((r) => r.stage == 'demonstration').toList(),
      after = ranges.where((r) => r.stage == 'independent').toList(),
      guided = ranges.where((r) => r.stage == 'guided').toList();
  final a = _stats(events, 'relax', before),
      b = _stats(events, 'relax', after),
      g = _stats(events, 'relax', guided);
  final baseline =
      _sd(detailMap(detailMap(summary['reference'])['relax'])) ?? 0;
  final lines = <String>[
    _enough(a, before) && _enough(b, after)
        ? _change(
            b.mean - a.mean,
            math.max(3, baseline * .5),
            tr('自主练习的放松指标较示范阶段'),
          )
        : tr('示范或自主阶段有效数据不足，暂不解释前后放松变化。'),
  ];
  if (_enough(b, after)) {
    lines.add(tr('自主练习阶段的放松指标波动约 {p0} 分。', {'p0': detailNumber(b.sd)}));
    if (_enough(g, guided)) {
      lines.add(
        tr('自主阶段较跟随阶段的放松均值变化 {p0} 分，可结合曲线观察引导减弱后的延续情况。', {
          'p0': detailNumber(b.mean - g.mean),
        }),
      );
    }
  } else {
    lines.add(tr('自主练习尚无足够观察，不能据此判断能否保持放松趋势。'));
  }
  if (_n(flow['readinessBefore']) != null &&
      _n(flow['readinessAfter']) != null) {
    lines.add(
      tr('主观准备度由 {p0} 变为 {p1}，与放松曲线分别观察。', {
        'p0': detailNumber(flow['readinessBefore'], decimals: 0),
        'p1': detailNumber(flow['readinessAfter'], decimals: 0),
      }),
    );
  }
  return lines.take(4).toList();
}

List<String> recoveryNotes() => [
  tr('只观察放松指标，分别统计示范、跟随和自主练习；暂停及重检等待不计入练习时间。'),
  tr('阶段变化使用本任务保存的有效指标，不填补缺失区间；任一比较段不足10秒或覆盖不足一半时不解释趋势。'),
  tr('个人放松基线用于提供参照，指标变高或主观评分变化不直接等同于恢复效率提高。'),
];
