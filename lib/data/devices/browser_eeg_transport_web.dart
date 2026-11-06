import 'dart:async';
import 'dart:js_interop';
import 'eeg_transport.dart';

@JS('neuroxBle')
external _WebBle get _bridge;
extension type _WebBle(JSObject _) implements JSObject {
  external void listen(JSFunction callback);
  external void cancel();
  external JSPromise<JSAny?> invoke(String method, JSAny? args);
}

EegTransport createBrowserEegTransport() => BrowserEegTransport();

class BrowserEegTransport implements PreviewCapableTransport {
  late final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast(
        onListen: () => _bridge.listen(
          ((JSObject event) {
            _controller.add(Map<String, dynamic>.from(event.dartify() as Map));
          }).toJS,
        ),
        onCancel: () => _bridge.cancel(),
      );
  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;
  Future<Object?> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async => (await _bridge.invoke(method, args.jsify()).toDart).dartify();
  Future<Map<String, dynamic>> _status(String method) async =>
      Map<String, dynamic>.from(await _invoke(method) as Map);
  @override
  Future<Map<String, dynamic>> access() => _status('access');
  @override
  Future<Map<String, dynamic>> requestAccess() => _status('requestAccess');
  @override
  Future<Map<String, dynamic>> enableBluetooth() => _status('enableBluetooth');
  @override
  Future<void> scan() async {
    await _invoke('scan');
  }

  @override
  Future<void> stopScan() async {
    await _invoke('stopScan');
  }

  @override
  Future<void> connect(String address) async {
    await _invoke('connect', {'address': address});
  }

  @override
  Future<void> disconnect() async {
    await _invoke('disconnect');
  }

  @override
  Future<void> openSettings({bool location = false}) async {
    await _invoke('openSettings');
  }

  @override
  Future<String?> startRecording() async =>
      await _invoke('startRecording') as String?;
  @override
  Future<String?> stopRecording() async =>
      await _invoke('stopRecording') as String?;
  @override
  Future<bool> exportRecording() async =>
      await _invoke('exportRecording') == true;
  @override
  Future<void> setPreview(bool enabled) async {
    await _invoke('setPreview', {'enabled': enabled});
  }
}
