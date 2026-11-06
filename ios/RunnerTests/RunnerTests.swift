import Flutter
import UIKit
import XCTest
import Security
import SQLite3
@testable import Runner

/// Runs against real SQLite and simulator Keychain, never BLE or user data.
class RunnerTests: XCTestCase {
  func testCaptureHealthIsBoundedAndNeverStoresPayloadsOrErrorDescriptions() throws {
    let url = root.appendingPathComponent("health.json")
    let health = CaptureDiagnostics(url: url)
    health.updateContext(phase: "ready", recording: true, foreground: true, connection: 1)
    let error = NSError(domain: "NSCocoaErrorDomain", code: 640, userInfo: [NSLocalizedDescriptionKey: "SECRET PATH", NSUnderlyingErrorKey: NSError(domain: "NSPOSIXErrorDomain", code: 28)])
    for _ in 0..<110 {
      health.record("write_failure", fields: ["stage": "write", "raw": [1,2], "account": "SECRET", "path": "SECRET"], error: error)
      health.waitForPendingWrites()
    }
    let data = try Data(contentsOf: url)
    let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let events = value["events"] as! [[String: Any]]
    XCTAssertEqual(events.count, CaptureDiagnostics.eventLimit)
    XCTAssertLessThanOrEqual(data.count, CaptureDiagnostics.byteLimit)
    XCTAssertEqual(events.last?["errorCode"] as? Int, 640)
    XCTAssertEqual(events.last?["underlyingCode"] as? Int, 28)
    XCTAssertEqual(events.last?["stage"] as? String, "write")
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET"))
    XCTAssertNil(events.last?["raw"])
    let before = data
    health.record("SECRET", fields: ["phase": "SECRET"])
    health.waitForPendingWrites()
    XCTAssertEqual(try Data(contentsOf: url), before)
    try Data(repeating: 0x41, count: CaptureDiagnostics.byteLimit + 1).write(to: url)
    health.record("system_disconnect", error: NSError(domain: "CBErrorDomain", code: 6))
    health.waitForPendingWrites()
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    XCTAssertEqual((restored["events"] as? [Any])?.count, 1)
  }

  func testCaptureHealthTracksQueueWaitSizesAndSeparateSyncAndIndexTimes() throws {
    let health = CaptureDiagnostics(url: root.appendingPathComponent("metrics.json"))
    health.beginCapture()
    let queued = health.enqueueRecord()
    _ = health.enqueueRecord()
    let started = health.startRecord(queuedAt: queued - 0.1)
    health.fileSize(12345)
    health.duration("Sync", milliseconds: 12)
    health.duration("Index", milliseconds: 25)
    health.finishRecord(startedAt: started)
    health.finishRecord(startedAt: started)
    let metrics = health.snapshot()
    XCTAssertEqual(metrics["pendingRecords"] as? Double, 0)
    XCTAssertEqual(metrics["peakPendingRecords"] as? Double, 2)
    XCTAssertEqual(metrics["fileBytes"] as? Double, 12345)
    XCTAssertGreaterThanOrEqual(metrics["maxQueueMs"] as? Double ?? 0, 100)
    XCTAssertEqual(metrics["maxSyncMs"] as? Double, 12)
    XCTAssertEqual(metrics["maxIndexMs"] as? Double, 25)
    health.waitForPendingWrites()
  }

