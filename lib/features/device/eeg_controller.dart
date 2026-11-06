import 'package:neurox/l10n/app_language.dart';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../data/devices/eeg_transport.dart';
import '../../data/devices/kseeg_protocol.dart';

enum NotificationHealth { disconnected, waiting, normal, stale, invalid }

class EegDevice {
  const EegDevice({
    required this.address,
    required this.name,
    required this.rssi,
    required this.advertisesService,
  });
  factory EegDevice.fromEvent(Map<String, dynamic> value) => EegDevice(
    address: value['address'] as String,
    name: value['name'] as String? ?? '',
    rssi: value['rssi'] as int?,
    advertisesService: value['advertisesService'] == true,
  );
  final String address;
  final String name;
  final int? rssi;
  final bool advertisesService;
  String get label => name.isEmpty ? tr('未命名蓝牙设备') : name;
  bool get likelyEeg => advertisesService || name.toUpperCase().contains('EEG');
}

class RawSampleBatch {
  RawSampleBatch(
    this.channel1,
    this.channel2,
    this.at,
    this.connection,
    this.address,
    this.simulated, {
    this.contact,
    this.leadByte,
  });
  final List<double> channel1, channel2;
  final DateTime at;
  final int? connection;
  final String? address;
  final bool simulated;
  final bool? contact;
  final int? leadByte;
}

