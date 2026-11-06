import 'package:flutter/services.dart';
import 'package:neurox/features/tasks/task_controller.dart';
import 'package:neurox/features/tasks/signal_pipeline.dart';
import 'package:neurox/features/device/eeg_controller.dart';
import 'fake_eeg_transport.dart';

class MonitorBackend implements BaselineBackend {
  final calls = <String>[];
  final arguments = <String, Map<String, dynamic>?>{};
  bool failFinish = false, failAlert = false, nativeInterrupted = false;
  int attempt = 0, learningCount = 0;
  bool hasReference = true;
  bool failDelete = false;
  Future<void>? baselineFinishBarrier;
  Future<Map<String, dynamic>>? feedbackSettingsBarrier;
  Map<String, dynamic> profile = {};
  Map<String, dynamic> referenceSnapshot = {};
  Map<String, dynamic> Function()? contextReader;
  Map<String, dynamic> get referenceInfo => {
    'available': hasReference,
    'compatible': true,
    'id': 'SAVED PERSONAL BASELINE',
    'started': 1793678400.0,
    'device': 'TEST ONLY',
    'snapshot': referenceSnapshot,
  };
  Map<String, dynamic> attached(String attempt) => {
    'attempt': attempt,
    'snapshot': {
      ...referenceSnapshot,
      'attemptId': attempt,
      'context': contextReader?.call() ?? {},
      'referenceOrigin': {
        'version': 'personal-reference-v1',
        'sessionId': 'SAVED PERSONAL BASELINE',
        'attemptId': 'ORIGINAL',
        'collectedAt': 1793678400.0,
        'reused': true,
      },
    },
  };
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    calls.add(method);
    if (method == 'baselineFinish' && baselineFinishBarrier != null) {
      await baselineFinishBarrier;
    }
    if (method == 'deleteSession' && failDelete) {
      throw PlatformException(code: 'test', message: 'TEST cleanup failed');
    }
    arguments[method] = args;
    if (method == 'feedbackSettings' && feedbackSettingsBarrier != null) {
      return await feedbackSettingsBarrier!;
    }
    if (method == 'monitorAlert' && failAlert) {
      throw PlatformException(
        code: 'notice',
        message: 'TEST notification unavailable',
      );
    }
    if (method == 'monitorFinish' && failFinish) {
      throw PlatformException(code: 'test', message: '测试保存失败');
    }
    if (method == 'monitorStatus') {
      return {'nativeInterrupted': nativeInterrupted};
    }
    if (method == 'baselineCapabilities') return {'profile': profile};
    if (method == 'baselinePreflight') {
      return {'storageReady': true, 'unresolved': []};
    }
    if (method == 'baselineReference') return referenceInfo;
    if (method == 'learningStart') {
      return {
        'id': ++learningCount == 1
            ? 'SYNTHETIC TASK'
            : 'SYNTHETIC TASK $learningCount',
        'path': 'test.jsonl',
        ...attached('A'),
      };
    }
    if (method == 'learningRefresh') return attached('B${++attempt}');
    if (method == 'baselineStart') {
      return {'id': 'SYNTHETIC TASK', 'path': 'test.jsonl', 'attempt': 'A'};
    }
    if (method == 'baselineRetry') return {'attempt': 'B${++attempt}'};
    return {'accepted': true};
  }
}

class MonitorFixture {
  final transport = FakeEegTransport(), backend = MonitorBackend();
  late final EegController eeg;
  late final TaskController task;
  double clock = 0;
  Future<void> initialize({bool running = true, int minutes = 0}) async {
    final date = DateTime(2026, 11, 3, 12);
    eeg = EegController(transport, clock: () => date);
    task = TaskController(eeg, backend: backend, clock: () => clock);
    await eeg.initialize();
    await eeg.connect(
      const EegDevice(
        address: testDeviceAddress,
        name: 'TEST ONLY',
        rssi: -20,
        advertisesService: true,
      ),
    );
    transport.packet('raw', rawPacket(), date);
    task.profile = SignalProfile({
      'verified': true,
      'version': 'SYNTHETIC',
      'evidence': 'STATE TEST ONLY',
      'unit': 'test',
      'sampleRate': 512.0,
      'scale': 1.0,
      'flatStd': .01,
      'maxPeakToPeak': 20.0,
      'maxStep': 2.0,
      'adcMin': -100.0,
      'adcMax': 100.0,
    });
    task.storageReady = true;
    quality();
    backend.profile = task.profile.values;
    backend.contextReader = () => task.context;
    backend.referenceSnapshot = {
      'algorithm': baselineAlgorithmVersion,
      'attemptId': 'ORIGINAL',
      'state': 'ready',
      'context': Map<String, dynamic>.from(task.context),
      'elapsed': 90.0,
      'attemptElapsed': 100.0,
      'validSeconds': 90.0,
      'adaptationSeconds': 10,
      'readingVersion': baselineReadingVersion,
      'statistics': {
        'attention': {'mean': 60.0, 'variance': 4.0, 'drift': 0.0},
        'relax': {'mean': 40.0, 'variance': 4.0, 'drift': 0.0},
      },
    };
    task.savedReference = backend.referenceInfo;
    task.targetMinutes = minutes;
    await task.startLearning();
    transport.emit({'type': 'recording', 'active': true, 'state': 'recording'});
    ready();
    clock = 100;
    if (running) await task.startMonitoring();
  }

  void quality() {
    task.quality = const AnalysisWindow(
      sequence: 1,
      start: 0,
      end: 4,
      reason: 'good',
      features: {'attention': 60, 'relax': 40},
    );
  }

  void ready() {
    quality();
  }

  Future<void> close() async {
    task.dispose();
    eeg.dispose();
    await transport.close();
  }
}