  func testCaptureHealthDropsDiagnosticBacklogAndCacheFailureIsNonfatal() throws {
    let queue = DispatchQueue(label: "test.blocked.health")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    let url = root.appendingPathComponent("backlog.json")
    let health = CaptureDiagnostics(url: url, queue: queue)
    for _ in 0..<100 { health.record("io_sample") }
    XCTAssertGreaterThan(health.snapshot()["droppedDiagnostics"] as? Double ?? 0, 0)
    gate.signal(); health.waitForPendingWrites()
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    XCTAssertLessThanOrEqual((value["events"] as? [Any])?.count ?? 100, 8)
    let blocked = root.appendingPathComponent("not-a-directory")
    try Data().write(to: blocked)
    let failing = CaptureDiagnostics(url: blocked.appendingPathComponent("summary.json"))
    failing.record("system_disconnect")
    failing.waitForPendingWrites() // Failure to save diagnostics has no capture callback.
    XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("summary.json").path))
  }

  @MainActor func testRecordingSerializationFailureRetainsWriteStageAndAppDisconnectCause() async throws {
    try register()
    let url = root.appendingPathComponent("health.json")
    let health = CaptureDiagnostics(url: url)
    let defaults = UserDefaults(suiteName: service)!
    defer { defaults.removePersistentDomain(forName: service) }
    let notices = AppNotifications(preferences: defaults, schedule: { _, _ in }, cancel: { _ in })
    let bridge = EegBleBridge(store: store, notifications: notices, observeLifecycle: false, diagnostics: health)
    let started = expectation(description: "created")
    bridge.beginRecording(device: "SYNTHETIC ONLY") { result in XCTAssertTrue(result is String); started.fulfill() }
    await fulfillment(of: [started], timeout: 5)
    bridge.appendRecord(["type": "packet", "invalid": Double.nan])
    let drained = expectation(description: "error handling drained")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drained.fulfill() }
    await fulfillment(of: [drained], timeout: 5)
    health.waitForPendingWrites()
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let events = value["events"] as! [[String: Any]]
    XCTAssertTrue(events.contains { $0["event"] as? String == "write_failure" && $0["stage"] as? String == "serialize" })
    XCTAssertTrue(events.contains { $0["event"] as? String == "app_disconnect" && $0["reason"] as? String == "recording_write_failed" })
    XCTAssertFalse(events.contains { $0["event"] as? String == "system_disconnect" })
    XCTAssertEqual(health.snapshot()["pendingRecords"] as? Double, 0)
  }

  func testBaselineGuardDiagnosticsAreBoundedAndExcludeRawAndAccountData() throws {
    let url=root.appendingPathComponent("guard.json")
    for i in 0..<65 {
      try BaselineGuardDiagnostics.append(["type":"interrupted","reason":"contact","guardVersion":"baseline-guard-v2","elapsed":i,"leadByte":1,"raw":[1,2,3],"account":"private-user","scores":["attention":90]],to:url,version:"TEST",build:"TEST")
    }
    let data=try Data(contentsOf:url)
    let value=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    let events=try XCTUnwrap(value["events"] as? [[String:Any]])
    XCTAssertEqual(events.count,40)
    XCTAssertEqual(events.first?["elapsed"] as? Int,25)
    XCTAssertEqual(events.last?["elapsed"] as? Int,64)
    let text=String(data:data,encoding:.utf8)!
    XCTAssertFalse(text.contains("private-user"));XCTAssertFalse(text.contains("scores"));XCTAssertFalse(text.contains("\"raw\""))
  }
  func testBaselineGuardDiagnosticsRejectUnknownEventsAndRecoverFromOversizedCache() throws {
    let url=root.appendingPathComponent("guard.json")
    let good:[String:Any]=["type":"start","reason":"good","guardVersion":"baseline-guard-v2"]
    try BaselineGuardDiagnostics.append(good,to:url,version:"TEST",build:"TEST")
    let previous=try Data(contentsOf:url)
    XCTAssertThrowsError(try BaselineGuardDiagnostics.append(["type":"account","reason":"secret","guardVersion":"baseline-guard-v2"],to:url,version:"TEST",build:"TEST"))
    XCTAssertEqual(try Data(contentsOf:url),previous)
    try Data(repeating:0x41,count:65537).write(to:url)
    try BaselineGuardDiagnostics.append(good,to:url,version:"TEST",build:"TEST")
    let value=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    XCTAssertEqual((value["events"] as? [Any])?.count,1)
  }

  var root: URL!
  var service: String!
  var store: LocalStore!
  let password = "test-password-2026"
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    service = "neurox.tests.\(UUID().uuidString)"
    store = LocalStore(root: root, service: service)
  }
  override func tearDownWithError() throws {
    store = nil
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service!] as CFDictionary)
    try? FileManager.default.removeItem(at: root)
  }
  @discardableResult func call(_ name: String, _ args: [String: Any] = [:]) throws -> Any? {
    try store.queue.sync { try store.perform(name, args) }
  }
  func register() throws { try call("register", ["name": "student", "password": password]) }
  func sql(_ text: String) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(root.appendingPathComponent("neurox.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, text, nil, nil, nil), SQLITE_OK)
  }
  // Deliberately synthetic. Never used by the production LocalStore initializer.
  var baselineFixture: [String:Any] { ["verified":true,"version":"synthetic-v1","evidence":"Unit test only","unit":"test-unit","sampleRate":512.0,"scale":1.0,"flatStd":0.01,"maxPeakToPeak":20.0,"maxStep":2.0,"adcMin":-100.0,"adcMax":100.0] }
  func configureBaselineFixture() throws {
    store = LocalStore(root:root,service:service,signalProfile:baselineFixture)
    try register()
  }
  func testExplicitBaselineSelectionPersistsAndCannotCrossAccounts() throws {
    try configureBaselineFixture();let context=personalReferenceContext
    let (first,_,_)=try savePersonalReference(context:context,attention:60)
    let info=try call("baselineReference",["context":context]) as! [String:Any]
    XCTAssertEqual(info["id"] as? String,first)
    let (second,_,_)=try savePersonalReference(context:context,attention:70)
    XCTAssertEqual((try call("baselineReference",["context":context]) as! [String:Any])["id"] as? String,first)
    XCTAssertEqual(((try call("baselineList") as! [String:Any])["items"] as! [Any]).count,2)
    _ = try call("baselineSelect",["id":second,"context":context])
    try call("setFeedbackSettings",["sound":true,"vibration":false,"notice":false])
    store=LocalStore(root:root,service:service,signalProfile:baselineFixture)
    try call("login",["name":"student","password":password])
    XCTAssertEqual((try call("baselineReference",["context":context]) as! [String:Any])["id"] as? String,second)
    XCTAssertEqual((try call("feedbackSettings") as! [String:Any])["sound"] as? Bool,true)
    try call("logout");try call("register",["name":"other","password":password])
    XCTAssertThrowsError(try call("baselineSelect",["id":first,"context":context]))
    XCTAssertTrue((try call("feedbackSettings") as! [String:Any]).isEmpty)
  }
  func testSceneSnapshotSupportsLongStudyRecoveryAndFrozenReference() throws {
    try configureBaselineFixture();let context=personalReferenceContext
    let (source,_,reference)=try savePersonalReference(context:context)
    let (id,url)=try store.createSession(device:"SYNTHETIC",kind:"task",task:["minutes":45,"scene":"go"])
    try Data().write(to:url)
    let attached=try store.attachSavedReference(id:id,sourceID:source,context:context)
    var snapshot=monitoringSnapshot(attached["attempt"] as! String,context,reference,phase:"preparing")
    snapshot["version"]="sdk-personal-monitor-v2";snapshot["targetSeconds"]=2700
    snapshot["scene"]="go";snapshot["rules"]=["sustainedSeconds":10.0,"recoverySeconds":15.0]
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot]))
    snapshot["phase"]="recovery";snapshot["recoveryActivitySeconds"]=60.0
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot]))
    snapshot["reference"]=["attention":["mean":99,"variance":1],"relax":["mean":99,"variance":1]]
    XCTAssertThrowsError(try store.saveMonitoring(["id":id,"snapshot":snapshot]))
  }
  func testNotificationChannelOffCancelsWatchdogAndStateNoticeDoesNotRequestSound() {
    let defaults=UserDefaults(suiteName:UUID().uuidString)!
    var sent:[AppNotice]=[], cancelled:[String]=[]
    let notices=AppNotifications(preferences:defaults,schedule:{notice,_ in sent.append(notice)},cancel:{cancelled += $0})
    notices.setEnabled(true);notices.configure(["notice":true,"sound":false,"vibration":false])
    notices.receivedRaw(scope:"SYNTHETIC")
    XCTAssertEqual(sent.count,1)
    notices.configure(["notice":false,"sound":false,"vibration":false])
    XCTAssertFalse(cancelled.isEmpty)
    notices.post(AppNotice(kind:"state",scope:"ALL_OFF",title:"TEST",body:"TEST",sound:false))
    XCTAssertEqual(sent.count,1)
    notices.configure(["notice":true,"sound":false,"vibration":false])
    notices.post(AppNotice(kind:"state",scope:"ON",title:"TEST",body:"TEST",sound:false))
    XCTAssertEqual(sent.count,2);XCTAssertFalse(sent.last!.sound)
  }
  func testManualTimedAndGameCompletionCategoriesPersist() throws {
    try configureBaselineFixture();let context=personalReferenceContext
    let (source,_,reference)=try savePersonalReference(context:context)
    func finishCase(_ scene:String,_ target:Int,_ elapsed:Double,_ reason:String,_ game:[String:Any]=[:]) throws -> String {
      let (id,url)=try store.createSession(device:"SYNTHETIC",kind:"task",task:["minutes":target/60,"scene":scene]);try Data().write(to:url)
      let attached=try store.attachSavedReference(id:id,sourceID:source,context:context)
      var snapshot=monitoringSnapshot(attached["attempt"] as! String,context,reference,elapsed:elapsed,phase:"finished")
      snapshot["version"]="sdk-personal-monitor-v2";snapshot["targetSeconds"]=target;snapshot["endReason"]=reason;snapshot["game"]=game
      XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot]))
      try store.updateSession(id,state:"saved",packets:1,samples:16,reason:"");store.clearCaptureOwner();try store.finishMonitoring(id:id)
      return (try call("detail",["id":id]) as! [String:Any])["task_state"] as! String
    }
    XCTAssertEqual(try finishCase("learning",0,7200,"user_completed"),"task_complete")
    XCTAssertEqual(try finishCase("archery",0,10,"user_completed"),"task_complete")
    XCTAssertEqual(try finishCase("recovery",180,60,"user_ended"),"task_ended")
    XCTAssertEqual(try finishCase("recovery",180,60,"user_completed"),"task_ended")
    XCTAssertEqual(try finishCase("recovery",180,180,"target_reached"),"task_complete")
    XCTAssertEqual(try finishCase("training",0,25,"game_completed",["finished":true,"outcome":"completed"]),"task_complete")
    XCTAssertEqual(try finishCase("training",0,120,"protocol_finished",["finished":true,"outcome":"timeout"]),"task_complete")
    XCTAssertEqual(try finishCase("training",0,10,"user_ended",["finished":false,"outcome":"running"]),"task_ended")
  }
  func testGlobalMutePreservesChannelsAcrossRestartAndAccounts() throws {
    try register()
    try call("setFeedbackSettings",["sound":true,"vibration":false,"notice":true,"muted":false])
    try call("setFeedbackMute",["muted":true])
    var settings=try call("feedbackSettings") as! [String:Any]
    XCTAssertEqual(settings["muted"] as? Bool,true)
    XCTAssertEqual(settings["sound"] as? Bool,true)
    XCTAssertEqual(settings["vibration"] as? Bool,false)
    XCTAssertEqual(settings["notice"] as? Bool,true)
    store=LocalStore(root:root,service:service,signalProfile:baselineFixture)
    try call("login",["name":"student","password":password])
    settings=try call("feedbackSettings") as! [String:Any]
    XCTAssertEqual(settings["muted"] as? Bool,true)
    try call("setFeedbackMute",["muted":false])
    settings=try call("feedbackSettings") as! [String:Any]
    XCTAssertEqual(settings["muted"] as? Bool,false)
    XCTAssertEqual(settings["sound"] as? Bool,true)
    XCTAssertEqual(settings["notice"] as? Bool,true)
    try call("logout");try call("register",["name":"other","password":password])
    XCTAssertTrue((try call("feedbackSettings") as! [String:Any]).isEmpty)
  }
  func testGlobalMuteStopsAllFeedbackAndCancelsWatchdogUntilRestored() {
    let defaults=UserDefaults(suiteName:UUID().uuidString)!
    var sent=0,cancelled=0
    let notifications=AppNotifications(preferences:defaults,schedule:{_,_ in sent+=1},cancel:{_ in cancelled+=1})
    notifications.setEnabled(true)
    let channels:[String:Any]=["sound":true,"vibration":true,"notice":true,"muted":false]
    notifications.configure(channels);notifications.receivedRaw(scope:"normal")
    XCTAssertEqual(sent,1)
    notifications.configure(channels.merging(["muted":true]){_,new in new})
    XCTAssertTrue(notifications.userMuted);XCTAssertEqual(cancelled,1)
    notifications.post(AppNotice(kind:"state",scope:"muted",title:"TEST",body:"TEST"))
    notifications.receivedRaw(scope:"muted")
    notifications.deliverFeedback(channels,kind:"task.test",scope:"muted",title:"TEST",body:"TEST") {result in
      for key in ["sound","vibration","notice"] {XCTAssertEqual(result[key] as? String,"silenced")}
    }
    XCTAssertEqual(sent,1)
    notifications.configure(channels)
    XCTAssertFalse(notifications.userMuted)
    notifications.receivedRaw(scope:"restored")
    XCTAssertEqual(sent,2)
    XCTAssertEqual((defaults.dictionary(forKey:"neurox.feedback.channels")?["sound"] as? Bool),true)
  }
  func testGameSilenceSuppressesEveryChannelAndWatchdog() {
    let defaults=UserDefaults(suiteName:UUID().uuidString)!
    var sent=0,cancelled=0
    let notifications=AppNotifications(preferences:defaults,schedule:{_,_ in sent+=1},cancel:{_ in cancelled+=1})
    notifications.setEnabled(true);notifications.configure(["sound":false,"vibration":false,"notice":true]);notifications.receivedRaw(scope:"before")
    XCTAssertEqual(sent,1);notifications.taskSilenced=true;XCTAssertEqual(cancelled,1)
    notifications.post(AppNotice(kind:"state",scope:"game",title:"TEST",body:"TEST"));notifications.receivedRaw(scope:"game")
    notifications.deliverFeedback(["sound":true,"vibration":true,"notice":true],kind:"task.test",scope:"game",title:"TEST",body:"TEST") {channels in
      XCTAssertEqual(channels["sound"] as? String,"silenced");XCTAssertEqual(channels["vibration"] as? String,"silenced");XCTAssertEqual(channels["notice"] as? String,"silenced")
    }
    XCTAssertEqual(sent,1);notifications.taskSilenced=false
    notifications.post(AppNotice(kind:"state",scope:"after",title:"TEST",body:"TEST",sound:false));XCTAssertEqual(sent,2)
  }
  func testBaselineUnconfirmedProfileBlocksAndPreservesDiagnosticAccess() throws {
    store = LocalStore(root:root, service:service, signalProfile:["verified":false])
    try register()
    XCTAssertThrowsError(try store.createSession(device:"TEST",kind:"baseline"))
    let (id,url)=try store.createSession(device:"TEST")
    try Data("test".utf8).write(to:url)
    try store.updateSession(id,state:"saved",packets:1,samples:16,reason:"test")
    XCTAssertEqual((try call("detail",["id":id]) as! [String:Any])["kind"] as? String,"diagnostic")
    XCTAssertEqual((try call("baselinePreflight") as! [String:Any])["storageReady"] as? Bool,true)
  }
  func testBaselineSelectionReadDoesNotChooseReference() throws {
    try configureBaselineFixture()
    let first=try call("baselineSelection") as! [String:Any]
    XCTAssertEqual(first["id"] as? String, "")
    let second=try call("baselineSelection") as! [String:Any]
    XCTAssertEqual(second["id"] as? String, "")
  }
  func testBaselineAttemptsOwnershipInvalidationAndRestart() throws {
    try configureBaselineFixture()
    let (id,url)=try store.createSession(device:"TEST",kind:"baseline",task:["name":"SYNTHETIC","minutes":5])
    try Data("test\n".utf8).write(to:url)
    try store.updateSession(id,state:"recording",packets:10,samples:160,reason:"")
    let context:[String:Any]=["device":"TEST","connection":1,"profile":"synthetic-v1","unit":"test-unit"]
    let first=try store.beginAttempt(id:id,context:context)
    func payload(_ attempt:String,_ state:String) -> [String:Any] {
      ["id":id,"attempt":attempt,"snapshot":["attemptId":attempt,"state":state,"elapsed":80.0,"validSeconds":60.0,"context":context,"statistics":["alphaRelative":["mean":0.5,"variance":0.01]]],"window":["sequence":1,"start":0,"end":4]]
    }
    try store.saveBaseline(payload(first,"ready"))
    try store.invalidateBaseline(id:id,reason:"background")
    XCTAssertThrowsError(try store.saveBaseline(payload(first,"ready")))
    let second=try store.beginAttempt(id:id,context:context)
    XCTAssertNotEqual(first,second)
    XCTAssertThrowsError(try store.saveBaseline(payload(first,"invalid")))
    try store.saveBaseline(payload(second,"collecting"))
    XCTAssertThrowsError(try store.createSession(device:"SECOND"))
    XCTAssertThrowsError(try call("deleteSession",["id":id]))
    try store.updateSession(id,state:"interrupted",packets:10,samples:160,reason:"test")
    store.clearCaptureOwner()
    try call("logout");try call("register",["name":"other","password":password])
    XCTAssertThrowsError(try store.saveBaseline(payload(second,"ready")))
    XCTAssertThrowsError(try store.finishBaseline(id:id))
    try call("logout")
    store=LocalStore(root:root,service:service,signalProfile:baselineFixture)
    try call("login",["name":"student","password":password])
    let row=try call("detail",["id":id]) as! [String:Any]
    XCTAssertEqual(row["task_state"] as? String,"interrupted_pending")
    XCTAssertEqual((row["attempts"] as! [[String:Any]]).count,2)
    let windows = row["windows"] as! [[String:Any]]
    XCTAssertEqual(Set(windows.compactMap { $0["attempt_id"] as? String }), Set([first,second]))
    XCTAssertThrowsError(try store.resumeTaskFile(id:id))
    try store.finishBaseline(id:id)
    XCTAssertEqual((try call("detail",["id":id]) as! [String:Any])["task_state"] as? String,"baseline_incomplete")
    XCTAssertEqual(try store.exportURL(id:id),url)
    try call("deleteSession",["id":id])
    XCTAssertEqual((try call("sessions") as! [Any]).count,0)
  }
  func testBaselineCannotClaimReadinessWithInsufficientCoverageOrWrongContext() throws {
    try configureBaselineFixture()
    let (id,url)=try store.createSession(device:"TEST",kind:"baseline")
    try Data().write(to:url)
    let attempt=try store.beginAttempt(id:id,context:["device":"TEST"])
    var snapshot:[String:Any]=["attemptId":attempt,"state":"ready","elapsed":100.0,"validSeconds":60.0,"context":["device":"TEST"],"statistics":["alpha":["mean":1,"variance":1]]]
    XCTAssertThrowsError(try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":snapshot]))
    snapshot["elapsed"]=70.0;snapshot["context"]=["device":"WRONG"]
    XCTAssertThrowsError(try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":snapshot]))
  }
  func testBaselineTransactionFailureDoesNotPublishReady() throws {
    try configureBaselineFixture()
    let (id,url)=try store.createSession(device:"TEST",kind:"baseline")
    try Data().write(to:url)
    let context:[String:Any]=["device":"TEST"]
    let attempt=try store.beginAttempt(id:id,context:context)
    try sql("CREATE TRIGGER fail_baseline_window BEFORE INSERT ON baseline_windows BEGIN SELECT RAISE(ABORT,'test failure'); END")
    let snapshot:[String:Any]=["attemptId":attempt,"state":"ready","elapsed":70.0,"validSeconds":60.0,"context":context,"statistics":["alpha":["mean":1,"variance":1]]]
    XCTAssertThrowsError(try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":snapshot,"window":["sequence":1]]))
    let row=try call("detail",["id":id]) as! [String:Any]
    XCTAssertEqual(row["baseline_json"] as? String,"{}")
    XCTAssertEqual((row["attempts"] as! [[String:Any]]).first?["state"] as? String,"collecting")
  }
  func testBaselineNativeBackgroundInvalidatesButKeepsRawFileAndIdentity() throws {
    try configureBaselineFixture()
    let defaults=UserDefaults(suiteName:service)!
    defer {defaults.removePersistentDomain(forName:service)}
    let notifications=AppNotifications(preferences:defaults,schedule:{_,_ in},cancel:{_ in})
    let bridge=EegBleBridge(store:store,notifications:notifications,observeLifecycle:false)
    let created=expectation(description:"baseline file")
    bridge.beginRecording(device:"SYNTHETIC TEST",kind:"baseline",task:["name":"TEST","minutes":5]) { value in XCTAssertFalse(value is FlutterError);created.fulfill() }
    wait(for:[created],timeout:5)
    let row=(try call("sessions") as! [[String:Any]])[0],id=row["id"] as! String
    let context:[String:Any]=["device":"TEST"]
    let attempt=try store.beginAttempt(id:id,context:context)
    try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":["attemptId":attempt,"state":"ready","elapsed":70.0,"validSeconds":60.0,"context":context,"statistics":["alpha":["mean":1,"variance":1]]]])
    bridge.backgrounded()
    bridge.appendRecord(["type":"packet","uuid":"8653000b-43e6-47b7-9cb0-5fc21d4ae340","hex":String(repeating:"00",count:69)])
    XCTAssertTrue(store.authorized())
    let stopped=expectation(description:"flush")
    bridge.stopRecording({ value in XCTAssertFalse(value is FlutterError);stopped.fulfill() })
    wait(for:[stopped],timeout:5)
    try store.finishBaseline(id:id)
    let saved=try call("detail",["id":id]) as! [String:Any]
    XCTAssertEqual(saved["task_state"] as? String,"baseline_incomplete")
    XCTAssertEqual(saved["samples"] as? Int,16)
    let content=try String(contentsOf:store.exportURL(id:id),encoding:.utf8)
    XCTAssertTrue(content.contains("baseline_summary"));XCTAssertTrue(content.contains("background"));XCTAssertTrue(content.contains("synthetic-v1"))
  }
  func testCompletedBaselineReadinessSurvivesRestartAsHistoryOnly() throws {
    try configureBaselineFixture()
    let (id,url)=try store.createSession(device:"TEST",kind:"baseline")
    try Data().write(to:url)
    let context:[String:Any]=["device":"TEST"]
    let attempt=try store.beginAttempt(id:id,context:context)
    try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":["attemptId":attempt,"state":"ready","elapsed":70.0,"validSeconds":60.0,"context":context,"statistics":["alpha":["mean":1,"variance":1]]]])
    try store.updateSession(id,state:"saved",packets:0,samples:0,reason:"");store.clearCaptureOwner()
    try store.finishBaseline(id:id)
    store=LocalStore(root:root,service:service,signalProfile:baselineFixture)
    try call("login",["name":"student","password":password])
    let row=try call("detail",["id":id]) as! [String:Any]
    XCTAssertEqual(row["task_state"] as? String,"baseline_ready")
    XCTAssertEqual((row["attempts"] as! [[String:Any]]).first?["state"] as? String,"ready")
    XCTAssertThrowsError(try store.resumeTaskFile(id:id))
  }
  func testUserAcceptedRawProfileIsUsableButNeverVerified() throws {
    try register()
    let cap = try call("baselineCapabilities") as! [String:Any]
    let profile = cap["profile"] as! [String:Any]
    XCTAssertEqual(profile["verified"] as? Bool,false)
    XCTAssertEqual(profile["sampleRateAssumed"] as? Bool,true)
    XCTAssertEqual(profile["sampleRate"] as? Double,512)
    XCTAssertNoThrow(try store.requireSignalProfile())
    let (id,url) = try store.createSession(device:"SYNTHETIC RAW",kind:"baseline")
    try Data().write(to:url)
    let attempt = try store.beginAttempt(id:id,context:["sampleRate":512.0,"sampleRateAssumed":true])
    try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":["attemptId":attempt,"state":"collecting","elapsed":1.0,"validSeconds":0.0,"context":["sampleRate":512,"sampleRateAssumed":true]]])
    let detail = try call("detail",["id":id]) as! [String:Any]
    XCTAssertTrue((detail["task_json"] as? String ?? "").contains("basic_only_uncalibrated"))
  }
  func learningSnapshot(_ attempt:String,_ context:[String:Any],_ stats:[String:Any]) -> [String:Any] {
    ["attemptId":attempt,"state":"ready","elapsed":90.0,"attemptElapsed":100.0,"adaptationSeconds":10,"readingVersion":"neutral-reading-v1","validSeconds":70.0,"context":context,"algorithm":LocalStore.baselineAlgorithm,"featureDefinition":["version":LocalStore.baselineAlgorithm],"statistics":stats]
  }
  func testSDKBaselineRequiresMatchingVersionAndTwoValidReferenceMetrics() throws {
    try configureBaselineFixture()
    let (id,url)=try store.createSession(device:"SYNTHETIC SDK",kind:"baseline")
    try Data().write(to:url)
    let context:[String:Any]=["algorithm":LocalStore.baselineAlgorithm,"device":"TEST"]
    let attempt=try store.beginAttempt(id:id,context:context)
    let stats:[String:Any]=["attention":["mean":60.0,"variance":0.0,"drift":0.0],"relax":["mean":40.0,"variance":0.0,"drift":0.0]]
    let good=learningSnapshot(attempt,context,stats)
    try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":good])
    for key in ["algorithm","elapsed","adaptationSeconds","readingVersion","statistics"] {
      var invalid=good
      switch key {
      case "algorithm":invalid[key]="neurox-sdk-attention-relax-v3"
      case "elapsed":invalid[key]=60.0
      case "adaptationSeconds":invalid[key]=0
      case "readingVersion":invalid[key]="wrong"
      default:invalid[key]=["attention":["mean":60.0,"variance":0.0,"drift":0.0]]
      }
      XCTAssertThrowsError(try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":invalid]),key)
    }
    for bad:[String:Any] in [["mean":4.0,"variance":0.0,"drift":0.0],["mean":60.0,"variance":401.0,"drift":0.0],["mean":60.0,"variance":0.0,"drift":11.0],["mean":60.0,"variance": -1.0,"drift":0.0]] {
      var invalid=good;invalid["statistics"]=["attention":bad,"relax":["mean":40.0,"variance":0.0,"drift":0.0]]
      XCTAssertThrowsError(try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":invalid]))
    }
    try store.updateSession(id,state:"saved",packets:0,samples:0,reason:"");store.clearCaptureOwner();try store.finishBaseline(id:id)
    XCTAssertTrue(try String(contentsOf:store.exportURL(id:id),encoding:.utf8).contains(LocalStore.baselineAlgorithm))
  }
  var personalReferenceContext:[String:Any] {
    ["algorithm":LocalStore.baselineAlgorithm,"device":"TEST","connection":1,"profile":"synthetic-v1","unit":"test-unit","mode":"verified","sampleRate":512.0,"sampleRateAssumed":false]
  }
  func savePersonalReference(context:[String:Any],attention:Double=60) throws -> (String,String,[String:Any]) {
    let (id,url)=try store.createSession(device:"TEST BASELINE",kind:"baseline",task:["name":"PERSONAL BASELINE"])
    try Data("{\"type\":\"test\"}\n".utf8).write(to:url)
    let attempt=try store.beginAttempt(id:id,context:context)
    let reference:[String:Any]=["attention":["mean":attention,"variance":25.0,"drift":0.0],"relax":["mean":40.0,"variance":16.0,"drift":0.0]]
    try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":learningSnapshot(attempt,context,reference)])
    try store.updateSession(id,state:"saved",packets:0,samples:0,reason:"");store.clearCaptureOwner();try store.finishBaseline(id:id)
    return (id,attempt,reference)
  }
  func testSavedPersonalReferenceDoesNotExpireAndRebindsAcrossConnections() throws {
    var now=1000.0
    let (id,_,attempt,context,reference)=try prepareMonitoringFixture(uptime:{now})
    now=1000000
    XCTAssertThrowsError(try store.beginAttempt(id:id,context:context))
    let detail=try call("detail",["id":id]) as! [String:Any]
    var frozen=try JSONSerialization.jsonObject(with:(detail["baseline_json"] as! String).data(using:.utf8)!) as! [String:Any]
    frozen["statistics"]=["attention":["mean":99,"variance":0,"drift":0],"relax":["mean":40,"variance":0,"drift":0]]
    XCTAssertThrowsError(try store.saveBaseline(["id":id,"attempt":attempt,"snapshot":frozen]))
    try store.startMonitoring(["id":id,"snapshot":monitoringSnapshot(attempt,context,reference)],context:context)
    let source=try call("baselineReference",["context":context]) as! [String:Any]
    XCTAssertEqual(source["available"] as? Bool,true)
    XCTAssertEqual(source["compatible"] as? Bool,true)
    var next=context;next["connection"]=99
    let attached=try store.attachSavedReference(id:id,sourceID:source["id"] as! String,context:next)
    let rebound=attached["snapshot"] as! [String:Any]
    XCTAssertEqual((rebound["referenceOrigin"] as? [String:Any])?["reused"] as? Bool,true)
    XCTAssertEqual(NSDictionary(dictionary:rebound["statistics"] as! [String:Any]),NSDictionary(dictionary:reference))
    try store.startMonitoring(["id":id,"snapshot":monitoringSnapshot(attached["attempt"] as! String,next,reference)],context:next)
    XCTAssertThrowsError(try call("deleteSession",["id":source["id"]!]))
    var wrong=next;wrong["device"]="OTHER"
    XCTAssertThrowsError(try store.validateSavedReference(sourceID:source["id"] as! String,context:wrong))
  }
  func testPersonalReferenceSurvivesRestartIsOwnedAndDoesNotPublishFailedRerecord() throws {
    try configureBaselineFixture();let context=personalReferenceContext
    let (source,_,_)=try savePersonalReference(context:context)
    let (failed,url)=try store.createSession(device:"FAILED",kind:"baseline")
    try Data().write(to:url);_=try store.beginAttempt(id:failed,context:context)
    try store.updateSession(failed,state:"saved",packets:0,samples:0,reason:"");store.clearCaptureOwner();try store.finishBaseline(id:failed)
    store=LocalStore(root:root,service:service,signalProfile:baselineFixture)
    try call("login",["name":"student","password":password])
    XCTAssertEqual((try call("baselineReference",["context":context]) as! [String:Any])["id"] as? String,source)
    try call("logout");try call("register",["name":"OTHER","password":password])
    XCTAssertEqual((try call("baselineReference",["context":context]) as! [String:Any])["available"] as? Bool,false)
    XCTAssertThrowsError(try store.validateSavedReference(sourceID:source,context:context))
  }
  func testRerecordedBaselineAppliesOnlyToFutureTasks() throws {
    let (id,_,attempt,context,reference)=try prepareMonitoringFixture()
    let first=(try call("baselineReference",["context":context]) as! [String:Any])["id"] as! String
    var end=monitoringSnapshot(attempt,context,reference,phase:"finished");end["endReason"]="user_ended"
    _=try store.saveMonitoring(["id":id,"snapshot":end]);try store.updateSession(id,state:"saved",packets:0,samples:0,reason:"");store.clearCaptureOwner();try store.finishMonitoring(id:id)
    let (new,_,_)=try savePersonalReference(context:context,attention:70)
    _ = try call("baselineSelect",["id":new,"context":context])
    XCTAssertNotEqual(first,new)
    XCTAssertEqual((try call("baselineReference",["context":context]) as! [String:Any])["id"] as? String,new)
    let old=try call("detail",["id":id]) as! [String:Any]
    let frozen=try JSONSerialization.jsonObject(with:(old["baseline_json"] as! String).data(using:.utf8)!) as! [String:Any]
    XCTAssertEqual((frozen["referenceOrigin"] as? [String:Any])?["sessionId"] as? String,first)
    XCTAssertEqual(((frozen["statistics"] as? [String:Any])?["attention"] as? [String:Any])?["mean"] as? Double,60)
  }
  func replayFixture() throws -> (String,[String:Any]) {
    try configureBaselineFixture()
    let reference:[String:Any]=["attention":["mean":60.0,"variance":25.0],"relax":["mean":40.0,"variance":9.0]]
    let (id,url)=try store.createSession(device:"SOURCE",kind:"task",task:["scene":"learning","name":"Original study"])
    try Data("original raw fixture\n".utf8).write(to:url)
    let original:[String:Any]=["elapsed":60.0,"algorithm":LocalStore.baselineAlgorithm,"reference":reference]
    let encoded=String(data:try JSONSerialization.data(withJSONObject:original),encoding:.utf8)!
    try sql("UPDATE sessions SET state='saved',task_state='task_complete',monitor_json='\(encoded)' WHERE id='\(id)'")
    store.clearCaptureOwner()
    let snapshot:[String:Any]=["version":"sdk-personal-monitor-v2","algorithm":LocalStore.baselineAlgorithm,"scene":"esports","phase":"finished","elapsed":60.0,"validSeconds":60.0,"reference":reference,"rules":["sustainedSeconds":10.0,"recoverySeconds":15.0],"durations":["stable":40.0,"deviation":20.0,"unknown":0.0],"eventSequence":2]
    let args:[String:Any]=["id":id,"scene":"esports","snapshot":snapshot,"events":[["sequence":1,"type":"start","elapsed":0.0],["sequence":2,"type":"finish","elapsed":60.0]]]
    return (id,args)
  }
  func testScenarioReplayIsIndependentMarkedAndDoesNotChangeSourceOrBaselineSelection() throws {
    let (source,args)=try replayFixture()
    let before=try call("detail",["id":source]) as! [String:Any]
    let selected=try call("baselineSelection") as! [String:Any]
    let created=try call("saveScenarioReplay",args) as! [String:Any],id=created["id"] as! String
    XCTAssertNotEqual(id,source)
    let row=try call("detail",["id":id]) as! [String:Any]
    let task=try JSONSerialization.jsonObject(with:Data((row["task_json"] as! String).utf8)) as! [String:Any]
    XCTAssertEqual(task["isReplay"] as? Bool,true);XCTAssertEqual(task["replaySourceId"] as? String,source)
    XCTAssertEqual(task["containsRawEEG"] as? Bool,false);XCTAssertEqual(row["samples"] as? Int,0)
    let file=try store.exportURL(id:id),text=try String(contentsOf:file,encoding:.utf8)
    XCTAssertTrue(text.contains("test_replay"));XCTAssertFalse(text.contains("original raw fixture"))
    XCTAssertEqual((try call("detail",["id":source]) as! [String:Any])["monitor_json"] as? String,before["monitor_json"] as? String)
    XCTAssertEqual((try call("baselineSelection") as! [String:Any])["id"] as? String,selected["id"] as? String)
    let png=UIGraphicsImageRenderer(size:CGSize(width:2,height:2)).pngData { context in UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:2,height:2)) }
    XCTAssertNoThrow(try store.learningReportURL(id:id,png:png))
    try call("deleteSession",["id":id]);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    XCTAssertNoThrow(try store.exportURL(id:source))
  }
  func testScenarioReplayRejectsWrongOwnerRulesReferenceAndRollsBackFileOnFailure() throws {
    let (source,args)=try replayFixture()
    var wrong=args;var snap=args["snapshot"] as! [String:Any];snap["rules"]=["sustainedSeconds":25,"recoverySeconds":10];wrong["snapshot"]=snap
    XCTAssertThrowsError(try call("saveScenarioReplay",wrong))
    snap=args["snapshot"] as! [String:Any];snap["reference"]=["attention":["mean":99,"variance":25]];wrong=args;wrong["snapshot"]=snap
    XCTAssertThrowsError(try call("saveScenarioReplay",wrong))
    try sql("CREATE TRIGGER reject_replay_event BEFORE INSERT ON task_events BEGIN SELECT RAISE(ABORT,'test replay failure'); END")
    let before=Set(try FileManager.default.contentsOfDirectory(atPath:root.path))
    XCTAssertThrowsError(try call("saveScenarioReplay",args))
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:root.path)),before)
    XCTAssertEqual((try call("sessions") as! [[String:Any]]).count,1)
    try sql("DROP TRIGGER reject_replay_event")
    try call("logout");try call("register",["name":"other","password":password])
    XCTAssertThrowsError(try call("saveScenarioReplay",args))
    try call("logout");try call("login",["name":"student","password":password])
    try sql("UPDATE sessions SET task_state='active' WHERE id='\(source)'")
    XCTAssertThrowsError(try call("saveScenarioReplay",args))
  }
  func testLearningReportImageOwnershipActiveGuardAndDeletion() throws {
    try register()
    let (id,url)=try store.createSession(device:"TEST",kind:"task",task:["scene":"learning"])
    try Data().write(to:url)
    let png=UIGraphicsImageRenderer(size:CGSize(width:2,height:2)).pngData { context in
      UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:2,height:2))
    }
    XCTAssertThrowsError(try store.learningReportURL(id:id,png:png))
    try sql("UPDATE sessions SET state='saved',task_state='task_ended' WHERE id='\(id)'")
    store.clearCaptureOwner()
    XCTAssertThrowsError(try store.learningReportURL(id:id,png:Data("invalid".utf8)))
    let report=try store.learningReportURL(id:id,png:png)
    XCTAssertEqual(try Data(contentsOf:report),png)
    try call("logout");try call("register",["name":"other","password":password])
    XCTAssertThrowsError(try store.learningReportURL(id:id,png:png))
    try call("logout");try call("login",["name":"student","password":password])
    try call("deleteSession",["id":id]);XCTAssertFalse(FileManager.default.fileExists(atPath:report.path))
  }
  func testAccountDeletionRemovesLearningReportImage() throws {
    try register()
    let (id,url)=try store.createSession(device:"TEST",kind:"task",task:["scene":"learning"])
    try Data().write(to:url)
    try sql("UPDATE sessions SET state='saved',task_state='task_ended' WHERE id='\(id)'")
    store.clearCaptureOwner()
    let png=UIGraphicsImageRenderer(size:CGSize(width:2,height:2)).pngData { context in
      UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:2,height:2))
    }
    let report=try store.learningReportURL(id:id,png:png)
    try call("deleteAccount",["password":password])
    XCTAssertFalse(FileManager.default.fileExists(atPath:report.path))
  }
  func testLearningSessionLocksEffectiveBaselineAndRejectsReplacementOrRecalculation() throws {
    try configureBaselineFixture();let context=personalReferenceContext
    let (first,_,reference)=try savePersonalReference(context:context,attention:60)
    let (second,_,other)=try savePersonalReference(context:context,attention:70)
    let (id,url)=try store.createSession(device:"LEARNING",kind:"task",task:["minutes":5]);try Data().write(to:url)
    let attached=try store.attachSavedReference(id:id,sourceID:first,context:context)
    XCTAssertThrowsError(try store.attachSavedReference(id:id,sourceID:second,context:context))
    XCTAssertThrowsError(try store.saveMonitoring(["id":id,"snapshot":monitoringSnapshot(attached["attempt"] as! String,context,other,phase:"preparing")]))
    let accepted=try store.saveMonitoring(["id":id,"snapshot":monitoringSnapshot(attached["attempt"] as! String,context,reference,phase:"preparing")]);XCTAssertTrue(accepted)
    let snapshot=try store.monitorStatus(id:id)
    XCTAssertEqual((snapshot["referenceOrigin"] as? [String:Any])?["sessionId"] as? String,first)
  }
  func prepareMonitoringFixture(uptime: (() -> TimeInterval)? = nil) throws -> (String,URL,String,[String:Any],[String:Any]) {
    if let uptime=uptime {store=LocalStore(root:root,service:service,signalProfile:baselineFixture,uptime:uptime);try register()}
    else {try configureBaselineFixture()}
    var context=personalReferenceContext
    let (source,_,reference)=try savePersonalReference(context:context)
    context["connection"]=2
    let (id,url)=try store.createSession(device:"SYNTHETIC MONITOR",kind:"task",task:["name":"TEST TASK","minutes":5])
    try Data("{\"type\":\"test\"}\n".utf8).write(to:url)
    try store.updateSession(id,state:"recording",packets:10,samples:160,reason:"")
    let attached=try store.attachSavedReference(id:id,sourceID:source,context:context)
    return (id,url,attached["attempt"] as! String,context,reference)
  }
  func monitoringSnapshot(_ attempt:String,_ context:[String:Any],_ reference:[String:Any],elapsed:Double=0,state:String="unknown",phase:String="running") -> [String:Any] {
    ["version":"sdk-personal-monitor-v1","algorithm":LocalStore.baselineAlgorithm,"phase":phase,"state":state,"targetSeconds":300,"elapsed":elapsed,"validSeconds":elapsed,"durations":["stable":elapsed,"deviation":0.0,"unknown":0.0],"referenceAttempt":attempt,"reference":reference,"context":context,"wallSeconds":elapsed,"remindersEnabled":true]
  }
  func testMonitoringPersistenceFinishFeedbackSummaryAndOwnership() throws {
    let (id,url,attempt,context,reference)=try prepareMonitoringFixture()
    var snapshot=monitoringSnapshot(attempt,context,reference)
    try store.startMonitoring(["id":id,"snapshot":snapshot,"events":[["sequence":1,"type":"start","attempt":attempt,"elapsed":0]]],context:context)
    XCTAssertEqual((try call("detail",["id":id]) as! [String:Any])["kind"] as? String,"task")
    snapshot=monitoringSnapshot(attempt,context,reference,elapsed:30,state:"deviation")
    let notice:[String:Any]=["sequence":2,"type":"reminder","delivery":"pending","attempt":attempt,"elapsed":30.0,"candidateSeconds":25.0]
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[notice]]))
    XCTAssertTrue(try store.requestMonitorAlert(id:id,sequence:2))
    XCTAssertFalse(try store.requestMonitorAlert(id:id,sequence:2))
    let again:[String:Any]=["sequence":3,"type":"reminder","delivery":"pending","attempt":attempt,"elapsed":30.0,"candidateSeconds":25.0]
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[again]]))
    XCTAssertFalse(try store.requestMonitorAlert(id:id,sequence:3))
    snapshot["phase"]="finished";snapshot["endReason"]="user_ended"
    _=try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[]])
    try store.updateSession(id,state:"saved",packets:10,samples:160,reason:"");store.clearCaptureOwner()
    try store.finishMonitoring(id:id);XCTAssertTrue(try store.monitorFinalized(id:id))
    try store.finishMonitoring(id:id);try store.finishBaseline(id:id)
    let savedLines=try String(contentsOf:url,encoding:.utf8).split(separator:"\n").filter{$0.contains("task_summary")}
    XCTAssertEqual(savedLines.count,1)
    try call("taskFeedback",["id":id,"feedback":["rating":4,"note":"TEST FEEDBACK"]])
    let exported=try store.summaryURL(id:id)
    let data=try JSONSerialization.jsonObject(with:Data(contentsOf:exported)) as! [String:Any]
    XCTAssertEqual((data["feedback"] as? [String:Any])?["rating"] as? Int,4)
    XCTAssertEqual((data["events"] as! [[String:Any]]).count,3)
    XCTAssertTrue(try String(contentsOf:url,encoding:.utf8).contains("task_summary"))
    try call("logout");try call("register",["name":"OTHER","password":password])
    XCTAssertThrowsError(try store.summaryURL(id:id));XCTAssertThrowsError(try store.monitorStatus(id:id))
    try call("logout");try call("login",["name":"student","password":password]);try call("deleteSession",["id":id])
    XCTAssertFalse(FileManager.default.fileExists(atPath:exported.path));XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
  }
  func testNewDeviationMayAlertImmediatelyWithoutCooldownButSameEpisodeIsDeduplicated() throws {
    let (id,_,attempt,context,reference)=try prepareMonitoringFixture()
    try store.startMonitoring(["id":id,"snapshot":monitoringSnapshot(attempt,context,reference),"events":[["sequence":1,"type":"start","attempt":attempt,"elapsed":0.0]]],context:context)
    let began=Date().timeIntervalSince1970
    var snapshot=monitoringSnapshot(attempt,context,reference,elapsed:30,state:"deviation")
    let first:[String:Any]=["sequence":3,"type":"reminder","delivery":"pending","attempt":attempt,"elapsed":30.0,"candidateSeconds":25.0]
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[["sequence":2,"type":"deviation","attempt":attempt,"elapsed":30.0],first]]))
    XCTAssertTrue(try store.requestMonitorAlert(id:id,sequence:3))
    XCTAssertFalse(try store.requestMonitorAlert(id:id,sequence:3))
    let duplicate:[String:Any]=["sequence":4,"type":"reminder","delivery":"pending","attempt":attempt,"elapsed":30.0,"candidateSeconds":25.0]
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[duplicate]]))
    XCTAssertFalse(try store.requestMonitorAlert(id:id,sequence:4))
    snapshot=monitoringSnapshot(attempt,context,reference,elapsed:40,state:"stable")
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[["sequence":5,"type":"recovery","attempt":attempt,"elapsed":40.0]]]))
    snapshot=monitoringSnapshot(attempt,context,reference,elapsed:65,state:"deviation")
    let next:[String:Any]=["sequence":7,"type":"reminder","delivery":"pending","attempt":attempt,"elapsed":65.0,"candidateSeconds":25.0]
    XCTAssertTrue(try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[["sequence":6,"type":"deviation","attempt":attempt,"elapsed":65.0],next]]))
    XCTAssertTrue(try store.requestMonitorAlert(id:id,sequence:7))
    XCTAssertFalse(try store.requestMonitorAlert(id:id,sequence:7))
    XCTAssertLessThan(Date().timeIntervalSince1970-began,150)
  }
  func testUnstartedStudyCanCloseAndDeleteWithoutChangingPersonalReference() throws {
    let (id, url, attempt, context, reference) = try prepareMonitoringFixture()
    var snapshot = monitoringSnapshot(attempt, context, reference, phase: "preparing")
    XCTAssertTrue(try store.saveMonitoring(["id": id, "snapshot": snapshot]))
    let before = try call("baselineReference", ["context": context]) as! [String: Any]
    snapshot["phase"] = "finished"; snapshot["endReason"] = "user_ended"
    try store.updateSession(id, state: "saved", packets: 0, samples: 0, reason: "")
    XCTAssertTrue(try store.saveMonitoring(["id": id, "snapshot": snapshot]))
    try store.finishMonitoring(id: id)
    _ = try call("deleteSession", ["id": id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertThrowsError(try call("detail", ["id": id]))
    let after = try call("baselineReference", ["context": context]) as! [String: Any]
    XCTAssertEqual(before["id"] as? String, after["id"] as? String)
    XCTAssertTrue(after["available"] as? Bool == true)
  }

  func testInterruptedStudyRebindsSameReferenceAndPreservesElapsedAcrossNewConnection() throws {
    let (id, _, attempt, context, reference) = try prepareMonitoringFixture()
    let original = monitoringSnapshot(attempt, context, reference, elapsed: 30)
    try store.startMonitoring(["id": id, "snapshot": original], context: context)
    let before = try store.monitorStatus(id: id)
    let source = (before["referenceOrigin"] as! [String: Any])["sessionId"] as! String
    try store.interruptMonitoring(id: id, reason: "disconnected")
    XCTAssertThrowsError(try store.startMonitoring(["id": id, "snapshot": original], context: context))
    var nextContext = context; nextContext["connection"] = 3
    let rebound = try store.attachSavedReference(id: id, sourceID: source, context: nextContext)
    XCTAssertNotEqual(rebound["attempt"] as? String, attempt)
    let resumed = monitoringSnapshot(rebound["attempt"] as! String, nextContext, reference, elapsed: 30)
    try store.startMonitoring(["id": id, "snapshot": resumed], context: nextContext)
    let after = try store.monitorStatus(id: id)
    XCTAssertEqual(after["phase"] as? String, "running")
    XCTAssertEqual(after["elapsed"] as? Double, 30)
    XCTAssertEqual((after["referenceOrigin"] as? [String: Any])?["sessionId"] as? String, source)
    XCTAssertTrue(NSDictionary(dictionary: after["reference"] as! [String: Any]).isEqual(to: reference))
    XCTAssertEqual((try call("detail", ["id": id]) as! [String: Any])["task_state"] as? String, "active")
  }

  func testMonitoringNativeBackgroundBarrierAndColdRestartNeverResumeJudgement() throws {
    let (id,_,attempt,context,reference)=try prepareMonitoringFixture()
    var snapshot=monitoringSnapshot(attempt,context,reference)
    try store.startMonitoring(["id":id,"snapshot":snapshot],context:context)
    snapshot=monitoringSnapshot(attempt,context,reference,elapsed:5,state:"stable")
    _=try store.saveMonitoring(["id":id,"snapshot":snapshot])
    try store.invalidateBaseline(id:id,reason:"background");try store.interruptMonitoring(id:id,reason:"background")
    XCTAssertEqual(try store.monitorStatus(id:id)["phase"] as? String,"interrupted")
    XCTAssertFalse(try store.saveMonitoring(["id":id,"snapshot":snapshot]))
    snapshot["phase"]="interrupted";_=try store.saveMonitoring(["id":id,"snapshot":snapshot])
    snapshot["phase"]="running";XCTAssertFalse(try store.saveMonitoring(["id":id,"snapshot":snapshot]))
    XCTAssertThrowsError(try store.startMonitoring(["id":id,"snapshot":snapshot],context:context))
    store=LocalStore(root:root,service:service,signalProfile:baselineFixture)
    try call("login",["name":"student","password":password])
    let row=try call("detail",["id":id]) as! [String:Any]
    XCTAssertEqual(row["task_state"] as? String,"interrupted_pending")
    XCTAssertEqual(try store.monitorStatus(id:id)["elapsed"] as? Double,5)
    try store.finishBaseline(id:id)
    XCTAssertEqual((try call("detail",["id":id]) as! [String:Any])["task_state"] as? String,"task_ended")
  }
  func testMonitoringStartRollbackAndEventConflicts() throws {
    let (id,_,attempt,context,reference)=try prepareMonitoringFixture()
    let snapshot=monitoringSnapshot(attempt,context,reference)
    try sql("CREATE TRIGGER fail_monitor BEFORE INSERT ON task_events BEGIN SELECT RAISE(ABORT,'test'); END")
    let args:[String:Any]=["id":id,"snapshot":snapshot,"events":[["sequence":1,"type":"start"]]]
    XCTAssertThrowsError(try store.startMonitoring(args,context:context))
    let row=try call("detail",["id":id]) as! [String:Any]
    XCTAssertEqual(row["kind"] as? String,"task");XCTAssertEqual(row["monitor_json"] as? String,"{}")
    try sql("DROP TRIGGER fail_monitor");try store.startMonitoring(args,context:context)
    XCTAssertThrowsError(try store.saveMonitoring(["id":id,"snapshot":snapshot,"events":[["sequence":1,"type":"different"]]]))
    var stale=snapshot;stale["referenceAttempt"]="OLD ATTEMPT"
    XCTAssertThrowsError(try store.saveMonitoring(["id":id,"snapshot":stale]))
    var invalid=snapshot;invalid["elapsed"]=20.0;invalid["validSeconds"]=21.0
    XCTAssertThrowsError(try store.saveMonitoring(["id":id,"snapshot":invalid]))
  }
  func testMonitoringLongPauseRequiresFreshBaselineAttempt() throws {
    let (id,_,attempt,context,reference)=try prepareMonitoringFixture()
    var snapshot=monitoringSnapshot(attempt,context,reference)
    try store.startMonitoring(["id":id,"snapshot":snapshot],context:context)
    snapshot["phase"]="paused";snapshot["pauseStartedWallSeconds"]=0.0
    _=try store.saveMonitoring(["id":id,"snapshot":snapshot])
    snapshot["phase"]="running";snapshot["wallSeconds"]=60.0
    XCTAssertThrowsError(try store.startMonitoring(["id":id,"snapshot":snapshot],context:context))
  }
  func testSchemaThreeMigrationPreservesOwnedDiagnosticFile() throws {
    try register()
    let (id,url)=try store.createSession(device:"OLD DIAGNOSTIC")
    try Data("TEST".utf8).write(to:url);try store.updateSession(id,state:"saved",packets:4,samples:64,reason:"");store.clearCaptureOwner()
    store=nil
    try sql("DROP TABLE task_events; ALTER TABLE sessions DROP COLUMN monitor_json; ALTER TABLE sessions DROP COLUMN feedback_json; PRAGMA user_version=3;")
    store=LocalStore(root:root,service:service)
    try call("login",["name":"student","password":password])
    let row=try call("detail",["id":id]) as! [String:Any]
    XCTAssertEqual(row["kind"] as? String,"diagnostic");XCTAssertEqual(row["monitor_json"] as? String,"{}")
    XCTAssertEqual(row["samples"] as? Int,64);XCTAssertEqual(try store.exportURL(id:id),url)
  }
  func testRegistrationLoginAndNoImplicitLoginAfterRestart() throws {
    XCTAssertEqual((try call("check") as? [String: Any])?["state"] as? String, "register")
    try register(); XCTAssertTrue(store.authorized())
    XCTAssertThrowsError(try call("register", ["name": "second", "password": password]))
    store = LocalStore(root: root, service: service)
    XCTAssertFalse(store.authorized())
    XCTAssertEqual((try call("check") as? [String: Any])?["state"] as? String, "login")
    XCTAssertThrowsError(try call("sessions"))
    try call("login", ["name": "student", "password": password]); XCTAssertTrue(store.authorized())
  }
  func testPersistentLockoutAndEmptyPassword() throws {
    try register(); store.lock()
    for _ in 0..<5 { XCTAssertThrowsError(try call("login", ["name": "student", "password": ""])) }
    store = LocalStore(root: root, service: service)
    XCTAssertThrowsError(try call("login", ["name": "student", "password": password]))
    XCTAssertFalse(store.authorized())
    try sql("UPDATE account SET locked_until=0")
    try call("login", ["name": "student", "password": password]); XCTAssertTrue(store.authorized())
  }
  func testPasswordChangeRequiresOldPasswordAndLocks() throws {
    try register()
    XCTAssertThrowsError(try call("changePassword", ["password": "wrong", "newPassword": "new-password-123"]))
    try call("changePassword", ["password": password, "newPassword": "new-password-123"])
    XCTAssertFalse(store.authorized())
    XCTAssertThrowsError(try call("login", ["name": "student", "password": password]))
    try call("login", ["name": "student", "password": "new-password-123"])
  }
  func testMissingCredentialAndOrphanCredentialFailClosed() throws {
    try register()
    store = LocalStore(root: root.appendingPathComponent("different-install"), service: service)
    XCTAssertThrowsError(try call("check")); XCTAssertFalse(store.authorized())
    store = LocalStore(root: root, service: service)
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service!] as CFDictionary)
    XCTAssertThrowsError(try call("check")); XCTAssertThrowsError(try call("login", ["name": "student", "password": password]))
  }
  func testPendingRegistrationRecovery() throws {
    try register(); store.lock(); try sql("UPDATE account SET state='pending'")
    XCTAssertEqual((try call("check") as? [String: Any])?["state"] as? String, "login")
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service!] as CFDictionary)
    try sql("UPDATE account SET state='pending'")
    XCTAssertEqual((try call("check") as? [String: Any])?["state"] as? String, "register")
  }
  func testHistoryOwnershipMissingFilesAndRestartRecovery() throws {
    try register()
    let (id, url) = try store.createSession(device: "TEST INPUT ONLY")
    try Data("{\"type\":\"test\"}\n".utf8).write(to: url)
    try store.updateSession(id, state: "recording", packets: 12, samples: 16, reason: "test")
    XCTAssertThrowsError(try store.exportURL(id: id))
    store = LocalStore(root: root, service: service)
    try call("login", ["name": "student", "password": password])
    let row = try call("detail", ["id": id]) as! [String: Any]
    XCTAssertEqual(row["state"] as? String, "interrupted")
    XCTAssertEqual(row["packets"] as? Int, 12)
    XCTAssertEqual(try store.exportURL(id: id), url)
    XCTAssertThrowsError(try call("detail", ["id": "foreign-id"]))
    try FileManager.default.removeItem(at: url)
    XCTAssertEqual((try call("detail", ["id": id]) as? [String: Any])?["exists"] as? Bool, false)
    XCTAssertThrowsError(try store.exportURL(id: id))
    try call("deleteSession", ["id": id]); XCTAssertEqual((try call("sessions") as? [Any])?.count, 0)
  }
  func testLegacyRequiresExplicitClaimAndAccountDeletionPreservesUnclaimed() throws {
    try register()
    let claimed = root.appendingPathComponent("old.jsonl"), unclaimed = root.appendingPathComponent("unclaimed.jsonl")
    try Data().write(to: claimed); try Data().write(to: unclaimed)
    XCTAssertEqual((try call("sessions") as? [Any])?.count, 0)
    XCTAssertEqual((try call("legacy") as? [String])?.count, 2)
    XCTAssertThrowsError(try call("claimLegacy", ["path": "../outside.jsonl"]))
    try call("claimLegacy", ["path": "old.jsonl"])
    XCTAssertEqual((try call("sessions") as? [Any])?.count, 1)
    XCTAssertThrowsError(try call("deleteAccount", ["password": "wrong"]))
    try call("deleteAccount", ["password": password])
    XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unclaimed.path))
    XCTAssertFalse(store.authorized())
    XCTAssertEqual((try call("check") as? [String: Any])?["state"] as? String, "register")
  }
  func testRegistrationDatabaseCommitFailureRecoversSameIdentity() throws {
    _ = try call("check")
    try sql("CREATE TRIGGER fail_ready BEFORE UPDATE OF state ON account WHEN NEW.state='ready' BEGIN SELECT RAISE(ABORT, 'injected test write failure'); END")
    XCTAssertThrowsError(try register()); XCTAssertFalse(store.authorized())
    XCTAssertThrowsError(try call("check"))
    try sql("DROP TRIGGER fail_ready")
    XCTAssertEqual((try call("check") as? [String: Any])?["state"] as? String, "login")
    try call("login", ["name": "student", "password": password]); XCTAssertTrue(store.authorized())
  }
  func testDeletionFailureKeepsTombstoneAndStartupRetries() throws {
    try register()
    let (id, url) = try store.createSession(device: "TEST ONLY")
    try Data().write(to: url)
    try store.updateSession(id, state: "saved", packets: 0, samples: 0, reason: "test")
    try sql("CREATE TRIGGER fail_delete BEFORE DELETE ON account BEGIN SELECT RAISE(ABORT, 'injected test delete failure'); END")
    XCTAssertThrowsError(try call("deleteAccount", ["password": password]))
    XCTAssertFalse(store.authorized()); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertThrowsError(try call("check"))
    try sql("DROP TRIGGER fail_delete")
    XCTAssertEqual((try call("check") as? [String: Any])?["state"] as? String, "register")
  }
  func testCorruptAndNewerDatabaseNeverBecomesEmptyRegistration() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not SQLite".utf8).write(to: root.appendingPathComponent("neurox.sqlite"))
    XCTAssertThrowsError(try call("check")); XCTAssertFalse(store.authorized())
    try FileManager.default.removeItem(at: root.appendingPathComponent("neurox.sqlite"))
    try sql("PRAGMA user_version=99")
    XCTAssertThrowsError(try call("check"))
  }
  func testSixCharacterPasswordAndMultipleAccountIsolation() throws {
    XCTAssertThrowsError(try call("register", ["name": "short", "password": "12345"]))
    try call("register", ["name": "first", "password": "123456"])
    let firstID = (try call("profile") as! [String: Any])["id"] as! String
    let (recordID, url) = try store.createSession(device: "TEST ONLY")
    try Data("test".utf8).write(to: url)
    try store.updateSession(recordID, state: "saved", packets: 1, samples: 16, reason: "test")
    store.clearCaptureOwner()
    try call("logout"); try call("register", ["name": "second", "password": "abcdef"])
    let secondID = (try call("profile") as! [String: Any])["id"] as! String
    XCTAssertNotEqual(firstID, secondID)
    XCTAssertEqual((try call("sessions") as! [Any]).count, 0)
    XCTAssertThrowsError(try call("detail", ["id": recordID]))
    XCTAssertThrowsError(try call("deleteSession", ["id": recordID]))
    XCTAssertThrowsError(try store.exportURL(id: recordID))
    try call("deleteAccount", ["password": "abcdef"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    try call("login", ["name": "first", "password": "123456"])
    XCTAssertEqual((try call("sessions") as! [Any]).count, 1)
    try call("changePassword", ["password": "123456", "newPassword": "654321"])
    try call("login", ["name": "first", "password": "654321"])
    try call("logout")
    XCTAssertThrowsError(try call("register", ["name": "FIRST", "password": "123456"]))
  }
  func testLegacySingleCredentialMigratesWithoutChangingOwnerOrFiles() throws {
    try register()
    let id = (try call("profile") as! [String: Any])["id"] as! String
    let (record, url) = try store.createSession(device: "TEST MIGRATION")
    try Data("test".utf8).write(to: url)
    try store.updateSession(record, state: "saved", packets: 2, samples: 32, reason: "test")
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service!, kSecAttrAccount as String: id]
    var read = query; read[kSecReturnData as String] = true
    var value: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &value), errSecSuccess)
    var old = query; old[kSecAttrAccount as String] = "single-local-account"; old[kSecValueData as String] = value!
    old[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    XCTAssertEqual(SecItemAdd(old as CFDictionary, nil), errSecSuccess)
    XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
    try sql("PRAGMA user_version=1")
    store = LocalStore(root: root, service: service)
    _ = try call("check"); try call("login", ["name": "student", "password": password])
    XCTAssertEqual((try call("profile") as! [String: Any])["id"] as? String, id)
    XCTAssertEqual((try call("detail", ["id": record]) as! [String: Any])["samples"] as? Int, 32)
    XCTAssertEqual(try store.exportURL(id: record), url)
    var oldLookup = query; oldLookup[kSecAttrAccount as String] = "single-local-account"
    XCTAssertEqual(SecItemCopyMatching(oldLookup as CFDictionary, nil), errSecItemNotFound)
  }
  @MainActor func testNativeJSONLRecordingPersistsWhileAccessLocked() async throws {
    try call("register", ["name": "second", "password": "abcdef"])
    try call("logout"); try register()
    let defaults = UserDefaults(suiteName: service)!
    let notifications = AppNotifications(preferences: defaults, schedule: { _, _ in }, cancel: { _ in })
    let bridge = EegBleBridge(store: store, notifications: notifications, observeLifecycle: false)
    let started = expectation(description: "file and index created")
    var path: String?
    bridge.beginRecording(device: "SYNTHETIC TEST INPUT") { result in
      path = result as? String; XCTAssertNotNil(path); started.fulfill()
    }
    await fulfillment(of: [started], timeout: 5)
    let first = (try call("sessions") as! [[String: Any]])[0]
    let id = first["id"] as! String
    let packet: [String: Any] = ["type": "packet", "source": "SYNTHETIC TEST INPUT", "uuid": "8653000b-43e6-47b7-9cb0-5fc21d4ae340", "receivedAt": 123456, "hex": String(repeating: "00", count: 69)]
    bridge.appendRecord(packet)
    bridge.backgrounded()
    XCTAssertTrue(store.authorized(), "App switching keeps the in-memory login")
    bridge.foregrounded()
    store.lock()
    XCTAssertThrowsError(try call("sessions"))
    XCTAssertThrowsError(try call("login", ["name": "second", "password": "abcdef"]))
    XCTAssertThrowsError(try call("register", ["name": "third", "password": "123456"]))
    bridge.appendRecord(packet) // No Keychain or foreground identity required for an existing recorder.
    let stopped = expectation(description: "flushed and indexed")
    bridge.stopRecording { result in
      XCTAssertFalse(result is FlutterError); stopped.fulfill()
    }
    await fulfillment(of: [stopped], timeout: 5)
    try call("login", ["name": "student", "password": password])
    let row = try call("detail", ["id": id]) as! [String: Any]
    XCTAssertEqual(row["state"] as? String, "saved")
    XCTAssertEqual(row["packets"] as? Int, 2); XCTAssertEqual(row["samples"] as? Int, 32)
    let lines = try String(contentsOfFile: path!, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 4)
    XCTAssertTrue(lines[0].contains("session_id")); XCTAssertTrue(lines.last!.contains("123456"))
    try call("deleteSession", ["id": id]); XCTAssertFalse(FileManager.default.fileExists(atPath: path!))
    defaults.removePersistentDomain(forName: service)
  }
  func testNotificationFrameworkDeduplicatesAndCancelsStaleAlerts() {
    let defaults = UserDefaults(suiteName: service)!
    defer { defaults.removePersistentDomain(forName: service) }
    var sent: [(AppNotice, TimeInterval?)] = []; var cancelled: [String] = []
    let notifications = AppNotifications(preferences: defaults, schedule: { sent.append(($0, $1)) }, cancel: { cancelled += $0 })
    let notice = AppNotice(kind: "save_failed", scope: "test", title: "采集异常", body: "测试内容")
    let now = Date(timeIntervalSince1970: 1000)
    notifications.post(notice, now: now); XCTAssertTrue(sent.isEmpty)
    notifications.setEnabled(true)
    notifications.post(notice, now: now); notifications.post(notice, now: now.addingTimeInterval(1))
    XCTAssertEqual(sent.count, 1)
    notifications.post(notice, now: now.addingTimeInterval(60)); XCTAssertEqual(sent.count, 2)
    notifications.receivedRaw(scope: "test", now: now)
    notifications.receivedRaw(scope: "test", now: now.addingTimeInterval(1))
    XCTAssertEqual(sent.count, 3); XCTAssertEqual(sent.last?.1, 20)
    notifications.receivedRaw(scope: "test", now: now.addingTimeInterval(5)); XCTAssertEqual(sent.count, 4)
    notifications.cancelWatchdog(); XCTAssertEqual(cancelled.last, "neurox.test.data_stalled")
    notifications.setEnabled(false); notifications.post(notice, now: now.addingTimeInterval(120))
    XCTAssertEqual(sent.count, 4)
  }

  func testLanguagePreferenceAndNativePendingAlertUpdate() throws {
    let defaults = UserDefaults(suiteName: service)!
    defer { defaults.removePersistentDomain(forName: service) }
    let locale = AppLocale(preferences: defaults)
    XCTAssertEqual(locale.language, "zh")
    try locale.setLanguage("en")
    XCTAssertEqual(AppLocale(preferences: defaults).language, "en")
    XCTAssertThrowsError(try locale.setLanguage("unsupported"))
    var sent: [(AppNotice, TimeInterval?)] = []
    let notifications = AppNotifications(preferences: defaults, schedule: { sent.append(($0, $1)) }, cancel: { _ in })
    notifications.setEnabled(true)
    let now = Date(timeIntervalSince1970: 1000)
    notifications.receivedRaw(scope: "test", now: now)
    XCTAssertEqual(sent.last?.0.title, "Acquisition data stalled")
    try locale.setLanguage("zh")
    notifications.refreshLanguage(now: now.addingTimeInterval(15))
    XCTAssertEqual(sent.last?.0.title, "采集数据已停滞")
    XCTAssertEqual(sent.last?.1, 5)
    XCTAssertEqual(sent[0].0.identifier, sent[1].0.identifier)
  }

}
