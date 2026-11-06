import 'signal_pipeline.dart';

/// Confirmation uses distinct received reports, never a timer over cached values.
class BaselineGuard {
  static const version = 'baseline-guard-v2';
  static const contactSeconds = 3.0;
  static const maximumReportGap = .5;
  static const waveformWindows = 8;
  static const dataWindows = 5;
  double? _contactStart, _lastContactAt, _lastQualityEnd;
  int contactReports = 0, waveWindows = 0, missingWindows = 0;
  bool contactPending = false, contactConfirmed = false;

  String? contact(double at, bool? attached) {
    if (!at.isFinite || attached == null) return null;
    if (attached) {
      contactPending = contactConfirmed = false;
      _contactStart = _lastContactAt = null;
      contactReports = 0;
      return null;
    }
    if (_lastContactAt == null ||
        at < _lastContactAt! ||
        at - _lastContactAt! > maximumReportGap) {
      _contactStart = at;
      contactReports = 0;
    }
    _lastContactAt = at;
    contactPending = true;
    contactReports++;
    contactConfirmed =
        contactReports >= 10 && at - _contactStart! >= contactSeconds;
    return contactConfirmed ? 'contact' : null;
  }

  String? quality(AnalysisWindow window) {
    if (!window.end.isFinite ||
        !window.start.isFinite ||
        _lastQualityEnd != null && window.end <= _lastQualityEnd!) {
      return null;
    }
    final consecutive =
        _lastQualityEnd == null ||
        (window.end - _lastQualityEnd! - 1).abs() < .05;
    _lastQualityEnd = window.end;
    if (!consecutive || (window.end - window.start - 1).abs() > .05) {
      waveWindows = missingWindows = 0;
    }
    if ((window.end - window.start - 1).abs() > .05) return null;
    final reason = window.source['rawQuality'] as String? ?? window.reason;
    final wave = [
      'flat',
      'saturation',
      'raw_range',
      'amplitude',
      'step',
    ].contains(reason);
    final missing = ['coverage', 'gap'].contains(reason);
    waveWindows = wave ? waveWindows + 1 : 0;
    missingWindows = missing ? missingWindows + 1 : 0;
    if (waveWindows >= waveformWindows) return 'waveform';
    if (missingWindows >= dataWindows) return 'data_loss';
    return null;
  }

  void resetQuality() {
    _lastQualityEnd = null;
    waveWindows = missingWindows = 0;
  }

  void reset() {
    _contactStart = _lastContactAt = null;
    contactPending = contactConfirmed = false;
    contactReports = 0;
    resetQuality();
  }
}
