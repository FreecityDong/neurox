import 'dart:convert';

enum HistoryTaskType {
  baseline,
  learning,
  training,
  competition,
  recovery,
  other,
}

enum HistoryTaskStatus {
  completed,
  incomplete,
  running,
  paused,
  interrupted,
  saveFailed,
  saved,
  unknown,
}

enum HistoryPeriod { all, today, week, month }

Map<String, dynamic> _historyMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is! String) return {};
  try {
    final decoded = jsonDecode(value);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  } catch (_) {
    return {};
  }
}

double? _nonnegative(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

class HistoryEntry {
  HistoryEntry(this.data)
    : metadata = _historyMap(data['task_json']),
      monitor = _historyMap(data['monitor_json']),
      baseline = _historyMap(data['baseline_json']);
  final Map<String, dynamic> data, metadata, monitor, baseline;
  String get id => data['id'] as String? ?? '';
  String get name => data['name'] as String? ?? '';
  String? get scene {
    final protocol = metadata['protocol'];
    final rules = monitor['rules'];
    final savedProtocol = rules is Map ? rules['protocol'] : null;
    final value =
        metadata['scene'] ??
        (protocol is Map ? protocol['scene'] : null) ??
        monitor['scene'] ??
        (savedProtocol is Map ? savedProtocol['scene'] : null);
    return value is String ? value : null;
  }

  HistoryTaskType get type {
    if (data['kind'] == 'baseline') return HistoryTaskType.baseline;
    if (data['kind'] != 'task') return HistoryTaskType.other;
    return switch (scene) {
      'learning' => HistoryTaskType.learning,
      'training' => HistoryTaskType.training,
      'esports' || 'go' || 'archery' => HistoryTaskType.competition,
      'recovery' => HistoryTaskType.recovery,
      _ => HistoryTaskType.other,
    };
  }

  HistoryTaskStatus get status {
    if (['save_failed', 'deleting'].contains(data['state'])) {
      return HistoryTaskStatus.saveFailed;
    }
    switch (data['task_state']) {
      case 'task_complete':
      case 'baseline_ready':
        return HistoryTaskStatus.completed;
      case 'task_ended':
      case 'baseline_incomplete':
        return HistoryTaskStatus.incomplete;
      case 'interrupted_pending':
        return HistoryTaskStatus.interrupted;
      case 'active':
        if (monitor['phase'] == 'paused') return HistoryTaskStatus.paused;
        if (monitor['phase'] == 'interrupted') {
          return HistoryTaskStatus.interrupted;
        }
        return HistoryTaskStatus.running;
    }
    return switch (data['state']) {
      'creating' || 'recording' => HistoryTaskStatus.running,
      'interrupted' => HistoryTaskStatus.interrupted,
      'saved' || 'imported' => HistoryTaskStatus.saved,
      _ => HistoryTaskStatus.unknown,
    };
  }

  DateTime? get started {
    final value = data['started'];
    if (value is! num ||
        !value.isFinite ||
        (value * 1000).abs() > 8640000000000000) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
  }

  double? get durationSeconds {
    final measured = data['kind'] == 'baseline'
        ? _nonnegative(baseline['attemptElapsed']) ??
              _nonnegative(baseline['elapsed'])
        : data['kind'] == 'task'
        ? _nonnegative(monitor['elapsed'])
        : null;
    if (measured != null) return measured;
    // Imported file modification times are not evidence of recording duration.
    if (data['state'] == 'imported' ||
        [
          HistoryTaskStatus.running,
          HistoryTaskStatus.paused,
        ].contains(status)) {
      return null;
    }
    final from = data['started'], to = data['ended'];
    if (from is num &&
        to is num &&
        from.isFinite &&
        to.isFinite &&
        to >= from) {
      return (to - from).toDouble();
    }
    return null;
  }

  bool inPeriod(HistoryPeriod period, DateTime now) {
    if (period == HistoryPeriod.all) return true;
    final start = started;
    if (start == null) return false;
    final days = switch (period) {
      HistoryPeriod.today => 1,
      HistoryPeriod.week => 7,
      HistoryPeriod.month => 30,
      _ => 1,
    };
    DateTime day(int offset) => now.isUtc
        ? DateTime.utc(now.year, now.month, now.day + offset)
        : DateTime(now.year, now.month, now.day + offset);
    return !start.isBefore(day(1 - days)) && start.isBefore(day(1));
  }

  bool matches({
    HistoryTaskStatus? state,
    HistoryTaskType? kind,
    HistoryPeriod period = HistoryPeriod.all,
    required DateTime now,
  }) =>
      (state == null || status == state) &&
      (kind == null || type == kind) &&
      inPeriod(period, now);
}

String historyDuration(Object? seconds) {
  final value = _nonnegative(seconds);
  if (value == null) return '—';
  final s = value.floor(),
      hours = s ~/ 3600,
      minutes = (s % 3600) ~/ 60,
      rest = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return hours > 0
      ? '${two(hours)}:${two(minutes)}:${two(rest)}'
      : '${two(minutes)}:${two(rest)}';
}
