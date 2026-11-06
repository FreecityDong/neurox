import CoreBluetooth
import Flutter
import UIKit
import AudioToolbox
import Darwin

/// Native BLE and recording continue for an explicitly started diagnostic while locked.
final class EegBleBridge: NSObject, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let serviceID = CBUUID(string: "8653000a-43e6-47b7-9cb0-5fc21d4ae340")
  private let rawID = CBUUID(string: "8653000b-43e6-47b7-9cb0-5fc21d4ae340")
  private let writeID = CBUUID(string: "8653000c-43e6-47b7-9cb0-5fc21d4ae340")
  private let frequencyID = CBUUID(string: "8653000e-43e6-47b7-9cb0-5fc21d4ae340")
  private let featureID = CBUUID(string: "8653000d-43e6-47b7-9cb0-5fc21d4ae340")
  private var central: CBCentralManager?
  private var sink: FlutterEventSink?
  private var devices: [String: CBPeripheral] = [:]
  private var active: CBPeripheral?
  private var retiring = Set<UUID>()
  private var session = 0
  private var address = ""
  private var phase = "disconnected"
  private var scanning = false
  private var scanTimer: DispatchWorkItem?
  private var stepTimer: DispatchWorkItem?
  private var permissionResult: FlutterResult?
  private var subscriptions: [CBCharacteristic] = []
  private var control: CBCharacteristic?
  private var commandIndex = 0
  private var awaitingWrite = false
  private var recording = false
  private var recordKind = "diagnostic"
  private var taskID: String?
  private var lastRawAt: Date?
  private var lastURL: URL?
  private var exporting = false
  private var sequence = 0
  private var rawNotifications = 0
  private let io = DispatchQueue(label: "neurox.eeg.recording")
  private let store: LocalStore
  private let notifications: AppNotifications
  private let diagnostics: CaptureDiagnostics
  private var notificationScope = UUID().uuidString
  private var wasBackgrounded = false
  private var recordID: String?
  private var lastRecordID: String?
  private var recordPackets = 0
  private var recordSamples = 0
  private var recordFailure: String?
  private var closing = false
  private var writer: FileHandle? // Only accessed on io.

  init(messenger: FlutterBinaryMessenger? = nil, store: LocalStore, notifications: AppNotifications, observeLifecycle: Bool = true, diagnostics: CaptureDiagnostics = CaptureDiagnostics()) {
    self.store = store
    self.notifications = notifications
    self.diagnostics = diagnostics
    super.init()
    store.isRecording = { [weak self] in self?.recording == true || self?.closing == true }
    store.beforeLock = { [weak self] completion in
      guard let self = self else { completion(nil); return }
      self.stopRecording({ value in
        if let error = value as? FlutterError { completion(LocalFailure(error.message ?? "记录保存失败")) }
        else { self.disconnect("账号操作，采集已停止"); completion(nil) }
      })
    }
    if let messenger = messenger {
      FlutterMethodChannel(name: "neurox/eeg/methods", binaryMessenger: messenger)
        .setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
      FlutterEventChannel(name: "neurox/eeg/events", binaryMessenger: messenger).setStreamHandler(self)
    }
    guard observeLifecycle else { return }
    NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(foregrounded),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  deinit { NotificationCenter.default.removeObserver(self) }
  @objc func backgrounded() {
    wasBackgrounded = true
    updateDiagnosticContext()
    if let id = taskID { try? store.invalidateBaseline(id: id, reason: "background");try? store.interruptMonitoring(id:id,reason:"background") }
    // Retain in-memory identity and recorder ownership across app switches.
    stopScan()
    if recording {
      appendRecord(["type": "lifecycle", "state": "background", "receivedAt": Int(Date().timeIntervalSince1970 * 1000),
        "note": "原生原始数据继续；后台Dart算法不保证执行"])
      // This is a short drain of queued IO, not a perpetual background task.
      var token = UIBackgroundTaskIdentifier.invalid
      token = UIApplication.shared.beginBackgroundTask(withName: "NeuroX flush") {
        if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid }
      }
      io.async {
        try? self.synchronizeWriter()
        DispatchQueue.main.async {
          if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid }
        }
      }
    } else { disconnect("未开始诊断记录，后台停止连接") }
  }
  @objc func foregrounded() {
    guard wasBackgrounded else { return }
    wasBackgrounded = false
    updateDiagnosticContext()
    emit("algorithmReset")
    if active != nil {
      emit("connection", ["state": phase, "message": "已返回前台，请核对数据到达状态", "address": address, "session": session])
      emit("recording", ["active": recording, "name": lastURL?.path ?? "", "state": recording ? "recording" : closing ? "saving" : "interrupted"])
    }
  }
  private func issue(_ kind: String, _ body: String) {
    notifications.post(AppNotice(kind: kind, scope: notificationScope, title: "采集异常", body: body))
  }

  private func manager() -> CBCentralManager {
    if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
    return central!
  }
  private func access() -> [String: Any] {
    let authorization = CBManager.authorization
    return ["platform": "ios", "supported": central?.state != .unsupported,
      "enabled": central?.state == .poweredOn,
      "permissionsGranted": authorization == .allowedAlways,
      "permanentlyDenied": authorization == .denied || authorization == .restricted,
      "locationRequired": false, "locationEnabled": true]
  }
  private func emit(_ type: String, _ fields: [String: Any] = [:]) {
    var event = fields; event["type"] = type
    if ["connection", "error", "log", "recording"].contains(type) {
      print("NeuroX BLE \(type): \(fields)"); fflush(stdout)
    }
    sink?(event)
  }
  private func updateDiagnosticContext() {
    diagnostics.updateContext(phase: phase, recording: recording, foreground: UIApplication.shared.applicationState == .active, connection: session)
  }
  private func state(_ value: String, _ message: String) {
    phase = value
    updateDiagnosticContext(); diagnostics.record("link_state")
    emit("connection", ["state": value, "message": message, "address": address, "session": session,
      "rawNotifications": rawNotifications])
  }
  private func log(_ message: String) { emit("log", ["message": message]) }
  private func armTimeout(_ seconds: Double, _ message: String) {
    stepTimer?.cancel()
    let token = session
    let item = DispatchWorkItem { [weak self] in
      guard let self = self, self.session == token else { return }
      self.fail(message)
    }
    stepTimer = item
    DispatchQueue.main.asyncAfter(deadline: .now()+seconds, execute: item)
  }
  private func failure(_ text: String, _ result: FlutterResult) {
    result(FlutterError(code: "eeg", message: text, details: nil))
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if !["access", "recordAlgorithm"].contains(call.method) && !store.authorized() {
      failure("请先重新登录", result); return
    }
    switch call.method {
    case "access": result(access())
    case "requestAccess":
      guard permissionResult == nil else { failure("正在等待蓝牙授权", result); return }
      permissionResult = result
      let value = manager()
      if value.state != .unknown && value.state != .resetting { resolvePermission() }
    case "enableBluetooth": _ = manager(); result(access())
    case "openSettings", "openLocationSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      result(nil)
    case "scan":
      guard manager().state == .poweredOn && CBManager.authorization == .allowedAlways else {
        failure("请允许蓝牙权限，并在系统中开启蓝牙", result); return
      }
      guard active == nil else { failure("请先断开当前设备", result); return }
      stopScan(); devices.removeAll(); scanning = true
      manager().scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
      emit("scan", ["scanning": true])
      let timer = DispatchWorkItem { [weak self] in self?.stopScan() }
      scanTimer = timer; DispatchQueue.main.asyncAfter(deadline: .now()+15, execute: timer)
      result(nil)
    case "stopScan": stopScan(); result(nil)
    case "connect":
      guard manager().state == .poweredOn, let id = args["address"] as? String,
            let peripheral = devices[id] else { failure("请重新搜索并选择头带", result); return }
      guard active == nil && !retiring.contains(peripheral.identifier) else {
        failure("已有连接或断开操作正在进行，请稍后重试", result); return
      }
      stopScan(); session += 1; address = id; active = peripheral; rawNotifications = 0
      notificationScope = UUID().uuidString
      subscriptions.removeAll(); control = nil; commandIndex = 0; awaitingWrite = false
      peripheral.delegate = self
      state("connecting", "正在连接头带…")
      manager().connect(peripheral)
      armTimeout(20, "连接超时，尚未收到脑电数据")
      result(nil)
    case "disconnect": disconnect("已主动断开，采集已停止"); result(nil)
    case "startRecording": startRecording(result)
    case "stopRecording":
      if taskID != nil {failure("任务进行中，请在任务页结束并保存。",result)}else{stopRecording(result)}
    case "baselineStart": baselineStart(args, result)
    case "learningStart": learningStart(args,result)
    case "learningRefresh": learningRefresh(args,result)
    case "baselineRetry": baselineRetry(args, result)
    case "baselineUpdate": baselineUpdate(args, result)
    case "baselineFinish": baselineFinish(args, result)
    case "monitorStart":
      do {
        try checkBaselineDevice()
        guard recording,recordID == args["id"] as? String,taskID == args["id"] as? String else {throw LocalFailure("原始记录未就绪，不能开始监测。")}
        try store.startMonitoring(args,context:baselineContext());appendRecord(["type":"monitor_start","payload":args]);flushMonitor(result)
      } catch {failure(error.localizedDescription,result)}
    case "monitorUpdate":
      do {
        let accepted=try store.saveMonitoring(args)
        if accepted, recording,recordID == args["id"] as? String {appendRecord(["type":"monitor_update","payload":args]);flushMonitor(result)}
        else {result(["accepted":accepted])}
      } catch {failure(error.localizedDescription,result)}
    case "monitorStatus":
      do {result(try store.monitorStatus(id:args["id"] as? String ?? ""))}catch{failure(error.localizedDescription,result)}
    case "monitorAlert":
      do {
        guard UIApplication.shared.applicationState == .active,!wasBackgrounded,recording,recordID == args["id"] as? String,let last=lastRawAt,Date().timeIntervalSince(last)<3 else {result(["accepted":false,"reason":"not_active_or_raw_unavailable"]);return}
        let accepted=try store.requestMonitorAlert(id:args["id"] as? String ?? "",sequence:args["sequence"] as? Int ?? 0)
        guard accepted else {result(["accepted":false,"reason":"state_changed_or_cooldown"]);return}
        let options=args["feedback"] as? [String:Any] ?? [:]
        notifications.deliverFeedback(options,kind:"state",scope:args["id"] as? String ?? "task",title:"专注状态变化",body:"专注指标持续低于个人参考，可打开 NeuroX 查看记录。") {channels in
          result(["accepted":true,"channels":channels])
        }
      } catch {failure(error.localizedDescription,result)}
    case "monitorFinish": monitorFinish(args,result)
    case "exportLearningReport":
      do {
        guard !recording, !closing, !exporting,
          let bytes=args["png"] as? FlutterStandardTypedData, bytes.data.count<=20*1024*1024,
          let image=UIImage(data:bytes.data),image.size.width<=2048,image.size.height<=7000 else {throw LocalFailure("报告图片无法导出，请结束记录后重试。")}
        export(try store.learningReportURL(id:args["id"] as? String ?? "",png:bytes.data),result)
      } catch {failure(error.localizedDescription,result)}
    case "exportTaskSummary":
      do {export(try store.summaryURL(id:args["id"] as? String ?? ""),result)}catch{failure(error.localizedDescription,result)}
    case "recordingStatus":
      result(["active": recording, "name": lastURL?.path ?? "", "state": recording ? "recording" : closing ? "saving" : "idle"])
    case "recordAlgorithm":
      if UIApplication.shared.applicationState == .active && store.authorized() && recording && (args["session"] as? Int) == session && (args["address"] as? String) == address {
        appendRecord(args.merging(["source": "host/Dart port of KSEEG102_Python_Mac"]) { _, new in new })
      }
      result(nil)
    case "exportRecording":
      do {
        guard let id = args["id"] as? String ?? lastRecordID else { throw LocalFailure("请从历史选择记录") }
        export(try store.exportURL(id: id), result)
      } catch { failure(error.localizedDescription, result) }
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func resolvePermission() {
    let result = permissionResult; permissionResult = nil; result?(access())
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; emit("adapter", access()); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    disconnect("页面已关闭，采集已停止"); sink = nil; return nil
  }
  private func stopScan() {
    scanTimer?.cancel(); scanTimer = nil
    central?.stopScan(); scanning = false; emit("scan", ["scanning": false])
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    updateDiagnosticContext(); diagnostics.record("adapter_state", fields: ["adapterState": central.state.rawValue])
    emit("adapter", access())
    if central.state != .unknown && central.state != .resetting { resolvePermission() }
    if central.state != .poweredOn && active != nil { issue("connection_lost", "系统蓝牙不可用，采集已停止。请打开 NeuroX 检查已保存部分。"); disconnect("系统蓝牙不可用，采集已停止") }
  }
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard scanning else { return }
    let id = peripheral.identifier.uuidString
    devices[id] = peripheral
    let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    emit("device", ["address": id,
      "name": advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "",
      "rssi": RSSI.intValue == 127 ? NSNull() : RSSI,
      "advertisesService": services.contains(serviceID)])
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral === active && phase == "connecting" else { return }
    state("discovering", "已建立链路，正在发现 EEG 服务…")
    armTimeout(15, "EEG服务发现超时")
    peripheral.discoverServices([serviceID])
  }
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard peripheral === active else { return }
    updateDiagnosticContext(); diagnostics.record("connect_failed", error: error)
    fail("连接失败：\(error?.localizedDescription ?? "未知系统错误")")
  }
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    retiring.remove(peripheral.identifier)
    guard peripheral === active else { return }
    updateDiagnosticContext(); diagnostics.record("system_disconnect", error: error)
    issue("connection_lost", "设备连接中断，采集已停止。请打开 NeuroX 检查已保存部分。")
    let message = "设备已断开\(error.map { "：\($0.localizedDescription)" } ?? "")"
    cleanActive(cancel: false); state("disconnected", message)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peripheral === active && phase == "discovering" else { return }
    if let error = error { fail("服务发现失败：\(error.localizedDescription)", error: error); return }
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
      fail("未找到KSEEG102 F-version EEG服务"); return
    }
    peripheral.discoverCharacteristics([rawID, frequencyID, featureID, writeID], for: service)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peripheral === active && phase == "discovering" else { return }
    if let error = error { fail("特征发现失败：\(error.localizedDescription)", error: error); return }
    let chars = service.characteristics ?? []
    guard let raw = chars.first(where: { $0.uuid == rawID }), raw.properties.contains(.notify) else {
      fail("未找到可通知的原始脑电特征"); return
    }
    control = chars.first(where: { $0.uuid == writeID })
    guard let control = control,
          control.properties.contains(.write) || control.properties.contains(.writeWithoutResponse) else {
      fail("缺少SDK初始化控制特征"); return
    }
    subscriptions = [raw]
    for id in [frequencyID, featureID] {
      if let char = chars.first(where: { $0.uuid == id }), char.properties.contains(.notify) { subscriptions.append(char) }
      else { log("设备未提供可订阅的可选特征：\(id.uuidString)") }
    }
    state("configuring", "正在按Python流程订阅脑电与指标…")
    subscribeNext()
  }
  private func subscribeNext() {
    guard let peripheral = active else { return }
    if let char = subscriptions.first {
      armTimeout(10, "订阅通知超时：\(char.uuid.uuidString)")
      peripheral.setNotifyValue(true, for: char)
    } else { commandIndex = 0; writeNext() }
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === active && phase == "configuring", subscriptions.first?.uuid == characteristic.uuid else { return }
    if let error = error { fail("通知订阅失败：\(error.localizedDescription)", error: error); return }
    guard characteristic.isNotifying else { fail("通知未开启：\(characteristic.uuid)"); return }
    log("订阅完成：\(characteristic.uuid.uuidString)")
    subscriptions.removeFirst(); subscribeNext()
  }
  private func writeNext() {
    guard let peripheral = active, let control = control, phase == "configuring" else { return }
    if commandIndex == 2 {
      stepTimer?.cancel(); stepTimer = nil
      state("ready", "订阅和初始化完成，等待真实脑电数据…"); return
    }
    let response = control.properties.contains(.write)
    if !response && !peripheral.canSendWriteWithoutResponse {
      armTimeout(10, "等待设备可写超时"); return
    }
    let command: UInt8 = commandIndex == 0 ? 0x35 : 0x45
    awaitingWrite = true
    armTimeout(10, "初始化写入超时")
    peripheral.writeValue(Data([command]), for: control, type: response ? .withResponse : .withoutResponse)
    if !response { writeCompleted() }
  }
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    if peripheral === active && !awaitingWrite { writeNext() }
  }
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === active && phase == "configuring" && characteristic.uuid == writeID && awaitingWrite else { return }
    if let error = error { fail("初始化写入失败：\(error.localizedDescription)", error: error); return }
    writeCompleted()
  }
  private func writeCompleted() {
    awaitingWrite = false
    log("初始化完成：\(commandIndex == 0 ? "35" : "45")")
    commandIndex += 1
    let token = session
    DispatchQueue.main.asyncAfter(deadline: .now() + (commandIndex == 1 ? 0.1 : 0)) { [weak self] in
      guard let self = self, self.session == token else { return }
      self.writeNext()
    }
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === active else { return }
    if let error = error { log("通知失败：\(error.localizedDescription)"); return }
    guard let bytes = characteristic.value else { return }
    let uuid = characteristic.uuid.uuidString.lowercased()
    if characteristic.uuid == rawID && bytes.count >= 69 {
      if recording { notifications.receivedRaw(scope: notificationScope) }
      lastRawAt = Date()
      diagnostics.rawReceived(at: lastRawAt!)
      rawNotifications += 1
      if rawNotifications == 1 || rawNotifications % 128 == 0 {
        print("NeuroX BLE raw: session=\(session), packets=\(rawNotifications), bytes=\(bytes.count)")
        fflush(stdout)
      }
    }
    let fields: [String: Any] = ["uuid": uuid, "address": address, "session": session,
      "receivedAt": Int(Date().timeIntervalSince1970 * 1000)]
    if recording {
      var record = fields
      record["type"] = "packet"; record["source"] = "KSEEG102 iOS/CoreBluetooth"
      record["hex"] = bytes.map { String(format: "%02x", $0) }.joined()
      appendRecord(record)
    }
    var event = fields; event["bytes"] = FlutterStandardTypedData(bytes: bytes)
    if UIApplication.shared.applicationState == .active && store.authorized() { emit("packet", event) }
  }
  private func cleanActive(cancel: Bool) {
    notifications.cancelWatchdog()
    lastRawAt = nil
    if let id = taskID { try? store.invalidateBaseline(id: id, reason: "disconnected") }
    stepTimer?.cancel(); stepTimer = nil; subscriptions.removeAll(); control = nil
    awaitingWrite = false
    stopRecording(nil, reason: "连接或生命周期中断")
    if let peripheral = active {
      peripheral.delegate = nil
      if cancel && peripheral.state != .disconnected {
        retiring.insert(peripheral.identifier); central?.cancelPeripheralConnection(peripheral)
      }
    }
    active = nil
  }
  private func fail(_ message: String, error: Error? = nil) { updateDiagnosticContext(); diagnostics.record(message.contains("超时") ? "initialization_timeout" : "initialization_failed", error: error); issue("connection_lost", "设备采集发生错误，请打开 NeuroX 检查连接及记录。"); cleanActive(cancel: true); state("error", message) }
  private func disconnect(_ message: String) {
    let source = ["未开始诊断记录，后台停止连接": "background_idle", "账号操作，采集已停止": "account_action", "已主动断开，采集已停止": "user_disconnect", "页面已关闭，采集已停止": "event_stream_closed", "系统蓝牙不可用，采集已停止": "bluetooth_unavailable", "写入失败，采集已停止": "recording_write_failed"][message] ?? "app_request"
    updateDiagnosticContext(); diagnostics.record("app_disconnect", fields: ["reason": source])
    stopScan(); cleanActive(cancel: true); state("disconnected", message) }

  private func startRecording(_ result: @escaping FlutterResult) {
    guard phase == "ready" && !recording && !closing else { failure("连接就绪且保存完成后才能开始新记录", result); return }
    beginRecording(device: active?.name ?? address, result: result)
  }
  // Internal recording boundary can be verified independently of a live peripheral.
  func beginRecording(device: String, kind: String = "diagnostic", task: [String: Any] = [:], result: @escaping FlutterResult) {
    guard !recording && !closing else { failure("已有记录正在创建或保存", result); return }
    do {
      let (id, url) = try store.createSession(device: device, kind: kind, task: task)
      recordKind = kind; taskID = ["baseline","task"].contains(kind) ? id : nil
      recordID = id; lastRecordID = id; recording = true; sequence = 0; lastURL = url
      updateDiagnosticContext(); diagnostics.beginCapture()
      recordPackets = 0; recordSamples = 0; recordFailure = nil
      io.async {
        do {
          guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw LocalFailure("无法创建记录文件") }
          self.writer = try FileHandle(forWritingTo: url)
          var header = try JSONSerialization.data(withJSONObject: ["type": "session", "session_id": id,
            "source": "KSEEG102 iOS/CoreBluetooth", "algorithm": "KSEEG102_Python_Mac / Dart isolate v1",
            "kind": kind, "task": task, "baseline_algorithm": ["baseline","task"].contains(kind) ? LocalStore.baselineAlgorithm : "not_applicable", "sampling_rate_assumed": ["baseline","task"].contains(kind) && self.store.signalProfile["sampleRateAssumed"] as? Bool == true, "profile": ["baseline","task"].contains(kind) ? self.store.signalProfile : [:],
            "sampling_rate": ["baseline","task"].contains(kind) ? self.store.signalProfile["sampleRate"] ?? NSNull() : NSNull(), "raw_unit": ["baseline","task"].contains(kind) ? "SDK raw" : "unconfirmed", "physical_unit": ["baseline","task"].contains(kind) && self.store.signalProfile["verified"] as? Bool == true ? self.store.signalProfile["unit"] ?? NSNull() : NSNull()] as [String: Any], options: [.sortedKeys])
          header.append(0x0a); try self.writer?.write(contentsOf: header); try self.synchronizeWriter()
          if let handle = self.writer { if let size = try? handle.offset() { self.diagnostics.fileSize(size) } }
          try self.updateCaptureIndex(id, state: "recording", packets: 0, samples: 0, reason: "")
          DispatchQueue.main.async { if self.recording { self.notifications.receivedRaw(scope: self.notificationScope) }; self.emit("recording", ["active": self.recording, "name": url.path]); result(url.path) }
        } catch {
          self.diagnostics.failure("write_failure", stage: "header", error: error)
          self.recordFailure = error.localizedDescription
          try? self.writer?.close(); self.writer = nil
          try? self.updateCaptureIndex(id, state: "save_failed", packets: 0, samples: 0, reason: error.localizedDescription)
          DispatchQueue.main.async { self.recording = false; self.recordID = nil; self.store.clearCaptureOwner(); self.issue("save_failed", "诊断文件创建或保存失败，请打开 NeuroX 查看历史记录。"); result(FlutterError(code: "recording", message: error.localizedDescription, details: nil)) }
        }
      }
    } catch { failure(error.localizedDescription, result) }
  }
  private func synchronizeWriter(_ handle: FileHandle? = nil) throws {
    guard let handle = handle ?? writer else { return }
    let started = ProcessInfo.processInfo.systemUptime
    defer { diagnostics.duration("Sync", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
    try handle.synchronize()
  }
  private func updateCaptureIndex(_ id: String, state: String, packets: Int, samples: Int, reason: String) throws {
    let started = ProcessInfo.processInfo.systemUptime
    defer { diagnostics.duration("Index", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
    try store.updateSession(id, state: state, packets: packets, samples: samples, reason: reason)
  }
  func appendRecord(_ fields: [String: Any]) {
    sequence += 1
    var value = fields; value["sequence"] = sequence
    let queuedAt = diagnostics.enqueueRecord()
    io.async {
      let started = self.diagnostics.startRecord(queuedAt: queuedAt)
      defer { self.diagnostics.finishRecord(startedAt: started) }
      var stage = "serialize"
      do {
        guard let writer = self.writer else { return }
        guard JSONSerialization.isValidJSONObject(value) else { throw LocalFailure("记录数据无法序列化。") }
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0a)
        stage = "write"
        let writeStarted = ProcessInfo.processInfo.systemUptime
        do {
          defer { self.diagnostics.duration("Write", milliseconds: (ProcessInfo.processInfo.systemUptime - writeStarted) * 1000) }
          try writer.write(contentsOf: data)
        }
        if let size = try? writer.offset() { self.diagnostics.fileSize(size) }
        if value["type"] as? String == "packet" {
          self.recordPackets += 1
          if value["uuid"] as? String == self.rawID.uuidString.lowercased(),
            let hex = value["hex"] as? String, hex.count >= 138 { self.recordSamples += 16 }
          if self.recordPackets % 128 == 0, let id = self.recordID {
            stage = "sync"; try self.synchronizeWriter(writer)
            stage = "index"
            try self.updateCaptureIndex(id, state: "recording", packets: self.recordPackets, samples: self.recordSamples, reason: "")
          }
        }
      } catch {
        self.diagnostics.failure("write_failure", stage: stage, error: error)
        self.recordFailure = error.localizedDescription
        try? self.writer?.close(); self.writer = nil
        if let id = self.recordID {
          try? self.updateCaptureIndex(id, state: "save_failed", packets: self.recordPackets, samples: self.recordSamples, reason: error.localizedDescription)
        }
        DispatchQueue.main.async {
          self.recording = false
          self.issue("save_failed", "诊断记录未完整保存，采集已停止。请打开 NeuroX 检查已保存部分。")
          self.emit("recording", ["active": false, "state": "save_failed"])
          self.emit("error", ["message": "记录未完整保存：\(error.localizedDescription)；请停止采集并查看历史"])
          self.disconnect("写入失败，采集已停止")
        }
      }
    }
  }
  func stopRecording(_ result: FlutterResult?, reason: String? = nil) {
    let wasRecording = recording; recording = false
    updateDiagnosticContext()
    let id = recordID; let path = lastURL?.path
    guard id != nil else { result?(path); return }
    if wasRecording { emit("recording", ["active": false, "name": path ?? "", "state": "saving"]) }
    closing = true
    notifications.cancelWatchdog()
    io.async {
      do {
        try self.synchronizeWriter(); try self.writer?.close(); self.writer = nil
        if let id = id {
          try self.updateCaptureIndex(id, state: self.recordFailure != nil ? "save_failed" : reason == nil ? "saved" : "interrupted",
            packets: self.recordPackets, samples: self.recordSamples, reason: self.recordFailure ?? reason ?? "用户停止记录")
        }
        self.diagnostics.record("capture_end")
        let failure = self.recordFailure
        DispatchQueue.main.async {
          self.closing = false
          if self.recordID == id { self.recordID = nil; self.store.clearCaptureOwner() }
          self.emit("recording", ["active": false, "name": path ?? "", "state": failure != nil ? "save_failed" : reason == nil ? "saved" : "interrupted"])
          if let failure = failure { result?(FlutterError(code: "recording", message: failure, details: nil)) }
          else { result?(path) }
        }
      } catch {
        self.diagnostics.failure("flush_failure", stage: "close", error: error)
        self.writer = nil; self.recordFailure = error.localizedDescription
        if let id = id { try? self.updateCaptureIndex(id, state: "save_failed", packets: self.recordPackets, samples: self.recordSamples, reason: error.localizedDescription) }
        DispatchQueue.main.async { self.closing = false; self.store.clearCaptureOwner(); self.issue("save_failed", "诊断记录保存失败，请打开 NeuroX 检查历史及文件状态。"); result?(FlutterError(code: "recording", message: error.localizedDescription, details: nil)) }
      }
    }
  }
  private func baselineContext() -> [String: Any] {
    ["algorithm":LocalStore.baselineAlgorithm,"device": address, "connection": session, "profile": store.signalProfile["version"] ?? "", "source": "KSEEG102 / foreground", "unit": store.signalProfile["unit"] ?? "", "mode":store.signalProfile["mode"] ?? "verified", "sampleRate":store.signalProfile["sampleRate"] ?? 0, "sampleRateAssumed":store.signalProfile["sampleRateAssumed"] as? Bool == true]
  }
  private func checkBaselineDevice() throws {
    try store.requireSignalProfile()
    guard phase == "ready", !closing, !wasBackgrounded, let last = lastRawAt, Date().timeIntervalSince(last) < 3 else { throw LocalFailure("设备连接或实时数据尚未就绪。") }
  }
  private func baselineStart(_ args: [String: Any], _ result: @escaping FlutterResult) {
    do {
      try checkBaselineDevice()
      guard !recording else { throw LocalFailure("请先结束当前记录。") }
      let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard name.count <= 80 else { throw LocalFailure("任务设置无效。") }
      beginRecording(device: active?.name ?? address, kind: "baseline", task: ["name": name.isEmpty ? "个人基线" : name, "purpose":"personal_baseline","usageVersion":"personal-reference-v1"]) { value in
        if let error = value as? FlutterError { result(error); return }
        do {
          guard let id = self.recordID else { throw LocalFailure("基线文件未建立。") }
          let attempt = try self.store.beginAttempt(id: id, context: self.baselineContext())
          result(["id": id, "path": self.lastURL?.path ?? "", "attempt": attempt])
        } catch { self.stopRecording({ _ in self.failure(error.localizedDescription, result) }, reason: "基线创建失败") }
      }
    } catch { failure(error.localizedDescription, result) }
  }
  private func learningStart(_ args:[String:Any],_ result:@escaping FlutterResult) {
    do {
      try checkBaselineDevice();guard !recording else {throw LocalFailure("请先结束当前记录。")}
      let name=(args["name"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines),minutes=args["minutes"] as? Int ?? 0
      guard (0...180).contains(minutes),name.count<=80 else {throw LocalFailure("任务设置无效。")}
      try store.validateSavedReference(sourceID:args["referenceId"] as? String ?? "",context:baselineContext())
      notifications.taskSilenced=args["scene"] as? String == "training"
      beginRecording(device:active?.name ?? address,kind:"task",task:["name":name.isEmpty ? "学习任务" : name,"minutes":minutes,"scene":args["scene"] as? String ?? "learning","protocol":args["protocol"] as? [String:Any] ?? [:]]) {value in
        if let error=value as? FlutterError {self.notifications.taskSilenced=false;result(error);return}
        do {
          guard let id=self.recordID else {throw LocalFailure("任务文件保存失败。")}
          var attached=try self.store.attachSavedReference(id:id,sourceID:args["referenceId"] as? String ?? "",context:self.baselineContext())
          self.appendRecord(["type":"saved_reference","payload":attached]);attached["id"]=id;attached["path"]=self.lastURL?.path ?? "";self.flushLearning(attached,result)
        }catch {self.stopRecording({_ in self.failure(error.localizedDescription,result)},reason:"学习任务准备失败")}
      }
    }catch{failure(error.localizedDescription,result)}
  }
  private func flushLearning(_ value:[String:Any],_ result:@escaping FlutterResult) {
    io.async {
      do {guard let writer=self.writer,self.recordFailure==nil else {throw LocalFailure("任务文件保存失败。")};try self.synchronizeWriter(writer);DispatchQueue.main.async{result(value)}}
      catch {self.diagnostics.failure("flush_failure", stage: "learning_flush", error: error);DispatchQueue.main.async{self.failure(error.localizedDescription,result)}}
    }
  }
  private func learningRefresh(_ args:[String:Any],_ result:@escaping FlutterResult) {
    do {
      try checkBaselineDevice();let id=args["id"] as? String ?? ""
      guard taskID==id,!recording || recordID==id else {throw LocalFailure("请先处理当前学习任务。")}
      try store.validateSavedReference(sourceID:args["referenceId"] as? String ?? "",context:baselineContext())
      if !recording {
        let url=try store.resumeTaskFile(id:id)
        try io.sync {self.writer=try FileHandle(forWritingTo:url);try self.writer?.seekToEnd()}
        do {try store.activateTaskFile(id:id)}catch{io.sync{try? self.writer?.close();self.writer=nil};throw error}
        recordID=id;recording=true;recordFailure=nil;emit("recording",["active":true,"name":url.path])
      }
      let attached=try store.attachSavedReference(id:id,sourceID:args["referenceId"] as? String ?? "",context:baselineContext())
      appendRecord(["type":"saved_reference_rebound","payload":attached]);flushLearning(attached,result)
    }catch{failure(error.localizedDescription,result)}
  }
  private func baselineRetry(_ args: [String: Any], _ result: @escaping FlutterResult) {
    do {
      try checkBaselineDevice()
      let id = args["id"] as? String ?? ""
      guard taskID == id, !recording || recordID == id else { throw LocalFailure("基线尝试已变更，请重新检查。") }
      if !recording {
        let url = try store.resumeTaskFile(id: id)
        // Drain the previous close before reopening this same session's file.
        try io.sync {
          self.writer = try FileHandle(forWritingTo: url)
          try self.writer?.seekToEnd()
        }
        do {try store.activateTaskFile(id:id)}
        catch {io.sync {try? self.writer?.close();self.writer=nil};throw error}
        recordID = id; recording = true; recordFailure = nil
        emit("recording", ["active": true, "name": url.path])
      }
      let attempt = try store.beginAttempt(id: id, context: baselineContext())
      result(["attempt": attempt])
    } catch { failure(error.localizedDescription, result) }
  }
  private func baselineUpdate(_ args: [String: Any], _ result: @escaping FlutterResult) {
    do {
      let id = args["id"] as? String ?? ""
      if let snapshot = args["snapshot"] as? [String: Any], snapshot["state"] as? String != "invalid" {
        try checkBaselineDevice()
        guard taskID == id, recording, recordID == id else { throw LocalFailure("基线已失效，请重新采集。") }
      }
      try store.saveBaseline(args)
      if recording, recordID == id {
        appendRecord(["type": "baseline", "payload": args])
        io.async {
          do {
            guard let writer = self.writer, self.recordFailure == nil else { throw LocalFailure("基线文件保存失败。") }
            try self.synchronizeWriter(writer)
            DispatchQueue.main.async { result([:]) }
          } catch { self.diagnostics.failure("flush_failure", stage: "baseline_flush", error: error); DispatchQueue.main.async { self.failure(error.localizedDescription, result) } }
        }
      } else { result([:]) }
    } catch { failure(error.localizedDescription, result) }
  }
  private func baselineFinish(_ args: [String: Any], _ result: @escaping FlutterResult) {
    let id = args["id"] as? String ?? ""
    let finish: FlutterResult = { value in
      if let error = value as? FlutterError { result(error); return }
      do {
        try self.store.finishBaseline(id: id)
        if self.taskID == id { self.taskID = nil; self.recordKind = "diagnostic"; self.notifications.taskSilenced=false }
        result([:])
      } catch { self.failure(error.localizedDescription, result) }
    }
    if recordID == id { stopRecording(finish) } else { finish(nil) }
  }
  private func flushMonitor(_ result:@escaping FlutterResult) {
    io.async {
      do {
        guard let writer=self.writer,self.recordFailure==nil else {throw LocalFailure("任务文件保存失败。")}
        try self.synchronizeWriter(writer);DispatchQueue.main.async {result(["accepted":true])}
      } catch {self.diagnostics.failure("flush_failure", stage: "monitor_flush", error: error);DispatchQueue.main.async {self.failure(error.localizedDescription,result)}}
    }
  }
  private func monitorFinish(_ args:[String:Any],_ result:@escaping FlutterResult) {
    let id=args["id"] as? String ?? ""
    do {
      if try store.monitorFinalized(id:id) {if taskID==id {taskID=nil;recordKind="diagnostic";notifications.taskSilenced=false};result([:]);return}
    } catch {failure(error.localizedDescription,result);return}
    let finish:FlutterResult = { value in
      if let error=value as? FlutterError {result(error);return}
      do {
        _=try self.store.saveMonitoring(args)
        try self.store.finishMonitoring(id:id)
        if self.taskID==id {self.taskID=nil;self.recordKind="diagnostic";self.notifications.taskSilenced=false}
        result([:])
      } catch {self.failure(error.localizedDescription,result)}
    }
    if recordID==id {stopRecording(finish)}else{finish(nil)}
  }
  private func export(_ url: URL, _ result: @escaping FlutterResult) {
    guard !recording, !closing, !exporting, FileManager.default.fileExists(atPath: url.path) else {
      failure("请先停止记录，再导出已有文件", result); return
    }
    guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
      failure("分享窗口不可用", result); return
    }
    while let next = presenter.presentedViewController { presenter = next }
    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    share.popoverPresentationController?.sourceView = presenter.view
    share.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
    exporting = true
    share.completionWithItemsHandler = { _, completed, _, error in
      self.exporting = false
      if let error = error { result(FlutterError(code: "export", message: error.localizedDescription, details: nil)) }
      else { result(completed) }
    }
    presenter.present(share, animated: true)
  }
}

/// Independent bounded metadata cache. Diagnostic failures never alter capture.
final class CaptureDiagnostics {
  static let eventLimit = 96
  static let byteLimit = 131072
  private let url: URL
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var metrics: [String: Double] = [:]
  private var context: [String: Any] = [:]
  private var lastRaw: Date?
  private var queuedDiagnostics = 0
  private var lastSample: TimeInterval = -.infinity
  private var capture = 0
  private static let events: Set<String> = ["link_state", "connect_failed", "system_disconnect", "app_disconnect", "initialization_failed", "initialization_timeout", "adapter_state", "capture_start", "capture_end", "write_failure", "flush_failure", "io_sample"]
  private static let reasons: Set<String> = ["background_idle", "account_action", "user_disconnect", "event_stream_closed", "bluetooth_unavailable", "recording_write_failed", "app_request"]
  private static let stages: Set<String> = ["open", "serialize", "write", "sync", "index", "header", "baseline_flush", "monitor_flush", "learning_flush", "close"]
  private static let numberKeys: Set<String> = ["pendingRecords", "peakPendingRecords", "fileBytes", "lastQueueMs", "maxQueueMs", "lastWriteMs", "maxWriteMs", "lastOperationMs", "maxOperationMs", "lastSyncMs", "maxSyncMs", "lastIndexMs", "maxIndexMs", "writeFailures", "rawPackets", "adapterState", "connection", "capture", "lastRawAge", "freeBytes", "uptime", "pid", "droppedDiagnostics"]

  init(url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("neurox-capture-health.json"), queue: DispatchQueue = DispatchQueue(label: "neurox.capture.health", qos: .utility)) {
    self.url = url; self.queue = queue
  }
  private func locked<T>(_ work: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }; return work()
  }
  func updateContext(phase: String, recording: Bool, foreground: Bool, connection: Int) {
    locked {
      if context["connection"] as? Int != connection { lastRaw = nil; metrics["rawPackets"] = 0 }
      context = ["phase": phase, "recording": recording, "foreground": foreground, "connection": connection]
    }
  }
  func rawReceived(at: Date) { locked { lastRaw = at; metrics["rawPackets", default: 0] += 1 } }
  func beginCapture() {
    locked {
      capture += 1; metrics["fileBytes"] = 0
      lastSample = -.infinity
    }
    record("capture_start")
  }
  func fileSize(_ bytes: UInt64) { locked { metrics["fileBytes"] = Double(bytes) } }
  func enqueueRecord() -> TimeInterval {
    locked {
      metrics["pendingRecords", default: 0] += 1
      metrics["peakPendingRecords"] = max(metrics["peakPendingRecords"] ?? 0, metrics["pendingRecords"]!)
    }
    return ProcessInfo.processInfo.systemUptime
  }
  func startRecord(queuedAt: TimeInterval) -> TimeInterval {
    let now = ProcessInfo.processInfo.systemUptime
    duration("Queue", milliseconds: (now - queuedAt) * 1000)
    return now
  }
  func finishRecord(startedAt: TimeInterval) {
    duration("Operation", milliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
    locked { metrics["pendingRecords"] = max(0, (metrics["pendingRecords"] ?? 1) - 1) }
    sample()
  }
  func duration(_ kind: String, milliseconds: Double) {
    guard ["Queue", "Write", "Sync", "Index", "Operation"].contains(kind), milliseconds.isFinite else { return }
    locked {
      metrics["last\(kind)Ms"] = max(0, milliseconds)
      metrics["max\(kind)Ms"] = max(metrics["max\(kind)Ms"] ?? 0, milliseconds)
    }
  }
  func failure(_ event: String, stage: String, error: Error) {
    locked { metrics["writeFailures", default: 0] += 1 }
    record(event, fields: ["stage": stage], error: error)
  }
  func snapshot() -> [String: Any] {
    locked {
      var value = context
      for (key, number) in metrics { value[key] = number }
      value["capture"] = capture
      if let last = lastRaw { value["lastRawAge"] = max(0, Date().timeIntervalSince(last)) }
      return value
    }
  }
  func sample() {
    let now = ProcessInfo.processInfo.systemUptime
    let due = locked { () -> Bool in
      guard now - lastSample >= 5 else { return false }
      lastSample = now; return true
    }
    if due { record("io_sample") }
  }
  private static func errorFields(_ error: NSError, prefix: String = "error") -> [String: Any] {
    let domains = ["NSCocoaErrorDomain", "NSPOSIXErrorDomain", "CBErrorDomain", "CBATTErrorDomain", "NSSQLiteErrorDomain"]
    return ["\(prefix)Domain": domains.contains(error.domain) ? error.domain : "other", "\(prefix)Code": error.code]
  }
  func record(_ event: String, fields: [String: Any] = [:], error: Error? = nil) {
    guard Self.events.contains(event) else { return }
    var input = snapshot(); input.merge(fields) { _, new in new }
    var row: [String: Any] = ["event": event, "timestamp": ISO8601DateFormatter().string(from: Date()), "uptime": ProcessInfo.processInfo.systemUptime,
      "pid": ProcessInfo.processInfo.processIdentifier, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""]
    for key in Self.numberKeys {
      if let n = input[key] as? NSNumber, n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 1e18 { row[key] = n }
    }
    if let phase = input["phase"] as? String, ["disconnected", "connecting", "discovering", "configuring", "ready", "error"].contains(phase) { row["phase"] = phase }
    for key in ["recording", "foreground"] { if let flag = input[key] as? Bool { row[key] = flag } }
    if let reason = input["reason"] as? String, Self.reasons.contains(reason) { row["reason"] = reason }
    if let stage = input["stage"] as? String, Self.stages.contains(stage) { row["stage"] = stage }
    if let error = error as NSError? {
      row.merge(Self.errorFields(error)) { _, new in new }
      if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { row.merge(Self.errorFields(underlying, prefix: "underlying")) { _, new in new } }
    }
    let accepted = locked { () -> Bool in
      guard queuedDiagnostics < 8 else { metrics["droppedDiagnostics", default: 0] += 1; return false }
      queuedDiagnostics += 1; return true
    }
    guard accepted else { return }
    let capturedRow = row
    queue.async {
      defer { self.locked { self.queuedDiagnostics -= 1 } }
      do {
        var history: [[String: Any]] = []
        let keys = Set(capturedRow.keys).union(Self.numberKeys).union(["phase", "recording", "foreground", "reason", "stage", "errorDomain", "errorCode", "underlyingDomain", "underlyingCode"])
        if let size = try? self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.byteLimit,
          let data = try? Data(contentsOf: self.url), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let previous = saved["events"] as? [[String: Any]] {
          history = previous.suffix(Self.eventLimit - 1).filter { Self.events.contains($0["event"] as? String ?? "") }.map { $0.filter { keys.contains($0.key) } }
        }
        var eventRow = capturedRow
        if let free = try? FileManager.default.attributesOfFileSystem(forPath: self.url.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber { eventRow["freeBytes"] = free }
        history.append(eventRow)
        var data = try JSONSerialization.data(withJSONObject: ["schema": 1, "events": history], options: [.sortedKeys])
        while data.count > Self.byteLimit && history.count > 1 {
          history.removeFirst(); data = try JSONSerialization.data(withJSONObject: ["schema": 1, "events": history], options: [.sortedKeys])
        }
        guard data.count <= Self.byteLimit else { return }
        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: self.url, options: .atomic)
      } catch { /* Diagnostics cannot stop recording, disconnect BLE, or expose file paths. */ }
    }
  }
  // Deterministic test barrier; capture never waits for the diagnostic queue.
  func waitForPendingWrites() { queue.sync {} }
}
