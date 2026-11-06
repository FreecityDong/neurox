import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import 'eeg_controller.dart';

String acquisitionHealthLabel(NotificationHealth health) =>
    trSource(switch (health) {
      NotificationHealth.normal => '解析正常',
      NotificationHealth.invalid => '解析异常',
      NotificationHealth.stale => '更新中断',
      NotificationHealth.waiting => '未收到',
      NotificationHealth.disconnected => '未连接',
    });

/// Display-only charts. Data availability always comes from the transport clock.
class AcquisitionDashboard extends StatelessWidget {
  const AcquisitionDashboard({super.key, required this.controller});
  final EegController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, raw = c.notificationHealth('raw');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff143c3e), Color(0xff102a3b)],
            ),
            border: Border.all(
              color: const Color(0xff81beb7).withValues(alpha: .28),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xff183d48).withValues(alpha: .14),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Text(
                    tr('实时脑电'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _StatusPill(health: raw, onDark: true),
                ],
              ),
              const SizedBox(height: 20),
              _Trace(
                channel: 1,
                color: const Color(0xff7dd9b9),
                values: raw == NotificationHealth.normal
                    ? c.rawChannel1
                    : const [],
                health: raw,
              ),
              const SizedBox(height: 16),
              _Trace(
                channel: 2,
                color: const Color(0xff7abde8),
                values: raw == NotificationHealth.normal
                    ? c.rawChannel2
                    : const [],
                health: raw,
              ),
              const SizedBox(height: 12),
              Text(
                tr('最近1024点 · 各通道自动缩放'),
                style: const TextStyle(color: Color(0xffa7c5cc), fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _SectionTitle(title: tr('设备侧指标'), caption: '0–100'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final columns = box.maxWidth >= 680
                ? 4
                : box.maxWidth >= 250 && scale < 1.8
                ? 2
                : 1;
            final width = (box.maxWidth - 12 * (columns - 1)) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (key, label, color) in [
                  ('attention', '专注', const Color(0xff51a98e)),
                  ('relax', '放松', const Color(0xff63a6cb)),
                  ('tired', '疲劳', const Color(0xff7898be)),
                  ('meditation', '冥想', const Color(0xff91ad6c)),
                ])
                  SizedBox(
                    width: width,
                    child: _MetricGauge(
                      metric: key,
                      label: trSource(label),
                      color: color,
                      value:
                          c.notificationHealth('feature') ==
                                  NotificationHealth.normal &&
                              (c.features[key] ?? 101) <= 100
                          ? c.features[key]?.toDouble()
                          : null,
                      health:
                          c.notificationHealth('feature') ==
                                  NotificationHealth.normal &&
                              (c.features[key] ?? 101) > 100
                          ? NotificationHealth.invalid
                          : c.notificationHealth('feature'),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        _Spectrum(controller: c),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _StatusItem(
                  label: tr('眨眼／咬牙数据'),
                  health: c.notificationHealth('blink_gnash'),
                ),
                if (c.hasNotification('other'))
                  _StatusItem(
                    label: tr('运动／光学数据'),
                    health: c.notificationHealth('other'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.caption});
  final String title, caption;
  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    spacing: 12,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      Text(
        caption,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    ],
  );
}

class _Trace extends StatelessWidget {
  const _Trace({
    required this.channel,
    required this.color,
    required this.values,
    required this.health,
  });
  final int channel;
  final Color color;
  final List<double> values;
  final NotificationHealth health;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            'CH$channel',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text(
            values.isEmpty ? '—' : values.last.toStringAsFixed(4),
            style: TextStyle(
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: 100,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                key: ValueKey('raw-chart-$channel'),
                painter: RawWavePainter(values, color),
              ),
            ),
            if (values.isEmpty)
              Center(
                child: Text(
                  acquisitionHealthLabel(health),
                  style: const TextStyle(
                    color: Color(0xff9cbac6),
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class RawWavePainter extends CustomPainter {
  RawWavePainter(this.values, this.color);
  final List<double> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .07)
      ..strokeWidth = .7;
    for (var i = 0; i <= 4; i++) {
      canvas.drawLine(
        Offset(0, size.height * i / 4),
        Offset(size.width, size.height * i / 4),
        grid,
      );
    }
    for (var i = 0; i <= 8; i++) {
      canvas.drawLine(
        Offset(size.width * i / 8, 0),
        Offset(size.width * i / 8, size.height),
        grid,
      );
    }
    if (values.length < 2 || values.any((v) => !v.isFinite)) return;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final extent = values.fold<double>(
      0,
      (v, n) => math.max(v, (n - mean).abs()),
    );
    final span = extent > 1e-10 ? extent : 1.0;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1),
          y = size.height * (.5 - .36 * (values[i] - mean) / span);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .15), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeJoin = StrokeJoin.round,
    );
    final last = Offset(
      size.width,
      size.height * (.5 - .36 * (values.last - mean) / span),
    );
    canvas.drawCircle(last, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant RawWavePainter old) =>
      old.values != values || old.color != color;
}

class _MetricGauge extends StatelessWidget {
  const _MetricGauge({
    required this.metric,
    required this.label,
    required this.color,
    required this.value,
    required this.health,
  });
  final String metric, label;
  final Color color;
  final double? value;
  final NotificationHealth health;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: tr('{p0}：{p1}，{p2}', {
        'p0': label,
        'p1': value?.toStringAsFixed(0) ?? '—',
        'p2': acquisitionHealthLabel(health),
      }),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: colors.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: .05),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: value == null
                          ? CustomPaint(
                              key: ValueKey('metric-gauge-$metric'),
                              painter: MetricArcPainter(
                                null,
                                color,
                                colors.outlineVariant,
                              ),
                            )
                          : TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0, end: value! / 100),
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 350),
                              builder: (_, progress, child) => CustomPaint(
                                key: ValueKey('metric-gauge-$metric'),
                                painter: MetricArcPainter(
                                  progress,
                                  color,
                                  colors.outlineVariant,
                                ),
                              ),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          value?.toStringAsFixed(0) ?? '—',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: value == null
                                    ? colors.onSurfaceVariant
                                    : colors.onSurface,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _StatusPill(health: health),
          ],
        ),
      ),
    );
  }
}

