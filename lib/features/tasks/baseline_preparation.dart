import 'signal_pipeline.dart';

/// Preparation checks fresh raw quality; score warm-up belongs to recording.
class BaselinePreparation {
  int stableWindows = 0;
  double? _lastEnd;
  String reason = 'warming';
  bool get ready => stableWindows >= 3;

  void reset() {
    stableWindows = 0;
    _lastEnd = null;
    reason = 'warming';
  }

  void add(AnalysisWindow window, {required bool contactGood}) {
    if (!window.end.isFinite || (_lastEnd != null && window.end <= _lastEnd!)) {
      return;
    }
    final consecutive =
        _lastEnd == null || (window.end - _lastEnd! - 1).abs() < .05;
    _lastEnd = window.end;
    final complete = (window.end - window.start - 1).abs() < .05;
    reason = !contactGood
        ? 'contact'
        : window.source['rawQuality'] as String? ??
              (window.good ? 'good' : window.reason);
    if (!consecutive || !complete) stableWindows = 0;
    stableWindows = complete && reason == 'good' ? stableWindows + 1 : 0;
  }
}
