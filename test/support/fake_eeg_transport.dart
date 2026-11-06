import 'dart:async';
import 'dart:typed_data';
import 'package:neurox/data/devices/eeg_transport.dart';
import 'package:neurox/data/devices/kseeg_protocol.dart';

class FakeEegTransport implements EegTransport {
  final bus = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final calls = <String>[];
  bool grantPermission = true;
  bool enabled = true;
  int session = 0;
  String? address;
  Map<String, dynamic> status = {
    'supported': true,
    'enabled': true,
    'permissionsGranted': true,
    'permanentlyDenied': false,
    'locationRequired': false,
    'locationEnabled': true,
  };
  @override
  Stream<Map<String, dynamic>> get events => bus.stream;
  void emit(Map<String, dynamic> event) => bus.add(event);
  void packet(String kind, Uint8List bytes, DateTime at, {int? fromSession}) =>
      emit({
        'type': 'packet',
        'uuid': KseegProtocol.uuids[kind],
        'bytes': bytes,
        'receivedAt': at.millisecondsSinceEpoch,
        'session': fromSession ?? session,
        'address': address,
      });
  @override
  Future<Map<String, dynamic>> access() async => status;
  @override
  Future<Map<String, dynamic>> requestAccess() async {
    calls.add('requestAccess');
    status = {...status, 'permissionsGranted': grantPermission};
    return status;
  }

  @override
  Future<Map<String, dynamic>> enableBluetooth() async {
    calls.add('enableBluetooth');
    status = {...status, 'enabled': enabled};
    return status;
  }

  @override
  Future<void> scan() async {
    calls.add('scan');
    emit({'type': 'scan', 'scanning': true});
  }

  @override
  Future<void> stopScan() async {
    calls.add('stopScan');
    emit({'type': 'scan', 'scanning': false});
  }

  @override
  Future<void> connect(String value) async {
    calls.add('connect');
    address = value;
    session++;
    emit({
      'type': 'connection',
      'state': 'connecting',
      'address': address,
      'session': session,
    });
    emit({
      'type': 'connection',
      'state': 'ready',
      'address': address,
      'session': session,
      'mtu': 247,
      'message': '已连接并订阅，等待真实脑电数据',
    });
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    emit({
      'type': 'connection',
      'state': 'disconnected',
      'address': address,
      'session': session,
    });
  }

  @override
  Future<void> openSettings({bool location = false}) async {
    calls.add(location ? 'locationSettings' : 'settings');
  }

  @override
  Future<String?> startRecording() async {
    calls.add('startRecording');
    return 'test.jsonl';
  }

  @override
  Future<String?> stopRecording() async {
    calls.add('stopRecording');
    return 'test.jsonl';
  }

  @override
  Future<bool> exportRecording() async {
    calls.add('exportRecording');
    return true;
  }

  Future<void> close() => bus.close();
}

const testDeviceAddress = 'AA:BB:CC:DD:EE:FF';
Uint8List rawPacket({int lead = 0}) {
  final b = Uint8List(69);
  b[3] = 111;
  b[68] = lead;
  final data = ByteData.sublistView(b);
  for (var i = 0; i < 16; i++) {
    data.setUint16(4 + i * 4, 30000 + i * 100);
    data.setUint16(6 + i * 4, 32000 - i * 100);
  }
  return b;
}
