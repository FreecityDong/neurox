import 'baseline_preparation.dart';
import 'baseline_guard.dart';
import 'monitoring_engine.dart';
import 'training_game.dart';
import 'training_observation.dart';
import '../../l10n/app_language.dart';
import 'scene_protocol.dart';
import 'recovery_flow.dart';
import '../shell/feedback_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../account/local_account.dart';
import '../device/eeg_controller.dart';
import 'signal_pipeline.dart';
import 'signal_worker.dart';

abstract interface class BaselineBackend {
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]);
}

class NativeBaselineBackend implements BaselineBackend {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async => Map<String, dynamic>.from(
    await MethodChannel(
          (method.startsWith('baseline') ||
                      method.startsWith('monitor') ||
                      method.startsWith('learning')) &&
                  ![
                    'baselinePreflight',
                    'baselineCapabilities',
                    'baselineReference',
                    'baselineList',
                    'baselineSelect',
                  ].contains(method)
              ? 'neurox/eeg/methods'
              : 'neurox/local',
        ).invokeMapMethod<String, dynamic>(method, args) ??
        {},
  );
}

class TaskController extends ChangeNotifier with WidgetsBindingObserver {
  TaskController(this.eeg, {BaselineBackend? backend, double Function()? clock})
    : _externalClock = clock,
      backend = backend ?? NativeBaselineBackend() {
    WidgetsBinding.instance.addObserver(this);
    eeg.addListener(_deviceChanged);
    _raw = eeg.rawSamples.listen(_samples);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }
  final EegController eeg;
  final BaselineBackend backend;
  StreamSubscription<RawSampleBatch>? _raw;
  StreamSubscription<AnalysisWindow>? _analysis;
  SignalWorker? _worker;
  Timer? _timer;
  final _clock = Stopwatch()..start();
  final double Function()? _externalClock;
  double get now => _externalClock?.call() ?? _clock.elapsedMicroseconds / 1e6;
  MonitoringEngine? monitor;
  bool usingSavedReference = false, learningPreparing = false;
  bool _learningRequiresRecheck = false, _learningStarted = false;
  final _learningSignalGuard = BaselineGuard();
  bool get guidedScene => scene != TaskScene.training;
  bool get learningResuming => _learningStarted;
  bool learningPreparationDiscarded = false;
  bool get unstartedLearning =>
      active && usingSavedReference && !_learningStarted;
  bool get initialLearningCheck => unstartedLearning && learningPreparing;
  double get learningPreparationSeconds => active && learningPreparing
      ? (now - _attemptStarted).clamp(0, 1000000).toDouble()
      : 0;
  TaskScene scene = TaskScene.learning;
  TrainingKind trainingKind = TrainingKind.obstacles;
  int trackingLevel = 1;
  TrainingGame? trainingGame;
  bool _trainingFinishing = false;
  void driveTraining() {
    final game = trainingGame, m = monitor;
    if (scene != TaskScene.training ||
        game == null ||
        m == null ||
        m.phase != 'running' ||
        busy ||
        _trainingFinishing) {
      return;
    }
    m.advance(now);
    game.advanceTo(m.elapsed);
    m.gameInfo = game.snapshot();
    if (game.finished) {
      _trainingFinishing = true;
      m.recordEvent('game_result', now, game.snapshot());
      m.finish(
        now,
        game.outcome == 'completed' ? 'game_completed' : 'protocol_finished',
      );
      _persistMonitor();
      unawaited(finish());
    }
  }

  void tapTraining(int value) {
    driveTraining();
    if (busy || monitor?.phase != 'running' || trainingGame == null) return;
    final answer = trainingGame!.tap(value);
    if (answer != null) {
      monitor!.recordEvent('game_response', now, {
        'value': value,
        'correct': answer,
        'gameElapsed': trainingGame!.elapsed,
      });
      monitor!.gameInfo = trainingGame!.snapshot();
      _persistMonitor();
    }
    driveTraining();
    _notify();
  }

  String sceneStage = 'study';
  bool conditionMatches = true;
  FeedbackOptions feedback = const FeedbackOptions();
  String recoveryMethod = 'breathing';
  RecoveryFlow? recoveryFlow;
  bool recoveryChoosing = false;
  void chooseRecovery() {
    if (busy || monitor == null || monitor!.finished) return;
    recoveryChoosing = true;
    monitor!.beginRecovery(now, {'stage': 'choosing_method'});
    _persistMonitor();
    _notify();
  }

  final List<Map<String, dynamic>> baselineChartEvents = [];
  List<Map<String, dynamic>> referenceLibrary = [];
  bool get stageIsKey => [
    'match',
    'thinking',
    'aiming',
    'release',
    'shooting',
  ].contains(sceneStage);
  bool get stageSupportsComparison =>
      scene != TaskScene.training &&
      conditionMatches &&
      !['aiming', 'release', 'shooting'].contains(sceneStage) &&
      (scene != TaskScene.recovery || sceneStage == 'recheck');
  void setScene(TaskScene value) {
    if (active || busy) return;
    scene = value;
    sceneStage = value.stages.first;
    conditionMatches = value == TaskScene.learning;
    targetMinutes = value == TaskScene.recovery ? 3 : 0;
    _notify();
  }

