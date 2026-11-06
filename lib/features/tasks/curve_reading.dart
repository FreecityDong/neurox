/// A recorded point near a pointer position, never an interpolated score.
class CurveReading {
  const CurveReading({required this.time, this.attention, this.relax});
  final double time;
  final double? attention, relax;
}

CurveReading readCurve(List<Map<String, dynamic>> samples, double requested) {
  Map<String, dynamic>? nearest;
  double distance = double.infinity, selectedTime = requested;
  for (final sample in samples) {
    final at =
        sample['curveSeconds'] ?? sample['wallSeconds'] ?? sample['elapsed'];
    if (at is! num || !at.isFinite || at < 0) continue;
    final delta = (at - requested).abs();
    if (delta < distance) {
      distance = delta;
      nearest = sample;
      selectedTime = at.toDouble();
    }
  }
  // Completed-second samples may be snapped within 0.75s, never across a gap.
  if (distance > .75) return CurveReading(time: requested);
  final scores = nearest?['scores'];
  double? value(String key) {
    final v = scores is Map ? scores[key] : null;
    return v is num && v.isFinite && v >= 0 && v <= 100 ? v.toDouble() : null;
  }

  return CurveReading(
    time: selectedTime,
    attention: value('attention'),
    relax: value('relax'),
  );
}
