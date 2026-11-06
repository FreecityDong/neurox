import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let locale = AppLocale()
  private let notifications = AppNotifications()
  private let localStore = LocalStore()
  private var eegBridge: EegBleBridge?
  private var startupChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Non-sensitive cache marker proves Dart completed a Flutter frame without a debugger.
    startupChannel = FlutterMethodChannel(name: "neurox/startup", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    startupChannel?.setMethodCallHandler { call, result in
      if call.method == "baselineGuardEvent" {
        do {
          let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
          try BaselineGuardDiagnostics.append(call.arguments as? [String:Any] ?? [:],to:cache.appendingPathComponent("neurox-baseline-guard.json"),
            version:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "",
            build:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "")
          result(nil)
        } catch {result(FlutterError(code:"guard_diagnostics",message:"Diagnostic summary unavailable",details:nil))}
        return
      }
      guard call.method == "firstFrameReady" else {result(FlutterMethodNotImplemented);return}
      do {
        let cache = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        let marker:[String:Any] = ["firstFrameReady":true,"pid":ProcessInfo.processInfo.processIdentifier,
          "version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "",
          "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") ?? "",
          "timestamp":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:marker,options:[.sortedKeys]).write(to:cache.appendingPathComponent("neurox-first-frame.json"),options:.atomic)
        result(nil)
      } catch {result(FlutterError(code:"startup_marker",message:"Startup marker unavailable",details:nil))}
    }

    locale.changed = { [weak self] in self?.notifications.refreshLanguage() }
    locale.attach(engineBridge.applicationRegistrar.messenger())
    notifications.attach(engineBridge.applicationRegistrar.messenger())
    localStore.attach(engineBridge.applicationRegistrar.messenger())
    eegBridge = EegBleBridge(messenger: engineBridge.applicationRegistrar.messenger(), store: localStore, notifications: notifications)
  }
}

/// Bounded, account-free diagnostic metadata; never a baseline or EEG recording.
enum BaselineGuardDiagnostics {
  static let limit=40
  static let types:Set<String>=["start","contact_pending","contact_recovered","quality_pending","quality_recovered","interrupted","discarded","cleanup_failed","ready"]
  static let reasons:Set<String>=["contact","waveform","wearing","data_loss","good","warming","comparison_warming","contact_pending","flat","raw_range","saturation","amplitude","step","coverage","gap","storage","processing","configuration","connection","disconnected","background","unstable","drift","floor","insufficient","ended","sdk_score_invalid","feature_schema","invalid_input","metadata","non_finite","spectrum","restart","data","waiting"]
  static func append(_ input:[String:Any],to url:URL,version:String,build:String,now:Date=Date()) throws {
    guard let type=input["type"] as? String,types.contains(type),let reason=input["reason"] as? String,reasons.contains(reason),
      input["guardVersion"] as? String == "baseline-guard-v2" else {throw LocalFailure("Invalid diagnostic summary")}
    var event:[String:Any]=["type":type,"reason":reason,"guardVersion":"baseline-guard-v2","version":version,"build":build,"timestamp":ISO8601DateFormatter().string(from:now)]
    if let phase=input["phase"] as? String,["preflight","recording"].contains(phase) {event["phase"]=phase}
    if let quality=input["qualityReason"] as? String,reasons.contains(quality) {event["qualityReason"]=quality}
    for key in ["elapsed","leadByte","contactReports","waveWindows","dataWindows","receivedRate","referenceRate","qualitySequence","qualityEnd"] {
      if let number=input[key] as? NSNumber,number.doubleValue.isFinite,number.doubleValue>=0,number.doubleValue<=1_000_000_000 {event[key]=number}
    }
    var events:[[String:Any]]=[]
    if let data=try? Data(contentsOf:url),data.count<=65536,
      let previous=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let old=previous["events"] as? [[String:Any]] {
      // Re-sanitize persisted fields; do not carry unknown content into future summaries.
      let allowed=Set(event.keys).union(["phase","qualityReason","elapsed","leadByte","contactReports","waveWindows","dataWindows","receivedRate","referenceRate","qualitySequence","qualityEnd"])
      events=old.suffix(limit-1).filter {row in
        guard let kind=row["type"] as? String,let why=row["reason"] as? String else{return false}
        return types.contains(kind) && reasons.contains(why)
      }.map {row in row.filter{allowed.contains($0.key)}}
    }
    events.append(event)
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:["schema":1,"events":events],options:[.sortedKeys]).write(to:url,options:.atomic)
  }
}