class MetricArcPainter extends CustomPainter {
  MetricArcPainter(this.progress, this.color, this.track);
  final double? progress;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2),
        radius = math.min(size.width, size.height) / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius),
        start = math.pi * .75,
        sweep = math.pi * 1.5;
    for (var i = 0; i <= 20; i++) {
      final angle = start + sweep * i / 20,
          dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * (radius - 12),
        center + dir * (radius - 16),
        Paint()
          ..color = track
          ..strokeWidth = 1,
      );
    }
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..color = track.withValues(alpha: .55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );
    if (progress == null || progress! <= 0) return;
    final amount = progress!.clamp(0, 1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: sweep,
        colors: [color.withValues(alpha: .45), color],
        transform: GradientRotation(start),
      ).createShader(rect);
    canvas.drawArc(
      rect,
      start,
      sweep * amount,
      false,
      Paint()
        ..color = color.withValues(alpha: .2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 13
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawArc(rect, start, sweep * amount, false, paint);
  }

  @override
  bool shouldRepaint(covariant MetricArcPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

class _Spectrum extends StatelessWidget {
  const _Spectrum({required this.controller});
  final EegController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, health = c.notificationHealth('frequency');
    const keys = ['delta', 'theta', 'alpha', 'beta', 'gamma'];
    final valid =
        health == NotificationHealth.normal &&
        keys.every(
          (k) =>
              (c.frequencies[k] ?? -1) >= 0 && (c.frequencies[k] ?? 256) <= 255,
        );
    final shownHealth = health == NotificationHealth.normal && !valid
        ? NotificationHealth.invalid
        : health;
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionTitle(title: tr('设备频谱'), caption: tr('0–255 · 设备值')),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: _StatusPill(health: shownHealth),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 170,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '255',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '0',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, key) in keys.indexed)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                              ),
                              child: _BandBar(
                                name: ['δ', 'θ', 'α', 'β', 'γ'][i],
                                value: valid ? c.frequencies[key] : null,
                                color: [
                                  const Color(0xffa8c68d),
                                  const Color(0xff70b7a0),
                                  const Color(0xff54acb4),
                                  const Color(0xff6fadd0),
                                  const Color(0xff8b9fbf),
                                ][i],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BandBar extends StatelessWidget {
  const _BandBar({
    required this.name,
    required this.value,
    required this.color,
  });
  final String name;
  final int? value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      FittedBox(
        child: Text(
          value?.toString() ?? '—',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                width: 24,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              if (value != null)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: value! / 255),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 350),
                  builder: (_, v, child) => Container(
                    width: 24,
                    height: box.maxHeight * v,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [color, color.withValues(alpha: .4)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: .18),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        name,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class _StatusItem extends StatelessWidget {
  const _StatusItem({required this.label, required this.health});
  final String label;
  final NotificationHealth health;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(label),
      _StatusPill(health: health),
    ],
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.health, this.onDark = false});
  final NotificationHealth health;
  final bool onDark;
  @override
  Widget build(BuildContext context) {
    final color = health == NotificationHealth.normal
        ? (onDark
              ? const Color(0xff9bdcbc)
              : Theme.of(context).colorScheme.primary)
        : health == NotificationHealth.invalid ||
              health == NotificationHealth.stale
        ? (onDark
              ? const Color(0xffffc39a)
              : Theme.of(context).colorScheme.error)
        : (onDark
              ? const Color(0xffb5c9d5)
              : Theme.of(context).colorScheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        acquisitionHealthLabel(health),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
