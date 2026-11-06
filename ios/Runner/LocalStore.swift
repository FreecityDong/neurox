import Foundation
import Security
import SQLite3
import CommonCrypto
import Flutter

struct LocalFailure: LocalizedError {
  let text: String
  var errorDescription: String? { text }
  init(_ text: String) { self.text = text }
}

/// All SQLite, credential and identity access is serialized on queue.
final class LocalStore {
  let queue = DispatchQueue(label: "neurox.local.store", qos: .userInitiated)
  private var db: OpaquePointer?
  private var user: String?
  private var epoch = 0
  private var captureOwner: String?
  private let service: String
  private let root: URL
  static let baselineAlgorithm = "neurox-sdk-learning-reference-v4"
  let signalProfile: [String: Any]
  private let uptime: () -> TimeInterval
  private var channel: FlutterMethodChannel?
  var beforeLock: ((@escaping (Error?) -> Void) -> Void)?
  var isRecording: (() -> Bool)?

  // Accepted provisional configuration; product screenshot now also specifies 512 SPS/channel.
  // Actual connected firmware/output configuration and physical conversion remain unverified.
  static let provisionalRawProfile: [String:Any] = [
    "verified":false, "mode":"raw_ratio_provisional", "assumptionAccepted":true,
    "sampleRateAssumed":true, "version":"raw-ratio-assumed512-v1",
    "evidence":"User accepted 512Hz; product screenshot supplied 2026-11-03 specifies 512 SPS/channel; connected configuration unverified; SDK raw units",
    "unit":"SDK raw", "sampleRate":512.0, "scale":1.0,
    "qualityStatus":"basic_only_uncalibrated", "flatStd":0.000001,
    "adcMin":0.0, "adcMax":6.5535, "maxPeakToPeak":6.5535, "maxStep":6.5535
  ]
  init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], service: String = "com.neurox.local.credentials.v1", signalProfile: [String: Any] = LocalStore.provisionalRawProfile, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.root = root
    self.service = service
    self.signalProfile = signalProfile
    self.uptime = uptime
  }
  deinit { sqlite3_close(db) }
  func attach(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "neurox/local", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }
  private func open() throws {
    if db != nil { return }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var candidate: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("neurox.sqlite").path, &candidate) == SQLITE_OK else {
      sqlite3_close(candidate); throw LocalFailure("本机数据库无法打开，请重试；不会自动清空数据。")
    }
    db = candidate
    do {
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.appendingPathComponent("neurox.sqlite").path)
      try run("PRAGMA foreign_keys=ON")
      let version = try rows("PRAGMA user_version").first?["user_version"] as? Int ?? 0
      guard version <= 5 else { throw LocalFailure("数据库版本较新，请使用对应版本App。") }
      if version == 0 {
        try run("BEGIN IMMEDIATE")
        do {
          try run("CREATE TABLE account (id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, nickname TEXT NOT NULL, state TEXT NOT NULL, failures INTEGER NOT NULL DEFAULT 0, locked_until REAL NOT NULL DEFAULT 0, reminders INTEGER NOT NULL DEFAULT 0)")
          try run("CREATE TABLE sessions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES account(id), name TEXT NOT NULL, path TEXT UNIQUE NOT NULL, state TEXT NOT NULL, started REAL NOT NULL, ended REAL, device TEXT NOT NULL, packets INTEGER NOT NULL DEFAULT 0, samples INTEGER NOT NULL DEFAULT 0, reason TEXT NOT NULL DEFAULT '')")
          try run("CREATE INDEX sessions_user_started ON sessions(user_id, started DESC)")
          try run("PRAGMA user_version=1"); try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
      }
      let hasTaskColumns = try rows("PRAGMA table_info(sessions)").contains { $0["name"] as? String == "kind" }
      if version < 3 && !hasTaskColumns {
        try run("BEGIN IMMEDIATE")
        do {
          try run("ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'diagnostic'")
          try run("ALTER TABLE sessions ADD COLUMN task_state TEXT NOT NULL DEFAULT 'none'")
          try run("ALTER TABLE sessions ADD COLUMN task_json TEXT NOT NULL DEFAULT '{}'")
          try run("ALTER TABLE sessions ADD COLUMN current_attempt TEXT NOT NULL DEFAULT ''")
          try run("ALTER TABLE sessions ADD COLUMN baseline_json TEXT NOT NULL DEFAULT '{}'")
          try run("CREATE TABLE baseline_attempts(id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, user_id TEXT NOT NULL, state TEXT NOT NULL, context_json TEXT NOT NULL, snapshot TEXT NOT NULL DEFAULT '{}')")
          try run("CREATE TABLE baseline_windows(attempt_id TEXT NOT NULL REFERENCES baseline_attempts(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(attempt_id,sequence))")
          try run("PRAGMA user_version=3"); try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
      }
      let hasMonitor = try rows("PRAGMA table_info(sessions)").contains {$0["name"] as? String == "monitor_json"}
      if !hasMonitor {
        try run("BEGIN IMMEDIATE")
        do {
          try run("ALTER TABLE sessions ADD COLUMN monitor_json TEXT NOT NULL DEFAULT '{}'")
          try run("ALTER TABLE sessions ADD COLUMN feedback_json TEXT NOT NULL DEFAULT '{}'")
          try run("CREATE TABLE task_events(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(session_id,sequence))")
          try run("PRAGMA user_version=4");try run("COMMIT")
        } catch {try? run("ROLLBACK");throw error}
      }
      try run("CREATE TABLE IF NOT EXISTS user_settings(user_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,key TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(user_id,key))")
      try run("PRAGMA user_version=5")
      for row in try rows("SELECT id FROM sessions WHERE kind IN ('baseline','task') AND task_state='active'") {
        if let id = row["id"] as? String {try invalidateBaselineUnlocked(id:id,reason:"restart");try interruptMonitorUnlocked(id:id,reason:"restart")}
      }
      try run("UPDATE sessions SET task_state='interrupted_pending' WHERE kind IN ('baseline','task') AND task_state='active'")
      // A recording never resumes across a process restart.
      try run("UPDATE sessions SET state='interrupted', reason='App中断；仅保留已落盘部分' WHERE state IN ('recording','creating')")
    } catch { sqlite3_close(db); db = nil; throw error }
  }
  private func statement(_ sql: String, _ values: [Any]) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
      throw LocalFailure("数据库读取或迁移失败，请重试，不会自动重建。")
    }
    for (i, value) in values.enumerated() {
      let index = Int32(i + 1)
      let status: Int32
      if let s = value as? String {
        status = sqlite3_bind_text(stmt, index, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      } else if let n = value as? Int { status = sqlite3_bind_int64(stmt, index, Int64(n)) }
      else if let n = value as? Double { status = sqlite3_bind_double(stmt, index, n) }
      else { status = sqlite3_bind_null(stmt, index) }
      guard status == SQLITE_OK else { sqlite3_finalize(stmt); throw LocalFailure("数据库参数写入失败") }
    }
    return stmt
  }
  private func run(_ sql: String, _ values: [Any] = []) throws {
    let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw LocalFailure("本机数据保存失败，请重试；已有数据保留。") }
  }
  private func rows(_ sql: String, _ values: [Any] = []) throws -> [[String: Any]] {
    let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
    var output: [[String: Any]] = []
    while true {
      let code = sqlite3_step(stmt)
      if code == SQLITE_DONE { return output }
      guard code == SQLITE_ROW else { throw LocalFailure("本机数据读取失败，请重试。") }
      var row: [String: Any] = [:]
      for i in 0..<sqlite3_column_count(stmt) {
        let key = String(cString: sqlite3_column_name(stmt, i))
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: row[key] = Int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: row[key] = sqlite3_column_double(stmt, i)
        case SQLITE_TEXT: row[key] = String(cString: sqlite3_column_text(stmt, i))
        default: break
        }
      }
      output.append(row)
    }
  }
  private func keyQuery(_ id: String = "single-local-account") -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
  }
  private func credential(_ id: String = "single-local-account") throws -> [String: Any]? {
    var query = keyQuery(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LocalFailure("钥匙串无法读取，请解锁设备后重试。")
    }
    return value
  }
  private func makeCredential(_ id: String, _ password: String) throws -> [String: Any] {
    guard password.count >= 6 && password.count <= 128 else { throw LocalFailure("密码须为6–128个字符。") }
    var salt = Data(count: 32)
    let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard status == errSecSuccess else { throw LocalFailure("安全随机数不可用，请重试。") }
    return ["id": id, "salt": salt.base64EncodedString(), "hash": try derive(password, salt, 600000).base64EncodedString(), "rounds": 600000, "version": 1]
  }
  private func derive(_ password: String, _ salt: Data, _ rounds: Int) throws -> Data {
    let passwordBytes = Array(password.utf8); var output = Data(count: 32)
    let status = output.withUnsafeMutableBytes { out in
      salt.withUnsafeBytes { saltBytes in
        password.withCString { pass in
          CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, passwordBytes.count,
            saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), out.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
        }
      }
    }
    guard status == kCCSuccess else { throw LocalFailure("密码验证服务不可用。") }
    return output
  }
  private func saveCredential(_ value: [String: Any], replacing: Bool) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    guard let id = value["id"] as? String else { throw LocalFailure("凭据身份无效") }
    let status: OSStatus
    if replacing { status = SecItemUpdate(keyQuery(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
    else {
      var query = keyQuery(id); query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(query as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw LocalFailure("凭据保存失败，账号未放行。请重试。") }
  }
  private func account(id: String? = nil, name: String? = nil) throws -> [String: Any]? {
    if let id = id ?? (name == nil ? user : nil) { return try rows("SELECT * FROM account WHERE id=?", [id]).first }
    if let name = name { return try rows("SELECT * FROM account WHERE name=?", [name]).first }
    return try rows("SELECT * FROM account ORDER BY rowid").first
  }
  private func credentialIDs() throws -> Set<String> {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
      kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
    query[kSecReturnData as String] = false
    var result: CFTypeRef?
    let code = SecItemCopyMatching(query as CFDictionary, &result)
    if code == errSecItemNotFound { return [] }
    guard code == errSecSuccess, let attributes = result as? [[String: Any]] else { throw LocalFailure("钥匙串状态不可用，请解锁重试。") }
    return Set(attributes.compactMap { $0[kSecAttrAccount as String] as? String })
  }
  private func migrateCredentials() throws {
    if let old = try credential() {
      guard let id = old["id"] as? String, try account(id: id) != nil else {
        throw LocalFailure("检测到旧钥匙串但本机资料缺失，不能自动替换身份。")
      }
      if let current = try credential(id) {
        guard NSDictionary(dictionary: current).isEqual(to: old) else { throw LocalFailure("凭据迁移冲突，请保留数据并重试。") }
      } else { try saveCredential(old, replacing: false) }
      guard SecItemDelete(keyQuery() as CFDictionary) == errSecSuccess else { throw LocalFailure("旧凭据迁移未完成，请解锁重试。") }
    }
    try run("PRAGMA user_version=4")
  }
  private func requireUser() throws -> String {
    guard let user = user, let row = try account(), row["id"] as? String == user,
      row["state"] as? String == "ready" else { throw LocalFailure("请先重新登录。") }
    return user
  }
  private func publicAccount(_ row: [String: Any]) -> [String: Any] {
    ["id": row["id"]!, "name": row["name"]!, "nickname": row["nickname"]!, "reminders": row["reminders"] ?? 0]
  }
  private func check() throws -> [String: Any] {
    try open(); try migrateCredentials()
    for row in try rows("SELECT * FROM account ORDER BY rowid") {
      let id = row["id"] as! String
      if row["state"] as? String == "deleting" { try finishDelete(id); continue }
      let key = try credential(id)
      if row["state"] as? String == "pending", key == nil {
        try run("DELETE FROM account WHERE id=?", [id]); continue
      }
      guard key?["id"] as? String == id, key?["version"] as? Int == 1 else {
        throw LocalFailure("账号资料与钥匙串不匹配；不会替换身份或自动认领旧文件。")
      }
      if row["state"] as? String == "pending" { try run("UPDATE account SET state='ready' WHERE id=?", [id]) }
    }
    let accounts = try rows("SELECT id,name FROM account WHERE state='ready' ORDER BY rowid")
    let known = Set(accounts.compactMap { $0["id"] as? String })
    guard try credentialIDs().subtracting(known).isEmpty else {
      throw LocalFailure("检测到无本机资料的孤立凭据，请保留数据并联系维护人员；不会自动创建或替换账号。")
    }
    return ["state": accounts.isEmpty ? "register" : "login", "name": accounts.first?["name"] ?? "",
      "recordingActive": captureOwner != nil]
  }
  private func verify(_ row: [String: Any], _ password: String, name: String? = nil) throws {
    let now = Date().timeIntervalSince1970
    let until = row["locked_until"] as? Double ?? Double(row["locked_until"] as? Int ?? 0)
    if until > now { throw LocalFailure("连续验证失败，请等待\(Int(ceil(until-now)))秒后重试。") }
    guard let key = try credential(row["id"] as! String), key["id"] as? String == row["id"] as? String,
      key["version"] as? Int == 1, let rounds = key["rounds"] as? Int, rounds == 600000,
      let saltText = key["salt"] as? String, let salt = Data(base64Encoded: saltText), salt.count == 32,
      let hashText = key["hash"] as? String, let hash = Data(base64Encoded: hashText), hash.count == 32 else {
      throw LocalFailure("账号凭据缺失或格式不匹配，无法登录。")
    }
    guard password.count <= 128 else { throw LocalFailure("账号或密码不正确。") }
    let computed = try derive(password, salt, rounds)
    var diff: UInt8 = 0
    for (a, b) in zip(computed, hash) { diff |= a ^ b }
    if diff != 0 || (name != nil && name != row["name"] as? String) {
      let failures = (row["failures"] as? Int ?? 0) + 1
      try run("UPDATE account SET failures=?, locked_until=? WHERE id=?", [failures, failures >= 5 ? now+60 : 0.0, row["id"]!])
      throw LocalFailure(failures >= 5 ? "账号或密码不正确。请等待60秒后重试。" : "账号或密码不正确。")
    }
    try run("UPDATE account SET failures=0, locked_until=0 WHERE id=?", [row["id"]!])
  }
  func authorized() -> Bool { queue.sync { user != nil } }
  func lock() { queue.sync { epoch += 1; user = nil } }
  func clearCaptureOwner() { queue.sync { captureOwner = nil } }
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let destructive = ["logout", "changePassword", "deleteAccount"].contains(call.method)
    if destructive, isRecording?() == true {
      result(FlutterError(code: "active_recording", message: "请先停止并保存诊断记录，再进行账号操作。", details: nil)); return
    }
    let capturedEpoch = queue.sync { epoch }
    let execute = { self.queue.async {
      do {
        guard capturedEpoch == self.epoch else { throw LocalFailure("应用已锁定，请重新登录。") }
        let value = try self.perform(call.method, args)
        DispatchQueue.main.async { result(value) }
      } catch {
        let code = call.method == "deleteAccount" && self.user == nil ? "cleanup_incomplete" : "local_store"
        DispatchQueue.main.async { result(FlutterError(code: code, message: error.localizedDescription, details: nil)) }
      }
    } }
    if destructive, let beforeLock = beforeLock {
      beforeLock { error in
        if let error = error { result(FlutterError(code: "save", message: error.localizedDescription, details: nil)) }
        else { execute() }
      }
    } else { execute() }
  }
  func perform(_ method: String, _ args: [String: Any]) throws -> Any? {
    try open()
    let password = args["password"] as? String ?? ""
    switch method {
    case "check": return try check()
    case "register":
      _ = try check()
      guard user == nil, captureOwner == nil else { throw LocalFailure("请先停止记录并退出当前账号，再注册其他账号。") }
      let name = (args["name"] as? String ?? "").lowercased()
      guard name.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil else { throw LocalFailure("账号须为3–32位字母、数字或下划线。") }
      guard try account(name: name) == nil else { throw LocalFailure("此本机账号名已存在，请登录或更换账号名。") }
      let id = UUID().uuidString; let key = try makeCredential(id, password)
      try run("INSERT INTO account(id,name,nickname,state) VALUES(?,?,?,'pending')", [id, name, name])
      try saveCredential(key, replacing: false)
      try run("UPDATE account SET state='ready' WHERE id=?", [id]); user = id
      return publicAccount(try account(id: id)!)
    case "login":
      _ = try check()
      let name = (args["name"] as? String ?? "").lowercased()
      guard let row = try account(name: name), row["state"] as? String == "ready" else { throw LocalFailure("账号或密码不正确。") }
      if let owner = captureOwner, row["id"] as? String != owner { throw LocalFailure("诊断仍在后台保存，请登录原账号停止记录后再切换账号。") }
      try verify(row, password, name: name)
      user = row["id"] as? String; return publicAccount(row)
    case "logout": user = nil; epoch += 1; return nil
    default: break
    }
    let id = try requireUser()
    switch method {
    case "baselineCapabilities": return ["profile": signalProfile]
    case "feedbackSettings":
      return try rows("SELECT value FROM user_settings WHERE user_id=? AND key='feedback'",[id]).first.map {try decode($0["value"])} ?? [:]
    case "setFeedbackSettings":
      let settings = ["sound":args["sound"] as? Bool ?? false,"vibration":args["vibration"] as? Bool ?? false,"notice":args["notice"] as? Bool ?? false,"muted":args["muted"] as? Bool ?? false]
      try run("INSERT OR REPLACE INTO user_settings(user_id,key,value) VALUES(?,'feedback',?)",[id,try encode(settings)])
      return settings
    case "setFeedbackMute":
      var settings = try rows("SELECT value FROM user_settings WHERE user_id=? AND key='feedback'",[id]).first.map {try decode($0["value"])} ?? [:]
      settings["muted"] = args["muted"] as? Bool ?? false
      settings.removeValue(forKey:"stageSilence")
      try run("INSERT OR REPLACE INTO user_settings(user_id,key,value) VALUES(?,'feedback',?)",[id,try encode(settings)])
      return settings
    case "baselineSelection":
      let selection=try rows("SELECT value FROM user_settings WHERE user_id=? AND key='reference'",[id]).first
      let selectedID=selection.flatMap {try? decode($0["value"])["id"] as? String}
      return ["id":selectedID ?? ""]
    case "baselineList":
      return ["items":try rows("SELECT * FROM sessions WHERE user_id=? AND kind='baseline' AND task_state='baseline_ready' AND state='saved' ORDER BY started DESC,rowid DESC",[id]).compactMap {row -> [String:Any]? in
        guard let snap=try? decode(row["baseline_json"]),snap["algorithm"] as? String == LocalStore.baselineAlgorithm else {return nil}
        return ["id":row["id"] ?? "","started":row["started"] ?? 0,"device":row["device"] ?? "","snapshot":snap]
      }]
    case "baselineSelect":
      let chosen=try owned(args,id)
      guard chosen["kind"] as? String == "baseline", chosen["task_state"] as? String == "baseline_ready",chosen["state"] as? String == "saved",
        let snap=try? decode(chosen["baseline_json"]),snap["algorithm"] as? String == LocalStore.baselineAlgorithm,snap["state"] as? String == "ready" else {throw LocalFailure("个人参考不可用。")}
      try run("INSERT OR REPLACE INTO user_settings(user_id,key,value) VALUES(?,'reference',?)",[id,try encode(["id":chosen["id"] ?? ""])])
      return try referenceInfoUnlocked(owner:id,context:args["context"] as? [String:Any])
    case "baselineReference": return try referenceInfoUnlocked(owner:id,context:args["context"] as? [String:Any])
    case "baselinePreflight":
      let probe = root.appendingPathComponent("baseline-probe-\(UUID().uuidString).tmp")
      defer { try? FileManager.default.removeItem(at: probe) }
      try Data("NeuroX storage probe".utf8).write(to: probe, options: .atomic)
      let pending = try rows("SELECT * FROM sessions WHERE user_id=? AND kind IN ('baseline','task') AND task_state IN ('active','interrupted_pending')", [id]).map(fileInfo)
      let free = (try FileManager.default.attributesOfFileSystem(forPath:root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
      return ["storageReady": free >= 16 * 1024 * 1024, "freeBytes":free, "unresolved": pending]
    case "taskFeedback":
      let row = try owned(args,id)
      guard row["kind"] as? String == "task", row["task_state"] as? String != "active", row["task_state"] as? String != "interrupted_pending" else {throw LocalFailure("请先结束并保存任务。")}
      let value = args["feedback"] as? [String:Any] ?? [:]
      let rating = value["rating"] as? Int ?? 0, note = value["note"] as? String ?? ""
      guard (0...5).contains(rating),note.count<=300 else {throw LocalFailure("反馈内容无效。")}
      try run("UPDATE sessions SET feedback_json=? WHERE id=? AND user_id=?",[try encode(["rating":rating,"note":note]),row["id"]!,id]);return nil
    case "profile": return publicAccount(try account()!)
    case "updateProfile":
      let nickname = (args["nickname"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard nickname.count <= 32 else { throw LocalFailure("昵称最多32个字符。") }
      try run("UPDATE account SET nickname=?, reminders=? WHERE id=?", [nickname, args["reminders"] as? Int ?? 0, id]); return publicAccount(try account()!)
    case "changePassword":
      try verify(try account()!, password)
      try saveCredential(makeCredential(id, args["newPassword"] as? String ?? ""), replacing: true)
      user = nil; epoch += 1; return nil
    case "deleteAccount":
      try verify(try account()!, password)
      try run("UPDATE account SET state='deleting' WHERE id=?", [id]); user = nil; epoch += 1
      try finishDelete(id); return nil
    case "saveScenarioReplay": return try saveScenarioReplay(args,owner:id)
    case "sessions":
      return try rows("SELECT * FROM sessions WHERE user_id=? ORDER BY started DESC", [id]).map(fileInfo)
    case "detail": return try fileInfo(owned(args, id))
    case "deleteSession":
      let row = try owned(args, id)
      guard row["task_state"] as? String != "active", row["state"] as? String != "recording" else { throw LocalFailure("请先停止记录。") }
      if row["kind"] as? String == "baseline" {
        for task in try rows("SELECT baseline_json FROM sessions WHERE user_id=? AND kind='task' AND task_state='active'",[id]) {
          let value=(try? decode(task["baseline_json"])) ?? [:]
          if (value["referenceOrigin"] as? [String:Any])?["sessionId"] as? String == row["id"] as? String {throw LocalFailure("该基线正在学习任务中使用，请先结束任务。")}
        }
      }
      try run("UPDATE sessions SET state='deleting' WHERE id=? AND user_id=?", [row["id"]!, id])
      let url = try safeURL(row["path"] as! String)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
      let summary = root.appendingPathComponent("exports/summary-\(row["id"] as! String).json")
      if FileManager.default.fileExists(atPath:summary.path) {try FileManager.default.removeItem(at:summary)}
      let report=root.appendingPathComponent("exports/learning-report-\(row["id"] as! String).png")
      if FileManager.default.fileExists(atPath:report.path) {try FileManager.default.removeItem(at:report)}
      try run("DELETE FROM sessions WHERE id=? AND user_id=?", [row["id"]!, id]); return nil
    case "legacy":
      let known = Set(try rows("SELECT path FROM sessions").compactMap { $0["path"] as? String })
      return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" && !known.contains($0.lastPathComponent) }.map { $0.lastPathComponent }.sorted()
    case "claimLegacy":
      let path = args["path"] as? String ?? ""; let url = try safeURL(path)
      guard FileManager.default.fileExists(atPath: url.path), try rows("SELECT id FROM sessions WHERE path=?", [path]).isEmpty else { throw LocalFailure("旧文件不可用或已归属。") }
      let date = (try url.resourceValues(forKeys: [.creationDateKey])).creationDate ?? Date()
      try run("INSERT INTO sessions(id,user_id,name,path,state,started,device,reason) VALUES(?,?,?,?,'imported',?,'旧版记录','用户明确确认归属；点数与时间跨度未核验')", [UUID().uuidString, id, path, path, date.timeIntervalSince1970]); return nil
    default: throw LocalFailure("不支持的本机操作")
    }
  }
  private func owned(_ args: [String: Any], _ id: String) throws -> [String: Any] {
    guard let row = try rows("SELECT * FROM sessions WHERE id=? AND user_id=?", [args["id"] as? String ?? "", id]).first else { throw LocalFailure("无法访问该记录。") }
    return row
  }
  private func safeURL(_ path: String) throws -> URL {
    guard path == (path as NSString).lastPathComponent, path.hasSuffix(".jsonl"), !path.contains("..") else { throw LocalFailure("记录路径无效。") }
    return root.appendingPathComponent(path)
  }
  private func saveScenarioReplay(_ args:[String:Any],owner:String) throws -> [String:Any] {
    let source=try owned(args,owner), metadata=try decode(source["task_json"]), original=try decode(source["monitor_json"]), baseline=try decode(source["baseline_json"])
    guard source["kind"] as? String == "task", source["state"] as? String == "saved", source["task_state"] as? String == "task_complete",
      metadata["scene"] as? String == "learning",metadata["isReplay"] as? Bool != true,original["algorithm"] as? String == LocalStore.baselineAlgorithm,
      let scene=args["scene"] as? String,["esports","go","archery"].contains(scene),
      var snapshot=args["snapshot"] as? [String:Any],snapshot["scene"] as? String == scene,
      snapshot["version"] as? String == "sdk-personal-monitor-v2",snapshot["algorithm"] as? String == LocalStore.baselineAlgorithm,
      snapshot["phase"] as? String == "finished",let total=(snapshot["elapsed"] as? NSNumber)?.doubleValue,total.isFinite,total>0,
      let sourceTime=(original["elapsed"] as? NSNumber)?.doubleValue,abs(total-sourceTime)<0.01,
      let durations=snapshot["durations"] as? [String:Any],let stable=(durations["stable"] as? NSNumber)?.doubleValue,
      let deviation=(durations["deviation"] as? NSNumber)?.doubleValue,let unknown=(durations["unknown"] as? NSNumber)?.doubleValue,
      [stable,deviation,unknown].allSatisfy({$0.isFinite && $0>=0}),abs(stable+deviation+unknown-total)<0.05,
      let valid=(snapshot["validSeconds"] as? NSNumber)?.doubleValue,valid.isFinite,abs(valid-stable-deviation)<0.05,
      let rules=snapshot["rules"] as? [String:Any],(rules["sustainedSeconds"] as? NSNumber)?.doubleValue == 10,(rules["recoverySeconds"] as? NSNumber)?.doubleValue == 15,
      let reference=snapshot["reference"] as? [String:Any],let expected=original["reference"] as? [String:Any] ?? baseline["statistics"] as? [String:Any],NSDictionary(dictionary:reference).isEqual(to:expected),
      let events=args["events"] as? [[String:Any]],!events.isEmpty,events.count<=200000,
      (snapshot["eventSequence"] as? Int)==events.count else {throw LocalFailure("该学习记录缺少完整指标或兼容的基线，暂不能回放。")}
    guard try rows("SELECT id FROM sessions WHERE user_id=? AND kind IN ('task','baseline') AND task_state IN ('active','interrupted_pending')",[owner]).isEmpty else {throw LocalFailure("请先结束当前任务，再复制测试回放。")}
    for (index,event) in events.enumerated() {
      guard event["sequence"] as? Int == index+1,let at=(event["elapsed"] as? NSNumber)?.doubleValue,at.isFinite,at>=0,at<=total+0.01 else {throw LocalFailure("回放记录无效。")}
    }
    let id=UUID().uuidString,sourceID=source["id"] as! String,path="neurox-replay-\(UUID().uuidString).jsonl"
    let target=try safeURL(path)
    snapshot["isReplay"]=true;snapshot["replaySourceId"]=sourceID;snapshot["referenceOrigin"]=original["referenceOrigin"] ?? baseline["referenceOrigin"] ?? [:]
    snapshot["remindersEnabled"]=false;snapshot["remindersRequested"]=0
    let task:[String:Any]=["scene":scene,"isReplay":true,"replaySourceId":sourceID,"replayCreatedAt":Date().timeIntervalSince1970,"sourceScene":"learning","sourceStarted":source["started"] ?? 0,"containsRawEEG":false,"algorithm":LocalStore.baselineAlgorithm]
    var file=Data()
    func append(_ object:[String:Any]) throws {file.append(try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]));file.append(0x0a)}
    try append(["type":"test_replay","sessionId":id,"metadata":task])
    for event in events {try append(["type":"replay_event","payload":event])}
    try append(["type":"replay_summary","payload":snapshot,"baseline":baseline])
    do {
      try file.write(to:target,options:.atomic)
      try run("BEGIN IMMEDIATE")
      do {
        try run("INSERT INTO sessions(id,user_id,name,path,state,started,ended,device,kind,task_state,task_json,baseline_json,monitor_json) VALUES(?,?,?,?,'saved',?,?,?,'task','task_complete',?,?,?)",[id,owner,"[Replay] \(source["name"] as? String ?? "")",path,source["started"] ?? 0,source["ended"] ?? NSNull(),source["device"] ?? "",try encode(task),try encode(baseline),try encode(snapshot)])
        for event in events {try run("INSERT INTO task_events(session_id,sequence,payload) VALUES(?,?,?)",[id,event["sequence"]!,try encode(event)])}
        try run("COMMIT")
      } catch {try? run("ROLLBACK");throw error}
    } catch {try? FileManager.default.removeItem(at:target);throw error}
    return ["id":id,"isReplay":true]
  }
  private func fileInfo(_ row: [String: Any]) throws -> [String: Any] {
    var value = row; let url = try safeURL(row["path"] as! String)
    value["exists"] = FileManager.default.fileExists(atPath: url.path)
    value["bytes"] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if ["baseline","task"].contains(row["kind"] as? String ?? "") {
      value["attempts"] = try rows("SELECT id,state,context_json,snapshot FROM baseline_attempts WHERE session_id=? AND user_id=? ORDER BY rowid", [row["id"]!, row["user_id"]!])
    }
    if row["kind"] as? String == "baseline" {
      value["windows"]=try rows("SELECT w.payload,w.attempt_id FROM baseline_windows w JOIN baseline_attempts a ON a.id=w.attempt_id WHERE a.session_id=? AND a.user_id=? ORDER BY a.rowid,w.sequence",[row["id"]!,row["user_id"]!])
    }
    if row["kind"] as? String == "task" {
      value["events"] = try rows("SELECT sequence,payload FROM task_events WHERE session_id=? ORDER BY sequence",[row["id"]!])
    }
    value["source"] = row["state"] as? String == "imported" ? "旧版文件；来源、算法与采集配置尚未核验" : "KSEEG102 / iOS CoreBluetooth；主机算法 Dart 移植 v1；采样率及物理单位待确认"
    if (try? decode(row["task_json"])["isReplay"] as? Bool) == true {value["source"]="测试回放：学习任务已保存指标；未采集新的原始脑电。"}
    return value
  }
  private func finishDelete(_ id: String) throws {
    for row in try rows("SELECT id,path FROM sessions WHERE user_id=?", [id]) {
      let url = try safeURL(row["path"] as! String)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
      let summary = root.appendingPathComponent("exports/summary-\(row["id"] as! String).json")
      if FileManager.default.fileExists(atPath:summary.path) {try FileManager.default.removeItem(at:summary)}
      let report=root.appendingPathComponent("exports/learning-report-\(row["id"] as! String).png")
      if FileManager.default.fileExists(atPath:report.path) {try FileManager.default.removeItem(at:report)}
    }
    let status = SecItemDelete(keyQuery(id) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalFailure("凭据清理未完成，请解锁后重试；已保留删除状态。") }
    try run("BEGIN IMMEDIATE")
    do {
      try run("DELETE FROM sessions WHERE user_id=?", [id]); try run("DELETE FROM account WHERE id=?", [id]); try run("COMMIT")
    } catch { try? run("ROLLBACK"); throw error }
  }
  func createSession(device: String, kind: String = "diagnostic", task: [String: Any] = [:]) throws -> (String, URL) {
    try queue.sync {
      try open(); let owner = try requireUser(); let id = UUID().uuidString
      if ["baseline","task"].contains(kind) {try requireSignalProfile()}
      guard try rows("SELECT id FROM sessions WHERE user_id=? AND kind IN ('baseline','task') AND task_state IN ('active','interrupted_pending')", [owner]).isEmpty else { throw LocalFailure("请先处理未完成的基线记录。") }
      let path = "neurox-\(id).jsonl"
      try run("INSERT INTO sessions(id,user_id,name,path,state,started,device,kind,task_state,task_json) VALUES(?,?,?,?,'creating',?,?,?,?,?)", [id, owner, ["baseline","task"].contains(kind) ? task["name"] as? String ?? "学习任务" : "采集诊断", path, Date().timeIntervalSince1970, device, kind, ["baseline","task"].contains(kind) ? "active" : "none", try encode(["baseline","task"].contains(kind) ? task.merging(["profile":signalProfile,"algorithm":LocalStore.baselineAlgorithm]) {_,new in new} : task)])
      captureOwner = owner
      return (id, try safeURL(path))
    }
  }
  func updateSession(_ id: String, state: String, packets: Int, samples: Int, reason: String) throws {
    try queue.sync {
      try run("UPDATE sessions SET state=?, packets=?, samples=?, ended=?, reason=? WHERE id=? AND state IN ('creating','recording','save_failed')", [state, packets, samples, state == "recording" ? NSNull() : Date().timeIntervalSince1970, reason, id])
    }
  }
  private func encode(_ value: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else { throw LocalFailure("基线数据包含无效数值。") }
    return String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
  }
  func requireSignalProfile() throws {
    let provisional = signalProfile["mode"] as? String == "raw_ratio_provisional" && signalProfile["assumptionAccepted"] as? Bool == true && signalProfile["sampleRateAssumed"] as? Bool == true && signalProfile["verified"] as? Bool != true && signalProfile["sampleRate"] as? Double == 512 && signalProfile["scale"] as? Double == 1 && signalProfile["unit"] as? String == "SDK raw"
    guard signalProfile["verified"] as? Bool == true || provisional,
      let evidence = signalProfile["evidence"] as? String, !evidence.isEmpty,
      let unit = signalProfile["unit"] as? String, !unit.isEmpty,
      let hz = signalProfile["sampleRate"] as? Double, hz.isFinite, hz >= 128, hz <= 2048 else {
      throw LocalFailure("设备采样率、物理单位或质量参数尚未确认，不能开始基线。")
    }
    guard hz == 512 else {throw LocalFailure("当前SDK算法仅支持512Hz配置。")}
    for key in ["scale", "flatStd", "maxPeakToPeak", "maxStep"] {
      guard let value = signalProfile[key] as? Double, value.isFinite, value > 0 else { throw LocalFailure("质量配置无效，不能开始基线。") }
    }
    guard let low = signalProfile["adcMin"] as? Double, let high = signalProfile["adcMax"] as? Double,
      low.isFinite, high.isFinite, low < high,
      (signalProfile["maxPeakToPeak"] as? Double ?? 0) > (signalProfile["flatStd"] as? Double ?? 0) else { throw LocalFailure("质量配置无效，不能开始基线。") }
  }
  func beginAttempt(id: String, context: [String: Any]) throws -> String {
    try queue.sync {
      try requireSignalProfile(); let owner = try requireUser(); let row = try owned(["id": id], owner)
      guard row["kind"] as? String == "baseline", row["task_state"] as? String == "active" else { throw LocalFailure("学习任务不能采集基线，请到个人基线重新记录。") }
      let attempt = UUID().uuidString
      try run("BEGIN IMMEDIATE")
      do {
        try run("UPDATE baseline_attempts SET state='invalid' WHERE session_id=? AND state IN ('collecting','ready')", [id])
        try run("INSERT INTO baseline_attempts(id,session_id,user_id,state,context_json) VALUES(?,?,?,'collecting',?)", [attempt,id,owner,try encode(context)])
        try run("UPDATE sessions SET current_attempt=?, baseline_json='{}' WHERE id=? AND user_id=?", [attempt,id,owner])
        try run("COMMIT");return attempt
      } catch { try? run("ROLLBACK");throw error }
    }
  }
  func resumeTaskFile(id: String) throws -> URL {
    try queue.sync {
      try requireSignalProfile(); let owner = try requireUser(); let row = try owned(["id":id],owner)
      guard ["baseline","task"].contains(row["kind"] as? String ?? ""), row["task_state"] as? String == "active" else {throw LocalFailure("基线任务已结束，不能继续。")}
      let url = try safeURL(row["path"] as! String)
      guard FileManager.default.fileExists(atPath:url.path) else {throw LocalFailure("原始文件缺失，无法继续基线。")}
      return url
    }
  }
  func activateTaskFile(id: String) throws {
    try queue.sync {
      let owner = try requireUser();let row = try owned(["id":id],owner)
      guard row["task_state"] as? String == "active" else {throw LocalFailure("基线任务已结束，不能继续。")}
      try run("UPDATE sessions SET state='recording', ended=NULL WHERE id=? AND user_id=?",[id,owner]);captureOwner=owner
    }
  }
  func saveBaseline(_ args: [String:Any]) throws {
    try queue.sync {
      let owner=try requireUser();let id=args["id"] as? String ?? "";let row=try owned(["id":id],owner)
      let attempt=args["attempt"] as? String ?? ""
      guard ["baseline","task"].contains(row["kind"] as? String ?? ""),row["task_state"] as? String == "active", row["current_attempt"] as? String == attempt,
        let saved=try rows("SELECT * FROM baseline_attempts WHERE id=? AND user_id=?",[attempt,owner]).first,
        let snapshot=args["snapshot"] as? [String:Any], let state=snapshot["state"] as? String,
        ["collecting","ready","failed","invalid"].contains(state) else {throw LocalFailure("基线尝试已变更，请重新检查。")}
      if saved["state"] as? String == "invalid", state != "invalid" {throw LocalFailure("基线已失效，请重新采集。")}
      if row["kind"] as? String == "task" {
        let frozen=try decode(saved["snapshot"])
        guard args["window"] == nil,let original=frozen["referenceOrigin"] as? [String:Any],let proposed=snapshot["referenceOrigin"] as? [String:Any],
          NSDictionary(dictionary:original).isEqual(to:proposed),let stats=frozen["statistics"] as? [String:Any],let supplied=snapshot["statistics"] as? [String:Any],NSDictionary(dictionary:stats).isEqual(to:supplied) else {throw LocalFailure("学习任务只能复用已保存参考，不能覆盖基线统计。")}
      }
      let elapsed=(snapshot["elapsed"] as? NSNumber)?.doubleValue ?? -1
      let valid=(snapshot["validSeconds"] as? NSNumber)?.doubleValue ?? -1
      guard elapsed.isFinite, valid.isFinite, elapsed>=0, elapsed<=182, valid>=0, valid <= elapsed + 0.01 else {throw LocalFailure("基线计时无效。")}
      if state == "ready" {
        guard valid>=60, elapsed>0, valid/elapsed>=0.7, let statistics=snapshot["statistics"] as? [String:Any], !statistics.isEmpty else {throw LocalFailure("基线有效数据不足。")}
      }
      guard let context = snapshot["context"] as? [String:Any],
        let storedData = (saved["context_json"] as? String)?.data(using:.utf8),
        let storedContext = try JSONSerialization.jsonObject(with:storedData) as? [String:Any],
        NSDictionary(dictionary:context).isEqual(to:storedContext), snapshot["attemptId"] as? String == attempt else {throw LocalFailure("基线尝试已变更，请重新检查。")}
      if storedContext["algorithm"] as? String == LocalStore.baselineAlgorithm {
        guard snapshot["algorithm"] as? String == LocalStore.baselineAlgorithm,
          let definition = snapshot["featureDefinition"] as? [String:Any], definition["version"] as? String == LocalStore.baselineAlgorithm else {throw LocalFailure("基线算法版本不一致，请重新采集。")}
        if state == "ready" {
          let stats = snapshot["statistics"] as? [String:Any] ?? [:]
          guard elapsed>=90,elapsed<=180,valid.rounded()==valid,
            let attemptElapsed=(snapshot["attemptElapsed"] as? NSNumber)?.doubleValue,attemptElapsed.isFinite,abs(attemptElapsed-elapsed-10)<0.02,
            snapshot["adaptationSeconds"] as? Int == 10,snapshot["readingVersion"] as? String == "neutral-reading-v1" else {throw LocalFailure("学习基线采集或适应时长不足。")}
          for key in ["attention","relax"] {
            guard let metric=stats[key] as? [String:Any], let mean=(metric["mean"] as? NSNumber)?.doubleValue,
              let variance=(metric["variance"] as? NSNumber)?.doubleValue, mean.isFinite,mean>=0,mean<=100, variance.isFinite,variance>=0,variance<=400,
              let drift=(metric["drift"] as? NSNumber)?.doubleValue,drift.isFinite,drift>=0,drift<=10 else {throw LocalFailure("个人参考统计退化，请重新采集。")}
          }
          let attention=stats["attention"] as! [String:Any]
          guard (attention["mean"] as! NSNumber).doubleValue > max(sqrt((attention["variance"] as! NSNumber).doubleValue),5) else {throw LocalFailure("专注参考过低，无法比较下降，请重新采集。")}
        }
      }
      var persisted=snapshot
      let previous = (try? decode(saved["snapshot"])) ?? [:]
      if state == "ready" && snapshot["referenceOrigin"] == nil {
        persisted["nativeReadyAtUptime"] = saved["state"] as? String == "ready" ? previous["nativeReadyAtUptime"] ?? uptime() : uptime()
      }
      let value=try encode(persisted)
      try run("BEGIN IMMEDIATE")
      do {
        try run("UPDATE baseline_attempts SET state=?,snapshot=? WHERE id=? AND user_id=?",[state,value,attempt,owner])
        try run("UPDATE sessions SET baseline_json=? WHERE id=? AND user_id=?",[value,id,owner])
        if let window=args["window"] as? [String:Any],let sequence=window["sequence"] as? Int {
          try run("INSERT OR IGNORE INTO baseline_windows(attempt_id,sequence,payload) VALUES(?,?,?)",[attempt,sequence,try encode(window)])
        }
        try run("COMMIT")
      }catch{try? run("ROLLBACK");throw error}
    }
  }
  func invalidateBaseline(id: String, reason: String) throws {
    try queue.sync {try invalidateBaselineUnlocked(id:id,reason:reason)}
  }
  private func invalidateBaselineUnlocked(id: String, reason: String) throws {
      guard let row=try rows("SELECT current_attempt FROM sessions WHERE id=? AND kind IN ('baseline','task') AND task_state='active'",[id]).first else{return}
      let attempt = row["current_attempt"] as? String ?? ""
      if let saved = try rows("SELECT snapshot FROM baseline_attempts WHERE id=? AND state IN ('collecting','ready')",[attempt]).first,
        let data = (saved["snapshot"] as? String)?.data(using:.utf8),
        var snapshot = try JSONSerialization.jsonObject(with:data) as? [String:Any] {
        snapshot["state"]="invalid";snapshot["reason"]=reason
        let value = try encode(snapshot)
        try run("UPDATE baseline_attempts SET state='invalid',snapshot=? WHERE id=? AND state IN ('collecting','ready')",[value,attempt])
        try run("UPDATE sessions SET baseline_json=? WHERE id=?",[value,id])
      }
  }
  func finishBaseline(id: String) throws {
    try queue.sync {
      let owner=try requireUser();let row=try owned(["id":id],owner)
      guard ["baseline","task"].contains(row["kind"] as? String ?? "") else{throw LocalFailure("无法访问该记录。") }
      if row["kind"] as? String == "task" {try finishMonitorUnlocked(row:row,owner:owner);return}
      guard !["recording","creating"].contains(row["state"] as? String ?? "") else {throw LocalFailure("请先停止记录。")}
      let attempt=try rows("SELECT state FROM baseline_attempts WHERE id=? AND user_id=?",[row["current_attempt"] ?? "",owner]).first
      if attempt?["state"] as? String == "collecting" {try run("UPDATE baseline_attempts SET state='invalid' WHERE id=?",[row["current_attempt"] ?? ""])}
      let state=attempt?["state"] as? String == "ready" ? "baseline_ready" : "baseline_incomplete"
      let url = try safeURL(row["path"] as! String)
      if FileManager.default.fileExists(atPath:url.path) {
        let attempts = try rows("SELECT id,state,context_json,snapshot FROM baseline_attempts WHERE session_id=? AND user_id=? ORDER BY rowid",[id,owner])
        let handle = try FileHandle(forWritingTo:url)
        defer {try? handle.close()}
        try handle.seekToEnd()
        var data = try JSONSerialization.data(withJSONObject:["type":"baseline_summary","task_state":state,"session_id":id,"task":row["task_json"] ?? "{}","attempts":attempts],options:[.sortedKeys])
        data.append(0x0a);try handle.write(contentsOf:data);try handle.synchronize()
      }
      try run("UPDATE sessions SET task_state=? WHERE id=? AND user_id=?",[state,id,owner])
    }
  }
  private func decode(_ value: Any?) throws -> [String:Any] {
    guard let string=value as? String,let data=string.data(using:.utf8),let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw LocalFailure("任务摘要无法读取。")}
    return result
  }
  private func referenceCompatible(_ saved:[String:Any],_ current:[String:Any]) -> Bool {
    let keys=["algorithm","device","profile","unit","mode","sampleRate","sampleRateAssumed"]
    let one=Dictionary(uniqueKeysWithValues:keys.map{($0,saved[$0] ?? NSNull())})
    let two=Dictionary(uniqueKeysWithValues:keys.map{($0,current[$0] ?? NSNull())})
    return NSDictionary(dictionary:one).isEqual(to:two)
  }
  private func referenceInfoUnlocked(owner:String,context:[String:Any]?) throws -> [String:Any] {
    let candidates=try rows("SELECT * FROM sessions WHERE user_id=? AND kind='baseline' AND task_state='baseline_ready' AND state='saved' ORDER BY started DESC,rowid DESC",[owner])
    let selection=try rows("SELECT value FROM user_settings WHERE user_id=? AND key='reference'",[owner]).first
    let selectedID=selection.flatMap {try? decode($0["value"])["id"] as? String}
    let effective = selectedID == nil ? Array(candidates.prefix(1)) : candidates.filter {$0["id"] as? String == selectedID}
    for row in effective {
      guard let snapshot=try? decode(row["baseline_json"]),snapshot["algorithm"] as? String == LocalStore.baselineAlgorithm,snapshot["state"] as? String == "ready",let saved=snapshot["context"] as? [String:Any] else {continue}
      if selectedID == nil {try run("INSERT OR REPLACE INTO user_settings(user_id,key,value) VALUES(?,'reference',?)",[owner,try encode(["id":row["id"] ?? ""])])}
      return ["available":true,"id":row["id"] ?? "","started":row["started"] ?? 0,"device":row["device"] ?? "","snapshot":snapshot,"compatible":context.map{referenceCompatible(saved,$0)} ?? false]
    }
    return ["available":false,"compatible":false]
  }
  func validateSavedReference(sourceID:String,context:[String:Any]) throws {
    try queue.sync {
      let owner=try requireUser(),source=try owned(["id":sourceID],owner)
      guard source["kind"] as? String == "baseline",source["task_state"] as? String == "baseline_ready",source["state"] as? String == "saved",
        let snapshot=try? decode(source["baseline_json"]),snapshot["state"] as? String == "ready",snapshot["algorithm"] as? String == LocalStore.baselineAlgorithm,
        let saved=snapshot["context"] as? [String:Any],referenceCompatible(saved,context) else {throw LocalFailure("个人基线与当前设备或算法配置不匹配，请重新记录基线。")}
    }
  }
  /// Copies the saved statistics, never creates new baseline observations.
  func attachSavedReference(id:String,sourceID:String,context:[String:Any]) throws -> [String:Any] {
    try queue.sync {
      let owner=try requireUser(),task=try owned(["id":id],owner),source=try owned(["id":sourceID],owner)
      guard task["kind"] as? String == "task",task["task_state"] as? String == "active",source["kind"] as? String == "baseline",source["task_state"] as? String == "baseline_ready",source["state"] as? String == "saved" else {throw LocalFailure("请先建立并保存个人基线。")}
      var snapshot=try decode(source["baseline_json"])
      guard snapshot["state"] as? String == "ready",snapshot["algorithm"] as? String == LocalStore.baselineAlgorithm,let saved=snapshot["context"] as? [String:Any],referenceCompatible(saved,context) else {throw LocalFailure("个人基线与当前设备或算法配置不匹配，请重新记录基线。")}
      let frozen=try decode(task["baseline_json"])
      if let origin=frozen["referenceOrigin"] as? [String:Any] {
        guard origin["sessionId"] as? String == sourceID,let original=origin["context"] as? [String:Any],referenceCompatible(original,context) else {throw LocalFailure("学习会话已锁定原基线，不能更换或重算。")}
        snapshot=frozen
      } else {
        snapshot["referenceOrigin"]=["version":"personal-reference-v1","sessionId":sourceID,"attemptId":snapshot["attemptId"] ?? "","collectedAt":source["started"] ?? 0,"context":saved,"reused":true]
      }
      let attempt=UUID().uuidString
      snapshot["attemptId"]=attempt;snapshot["context"]=context;snapshot["state"]="ready";snapshot["reason"]="good"
      snapshot["usagePolicy"]="saved personal baseline; explicit rerecord; no per-task collection or age expiry"
      snapshot.removeValue(forKey:"nativeReadyAtUptime")
      try run("BEGIN IMMEDIATE")
      do {
        try run("UPDATE baseline_attempts SET state='invalid' WHERE session_id=? AND state IN ('collecting','ready')",[id])
        try run("INSERT INTO baseline_attempts(id,session_id,user_id,state,context_json,snapshot) VALUES(?,?,?,'ready',?,?)",[attempt,id,owner,try encode(context),try encode(snapshot)])
        try run("UPDATE sessions SET current_attempt=?,baseline_json=? WHERE id=? AND user_id=?",[attempt,try encode(snapshot),id,owner])
        try run("COMMIT")
      }catch{try? run("ROLLBACK");throw error}
      return ["attempt":attempt,"snapshot":snapshot]
    }
  }
  func monitorStatus(id:String) throws -> [String:Any] {
    try queue.sync {let owner=try requireUser();let row=try owned(["id":id],owner);return try decode(row["monitor_json"])}
  }
  func startMonitoring(_ args:[String:Any], context:[String:Any]) throws {
    try queue.sync {
      let owner=try requireUser(),id=args["id"] as? String ?? "",row=try owned(["id":args["id"] ?? ""],owner)
      guard row["kind"] as? String == "task",row["task_state"] as? String == "active",
        let attempt=try rows("SELECT * FROM baseline_attempts WHERE id=? AND user_id=?",[row["current_attempt"] ?? "",owner]).first,
        attempt["state"] as? String == "ready",let snap=args["snapshot"] as? [String:Any],
        snap["referenceAttempt"] as? String == row["current_attempt"] as? String,
        NSDictionary(dictionary:try decode(attempt["context_json"])).isEqual(to:context),
        snap["phase"] as? String == "running" else {throw LocalFailure("基线或设备条件已变化，请重新采集。")}
      let previous=try decode(row["monitor_json"])
      let baseline=try decode(attempt["snapshot"])
      guard baseline["algorithm"] as? String == LocalStore.baselineAlgorithm else {throw LocalFailure("基线算法版本不一致，请重新采集。")}
      guard let snapContext=snap["context"] as? [String:Any],NSDictionary(dictionary:snapContext).isEqual(to:context),
        let proposed=snap["reference"] as? [String:Any],
        let storedStats=try decode(attempt["snapshot"])["statistics"] as? [String:Any],NSDictionary(dictionary:proposed).isEqual(to:storedStats),
        let minutes=try decode(row["task_json"])["minutes"] as? Int,snap["targetSeconds"] as? Int == minutes*60 else {throw LocalFailure("任务配置或个人参考不一致。")}
      if previous["phase"] as? String == "paused",let paused=(previous["pauseStartedWallSeconds"] as? NSNumber)?.doubleValue,
        let wall=(snap["wallSeconds"] as? NSNumber)?.doubleValue, wall-paused>=60,previous["referenceAttempt"] as? String == row["current_attempt"] as? String {throw LocalFailure("长时间暂停后需要重新准备数据。")}
      if previous["nativeInterrupted"] as? Bool == true, previous["referenceAttempt"] as? String == row["current_attempt"] as? String {throw LocalFailure("任务中断后需要重新准备数据。")}
      try saveMonitoringUnlocked(args,row:row,owner:owner,starting:true)

    }
  }
  func saveMonitoring(_ args:[String:Any]) throws -> Bool {
    try queue.sync {
      let owner=try requireUser(),row=try owned(["id":args["id"] ?? ""],owner)
      let previous=try decode(row["monitor_json"]),snap=args["snapshot"] as? [String:Any] ?? [:]
      if previous["nativeInterrupted"] as? Bool == true, snap["phase"] as? String == "running" {return false}
      try saveMonitoringUnlocked(args,row:row,owner:owner);return true
    }
  }
  private func saveMonitoringUnlocked(_ args:[String:Any],row:[String:Any],owner:String,starting:Bool=false) throws {
    guard row["task_state"] as? String == "active",let snap=args["snapshot"] as? [String:Any],
      ["sdk-personal-monitor-v1","sdk-personal-monitor-v2"].contains(snap["version"] as? String ?? ""),snap["algorithm"] as? String == LocalStore.baselineAlgorithm,
      ["running","paused","preparing","interrupted","rebuilding","recovery","finished"].contains(snap["phase"] as? String ?? ""),
      let elapsed=(snap["elapsed"] as? NSNumber)?.doubleValue,let valid=(snap["validSeconds"] as? NSNumber)?.doubleValue,
      let target=snap["targetSeconds"] as? Int,target>=0,target<=10800,elapsed.isFinite,valid.isFinite,
      elapsed>=0,(target==0 || elapsed<=Double(target)+0.01),valid>=0,valid<=elapsed+0.01 else {throw LocalFailure("任务计时或摘要无效。")}
    if snap["phase"] as? String == "running", snap["referenceAttempt"] as? String != row["current_attempt"] as? String {throw LocalFailure("基线或设备条件已变化，请重新采集。")}
    let durations=snap["durations"] as? [String:Any] ?? [:]
    let stable=(durations["stable"] as? NSNumber)?.doubleValue ?? -1,deviation=(durations["deviation"] as? NSNumber)?.doubleValue ?? -1,unknown=(durations["unknown"] as? NSNumber)?.doubleValue ?? -1
    guard stable.isFinite,deviation.isFinite,unknown.isFinite,stable>=0,deviation>=0,unknown>=0,
      abs(stable+deviation+unknown-elapsed)<0.02,abs(stable+deviation-valid)<0.02 else {throw LocalFailure("任务时间分段不一致。")}
    let bound=try decode(row["baseline_json"])
    guard let expected=bound["statistics"] as? [String:Any],let supplied=snap["reference"] as? [String:Any],NSDictionary(dictionary:expected).isEqual(to:supplied) else {throw LocalFailure("学习会话已锁定原基线，不能更换或重算。")}
    let old=try decode(row["monitor_json"])
    guard elapsed+0.01 >= ((old["elapsed"] as? NSNumber)?.doubleValue ?? 0) else {throw LocalFailure("任务摘要已更新，请刷新。")}
    var effective=snap
    if let origin=bound["referenceOrigin"] as? [String:Any] {effective["referenceOrigin"]=origin}
    if old["nativeInterrupted"] as? Bool == true && !starting {effective["nativeInterrupted"]=true}
    if old["checkpointOnly"] as? Bool == true {effective["checkpointOnly"]=true}
    let id=row["id"] as! String,encoded=try encode(effective)
    try run("BEGIN IMMEDIATE")
    do {
      try run("UPDATE sessions SET monitor_json=? WHERE id=? AND user_id=?",[encoded,id,owner])
      if starting {try run("UPDATE sessions SET kind='task' WHERE id=? AND user_id=?",[id,owner])}
      for event in args["events"] as? [[String:Any]] ?? [] {
        guard let sequence=event["sequence"] as? Int,sequence>0 else {throw LocalFailure("任务事件无效。")}
        let payload=try encode(event)
        if let existing=try rows("SELECT payload FROM task_events WHERE session_id=? AND sequence=?",[id,sequence]).first {
          // Native may add haptic delivery fields to this same immutable event.
          var before=try decode(existing["payload"]),after=event
          for key in ["delivery","requestedAtUnix"] {before.removeValue(forKey:key);after.removeValue(forKey:key)}
          guard try encode(before)==encode(after) else {throw LocalFailure("任务事件编号冲突。")}
        } else {try run("INSERT INTO task_events(session_id,sequence,payload) VALUES(?,?,?)",[id,sequence,payload])}
      }
      try run("COMMIT")
    } catch {try? run("ROLLBACK");throw error}
  }
  func interruptMonitoring(id:String,reason:String) throws {try queue.sync {try interruptMonitorUnlocked(id:id,reason:reason)}}
  private func interruptMonitorUnlocked(id:String,reason:String) throws {
    guard let row=try rows("SELECT monitor_json FROM sessions WHERE id=? AND kind='task' AND task_state='active'",[id]).first else {return}
    var snapshot=try decode(row["monitor_json"])
    snapshot["phase"]="interrupted";snapshot["state"]="unknown";snapshot["reason"]=reason
    snapshot["nativeInterrupted"]=true;snapshot["checkpointOnly"]=true
    try run("UPDATE sessions SET monitor_json=? WHERE id=?",[try encode(snapshot),id])
  }
  func requestMonitorAlert(id:String,sequence:Int) throws -> Bool {
    try queue.sync {
      let owner=try requireUser(),row=try owned(["id":id],owner),snapshot=try decode(row["monitor_json"])
      guard row["task_state"] as? String == "active",snapshot["phase"] as? String == "running",snapshot["state"] as? String == "deviation",snapshot["remindersEnabled"] as? Bool == true,
        let attempt=try rows("SELECT state FROM baseline_attempts WHERE id=? AND user_id=?",[row["current_attempt"] ?? "",owner]).first,attempt["state"] as? String == "ready",
        let event=try rows("SELECT payload FROM task_events WHERE session_id=? AND sequence=?",[id,sequence]).first else {return false}
      if (try decode(row["task_json"]))["scene"] as? String == "training" {return false}
      var payload=try decode(event["payload"])
      guard payload["type"] as? String == "reminder",payload["delivery"] as? String == "pending",((payload["candidateSeconds"] as? NSNumber)?.doubleValue ?? 0) >= (((snapshot["rules"] as? [String:Any])?["sustainedSeconds"] as? NSNumber)?.doubleValue ?? 25) else {return false}
      guard payload["attempt"] as? String == row["current_attempt"] as? String,
        let eventTime=(payload["elapsed"] as? NSNumber)?.doubleValue,
        let currentTime=(snapshot["elapsed"] as? NSNumber)?.doubleValue, currentTime-eventTime>=0,currentTime-eventTime<=2 else {return false}
      let previousEvents=try rows("SELECT sequence,payload FROM task_events WHERE session_id=? AND sequence<? ORDER BY sequence DESC",[id,sequence])
      var episodeStart=0
      for previous in previousEvents {
        let item=try decode(previous["payload"])
        if item["type"] as? String == "deviation",item["attempt"] as? String == payload["attempt"] as? String {
          episodeStart=(previous["sequence"] as? NSNumber)?.intValue ?? 0;break
        }
      }
      for previous in previousEvents {
        let number=(previous["sequence"] as? NSNumber)?.intValue ?? 0
        if number<=episodeStart {break}
        let item=try decode(previous["payload"])
        if item["type"] as? String == "reminder",item["attempt"] as? String == payload["attempt"] as? String,item["requestedAtUnix"] is NSNumber {return false}
      }
      let now=Date().timeIntervalSince1970
      payload["delivery"]="feedback_requested";payload["requestedAtUnix"]=now
      try run("UPDATE task_events SET payload=? WHERE session_id=? AND sequence=?",[try encode(payload),id,sequence]);return true
    }
  }
  func monitorFinalized(id:String) throws -> Bool {
    try queue.sync {let owner=try requireUser();let row=try owned(["id":id],owner);return ["task_complete","task_ended"].contains(row["task_state"] as? String ?? "")}
  }
  func finishMonitoring(id:String) throws {
    try queue.sync {let owner=try requireUser();let row=try owned(["id":id],owner);try finishMonitorUnlocked(row:row,owner:owner)}
  }
  private func finishMonitorUnlocked(row:[String:Any],owner:String) throws {
    if ["task_complete","task_ended"].contains(row["task_state"] as? String ?? "") {return}
    guard row["kind"] as? String == "task",!["recording","creating"].contains(row["state"] as? String ?? "") else {throw LocalFailure("请先停止并保存任务。")}
    let id=row["id"] as! String
    var snapshot=try decode(row["monitor_json"])
    if snapshot["phase"] as? String != "finished" {snapshot["phase"]="finished";snapshot["endReason"]="interrupted";snapshot["checkpointOnly"]=true}
    let reason=snapshot["endReason"] as? String ?? "",target=(snapshot["targetSeconds"] as? NSNumber)?.doubleValue ?? -1,elapsed=(snapshot["elapsed"] as? NSNumber)?.doubleValue ?? -1
    let task=try decode(row["task_json"]),game=snapshot["game"] as? [String:Any] ?? [:]
    let timed=reason == "target_reached" && target>0 && elapsed+0.01>=target
    let manual=reason == "user_completed" && target==0 && task["scene"] as? String != "training"
    let played=task["scene"] as? String == "training" && game["finished"] as? Bool == true && ((reason == "game_completed" && game["outcome"] as? String == "completed") || (reason == "protocol_finished" && game["outcome"] as? String == "timeout"))
    let state=(timed || manual || played) && row["task_state"] as? String != "interrupted_pending" && row["state"] as? String == "saved" ? "task_complete" : "task_ended"
    let events=try rows("SELECT sequence,payload FROM task_events WHERE session_id=? ORDER BY sequence",[id])
    let url=try safeURL(row["path"] as! String)
    if FileManager.default.fileExists(atPath:url.path) {
      let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()};try handle.seekToEnd()
      var data=try JSONSerialization.data(withJSONObject:["type":"task_summary","session_id":id,"summary":snapshot,"events":try events.map{try decode($0["payload"])}],options:[.sortedKeys]);data.append(0x0a);try handle.write(contentsOf:data);try handle.synchronize()
    }
    try run("UPDATE sessions SET task_state=?,monitor_json=? WHERE id=? AND user_id=?",[state,try encode(snapshot),id,owner])
  }
  func summaryURL(id:String) throws -> URL {
    try queue.sync {
      let owner=try requireUser();let row=try fileInfo(owned(["id":id],owner))
      guard row["kind"] as? String == "task",!["active","interrupted_pending"].contains(row["task_state"] as? String ?? "") else {throw LocalFailure("请先结束并保存任务。")}
      let directory=root.appendingPathComponent("exports");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      let url=directory.appendingPathComponent("summary-\(id).json")
      var exported:[String:Any]=["session":["id":row["id"] ?? "","name":row["name"] ?? "","started":row["started"] ?? 0,"state":row["task_state"] ?? "","device":row["device"] ?? ""],"summary":try decode(row["monitor_json"]),"feedback":try decode(row["feedback_json"]),"events":try (row["events"] as? [[String:Any]] ?? []).map{try decode($0["payload"])}]
      exported["attempts"]=try (row["attempts"] as? [[String:Any]] ?? []).map {item -> [String:Any] in
        ["id":item["id"] ?? "","state":item["state"] ?? "","context":try decode(item["context_json"]),"snapshot":try decode(item["snapshot"])]
      }
      try JSONSerialization.data(withJSONObject:exported,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic);return url
    }
  }
  func learningReportURL(id:String,png:Data) throws -> URL {
    try queue.sync {
      let owner=try requireUser(),row=try owned(["id":id],owner)
      let task=try decode(row["task_json"]),summary=try decode(row["monitor_json"])
      guard row["kind"] as? String == "task",["learning","esports","go","archery"].contains(task["scene"] as? String ?? summary["scene"] as? String ?? ""),
        !["active","interrupted_pending"].contains(row["task_state"] as? String ?? ""),
        !["recording","creating","deleting"].contains(row["state"] as? String ?? ""),
        png.count>8,png.count<=20*1024*1024,Array(png.prefix(8)) == [137,80,78,71,13,10,26,10] else {throw LocalFailure("请先结束并保存任务，再导出报告图片。")}
      let directory=root.appendingPathComponent("exports");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      let url=directory.appendingPathComponent("learning-report-\(id).png")
      try png.write(to:url,options:.atomic);return url
    }
  }
  func exportURL(id: String) throws -> URL {
    try queue.sync {
      let owner = try requireUser(); let row = try owned(["id": id], owner)
      guard !["recording", "creating", "deleting"].contains(row["state"] as? String ?? "") else { throw LocalFailure("请先停止并保存记录，或完成清理。") }
      let url = try safeURL(row["path"] as! String)
      guard FileManager.default.fileExists(atPath: url.path) else { throw LocalFailure("原始文件缺失，无法导出。") }
      return url
    }
  }
}
