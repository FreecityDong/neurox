import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import '../tasks/signal_pipeline.dart';
import '../tasks/signal_worker.dart';
import 'eeg_controller.dart';

enum DeviceQualityState { disconnected, checking, passed, unavailable }

/// One foreground check per BLE connection, using the task quality pipeline.
/// Its worker stops after success; task preparation still performs its own check.
class DeviceQualityAssessment extends ChangeNotifier
    with WidgetsBindingObserver {
  DeviceQualityAssessment(
    this.eeg, {
    Future<SignalProfile> Function()? profileLoader,
    double Function()? clock,
  }) : _profileLoader = profileLoader ?? _nativeProfile,
       _clock = clock {
    WidgetsBinding.instance.addObserver(this);
    _watch.start();
    eeg.addListener(_syncConnection);
    _samples = eeg.rawSamples.listen(_sample);
    _syncConnection();
  }
  final EegController eeg;
  final Future<SignalProfile> Function() _profileLoader;
  final double Function()? _clock;
  final _watch = Stopwatch();
  late final StreamSubscription<RawSampleBatch> _samples;
  SignalWorker? _worker;
  StreamSubscription<AnalysisWindow>? _windows;
  Object? _connection;
  int _generation = 0;
  bool _disposed = false, _suspended = false;
  double _origin = 0;
  DeviceQualityState state = DeviceQualityState.disconnected;
  String reason = 'waiting';
  double get _now => _clock?.call() ?? _watch.elapsedMicroseconds / 1e6;

  static Future<SignalProfile> _nativeProfile() async {
    final cap = await const MethodChannel(
      'neurox/local',
    ).invokeMapMethod<String, dynamic>('baselineCapabilities');
    return SignalProfile(
      Map<String, dynamic>.from(cap?['profile'] as Map? ?? {}),
    );
  }

  void _syncConnection() {
    final key = eeg.connected ? (eeg.selected?.address, eeg.session) : null;
    if (key == _connection) return;
    _connection = key;
    _generation++;
    _closeWorker();
    state = key == null
        ? DeviceQualityState.disconnected
        : DeviceQualityState.checking;
    reason = 'waiting';
    if (!_disposed) notifyListeners();
    if (key != null && !_suspended) unawaited(_begin());
  }

  Future<void> _begin() async {
    final generation = ++_generation;
    _closeWorker();
    state = DeviceQualityState.checking;
    reason = 'warming';
    _origin = _now;
    if (!_disposed) notifyListeners();
    SignalWorker? starting;
    try {
      final profile = await _profileLoader();
      if (_disposed || generation != _generation || _suspended) return;
      if (!profile.usable || profile.hz != 512) throw StateError('metadata');
      starting = SignalWorker();
      await starting.start(profile);
      if (_disposed || generation != _generation || _suspended) {
        await starting.close();
        return;
      }
      _worker = starting;
      _windows = starting.windows.listen(
        (window) {
          if (_disposed ||
              generation != _generation ||
              state != DeviceQualityState.checking) {
            return;
          }
          reason = window.reason;
          if (window.good && eeg.receiving && !eeg.previewMode) {
            state = DeviceQualityState.passed;
            _closeWorker();
          }
          notifyListeners();
        },
        onError: (Object _) {
          if (_disposed || generation != _generation) return;
          state = DeviceQualityState.unavailable;
          reason = 'processing';
          _closeWorker();
          notifyListeners();
        },
      );
    } catch (_) {
      if (starting != null) await starting.close();
      if (_disposed || generation != _generation) return;
      state = DeviceQualityState.unavailable;
      reason = 'metadata';
      notifyListeners();
    }
  }

  void _sample(RawSampleBatch batch) {
    if (_disposed ||
        _suspended ||
        batch.simulated ||
        state != DeviceQualityState.checking ||
        _worker == null) {
      return;
    }
    unawaited(_worker!.push(batch.channel1, batch.channel2, _now - _origin));
  }

  void retry() {
    if (!_disposed && eeg.connected && !_suspended) unawaited(_begin());
  }

  void suspend() {
    _suspended = true;
    if (state == DeviceQualityState.checking) {
      _generation++;
      _closeWorker();
    }
  }

  void resume() {
    if (!_suspended) return;
    _suspended = false;
    if (eeg.connected && state == DeviceQualityState.checking) {
      unawaited(_begin());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      suspend();
    }
    if (state == AppLifecycleState.resumed) resume();
  }

  void _closeWorker() {
    final worker = _worker;
    _worker = null;
    unawaited(_windows?.cancel());
    _windows = null;
    if (worker != null) unawaited(worker.close());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    eeg.removeListener(_syncConnection);
    unawaited(_samples.cancel());
    _closeWorker();
    _watch.stop();
    super.dispose();
  }
}
