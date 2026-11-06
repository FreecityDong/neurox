import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';

/// Cached SDK values and their personal baseline; displaying never queries scores.
class ReferenceMetrics extends StatelessWidget {
  const ReferenceMetrics({
    super.key,
    this.features,
    this.statistics,
    this.comparison = false,
    this.showTechnicalDetails = true,
  });
  final bool comparison;
  final bool showTechnicalDetails;
  final Map<String, double>? features;
  final Map<String, dynamic>? statistics;
  String format(Object? value, {double scale = 1}) =>
      value is num && value.isFinite ? (value * scale).toStringAsFixed(3) : '—';
  Map summary(String key) =>
      statistics?[key] is Map ? statistics![key] as Map : {};
  double? deviation(Map value) {
    final variance = value['variance'];
    return variance is num && variance.isFinite && variance >= 0
        ? math.sqrt(variance.toDouble())
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final e = summary('attention'), a = summary('relax');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          statistics == null
              ? comparison
                    ? tr('当前比较值（连续5秒中位数）')
                    : tr('当前SDK结果')
              : tr(showTechnicalDetails ? '个人SDK基线' : '个人参考结果'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (statistics == null) ...[
          Text(tr('SDK专注：{p0}', {'p0': format(features?['attention'])})),
          Text(tr('SDK放松：{p0}', {'p0': format(features?['relax'])})),
        ] else ...[
          Text(
            tr('专注基线：{p0} ± {p1}', {
              'p0': format(e['mean']),
              'p1': format(deviation(e)),
            }),
          ),
          Text(
            tr('放松基线：{p0} ± {p1}', {
              'p0': format(a['mean']),
              'p1': format(deviation(a)),
            }),
          ),
          Text(tr(showTechnicalDetails ? '基线以SDK结果的均值 ± 标准差表示。' : '均值 ± 标准差')),
        ],
        if (showTechnicalDetails) Text(tr('采用官方SDK还原算法，专注与放松分别建立个人基线。')),
      ],
    );
  }
}