class EegController extends ChangeNotifier {
  EegController(this.transport, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final EegTransport transport;
  final _rawSamples = StreamController<RawSampleBatch>.broadcast(sync: true);
  Stream<RawSampleBatch> get rawSamples => _rawSamples.stream;
  final DateTime Function() _clock;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _repaint;
  bool _disposed = false;
  bool _initialized = false;
  bool _dirty = false;
  bool supported = true;
  bool enabled = false;
  bool permissionsGranted = false;
  bool permanentlyDenied = false;
  bool locationRequired = false;
  bool locationEnabled = true;
  bool scanning = false;
  bool busy = false;
  bool recording = false;
  String recordingState = 'idle';
  bool displayPaused = false;
  String? recordingName;
  String? _error;
  String? get error => _error == null ? null : trSource(_error!);
  set error(String? value) => _error = value;
  String phase = 'disconnected';
  String _message = '开启设备电源，搜索并选择 KSEEG102';
  String get message => trSource(_message);
  set message(String value) => _message = value;
  EegDevice? selected;
  int? session;
  int? mtu;
  bool browserPicker = false;
  bool previewMode = false;
  bool pythonBridge = false;
  bool localAlgorithms = false;
  String platform = 'android';
  bool get hasAlgorithms => pythonBridge || localAlgorithms;
  bool showFiltered = false;
  Map<String, dynamic> algorithmValues = {};
  DateTime? algorithmAt;
  bool get algorithmStale =>
      algorithmAt == null ||
      _clock().difference(algorithmAt!) >= const Duration(seconds: 5);
  bool get canPreview => transport is PreviewCapableTransport && !pythonBridge;
  int packetCount = 0;
  int rawPacketCount = 0;
  int sampleCount = 0;
  int parseErrors = 0;
  int? power;
  bool? lead;
  int? leadByte;
  DateTime? connectedAt;
  DateTime? firstRawAt;
  DateTime? lastRawAt;
  DateTime? featureAt;
  DateTime? frequencyAt;
  Map<String, int> features = {};
  Map<String, int> frequencies = {};
  final Map<String, DateTime> _notificationAt = {};
  final Map<String, Map<String, Object>> _notifications = {};
  final Set<String> _notificationFailures = {};

  NotificationHealth notificationHealth(String kind) {
    if (!connected) return NotificationHealth.disconnected;
    if (_notificationFailures.contains(kind)) return NotificationHealth.invalid;
    final at = _notificationAt[kind];
    if (at == null) return NotificationHealth.waiting;
    return _clock().difference(at) >= Duration(seconds: kind == 'raw' ? 3 : 5)
        ? NotificationHealth.stale
        : NotificationHealth.normal;
  }

  bool hasNotification(String kind) =>
      _notificationAt.containsKey(kind) || _notificationFailures.contains(kind);
  Object? notificationValue(String kind, String key) {
    if (notificationHealth(kind) != NotificationHealth.normal) return null;
    final value = _notifications[kind]?[key];
    return value is List ? (value.isEmpty ? null : value.last) : value;
  }

  String lastHex = '';
  int lastPacketLength = 0;
  final Map<String, EegDevice> _devices = {};
  final ListQueue<double> _ch1 = ListQueue();
  final ListQueue<double> _ch2 = ListQueue();
  final ListQueue<double> _filtered1 = ListQueue();
  final ListQueue<double> _filtered2 = ListQueue();
  final ListQueue<String> _log = ListQueue();
  List<double> get rawChannel1 => List<double>.unmodifiable(_ch1);
  List<double> get rawChannel2 => List<double>.unmodifiable(_ch2);
  List<double> channel1 = [];
  List<double> channel2 = [];
  List<String> get logs => _log.toList().reversed.map(trSource).toList();
  String get diagnosticReport => [
    'NeuroX KSEEG102 · ${previewMode ? '模拟' : '真实设备'}',
    '设备：${selected?.label ?? '未选择'}',
    '状态：$phase · $dataStatus',
    '消息：$message',
    '全部通知：$packetCount；有效 raw：$rawPacketCount；解析失败：$parseErrors',
    '原始包长：$lastPacketLength；每通道点数：$sampleCount',
    if (error != null) '错误：$error',
    if (lastHex.isNotEmpty) '最后 raw：$lastHex',
    ...logs,
  ].map(trSource).join('\n');
  List<EegDevice> get devices {
    final values = _devices.values.toList();
    values.sort((a, b) {
      final priority = (b.likelyEeg ? 1 : 0).compareTo(a.likelyEeg ? 1 : 0);
      return priority != 0
          ? priority
          : (b.rssi ?? -999).compareTo(a.rssi ?? -999);
    });
    return values;
  }

  bool get connected => phase == 'ready';
  bool get connecting =>
      ['connecting', 'discovering', 'configuring'].contains(phase);
  bool get stale =>
      connected &&
      lastRawAt != null &&
      _clock().difference(lastRawAt!) >= const Duration(seconds: 3);
  bool get waitingTimedOut =>
      connected &&
      lastRawAt == null &&
      connectedAt != null &&
      _clock().difference(connectedAt!) >= const Duration(seconds: 5);
  bool get receiving => connected && lastRawAt != null && !stale;
  bool get metricsStale =>
      featureAt == null ||
      _clock().difference(featureAt!) >= const Duration(seconds: 5);
  bool get spectrumStale =>
      frequencyAt == null ||
      _clock().difference(frequencyAt!) >= const Duration(seconds: 5);
  double? get receivedSamplesPerSecond {
    if (firstRawAt == null || lastRawAt == null || rawPacketCount < 2) {
      return null;
    }
    final milliseconds = lastRawAt!.difference(firstRawAt!).inMilliseconds;
    return milliseconds > 0 ? (sampleCount - 16) * 1000 / milliseconds : null;
  }

  String get dataStatus => trSource(_dataStatus);
  String get _dataStatus => !connected
      ? '未采集'
      : lastRawAt == null
      ? waitingTimedOut
            ? '未收到原始数据'
            : '等待原始数据'
      : stale
      ? '数据已停滞'
      : '正在接收';
  String get lastArrival => trSource(_lastArrival);
  String get _lastArrival {
    if (lastRawAt == null) return '尚未收到';
    return '${(_clock().difference(lastRawAt!).inMilliseconds / 1000).clamp(0, double.infinity).toStringAsFixed(1)} 秒前';
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _subscription = transport.events.listen(
      _onEvent,
      onError: (Object e) {
        supported = false;
        error = _describe(e);
        _notify();
      },
    );
    _repaint = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_dirty && !displayPaused) {
        channel1 = (showFiltered ? _filtered1 : _ch1).toList();
        channel2 = (showFiltered ? _filtered2 : _ch2).toList();
        _dirty = false;
      }
      if (connected || scanning || busy) _notify();
    });
    await refreshAccess();
  }

  Future<void> refreshAccess() async {
    try {
      _access(await transport.access());
    } catch (e) {
      supported = false;
      error = _describe(e);
    }
    _notify();
  }

  void _access(Map<String, dynamic> value) {
    if (value['localAlgorithms'] == true && !localAlgorithms) {
      showFiltered = true;
    }
    localAlgorithms = value['localAlgorithms'] == true;
    platform = value['platform'] as String? ?? platform;
    pythonBridge = value['pythonBridge'] == true;
    browserPicker = value['browserPicker'] == true;
    previewMode = value['simulated'] == true;
    supported = value['supported'] == true;
    enabled = value['enabled'] == true;
    permissionsGranted = value['permissionsGranted'] == true;
    permanentlyDenied = value['permanentlyDenied'] == true;
    locationRequired = value['locationRequired'] == true;
    locationEnabled = value['locationEnabled'] != false;
  }

  Future<void> _action(Future<void> Function() action) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } catch (e) {
      error = _describe(e);
      _addLog(error!);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> _prepare() async {
    _access(await transport.requestAccess());
    if (!permissionsGranted) {
      error = permanentlyDenied
          ? '蓝牙权限已被拒绝，请在系统设置中允许本应用使用蓝牙。'
          : '需要蓝牙权限才能搜索和连接设备，可再次授权。';
      return false;
    }
    if (!enabled) _access(await transport.enableBluetooth());
    if (!enabled) {
      error = '蓝牙仍未开启，请打开手机蓝牙后重试。';
      return false;
    }
    if (locationRequired && !locationEnabled) {
      error = '此 Android 版本需要开启定位服务才能扫描 BLE。';
      return false;
    }
    return true;
  }

  Future<void> scan() => _action(() async {
    if (browserPicker) {
      _devices.clear();
      scanning = true;
      message = previewMode ? '正在搜索模拟设备…' : '请在浏览器弹窗中选择并授权 KSEEG102';
      try {
        await transport.scan();
      } finally {
        scanning = false;
      }
      return;
    }
    if (!await _prepare()) return;
    if (connected || connecting) {
      error = '请先断开设备再搜索。';
      return;
    }
    _devices.clear();
    scanning = true;
    message = '正在搜索附近设备（10 秒）…';
    try {
      await transport.scan();
    } catch (_) {
      scanning = false;
      rethrow;
    }
  });
  Future<void> stopScan() => _action(() async {
    await transport.stopScan();
    scanning = false;
  });
  Future<void> connect(EegDevice device) => _action(() async {
    if (!browserPicker && !await _prepare()) return;
    await transport.stopScan();
    scanning = false;
    _clearSession();
    selected = device;
    phase = 'connecting';
    message = '正在连接 ${device.label}…';
    try {
      await transport.connect(device.address);
    } catch (_) {
      phase = 'error';
      rethrow;
    }
  });
  Future<void> disconnect() => _action(() async {
    await transport.disconnect();
    phase = 'disconnected';
    recording = false;
    _clearLiveValues();
    message = '已断开连接，采集已停止';
  });
  Future<void> settings({bool location = false}) =>
      _action(() => transport.openSettings(location: location));
  Future<void> toggleRecording() => _action(() async {
    try {
      if (recording) {
        recordingState = 'saving';
        recordingName = await transport.stopRecording();
        recording = false;
        recordingState = 'saved';
      } else {
        recordingState = 'creating';
        recordingName = await transport.startRecording();
        recording = connected;
        recordingState = recording ? 'recording' : 'interrupted';
      }
    } catch (_) {
      recordingState = 'save_failed';
      rethrow;
    }
  });
  Future<void> exportRecording() => _action(() async {
    if (recording) {
      error = '请先停止记录再导出。';
      return;
    }
    final saved = await transport.exportRecording();
    if (saved) _addLog('记录已导出');
  });
  Future<void> switchPreview() => _action(() async {
    final bridge = transport;
    if (bridge is! PreviewCapableTransport) return;
    await bridge.setPreview(!previewMode);
    _devices.clear();
    selected = null;
    _clearSession();
    phase = 'disconnected';
    message = '选择设备，开始连接';
    _access(await bridge.access());
  });
  void toggleDisplay() {
    displayPaused = !displayPaused;
    if (!displayPaused) {
      channel1 = (showFiltered ? _filtered1 : _ch1).toList();
      channel2 = (showFiltered ? _filtered2 : _ch2).toList();
      _dirty = false;
    }
    _notify();
  }

  void setFiltered(bool enabled) {
    showFiltered = enabled;
    if (!displayPaused) {
      channel1 = (enabled ? _filtered1 : _ch1).toList();
      channel2 = (enabled ? _filtered2 : _ch2).toList();
    }
    _notify();
  }

  /// Called only after a different local identity authenticates, with capture stopped.
  void clearUserPresentation() {
    _clearSession();
    _devices.clear();
    _log.clear();
    selected = null;
    recordingName = null;
    recordingState = 'idle';
    recording = false;
    error = null;
    phase = 'disconnected';
    message = '开启设备电源，搜索并选择 KSEEG102';
    _notify();
  }

  void clearError() {
    error = null;
    _notify();
  }

  void _clearSession() {
    _clearLiveValues();
    session = null;
    connectedAt = null;
    firstRawAt = null;
    packetCount = 0;
    rawPacketCount = 0;
    sampleCount = 0;
    parseErrors = 0;
    displayPaused = false;
    lastHex = '';
    lastPacketLength = 0;
  }

  void _clearLiveValues() {
    _notificationAt.clear();
    _notifications.clear();
    _notificationFailures.clear();
    _filtered1.clear();
    _filtered2.clear();
    algorithmValues = {};
    algorithmAt = null;
    _ch1.clear();
    _ch2.clear();
    channel1 = [];
    channel2 = [];
    _dirty = false;
    power = null;
    lead = null;
    leadByte = null;
    features = {};
    frequencies = {};
    lastRawAt = null;
    featureAt = null;
    frequencyAt = null;
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed) return;
    switch (event['type']) {
      case 'algorithmReset':
        _clearLiveValues();
        firstRawAt = null;
        connectedAt = connected ? _clock() : null;
        packetCount = 0;
        rawPacketCount = 0;
        sampleCount = 0;
        parseErrors = 0;
        _notify();
      case 'adapter':
        _access(event);
        _notify();
      case 'device':
        final device = EegDevice.fromEvent(event);
        _devices[device.address] = device;
        _notify();
      case 'scan':
        scanning = event['scanning'] == true;
        if (!scanning && !connected && !connecting) {
          message = '搜索完成，共 ${_devices.length} 个设备';
        }
        _notify();
      case 'connection':
        final address = event['address'] as String?;
        if (address != null &&
            selected != null &&
            address != selected!.address) {
          return;
        }
        phase = event['state'] as String;
        message = event['message'] as String? ?? phase;
        mtu = event['mtu'] as int?;
        if (event['session'] is int) session = event['session'] as int;
        if (phase == 'ready') connectedAt ??= _clock();
        if (phase == 'error' || phase == 'disconnected') {
          recording = false;
          _clearLiveValues();
          if (phase == 'error') error = message;
        }
        _addLog(message);
        _notify();
      case 'packet':
        _packet(event);
      case 'algorithm':
        if ((!connected && !connecting) ||
            event['session'] != session ||
            (selected != null && event['address'] != selected!.address)) {
          return;
        }
        for (final (key, buffer) in [
          ('filtered_1', _filtered1),
          ('filtered_2', _filtered2),
        ]) {
          for (final value in event[key] as List? ?? []) {
            if (value is num && value.isFinite) buffer.add(value.toDouble());
          }
          while (buffer.length > 1024) {
            buffer.removeFirst();
          }
        }
        final updates = event['updates'] as List? ?? [];
        if (updates.isNotEmpty) {
          algorithmValues = Map<String, dynamic>.from(updates.last as Map);
          algorithmAt = DateTime.fromMillisecondsSinceEpoch(
            event['receivedAt'] as int,
          );
        }
        _dirty = true;
      case 'recording':
        recording = event['active'] == true;
        recordingState =
            event['state'] as String? ??
            (recording ? 'recording' : recordingState);
        recordingName = event['name'] as String? ?? recordingName;
        _notify();
      case 'error':
        error = event['message'] as String? ?? '未知错误';
        _addLog(error!);
        _notify();
      case 'log':
        _addLog(event['message'] as String? ?? '');
        _notify();
    }
  }

  void _packet(Map<String, dynamic> event) {
    if (!connecting && !connected) return;
    if (session != null && event['session'] != session) return;
    if (selected != null && event['address'] != selected!.address) return;
    packetCount++;
    String? kind;
    try {
      final value = event['bytes'];
      final bytes = value is Uint8List
          ? value
          : Uint8List.fromList((value as List).cast<int>());
      kind = KseegProtocol.kindFor(event['uuid'] as String);
      if (kind == 'raw') {
        lastPacketLength = bytes.length;
        lastHex = bytes
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join(' ');
      }
      final data = KseegProtocol.parse(
        kind,
        bytes,
        leadConvention: localAlgorithms && platform == 'ios'
            ? LeadConvention.windows
            : LeadConvention.android,
      );
      final at = DateTime.fromMillisecondsSinceEpoch(
        event['receivedAt'] as int,
      );
      _notifications[kind] = Map<String, Object>.unmodifiable(data);
      _notificationAt[kind] = at;
      _notificationFailures.remove(kind);
      switch (kind) {
        case 'raw':
          _rawSamples.add(
            RawSampleBatch(
              List<double>.unmodifiable(data['channel_1'] as List<double>),
              List<double>.unmodifiable(data['channel_2'] as List<double>),
              at,
              session,
              selected?.address,
              previewMode,
              contact: data['lead'] as bool,
              leadByte: bytes.last,
            ),
          );
          rawPacketCount++;
          sampleCount += 16;
          firstRawAt ??= at;
          lastRawAt = at;
          power = data['power'] as int;
          lead = data['lead'] as bool;
          leadByte = bytes.last;
          _ch1.addAll(data['channel_1'] as List<double>);
          _ch2.addAll(data['channel_2'] as List<double>);
          while (_ch1.length > 1024) {
            _ch1.removeFirst();
            _ch2.removeFirst();
          }
          _dirty = true;
        case 'feature':
          features = data.cast<String, int>();
          featureAt = at;
        case 'frequency':
          frequencies = data.cast<String, int>();
          frequencyAt = at;
      }
    } catch (e) {
      parseErrors++;
      if (kind != null) _notificationFailures.add(kind);
      _addLog('通知解析失败：$e');
      _notify();
    }
  }

  void _addLog(String value) {
    final time = _clock().toIso8601String().substring(11, 19);
    _log.addLast('$time  $value');
    while (_log.length > 80) {
      _log.removeFirst();
    }
  }

  String _describe(Object error) {
    if (error is MissingPluginException) return '当前平台尚未接入设备蓝牙，请在支持的平台真机运行。';
    if (error is PlatformException) {
      return error.message ?? '蓝牙操作失败（${error.code}）';
    }
    return error.toString();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _repaint?.cancel();
    unawaited(_rawSamples.close());
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
