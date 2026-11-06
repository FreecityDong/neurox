import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../algorithms/recovered_eeg.dart';
import 'eeg_transport.dart';
import 'kseeg_protocol.dart';

/// Leaves BLE and raw recording native; CPU work runs in a separate isolate.
class LocalAlgorithmTransport implements EegTransport {
  LocalAlgorithmTransport(this.native) {
    _events = StreamController.broadcast(onListen: _listen, onCancel: _cancel);
    _ready.future.ignore();
  }
  final EegTransport native;
  late final StreamController<Map<String, dynamic>> _events;
  final _receive = ReceivePort();
  final _ready = Completer<SendPort>();
  Isolate? _isolate;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  int _generation = 0, _pending = 0;
  int _windows = 0;
  int? _session;
  String? _address;
  bool _disabled = false, _recording = false, _closed = false;
  static const _channel = MethodChannel('neurox/eeg/methods');

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  Map<String, dynamic> _capabilities(Map<String, dynamic> value) => {
    ...value,
    'localAlgorithms': true,
  };
  void _listen() {
    _receive.listen((dynamic message) {
      if (message is SendPort) {
        if (!_ready.isCompleted) _ready.complete(message);
        return;
      }
      if (_closed) return;
      final event = Map<String, dynamic>.from(message as Map);
      if (event['generation'] != _generation ||
          event['session'] != _session ||
          event['address'] != _address) {
        return;
      }
      if (_pending > 0) _pending--;
      if (event['type'] == 'algorithmFailure') {
        _disabled = true;
        _events.add({
          'type': 'error',
          'message': '本机算法已停止：${event['message']}；原始采集继续',
        });
        return;
      }
      _events.add(event);
      if ((event['updates'] as List? ?? []).isNotEmpty) {
        _windows++;
        if (_windows == 1 || _windows % 20 == 0) {
          debugPrint(
            'NeuroX local algorithm: session=$_session, windows=$_windows',
          );
        }
      }
      if (_recording) {
        unawaited(
          _channel.invokeMethod<void>('recordAlgorithm', event).catchError((
            Object e,
          ) {
            if (!_closed) {
              _events.add({'type': 'error', 'message': '算法记录失败：$e'});
            }
          }),
        );
      }
    });
    _subscription = native.events.listen(_onNative, onError: _events.addError);
    unawaited(
      Isolate.spawn(_algorithmMain, _receive.sendPort)
          .then((value) {
            if (_closed) {
              value.kill(priority: Isolate.immediate);
            } else {
              _isolate = value;
            }
          })
          .catchError((Object error) {
            _disabled = true;
            if (!_closed) {
              _events.add({'type': 'error', 'message': '本机算法启动失败：$error'});
            }
            if (!_ready.isCompleted) _ready.completeError(error);
          }),
    );
  }

  void _onNative(Map<String, dynamic> event) {
    if (_closed) return;
    if (event['type'] == 'adapter') event = _capabilities(event);
    if (event['type'] == 'algorithmReset') {
      _generation++;
      _pending = 0;
      _windows = 0;
      _disabled = false;
      unawaited(
        _ready.future
            .then((port) {
              if (!_closed) port.send({'type': 'reset'});
            })
            .catchError((Object _) {}),
      );
    }
    if (event['type'] == 'connection') {
      if (event['state'] == 'connecting') {
        _generation++;
        _windows = 0;
        _pending = 0;
        _disabled = false;
        _session = event['session'] as int?;
        _address = event['address'] as String?;
        unawaited(
          _ready.future
              .then((port) {
                if (!_closed) port.send({'type': 'reset'});
              })
              .catchError((Object _) {}),
        );
      } else if (event['state'] == 'disconnected' ||
          event['state'] == 'error') {
        _generation++;
        _session = null;
        _address = null;
        _pending = 0;
        _recording = false;
      }
    }
    if (event['type'] == 'recording') _recording = event['active'] == true;
    _events.add(event);
    if (event['type'] != 'packet' ||
        _disabled ||
        _session == null ||
        event['session'] != _session ||
        event['address'] != _address ||
        (event['uuid'] as String).toLowerCase() != KseegProtocol.uuids['raw']) {
      return;
    }
    if (_pending >= 512) {
      _disabled = true;
      _events.add({'type': 'error', 'message': '本机算法积压超过512包，算法停止；原始采集和记录继续'});
      return;
    }
    _pending++;
    final generation = _generation;
    unawaited(
      _ready.future
          .then((port) {
            if (!_closed && generation == _generation) {
              port.send({...event, 'generation': generation});
            }
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> _cancel() async {
    _closed = true;
    await _subscription?.cancel();
    _isolate?.kill(priority: Isolate.immediate);
    _receive.close();
  }

  @override
  Future<Map<String, dynamic>> access() async =>
      _capabilities(await native.access());
  @override
  Future<Map<String, dynamic>> requestAccess() async =>
      _capabilities(await native.requestAccess());
  @override
  Future<Map<String, dynamic>> enableBluetooth() async =>
      _capabilities(await native.enableBluetooth());
  @override
  Future<void> scan() => native.scan();
  @override
  Future<void> stopScan() => native.stopScan();
  @override
  Future<void> connect(String address) => native.connect(address);
  @override
  Future<void> disconnect() => native.disconnect();
  @override
  Future<void> openSettings({bool location = false}) =>
      native.openSettings(location: location);
  @override
  Future<String?> startRecording() => native.startRecording();
  @override
  Future<String?> stopRecording() => native.stopRecording();
  @override
  Future<bool> exportRecording() => native.exportRecording();
}

Object? _jsonFinite(Object? value) {
  if (value is double && !value.isFinite) return null;
  if (value is List) return value.map(_jsonFinite).toList();
  if (value is Map) return value.map((key, v) => MapEntry(key, _jsonFinite(v)));
  return value;
}

void _algorithmMain(SendPort output) {
  final input = ReceivePort();
  var algorithm = RecoveredEegAlgorithms();
  output.send(input.sendPort);
  input.listen((dynamic message) {
    final event = Map<String, dynamic>.from(message as Map);
    if (event['type'] == 'reset') {
      algorithm = RecoveredEegAlgorithms();
      return;
    }
    final metadata = {
      for (final key in ['session', 'address', 'generation', 'receivedAt'])
        key: event[key],
    };
    try {
      final value = event['bytes'];
      final bytes = value is Uint8List
          ? value
          : Uint8List.fromList((value as List).cast<int>());
      final data = KseegProtocol.parse(
        'raw',
        bytes,
        leadConvention: LeadConvention.windows,
      );
      final result = algorithm.process(
        data['channel_1'] as List<double>,
        data['channel_2'] as List<double>,
      );
      output.send(
        _jsonFinite({
          'type': 'algorithm',
          ...metadata,
          ...result,
          'engine': 'KSEEG102_Python_Mac algorithms / Dart local isolate',
        }),
      );
    } catch (error) {
      output.send({
        'type': 'algorithmFailure',
        ...metadata,
        'message': error.toString(),
      });
    }
  });
}
