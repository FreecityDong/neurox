import 'package:flutter/services.dart';

abstract interface class EegTransport {
  Stream<Map<String, dynamic>> get events;
  Future<Map<String, dynamic>> access();
  Future<Map<String, dynamic>> requestAccess();
  Future<Map<String, dynamic>> enableBluetooth();
  Future<void> scan();
  Future<void> stopScan();
  Future<void> connect(String address);
  Future<void> disconnect();
  Future<void> openSettings({bool location = false});
  Future<String?> startRecording();
  Future<String?> stopRecording();
  Future<bool> exportRecording();
}

abstract interface class PreviewCapableTransport implements EegTransport {
  Future<void> setPreview(bool enabled);
}

class AndroidEegTransport implements EegTransport {
  static const _methods = MethodChannel('neurox/eeg/methods');
  static const _events = EventChannel('neurox/eeg/events');
  late final Stream<Map<String, dynamic>> _stream = _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));
  @override
  Stream<Map<String, dynamic>> get events => _stream;
  Future<Map<String, dynamic>> _status(String method) async =>
      Map<String, dynamic>.from(
        await _methods.invokeMapMethod<String, dynamic>(method) ?? {},
      );
  @override
  Future<Map<String, dynamic>> access() => _status('access');
  @override
  Future<Map<String, dynamic>> requestAccess() => _status('requestAccess');
  @override
  Future<Map<String, dynamic>> enableBluetooth() => _status('enableBluetooth');
  @override
  Future<void> scan() => _methods.invokeMethod('scan');
  @override
  Future<void> stopScan() => _methods.invokeMethod('stopScan');
  @override
  Future<void> connect(String address) =>
      _methods.invokeMethod('connect', {'address': address});
  @override
  Future<void> disconnect() => _methods.invokeMethod('disconnect');
  @override
  Future<void> openSettings({bool location = false}) =>
      _methods.invokeMethod(location ? 'openLocationSettings' : 'openSettings');
  @override
  Future<String?> startRecording() =>
      _methods.invokeMethod<String>('startRecording');
  @override
  Future<String?> stopRecording() =>
      _methods.invokeMethod<String>('stopRecording');
  @override
  Future<bool> exportRecording() async =>
      await _methods.invokeMethod<bool>('exportRecording') ?? false;
}