  Future<void> selectReference(String id) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      savedReference = await backend.call('baselineSelect', {
        'id': id,
        'context': context,
      });
    } catch (e) {
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  int _feedbackRevision = 0;
  Future<void> loadFeedbackPreferences() async {
    final revision = _feedbackRevision;
    try {
      final value = await backend.call('feedbackSettings');
      if (_disposed || revision != _feedbackRevision) return;
      applyFeedbackDefaults(FeedbackOptions.fromMap(value));
    } catch (_) {
      /* Task preflight retains its own preference load/error path. */
    }
  }

  void applyFeedbackDefaults(FeedbackOptions value) {
    if (_disposed) return;
    _feedbackDefaultsLoaded = true;
    setFeedback(active ? feedback.change('muted', value.muted) : value);
  }

  void setFeedback(FeedbackOptions value) {
    final muteChanged = feedback.muted != value.muted;
    _feedbackRevision++;
    // A choice on this task is authoritative over defaults loaded at start.
    _feedbackDefaultsLoaded = true;
    feedback = value;
    if (muteChanged) {
      unawaited(
        backend.call('setFeedbackMute', {'muted': value.muted}).catchError((
          Object e,
        ) {
          if (!_disposed) {
            error = tr('提醒设置保存失败，请重试。');
            _notify();
          }
          return <String, dynamic>{};
        }),
      );
    }
    if (backend is NativeBaselineBackend) {
      unawaited(
        const MethodChannel(
          'neurox/notifications',
        ).invokeMethod('configure', value.toMap()).catchError((Object e) {
          monitor?.recordEvent('feedback_unavailable', now, {
            'channel': 'configuration',
          });
        }),
      );
    }
    remindersEnabled = scene != TaskScene.training && value.enabled;
    monitor?.setReminders(remindersEnabled, now);
    monitor?.stageSilenced = scene == TaskScene.training || value.muted;
    monitor?.recordEvent('feedback_settings', now, {'settings': value.toMap()});
    _persistMonitor();
    _notify();
  }

  void setCondition(bool value) {
    conditionMatches = value;
    if (monitor != null) changeStage(sceneStage);
    _notify();
  }

  bool get competitionPostStage =>
      active && scene.competitive && sceneStage == scene.postStage;
  void endCompetitionStage() {
    final current = monitor;
    if (!active ||
        busy ||
        !scene.competitive ||
        learningPreparing ||
        current == null ||
        current.finished ||
        competitionPostStage) {
      return;
    }
    sceneStage = scene.postStage;
    current.changeStage(
      sceneStage,
      now,
      allowed: stageSupportsComparison,
      silenced: feedback.muted,
    );
    _persistMonitor();
    _notify();
  }

  void changeStage(String value) {
    if (monitor?.finished == true ||
        !scene.stages.contains(value) ||
        (competitionPostStage && value != sceneStage)) {
      return;
    }
    if (value == scene.postStage && value != sceneStage) return;
    sceneStage = value;
    monitor?.changeStage(
      value,
      now,
      allowed: stageSupportsComparison,
      silenced: scene == TaskScene.training || feedback.muted,
    );
    _persistMonitor();
    _notify();
  }

  void startRecovery(String method) {
    if (monitor == null || monitor!.finished || busy || recoveryFlow != null) {
      return;
    }
    _beginRecovery(method);
    _notify();
  }

  void _beginRecovery(String method) {
    recoveryChoosing = false;
    recoveryFlow = RecoveryFlow(
      method: method,
      linked: scene != TaskScene.recovery,
      startedAt: now,
    )..stepStartedAt = now;
    monitor!.beginRecovery(now, recoveryFlow!.toMap());
    _persistMonitor();
  }

  void advanceRecovery() {
    final flow = recoveryFlow;
    if (flow == null ||
        busy ||
        monitor == null ||
        !['running', 'recovery'].contains(monitor!.phase)) {
      return;
    }
    if (!flow.next(now)) return;
    if (scene == TaskScene.recovery) sceneStage = flow.stage;
    monitor!.recoveryInfo = flow.toMap();
    monitor!.recordEvent('recovery_step', now, flow.toMap());
    if (flow.stage == 'recheck') {
      if (scene == TaskScene.recovery) sceneStage = 'recheck';
      monitor!.endRecovery(now, flow.toMap());
      monitor!.comparisonAllowed = stageSupportsComparison;
      monitor!.stage = sceneStage;
    }
    if (scene == TaskScene.recovery) {
      monitor!.changeStage(
        sceneStage,
        now,
        allowed: stageSupportsComparison,
        silenced: feedback.muted,
      );
    }
    _persistMonitor();
    _notify();
  }

  void rateRecovery(int value, {required bool after}) {
    final flow = recoveryFlow;
    if (flow == null) return;
    if (after) {
      flow.readinessAfter = value;
    } else {
      flow.readinessBefore = value;
    }
    monitor?.recoveryInfo = flow.toMap();
    monitor?.recordEvent('recovery_rating', now, flow.toMap());
    _persistMonitor();
    _notify();
  }

  void leaveRecovery() {
    if (monitor == null || busy) return;
    if (recoveryFlow == null && recoveryChoosing) {
      recoveryChoosing = false;
      monitor!.endRecovery(now, {'completion': 'cancelled'}, beginCheck: false);
      _persistMonitor();
      _notify();
      return;
    }
    if (recoveryFlow == null) return;
    monitor!.recordEvent('recovery_complete', now, {
      ...recoveryFlow!.toMap(),
      'completion': recoveryFlow!.stage == 'recheck'
          ? 'recheck_started'
          : 'ended_early',
    });
    if (monitor!.phase == 'recovery') {
      monitor!.endRecovery(now, recoveryFlow!.toMap());
    }
    recoveryFlow = null;
    _persistMonitor();
    _notify();
  }

  Map<String, dynamic> savedReference = {};
  bool _feedbackDefaultsLoaded = false;
  double? _invalidSince;
  bool _dataNoticeSent = false, _hadValidAnalysis = false;
  void _technicalFeedback() {
    final m = monitor;
    if (scene == TaskScene.training ||
        m == null ||
        m.phase != 'running' ||
        !m.comparisonAllowed ||
        !_hadValidAnalysis) {
      return;
    }
    if (m.state != 'unknown') {
      _invalidSince = null;
      _dataNoticeSent = false;
      return;
    }
    _invalidSince ??= now;
    if (_dataNoticeSent || now - _invalidSince! < 5) return;
    _dataNoticeSent = true;
    m.recordEvent('data_unavailable', now, {'reason': m.reason});
    if (feedback.enabled &&
        !(feedback.muted) &&
        backend is NativeBaselineBackend) {
      final options = feedback;
      unawaited(
        const MethodChannel('neurox/notifications')
            .invokeMapMethod<String, dynamic>('feedback', {
              ...options.toMap(),
              'kind': 'task.data',
              'scope': sessionId,
              'title': tr('采集数据不足'),
              'body': tr('数据暂不可用，请检查设备与佩戴；已保存记录保留。'),
            })
            .then((value) {
              if (monitor == m) {
                m.recordEvent('feedback_delivery', now, {
                  'event': 'data_unavailable',
                  'channels': options.toMap(),
                  'result': value,
                });
              }
            })
            .catchError((Object e) {
              if (monitor == m) {
                m.recordEvent('feedback_delivery', now, {
                  'event': 'data_unavailable',
                  'delivery': 'unavailable',
                });
              }
            }),
      );
    }
  }

  bool get hasSavedReference => savedReference['available'] == true;
  bool get compatibleSavedReference {
    final saved = (savedReference['snapshot'] as Map?)?['context'] as Map?;
    if (saved == null) return false;
    return [
      'algorithm',
      'device',
      'profile',
      'unit',
      'mode',
      'sampleRate',
      'sampleRateAssumed',
    ].every((key) => saved[key] == context[key]);
  }

  bool get canStartLearning =>
      !baselineChecking &&
      !busy &&
      !active &&
      storageReady &&
      unresolved.isEmpty &&
      profile.usable &&
      profile.hz == 512 &&
      eeg.receiving &&
      !eeg.recording &&
      !eeg.previewMode &&
      !_background &&
      hasSavedReference &&
      compatibleSavedReference;
  bool remindersEnabled = false, _autoFinishAttempted = false;
  int _monitorAck = 0;
  int? latestReminderSequence;
  String? _learningRecoveryPromptSession;
  bool claimLearningRecoveryPrompt(String id) {
    if (active ||
        busy ||
        completedSession != id ||
        _learningRecoveryPromptSession != id) {
      return false;
    }
    _learningRecoveryPromptSession = null;
    return true;
  }

  String? completedTaskScene;
  String? completedSession;
  Map<String, dynamic>? completedBaseline;
  bool baselineDiscarded = false;
  bool get baselineCancellable =>
      active &&
      !usingSavedReference &&
      monitor == null &&
      baseline != null &&
      baseline!.state != 'ready';
  bool get needsRebaseline =>
      monitor != null &&
      (baseline?.state != 'ready' ||
          (monitor!.needsBaseline(now) &&
              monitor!.attemptId == baseline?.attemptId));
  bool get canMonitor =>
      active &&
      monitor?.finished != true &&
      baselineSaved &&
      !busy &&
      !_background &&
      eeg.receiving &&
      eeg.recording &&
      !eeg.previewMode &&
      eeg.lead != false &&
      quality?.good == true &&
      usingSavedReference &&
      (!guidedScene || !_learningRequiresRecheck) &&
      !needsRebaseline;

  double _attemptStarted = 0;
  String name = '';
  int targetMinutes = 0;
  SignalProfile profile = SignalProfile({});
  bool storageReady = false,
      busy = false,
      _disposed = false,
      _background = false;
  String? error, sessionId, path;
  List<Map<String, dynamic>> unresolved = [];
  BaselineAccumulator? baseline;
  AnalysisWindow? quality;
  Future<void> _writes = Future.value();
  int pendingWrites = 0;
  bool get baselineSaved =>
      baseline?.state == 'ready' && pendingWrites == 0 && error == null;
  bool get active => sessionId != null;
  String get qualityReason => !eeg.connected
      ? 'disconnected'
      : !eeg.receiving
      ? 'data'
      : (!profile.usable || profile.hz != 512)
      ? 'metadata'
      : profile.provisional && quality?.good == true
      ? 'raw_good'
      : quality?.reason ?? 'waiting';
  bool get canStart =>
      !busy &&
      !active &&
      storageReady &&
      unresolved.isEmpty &&
      profile.usable &&
      profile.hz == 512 &&
      eeg.receiving &&
      !eeg.recording &&
      !eeg.previewMode &&
      !_baselineGuard.contactPending &&
      eeg.lead != false &&
      (quality?.good == true ||
          baselineChecking && _baselinePreparation.ready) &&
      !_background;
  Map<String, dynamic> get context => {
    'algorithm': baselineAlgorithmVersion,
    'device': eeg.selected?.address,
    'connection': eeg.session,
    'profile': profile.version,
    'source': 'KSEEG102 / foreground',
    'unit': profile.unit,
    'mode': profile.values['mode'] ?? 'verified',
    'sampleRate': profile.hz,
    'sampleRateAssumed': profile.values['sampleRateAssumed'] == true,
  };
  Future<void> refresh({bool prepareSignal = true}) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      final cap = await backend.call('baselineCapabilities');
      final next = SignalProfile(
        Map<String, dynamic>.from(cap['profile'] as Map? ?? {}),
      );
      if (jsonEncode(profile.values) != jsonEncode(next.values)) {
        invalidate('configuration');
        await _analysis?.cancel();
        await _worker?.close();
        _worker = null;
        quality = null;
      }
      if (prepareSignal && _worker == null && next.usable) {
        final worker = SignalWorker();
        await worker.start(next);
        if (_disposed) {
          await worker.close();
          return;
        }
        _worker = worker;
        _analysis = worker.windows.listen(
          _window,
          onError: (Object e) {
            invalidate('processing');
            error = LocalAccount.describe(e);
            _notify();
          },
        );
      }
      profile = next;
      savedReference = await backend.call('baselineReference', {
        'context': context,
      });
      final library = await backend.call('baselineList');
      referenceLibrary = (library['items'] as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      if (!_feedbackDefaultsLoaded) {
        final revision = _feedbackRevision;
        final preferences = await backend.call('feedbackSettings');
        if (revision == _feedbackRevision) {
          feedback = FeedbackOptions.fromMap(preferences);
          remindersEnabled = feedback.enabled;
          _feedbackDefaultsLoaded = true;
          if (backend is NativeBaselineBackend) {
            try {
              await const MethodChannel(
                'neurox/notifications',
              ).invokeMethod('configure', feedback.toMap());
            } on MissingPluginException {
              /* unavailable platform */
            }
          }
        }
      }
      final check = await backend.call('baselinePreflight');
      storageReady = check['storageReady'] == true;
      unresolved = (check['unresolved'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      storageReady = false;
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  final _baselinePreparation = BaselinePreparation();
  bool baselineChecking = false;
  double baselineCheckProgress = 0;
  String baselineCheckReason = 'idle';
  int _baselineCheckGeneration = 0;
  Timer? _baselineCheckTimer;
  Completer<void>? _baselineCheckWake;

  void _wakeBaselineCheck() {
    _baselineCheckTimer?.cancel();
    final waiting = _baselineCheckWake;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<void> _waitBaselineCheck() async {
    final waiting = Completer<void>();
    _baselineCheckWake = waiting;
    final timer = Timer(const Duration(milliseconds: 200), () {
      if (!waiting.isCompleted) waiting.complete();
    });
    _baselineCheckTimer = timer;
    await waiting.future;
    timer.cancel();
    if (identical(_baselineCheckWake, waiting)) {
      _baselineCheckWake = null;
      _baselineCheckTimer = null;
    }
  }

  void resetBaselineCheck() {
    if (active || baselineChecking) return;
    baselineCheckProgress = 0;
    baselineCheckReason = 'idle';
  }

  void cancelBaselineCheck() {
    if (!baselineChecking) return;
    _baselineCheckGeneration++;
    _wakeBaselineCheck();
    baselineChecking = false;
    baselineCheckProgress = 0;
    baselineCheckReason = 'idle';
    _notify();
  }

  String? get _baselineBlockingReason => _background
      ? 'background'
      : !eeg.connected
      ? 'disconnected'
      : eeg.previewMode
      ? 'preview'
      : _baselineGuard.contactConfirmed
      ? 'contact'
      : !storageReady
      ? 'storage'
      : unresolved.isNotEmpty
      ? 'pending'
      : !profile.usable || profile.hz != 512
      ? 'configuration'
      : eeg.recording || active
      ? 'occupied'
      : null;

  Future<bool> checkAndStartBaseline({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (busy || active || baselineChecking) return false;
    final generation = ++_baselineCheckGeneration;
    baselineChecking = true;
    _baselineGuard.reset();
    _baselinePreparation.reset();
    baselineCheckProgress = 0;
    baselineCheckReason = 'checking';
    error = null;
    _notify();
    var expired = false;
    final deadline = Timer(timeout, () => expired = true);
    bool valid() => !_disposed && generation == _baselineCheckGeneration;
    try {
      await refresh();
      if (!valid()) return false;
      final blocked = _baselineBlockingReason;
      if (blocked != null || error != null) {
        baselineCheckReason = blocked ?? 'storage';
        return false;
      }
      // Require new analysis after the user's start action, not an old screen's result.
      quality = null;
      _worker?.reset();
      final connection = (eeg.selected?.address, eeg.session);
      final receiptStarted = now, receiptCount = eeg.sampleCount;
      baselineReceiptReferenceRate = null;
      while (valid()) {
        final failure = _baselineBlockingReason;
        if (failure != null ||
            connection != (eeg.selected?.address, eeg.session)) {
          baselineCheckReason = failure ?? 'disconnected';
          return false;
        }
        baselineCheckProgress = !eeg.receiving
            ? .35
            : .45 + .15 * _baselinePreparation.stableWindows.clamp(0, 3);
        baselineCheckReason = !eeg.receiving
            ? 'waiting_data'
            : _baselineGuard.contactPending || eeg.lead == false
            ? 'contact_wait'
            : ['warming', 'waiting'].contains(_baselinePreparation.reason)
            ? 'signal_warming'
            : _baselinePreparation.reason != 'good'
            ? 'signal_unstable'
            : 'stabilizing';
        if (expired) {
          baselineCheckReason = !eeg.receiving
              ? 'data'
              : _baselineGuard.contactPending || eeg.lead == false
              ? 'contact'
              : 'quality_timeout';
          _baselineDiagnostic('quality_pending', _baselinePreparation.reason);
          return false;
        }
        if (canStart) {
          final seconds = now - receiptStarted;
          final samples = eeg.sampleCount - receiptCount;
          baselineReceiptReferenceRate = seconds >= 2 && samples > 0
              ? samples / seconds
              : null;
          baselineCheckProgress = 1;
          baselineCheckReason = 'passed';
          await start();
          if (active) return true;
          if (valid()) baselineCheckReason = 'storage';
          return false;
        }
        _notify();
        await _waitBaselineCheck();
      }
      return false;
    } finally {
      deadline.cancel();
      if (valid()) {
        baselineChecking = false;
        _notify();
      }
    }
  }

  final BaselineGuard _baselineGuard = BaselineGuard();
  Completer<void>? _baselineContactWaiter;
  int? _lastBaselineLeadByte;
  double? _latestBaselineRate;
  final Map<String, double> _baselineDiagnosticTimes = {};

  void _baselineDiagnostic(String type, String reason) {
    if (backend is! NativeBaselineBackend) return;
    final key = '$type:$reason';
    if (![
          'interrupted',
          'discarded',
          'cleanup_failed',
          'ready',
        ].contains(type) &&
        now - (_baselineDiagnosticTimes[key] ?? -100) < 1) {
      return;
    }
    _baselineDiagnosticTimes[key] = now;
    final q = quality;
    unawaited(
      const MethodChannel('neurox/startup')
          .invokeMethod<void>('baselineGuardEvent', {
            'type': type,
            'reason': reason,
            'guardVersion': BaselineGuard.version,
            'phase': active ? 'recording' : 'preflight',
            'elapsed': active ? (now - _attemptStarted).clamp(0, 1000000) : 0,
            if (_lastBaselineLeadByte != null)
              'leadByte': _lastBaselineLeadByte,
            'contactReports': _baselineGuard.contactReports,
            'waveWindows': _baselineGuard.waveWindows,
            'dataWindows': _baselineGuard.missingWindows,
            if (_latestBaselineRate != null)
              'receivedRate': _latestBaselineRate,
            if (baselineReceiptReferenceRate != null)
              'referenceRate': baselineReceiptReferenceRate,
            if (q != null) 'qualityReason': q.source['rawQuality'] ?? q.reason,
            if (q != null) 'qualitySequence': q.sequence,
            if (q != null) 'qualityEnd': q.end,
          })
          .catchError((Object _) {}),
    );
  }

  void _wakeBaselineContact() {
    final waiting = _baselineContactWaiter;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<void> _waitBaselineContact() async {
    if (!_baselineGuard.contactPending || baselineInterruption != null) return;
    final waiting = Completer<void>();
    _baselineContactWaiter = waiting;
    final deadline = Timer(const Duration(seconds: 5), () {
      if (_baselineGuard.contactPending &&
          active &&
          baselineInterruption == null) {
        _abandonBaseline('data_loss');
      }
      _wakeBaselineContact();
    });
    await waiting.future;
    deadline.cancel();
    if (identical(_baselineContactWaiter, waiting)) {
      _baselineContactWaiter = null;
    }
  }

  void _baselineContactReport(RawSampleBatch batch) {
    if (batch.simulated ||
        _background ||
        !(baselineChecking ||
            active && !usingSavedReference && monitor == null)) {
      return;
    }
    final prior = _baselineGuard.contactPending;
    _lastBaselineLeadByte = batch.leadByte;
    final failure = _baselineGuard.contact(now, batch.contact);
    if (!prior && _baselineGuard.contactPending) {
      if (baselineChecking) _baselinePreparation.reset();
      quality = null;
      _baselineDiagnostic('contact_pending', 'contact');
    } else if (prior && !_baselineGuard.contactPending) {
      // Rebuild comparison evidence after recovery, without publishing suspect seconds.
      _baselineGuard.resetQuality();
      _worker?.reset();
      quality = null;
      _baselineDiagnostic('contact_recovered', 'good');
      _wakeBaselineContact();
    }
    if (failure != null && active) _abandonBaseline(failure);
  }

  String? baselineAnomaly, baselineInterruption;
  double? baselineReceiptReferenceRate;
  final List<(double, int)> _baselineReceiptMarks = [];
  bool _baselineAbortAttempted = false;

  void _abandonBaseline(String reason) {
    if (usingSavedReference || monitor != null || !active || baseline == null) {
      return;
    }
    if (baselineInterruption == null) {
      baselineInterruption = reason;
      _baselineDiagnostic('interrupted', reason);
      _wakeBaselineContact();
      baselineAnomaly = reason;
      baseline!.invalidate(reason);
      _autoFinishAttempted = true;
      if (['contact', 'wearing', 'waveform', 'data_loss'].contains(reason) &&
          feedback.enabled &&
          !feedback.muted &&
          backend is NativeBaselineBackend) {
        unawaited(
          const MethodChannel('neurox/notifications')
              .invokeMethod<Object?>('feedback', {
                ...feedback.toMap(),
                'kind': 'baseline.interrupted',
                'scope': sessionId,
                'title': tr('基线采集已中断'),
                'body': tr(
                  reason == 'contact'
                      ? '持续检测到电极接触异常，本次基线已中断。'
                      : reason == 'waveform' || reason == 'wearing'
                      ? '信号持续异常，本次基线已中断，请检查佩戴。'
                      : '数据接收持续不足，本次基线已中断，请检查连接。',
                ),
              })
              .then<void>((_) {})
              .catchError((Object _) {}),
        );
      }
      _notify();
    }
    if (busy || _baselineAbortAttempted) return;
    _baselineAbortAttempted = true;
    unawaited(cancelBaseline());
  }

  void _baselineTechnicalFeedback() {
    if (usingSavedReference ||
        !active ||
        !['collecting', 'ready'].contains(baseline?.state)) {
      return;
    }
    final at = now;
    _baselineReceiptMarks.add((at, eeg.sampleCount));
    while (_baselineReceiptMarks.length > 1 &&
        _baselineReceiptMarks[1].$1 <= at - 3) {
      _baselineReceiptMarks.removeAt(0);
    }
    final first = _baselineReceiptMarks.first;
    final reference = baselineReceiptReferenceRate;
    _latestBaselineRate = at > first.$1
        ? (eeg.sampleCount - first.$2) / (at - first.$1)
        : null;
    if (reference != null &&
        at - first.$1 >= 3 &&
        (eeg.sampleCount - first.$2) / (at - first.$1) < reference * .6) {
      _abandonBaseline('data_loss');
      return;
    }
  }

  Future<void> start() async {
    if (!canStart) return;
    busy = true;
    error = null;
    _notify();
    try {
      usingSavedReference = false;
      learningPreparing = false;
      baselineChartEvents.clear();
      final result = await backend.call('baselineStart', {
        'name': name.trim(),
        'purpose': 'personal_baseline',
      });
      completedSession = null;
      completedTaskScene = null;
      completedBaseline = null;
      baselineDiscarded = false;
      _baselineGuard.reset();
      _latestBaselineRate = null;
      _baselineDiagnosticTimes.clear();
      baselineAnomaly = null;
      baselineInterruption = null;
      _baselineAbortAttempted = false;
      _baselineReceiptMarks.clear();
      _baselineReceiptMarks.add((now, eeg.sampleCount));
      latestReminderSequence = null;
      sessionId = result['id'] as String;
      path = result['path'] as String?;
      _newAttempt(result['attempt'] as String);
      _baselineDiagnostic('start', 'good');
    } catch (e) {
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> startLearning() async {
    if (!canStartLearning) return;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await backend.call('learningStart', {
        'name': name.trim().isEmpty ? scene.label : name.trim(),
        'minutes': targetMinutes,
        'scene': scene.name,
        'protocol': {
          ...scene.toMap(),
          if (scene == TaskScene.recovery) 'recoveryMethod': recoveryMethod,
          if (scene == TaskScene.training) 'gameKind': trainingKind.name,
          if (scene == TaskScene.training) 'trackingLevel': trackingLevel,
        },
        'referenceId': savedReference['id'],
      });
      sessionId = result['id'] as String;
      path = result['path'] as String?;
      completedSession = null;
      latestReminderSequence = null;
      _monitorAck = 0;
      _hadValidAnalysis = false;
      _invalidSince = null;
      _dataNoticeSent = false;
      _autoFinishAttempted = false;
      usingSavedReference = true;
      learningPreparing = true;
      _learningRequiresRecheck = false;
      _learningStarted = false;
      learningPreparationDiscarded = false;
      _learningSignalGuard.reset();
      _restoreReference(result);
      monitor = MonitoringEngine(
        targetSeconds: targetMinutes * 60,
        at: now,
        reference: Map<String, dynamic>.from(
          baseline!.snapshot()['statistics'] as Map,
        ),
        attemptId: baseline!.attemptId,
        context: context,
        reminders: scene != TaskScene.training && remindersEnabled,
        prepared: true,
        rules: MonitoringRules(scene: scene),
        referenceOrigin: Map<String, dynamic>.from(
          baseline!.snapshot()['referenceOrigin'] as Map? ?? {},
        ),
      );
      monitor!.stage = sceneStage;
      monitor!.comparisonAllowed = stageSupportsComparison;
      monitor!.stageSilenced = scene == TaskScene.training || feedback.muted;
      monitor!.recordEvent('feedback_settings', now, {
        'settings': feedback.toMap(),
      });
      _persistMonitor();
    } catch (e) {
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  void _restoreReference(Map<String, dynamic> result) {
    _attemptStarted = now;
    baseline = BaselineAccumulator.fromSaved(
      attemptId: result['attempt'] as String,
      context: context,
      snapshot: Map<String, dynamic>.from(result['snapshot'] as Map),
    );
    _worker?.reset();
    quality = null;
  }

  Future<void> prepareLearning() async {
    if (busy ||
        !active ||
        !usingSavedReference ||
        monitor == null ||
        monitor!.finished) {
      return;
    }
    monitor!.advance(now);
    if (monitor!.finished) {
      await finish();
      return;
    }
    busy = true;
    error = null;
    learningPreparing = true;
    if (guidedScene) _learningRequiresRecheck = true;
    monitor!.rebuild(now, reuseReference: true);
    _persistMonitor();
    _notify();
    try {
      await _writes;
      final origin = baseline!.snapshot()['referenceOrigin'] as Map? ?? {};
      final result = await backend.call('learningRefresh', {
        'id': sessionId,
        'referenceId': origin['sessionId'],
      });
      _restoreReference(result);
      monitor!.referenceOrigin = Map<String, dynamic>.from(
        baseline!.snapshot()['referenceOrigin'] as Map? ?? {},
      );
      _learningRequiresRecheck = false;
      _learningSignalGuard.reset();
    } catch (e) {
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  void _newAttempt(String id) {
    _autoFinishAttempted = false;
    _attemptStarted = now;
    baseline = BaselineAccumulator(attemptId: id, context: context);
    _worker?.reset();
    quality = null;
  }

  Future<void> retry() async {
    if (usingSavedReference) {
      await prepareLearning();
      return;
    }
    if (busy ||
        !active ||
        baseline?.state == 'collecting' ||
        !eeg.receiving ||
        !profile.usable) {
      return;
    }
    busy = true;
    error = null;
    _notify();
    try {
      await _writes;
      final result = await backend.call('baselineRetry', {'id': sessionId});
      _newAttempt(result['attempt'] as String);
    } catch (e) {
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  void _samples(RawSampleBatch batch) {
    _baselineContactReport(batch);
    if (!batch.simulated &&
        !_background &&
        active &&
        guidedScene &&
        ['running', 'recovery'].contains(monitor?.phase)) {
      if (_learningSignalGuard.contact(now, batch.contact) != null) {
        invalidate('contact');
      }
    }
    if (active &&
        usingSavedReference &&
        guidedScene &&
        _learningRequiresRecheck &&
        !learningPreparing) {
      return;
    }
    if (_background || batch.simulated || !profile.usable || _worker == null) {
      return;
    }
    final at = now;
    unawaited(
      _worker!.push(
        batch.channel1,
        batch.channel2,
        active ? at - _attemptStarted : at,
      ),
    );
  }

  void _window(AnalysisWindow incoming) {
    if (_disposed || _background) return;
    final window =
        active &&
            !usingSavedReference &&
            monitor == null &&
            _baselineGuard.contactPending
        ? AnalysisWindow(
            sequence: incoming.sequence,
            start: incoming.start,
            end: incoming.end,
            reason: 'contact_pending',
            observationReason: 'contact_pending',
            source: incoming.source,
          )
        : incoming;
    quality = window;
    if (active &&
        usingSavedReference &&
        guidedScene &&
        ['running', 'recovery'].contains(monitor?.phase)) {
      final failure = scene.competitive && !stageSupportsComparison
          ? null
          : _learningSignalGuard.quality(window);
      if (scene.competitive && !stageSupportsComparison) {
        _learningSignalGuard.resetQuality();
      }
      if (failure != null || window.reason == 'invalid_input') {
        invalidate(failure ?? 'processing');
        return;
      }
    }
    if (baselineChecking) {
      _baselinePreparation.add(
        window,
        contactGood: !_baselineGuard.contactPending && eeg.lead != false,
      );
    }
    if (active &&
        !usingSavedReference &&
        monitor == null &&
        !_baselineGuard.contactPending) {
      final had =
          _baselineGuard.waveWindows > 0 || _baselineGuard.missingWindows > 0;
      final failure = _baselineGuard.quality(window);
      final has =
          _baselineGuard.waveWindows > 0 || _baselineGuard.missingWindows > 0;
      if (!had && has) {
        _baselineDiagnostic(
          'quality_pending',
          window.source['rawQuality'] as String? ?? window.reason,
        );
      }
      if (had && !has) _baselineDiagnostic('quality_recovered', 'good');
      if (failure != null) {
        _abandonBaseline(failure);
        return;
      }
    }
    final attempt = baseline;
    if (attempt?.state == 'collecting') {
      attempt!.advance(now - _attemptStarted);
      attempt.add(window);
      baselineChartEvents.add({
        'type': 'sample',
        'wallSeconds': window.end,
        'elapsed': window.end,
        'scores': window.good ? window.features : null,
      });
      if (!window.good) {
        baselineChartEvents.add({
          'type': 'quality',
          'wallSeconds': window.end,
          'elapsed': window.end,
          'reason': window.reason,
        });
      }
      _persist(window);
    }
    if (!busy && monitor?.phase == 'recovery') {
      monitor!.advance(now);
      if (monitor!.finished) return;
      monitor!.recordEvent('sample', now, {
        'scores': window.good ? window.features : null,
        'stage': recoveryFlow?.stage ?? 'recovery',
      });
      _persistMonitor();
    }
    if (!busy && monitor?.phase == 'running' && scene == TaskScene.training) {
      final m = monitor!;
      m.advance(now);
      if (m.phase != 'running' || trainingGame == null) return;
      final sample = trainingSample(
        window: window,
        sampleAt: _attemptStarted + window.end,
        receivedAt: now,
        gameSeconds: m.elapsed,
        attempt: m.attemptId,
      );
      if (sample != null) m.recordEvent('sample', now, sample);
      _persistMonitor();
      _notify();
      return;
    }
    if (!busy && monitor?.phase == 'running') {
      if (window.good && baseline?.state == 'ready') _hadValidAnalysis = true;
      monitor!.observe(
        at: now,
        sampleAt: _attemptStarted + window.end,
        features: window.features,
        good: window.good && baseline?.state == 'ready',
        why: baseline?.state == 'ready' ? window.reason : 'baseline_invalid',
      );
      if (!monitor!.comparisonAllowed) {
        monitor!.recordEvent('sample', now, {
          'scores': window.good ? window.features : null,
          'stage': sceneStage,
          'comparisonAllowed': false,
        });
      }
      _persistMonitor();
    }
    _notify();
  }

  void _persist([AnalysisWindow? window]) {
    if (!active || baseline == null) return;
    final args = {
      'id': sessionId,
      'attempt': baseline!.attemptId,
      'snapshot': baseline!.snapshot(),
      if (window != null) 'window': window.toMap(),
    };
    pendingWrites++;
    _writes = _writes.then((_) async {
      if (_disposed) return;
      try {
        await backend.call('baselineUpdate', args);
      } catch (e) {
        baseline?.invalidate('storage');
        error = LocalAccount.describe(e);
        _notify();
      } finally {
        pendingWrites--;
        _notify();
      }
    });
  }

  void invalidate(String reason) {
    if (active && !usingSavedReference && monitor == null && baseline != null) {
      _abandonBaseline(reason);
      return;
    }
    if (active &&
        usingSavedReference &&
        guidedScene &&
        monitor != null &&
        !monitor!.finished) {
      _learningRequiresRecheck = true;
    }
    final attemptNeeds =
        baseline != null && ['collecting', 'ready'].contains(baseline!.state);
    final monitorNeeds =
        monitor != null &&
        !monitor!.finished &&
        ((guidedScene ||
                ['background', 'storage', 'processing'].contains(reason))
            ? monitor!.phase != 'interrupted'
            : monitor!.phase == 'running' &&
                  (monitor!.state != 'unknown' || monitor!.reason != reason));
    if (!attemptNeeds && !monitorNeeds) return;
    if (monitor != null) {
      if (guidedScene ||
          ['background', 'storage', 'processing'].contains(reason)) {
        monitor!.interrupt(now, reason);
      } else {
        monitor!.block(now, reason);
      }
      _persistMonitor();
    }
    final attempt = baseline;
    if (attempt == null || !['collecting', 'ready'].contains(attempt.state)) {
      return;
    }
    attempt.invalidate(reason);
    _worker?.reset();
    quality = null;
    _persist();
    _notify();
  }

  void _deviceChanged() {
    if (!eeg.receiving && quality != null) {
      quality = null;
      _worker?.reset();
    }
    if (!active) {
      _notify();
      return;
    }
    if (active && baseline != null) {
      if (eeg.selected?.address != baseline!.context['device'] ||
          eeg.session != baseline!.context['connection']) {
        invalidate('connection');
      } else if (!eeg.connected) {
        invalidate('disconnected');
      } else if (eeg.stale || eeg.waitingTimedOut) {
        invalidate('data');
      } else if (eeg.recordingState == 'save_failed') {
        invalidate('storage');
      }
    }
  }

  void _tick() {
    if (_disposed) return;
    if (active && !_background) {
      _deviceChanged();
      if (!busy && ['running', 'recovery'].contains(monitor?.phase)) {
        monitor!.advance(now);
        driveTraining();
        _technicalFeedback();
        _persistMonitor();
      }
      _baselineTechnicalFeedback();
      if (!usingSavedReference && monitor == null && baseline != null) {
        if (baselineInterruption != null) {
          _abandonBaseline(baselineInterruption!);
        } else if (!busy &&
            !_autoFinishAttempted &&
            ['failed', 'invalid'].contains(baseline!.state)) {
          _abandonBaseline(baseline!.reason);
        } else if (!busy &&
            baseline!.state == 'ready' &&
            !_autoFinishAttempted) {
          _autoFinishAttempted = true;
          unawaited(finish());
        }
      }
      if (!busy && monitor?.finished == true && !_autoFinishAttempted) {
        _autoFinishAttempted = true;
        unawaited(finish());
      }
      if (baseline?.state == 'collecting') {
        final prior = baseline!.state;
        baseline!.advance(now - _attemptStarted);
        if (prior != baseline!.state) _persist();
      }
      _notify();
    }
  }

  Future<bool> cancelBaseline() async {
    if (busy || !baselineCancellable) return false;
    busy = true;
    error = null;
    _autoFinishAttempted = true;
    _notify();
    final id = sessionId!;
    try {
      baseline!.invalidate('ended');
      _persist();
      await _writes;
      // Finalize/close the writer before deleting only this owned unfinished record.
      await backend.call('baselineFinish', {
        'id': id,
        'attempt': baseline!.attemptId,
        'snapshot': baseline!.snapshot(),
      });
      await backend.call('deleteSession', {'id': id});
      _baselineDiagnostic('discarded', baselineInterruption ?? 'ended');
      sessionId = null;
      baseline = null;
      completedSession = null;
      completedTaskScene = null;
      completedBaseline = null;
      baselineDiscarded = true;
      quality = null;
      _worker?.reset();
      baselineAnomaly = null;
      _autoFinishAttempted = false;
      error = null;
      return true;
    } catch (e) {
      _baselineDiagnostic('cleanup_failed', 'storage');
      error = LocalAccount.describe(e);
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> discardUnstartedLearning() async {
    if (busy || !unstartedLearning || monitor == null) return false;
    busy = true;
    error = null;
    _autoFinishAttempted = true;
    _learningRequiresRecheck = true;
    quality = null;
    _worker?.reset();
    _notify();
    final id = sessionId!;
    try {
      monitor!.finish(now, 'user_ended');
      await _writes;
      // Close the native writer and finalize its index before deleting this draft only.
      await backend.call('monitorFinish', {
        'id': id,
        'snapshot': monitor!.snapshot(now),
        'events': monitor!.events
            .where((e) => (e['sequence'] as int) > _monitorAck)
            .toList(),
      });
      await backend.call('deleteSession', {'id': id});
      sessionId = null;
      path = null;
      baseline = null;
      monitor = null;
      completedSession = null;
      completedTaskScene = null;
      completedBaseline = null;
      _learningRecoveryPromptSession = null;
      learningPreparing = false;
      usingSavedReference = false;
      _learningRequiresRecheck = false;
      _learningStarted = false;
      _learningSignalGuard.reset();
      _monitorAck = 0;
      _autoFinishAttempted = false;
      latestReminderSequence = null;
      learningPreparationDiscarded = true;
      return true;
    } catch (e) {
      error = LocalAccount.describe(e);
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<String?> finish() async {
    if (busy || !active) return null;
    if (unstartedLearning) {
      await discardUnstartedLearning();
      return null;
    }
    if (!usingSavedReference &&
        monitor == null &&
        baseline != null &&
        baseline!.state != 'ready') {
      baselineInterruption ??= baseline!.state == 'collecting'
          ? 'ended'
          : baseline!.reason;
      await cancelBaseline();
      return null;
    }
    _autoFinishAttempted = true;
    busy = true;
    error = null;
    _notify();
    final id = sessionId!;
    try {
      monitor?.finish(
        now,
        monitor!.endReason.isEmpty
            ? (monitor!.openEnded && monitor!.validSeconds > 0
                  ? 'user_completed'
                  : 'user_ended')
            : monitor!.endReason,
      );
      if (baseline?.state == 'collecting') baseline!.invalidate('ended');
      _persist();
      await _writes;
      if (monitor != null) {
        monitor!.finish(
          now,
          monitor!.endReason.isEmpty
              ? (monitor!.openEnded && monitor!.validSeconds > 0
                    ? 'user_completed'
                    : 'user_ended')
              : monitor!.endReason,
        );
        await backend.call('monitorFinish', {
          'id': id,
          'snapshot': monitor!.snapshot(now),
          'events': monitor!.events
              .where((e) => (e['sequence'] as int) > _monitorAck)
              .toList(),
        });
      } else {
        await _waitBaselineContact();
        await backend.call('baselineFinish', {
          'id': id,
          'attempt': baseline!.attemptId,
          'snapshot': baseline!.snapshot(),
        });
      }
      if (monitor == null) await _waitBaselineContact();
      final discarded = monitor == null && baseline?.state != 'ready';
      if (discarded) {
        baselineInterruption ??= baseline?.reason ?? 'data';
        await backend.call('deleteSession', {'id': id});
        baselineDiscarded = true;
      }
      if (monitor == null) {
        _baselineDiagnostic(
          discarded ? 'discarded' : 'ready',
          discarded ? baselineInterruption ?? 'data' : 'good',
        );
      }
      completedBaseline = !discarded && monitor == null
          ? baseline?.snapshot()
          : null;
      _learningRecoveryPromptSession =
          !discarded &&
              (scene == TaskScene.learning || scene.competitive) &&
              monitor != null &&
              monitor!.elapsed > 0
          ? id
          : null;
      completedTaskScene = discarded
          ? null
          : monitor == null
          ? 'baseline'
          : scene.name;
      completedSession = discarded ? null : id;
      recoveryFlow = null;
      trainingGame = null;
      _trainingFinishing = false;
      recoveryChoosing = false;
      latestReminderSequence = null;
      sessionId = null;
      monitor = null;
      _monitorAck = 0;
      _autoFinishAttempted = false;
      baseline = null;
      learningPreparing = false;
      usingSavedReference = false;
      quality = null;
      _worker?.reset();
      return discarded ? null : id;
    } catch (e) {
      error = LocalAccount.describe(e);
      return null;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> startMonitoring() async {
    if (usingSavedReference &&
        monitor != null &&
        monitor!.needsBaseline(now) &&
        monitor!.attemptId == baseline?.attemptId) {
      await prepareLearning();
      return;
    }
    if (!canMonitor) return;
    busy = true;
    error = null;
    _notify();
    try {
      await _writes;
      final reference = Map<String, dynamic>.from(
        baseline!.snapshot()['statistics'] as Map,
      );
      if (monitor == null) {
        monitor = MonitoringEngine(
          targetSeconds: targetMinutes * 60,
          at: now,
          reference: reference,
          attemptId: baseline!.attemptId,
          context: context,
          reminders: remindersEnabled,
        );
      } else {
        monitor!.resume(
          now,
          reference,
          baseline!.attemptId,
          nextContext: context,
        );
      }
      final result = await backend.call('monitorStart', {
        'id': sessionId,
        'snapshot': monitor!.snapshot(now),
        'events': monitor!.events
            .where((e) => (e['sequence'] as int) > _monitorAck)
            .toList(),
      });
      _monitorAck = monitor!.sequence;
      monitor!.reanchor(now);
      learningPreparing = false;
      if (scene == TaskScene.training && trainingGame == null) {
        trainingGame = TrainingGame(
          kind: trainingKind,
          level: trackingLevel,
          seed: DateTime.now().microsecondsSinceEpoch,
        );
        monitor!.gameInfo = trainingGame!.snapshot();
        monitor!.recordEvent('game_start', now, trainingGame!.snapshot());
      }
      if (recoveryFlow != null && recoveryFlow!.stage != 'recheck') {
        recoveryFlow!.stepStartedAt = now;
        monitor!.beginRecovery(now, recoveryFlow!.toMap());
      }
      monitor!.comparisonAllowed = stageSupportsComparison;
      monitor!.stageSilenced = scene == TaskScene.training || feedback.muted;
      if (result['accepted'] == false) {
        throw PlatformException(
          code: 'monitor_start',
          message: '监测未能开始，请重新检查条件。',
        );
      }
      _learningStarted = true;
      if (scene == TaskScene.recovery && recoveryFlow == null) {
        _beginRecovery(recoveryMethod);
      }
    } catch (e) {
      monitor?.interrupt(now, 'storage');
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  void _persistMonitor() {
    final current = monitor;
    if (!active || current == null || _disposed) return;
    final snapshot = current.snapshot(now), id = sessionId;
    final sequence = snapshot['eventSequence'] as int;
    _writes = _writes.then((_) async {
      if (_disposed || monitor != current || !active) return;
      final events = current.events
          .where(
            (e) =>
                (e['sequence'] as int) > _monitorAck &&
                (e['sequence'] as int) <= sequence,
          )
          .toList();
      try {
        final result = await backend.call('monitorUpdate', {
          'id': id,
          'snapshot': snapshot,
          'events': events,
        });
        if (result['accepted'] == false) {
          if (current.phase != 'interrupted' && !current.finished) {
            current.interrupt(now, 'background', accountTime: false);
            invalidate('background');
          }
          return;
        }
        _monitorAck = sequence > _monitorAck ? sequence : _monitorAck;
        for (final event in events.where(
          (e) => e['type'] == 'reminder' && e['delivery'] == 'pending',
        )) {
          if (!_background &&
              current.phase == 'running' &&
              current.reminders &&
              current.state == 'deviation' &&
              !current.stageSilenced &&
              eeg.receiving &&
              quality?.good == true) {
            try {
              final options = feedback;
              final alertResult = await backend.call('monitorAlert', {
                'id': id,
                'sequence': event['sequence'],
                'feedback': options.toMap(),
              });
              current.recordEvent('feedback_delivery', now, {
                'eventSequence': event['sequence'],
                'channels': options.toMap(),
                'result': alertResult,
              });
              if (alertResult['accepted'] == true) {
                event['delivery'] = 'feedback_requested';
                latestReminderSequence = event['sequence'] as int;
              }
            } catch (e) {
              current.recordEvent('feedback_delivery', now, {
                'eventSequence': event['sequence'],
                'delivery': 'unavailable',
              });
            }
          }
        }
      } catch (e) {
        final prior = current.phase;
        current.interrupt(now, 'storage');
        baseline?.invalidate('storage');
        error = LocalAccount.describe(e);
        if (prior != 'interrupted' && !current.finished) _persistMonitor();
      }
      _notify();
    });
  }

  void pauseMonitoring() {
    if (!busy &&
        (monitor?.phase == 'running' ||
            scene == TaskScene.recovery && monitor?.phase == 'recovery')) {
      monitor!.pause(now);
      if (guidedScene) {
        _learningRequiresRecheck = true;
        _learningSignalGuard.reset();
        quality = null;
        _worker?.reset();
      }
      _persistMonitor();
      _notify();
    }
  }

  Future<void> continueMonitoring() async {
    if (guidedScene && usingSavedReference) {
      await prepareLearning();
      return;
    }
    if (needsRebaseline) {
      await rebuildMonitoring();
    } else {
      await startMonitoring();
    }
  }

  Future<void> rebuildMonitoring() async {
    if (usingSavedReference) {
      await prepareLearning();
      return;
    }
    if (busy || monitor == null || monitor!.finished) return;
    monitor!.rebuild(now);
    _persistMonitor();
    invalidate('rebaseline');
    if (eeg.receiving) await retry();
    _notify();
  }

  void setReminders(bool value) => setFeedback(
    FeedbackOptions(
      sound: feedback.sound,
      vibration: value,
      notice: value,
      muted: feedback.muted,
    ),
  );

  Future<void> adjust(String kind) async {
    if (monitor == null || busy) return;
    monitor!.adjustment(kind, now);
    _persistMonitor();
    if (kind == 'wearing') await rebuildMonitoring();
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ([
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ].contains(state)) {
      _background = true;
      invalidate('background');
      _worker?.reset();
      quality = null;
    }
    if (state == AppLifecycleState.resumed && !_background) {
      if (monitor != null) unawaited(_refreshNativeMonitor());
      return;
    }
    if (state == AppLifecycleState.resumed && _background) {
      if (monitor?.phase == 'running') {
        monitor!.interrupt(now, 'background', accountTime: false);
        invalidate('background');
      }
      _background = false;
      if (monitor != null) {
        unawaited(_refreshNativeMonitor());
      }
      quality = null;
      _worker?.reset();
    }
  }

  Future<void> _refreshNativeMonitor() async {
    try {
      final status = await backend.call('monitorStatus', {'id': sessionId});
      if (status['nativeInterrupted'] == true &&
          monitor != null &&
          monitor!.phase != 'interrupted' &&
          !monitor!.finished) {
        monitor!.interrupt(now, 'background', accountTime: false);
        invalidate('background');
        _notify();
      }
    } catch (e) {
      error = LocalAccount.describe(e);
      _notify();
    }
  }

  Future<void> resolve(String id) async {
    if (busy || active) return;
    busy = true;
    error = null;
    _notify();
    try {
      await backend.call('baselineFinish', {'id': id});
    } catch (e) {
      error = LocalAccount.describe(e);
    } finally {
      busy = false;
      _notify();
    }
    await refresh();
  }

  void clearDraft() {
    if (!active && !busy && !baselineChecking) {
      resetBaselineCheck();
      baselineDiscarded = false;
      baselineInterruption = null;
      baselineReceiptReferenceRate = null;
      name = '';
      usingSavedReference = false;
      learningPreparing = false;
      targetMinutes = 0;
      scene = TaskScene.learning;
      sceneStage = 'study';
      conditionMatches = true;
      recoveryFlow = null;
      recoveryMethod = 'breathing';
      trainingGame = null;
      _trainingFinishing = false;
      error = null;
      _feedbackDefaultsLoaded = false;
      _learningRequiresRecheck = false;
      _learningStarted = false;
      learningPreparationDiscarded = false;
      _learningSignalGuard.reset();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _baselineCheckGeneration++;
    _wakeBaselineCheck();
    _wakeBaselineContact();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    eeg.removeListener(_deviceChanged);
    _timer?.cancel();
    unawaited(_raw?.cancel());
    unawaited(_analysis?.cancel());
    unawaited(_worker?.close());
    super.dispose();
  }
}
