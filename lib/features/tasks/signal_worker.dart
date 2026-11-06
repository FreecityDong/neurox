import 'dart:async';
import 'dart:isolate';
import 'signal_pipeline.dart';

class SignalWorker {
  final _receive = ReceivePort();
  final _ready = Completer<SendPort>();
  final _windows = StreamController<AnalysisWindow>.broadcast();
  Isolate? _isolate;
  int _generation = 0, _pending = 0;
  bool _closed = false;
  Stream<AnalysisWindow> get windows => _windows.stream;
  Future<void> start(SignalProfile profile) async {
    _receive.listen((dynamic data) {
      if (data is SendPort) {
        _ready.complete(data);
        return;
      }
      if (_closed) return;
      final m = Map<String, dynamic>.from(data as Map);
      if (m['generation'] != _generation) return;
      if (_pending > 0) _pending--;
      if (m['error'] != null) {
        _windows.addError(StateError(m['error'] as String));
        return;
      }
      if (m['window'] != null) {
        _windows.add(
          AnalysisWindow.fromMap(Map<String, dynamic>.from(m['window'] as Map)),
        );
      }
    });
    _isolate = await Isolate.spawn(_signalMain, _receive.sendPort);
    if (_closed) {
      _isolate?.kill(priority: Isolate.immediate);
      return;
    }
    (await _ready.future).send({'type': 'profile', 'profile': profile.values});
  }

  void reset() {
    _generation++;
    _pending = 0;
  }

  Future<void> push(List<double> a, List<double> b, double at) async {
    if (_closed) return;
    if (_pending >= 128) {
      reset();
      _windows.addError(StateError('quality backlog'));
      return;
    }
    final generation = _generation;
    _pending++;
    final port = await _ready.future;
    if (!_closed && generation == _generation) {
      port.send({'generation': generation, 'a': a, 'b': b, 'at': at});
    }
  }

  Future<void> close() async {
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _receive.close();
    await _windows.close();
  }
}

void _signalMain(SendPort output) {
  final input = ReceivePort();
  output.send(input.sendPort);
  SignalPipeline? pipeline;
  SignalProfile? profile;
  int? generation;
  input.listen((dynamic data) {
    final m = Map<String, dynamic>.from(data as Map);
    if (m['type'] == 'profile') {
      profile = SignalProfile(Map<String, dynamic>.from(m['profile'] as Map));
      return;
    }
    final gen = m['generation'] as int;
    try {
      if (generation != gen) {
        final previousSequence = pipeline?.sequence ?? 0;
        pipeline = SignalPipeline(profile!)..sequence = previousSequence;
        generation = gen;
      }
      final result = pipeline!.push(
        (m['a'] as List).cast<double>(),
        (m['b'] as List).cast<double>(),
        (m['at'] as num).toDouble(),
      );
      output.send({'generation': gen, 'window': result?.toMap()});
    } catch (e) {
      output.send({'generation': gen, 'error': e.toString()});
    }
  });
}
