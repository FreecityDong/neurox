import Foundation
import UserNotifications
import Flutter
import AudioToolbox
import UIKit

struct AppNotice {
  let kind: String
  let scope: String
  let title: String
  let body: String
  var sound: Bool = true
  var identifier: String { "neurox.\(scope).\(kind)" }
}

/// Content and scheduling are independent of BLE so later features can reuse it.
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let center: UNUserNotificationCenter
  private let preferences: UserDefaults
  private var channel: FlutterMethodChannel?
  private var lastSent: [String: Date] = [:]
  private var lastWatchdog: Date?
  private var watchdogNotice: AppNotice?
  private var watchdogID: String?
  private let testSchedule: ((AppNotice, TimeInterval?) -> Void)?
  private let testCancel: (([String]) -> Void)?
  var taskSilenced=false {
    didSet {if taskSilenced {cancelWatchdog()}}
  }
  var userMuted: Bool { preferences.dictionary(forKey:"neurox.feedback.channels")?["muted"] as? Bool == true }
  var enabled: Bool { preferences.bool(forKey: "neurox.notifications.enabled") }

  init(center: UNUserNotificationCenter = .current(), preferences: UserDefaults = .standard,
       schedule: ((AppNotice, TimeInterval?) -> Void)? = nil, cancel: (([String]) -> Void)? = nil) {
    self.center = center; self.preferences = preferences; testSchedule = schedule; testCancel = cancel
    super.init()
    if schedule == nil { center.delegate = self }
  }
  func attach(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "neurox/notifications", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "configure":
        let args=call.arguments as? [String:Any] ?? [:]
        self.configure(args); result(nil)
      case "feedback", "testFeedback":
        let args=call.arguments as? [String:Any] ?? [:]
        let send = {self.deliverFeedback(args,kind:call.method == "testFeedback" ? "task.test" : (args["kind"] as? String ?? "task.event"),scope:args["scope"] as? String ?? UUID().uuidString,title:args["title"] as? String ?? "反馈测试",body:args["body"] as? String ?? "这是当前所选反馈方式的测试。",completion:result)}
        if call.method == "testFeedback",args["notice"] as? Bool == true,!self.userMuted,args["muted"] as? Bool != true,!self.taskSilenced {
          self.center.requestAuthorization(options:[.alert,.sound]) {allowed,_ in DispatchQueue.main.async {self.setEnabled(allowed);send()}}
        } else {send()}
      case "status": self.status(result)
      case "request":
        self.center.requestAuthorization(options: [.alert, .sound]) { allowed, error in
          DispatchQueue.main.async {
            if let error = error { result(FlutterError(code: "notifications", message: error.localizedDescription, details: nil)); return }
            self.setEnabled(allowed); self.status(result)
          }
        }
      case "disable": self.setEnabled(false); self.status(result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  func deliverFeedback(_ options:[String:Any],kind:String,scope:String,title:String,body:String,completion:@escaping ([String:Any])->Void) {
    if taskSilenced || userMuted || options["muted"] as? Bool == true {completion(["sound":"silenced","vibration":"silenced","notice":"silenced"]);return}
    let foreground=UIApplication.shared.applicationState == .active
    var result:[String:Any] = ["sound":options["sound"] as? Bool == true ? (foreground ? "requested" : "unavailable") : "disabled",
      "vibration":options["vibration"] as? Bool == true ? (foreground ? "requested" : "unavailable") : "disabled",
      "notice":"disabled"]
    if foreground && options["sound"] as? Bool == true {AudioServicesPlayAlertSound(1007)}
    if foreground && options["vibration"] as? Bool == true {UINotificationFeedbackGenerator().notificationOccurred(.warning)}
    guard options["notice"] as? Bool == true else {completion(result);return}
    center.getNotificationSettings {settings in DispatchQueue.main.async {
      if self.taskSilenced || self.userMuted {result["notice"]="silenced";completion(result);return}
      guard self.enabled,[UNAuthorizationStatus.authorized,.provisional,.ephemeral].contains(settings.authorizationStatus) else {result["notice"]="not_authorized";completion(result);return}
      self.schedule(AppNotice(kind:kind,scope:scope,title:title,body:body,sound:false),completion:{error in
        result["notice"]=error == nil ? "requested" : "unavailable";completion(result)
      })
    }}
  }
  func configure(_ options:[String:Any]) {
    preferences.set(options,forKey:"neurox.feedback.channels")
    if options["muted"] as? Bool == true {
      cancelWatchdog()
      center.removeAllPendingNotificationRequests()
    } else if options["notice"] as? Bool != true {cancelWatchdog()} else {refreshLanguage()}
  }
  private func status(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { value in
      DispatchQueue.main.async { result(["enabled": self.enabled, "authorization": value.authorizationStatus.rawValue]) }
    }
  }
  func setEnabled(_ enabled: Bool) {
    preferences.set(enabled, forKey: "neurox.notifications.enabled")
    if !enabled { cancelWatchdog() }
  }
  private func schedule(_ notice: AppNotice, after delay: TimeInterval? = nil, completion: ((Error?)->Void)? = nil) {
    guard !taskSilenced,!userMuted,enabled else { completion?(LocalFailure("Notifications disabled"));return }
    let localized = AppNotice(kind: notice.kind, scope: notice.scope,
      title: AppLocale.text(notice.title, preferences: preferences), body: AppLocale.text(notice.body, preferences: preferences),sound:notice.sound)
    if let testSchedule = testSchedule { testSchedule(localized, delay); completion?(nil); return }
    let content = UNMutableNotificationContent()
    content.title = localized.title; content.body = localized.body
    let options=preferences.dictionary(forKey:"neurox.feedback.channels") ?? [:]
    if notice.sound && options["sound"] as? Bool == true {content.sound = .default}
    content.threadIdentifier = "neurox.acquisition"
    // No account, device ID, waveform, credential or direct data route in payload.
    let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
    center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: trigger)) { error in
      if error != nil { print("NeuroX notification scheduling failed") }
      if let completion=completion {DispatchQueue.main.async {completion(error)}}
    }
  }
  func post(_ notice: AppNotice, now: Date = Date()) {
    guard !taskSilenced,!userMuted else {return}
    if let last=lastSent[notice.identifier],now.timeIntervalSince(last)<60 {return}
    let options=preferences.dictionary(forKey:"neurox.feedback.channels")
    let direct = notice.kind != "state" && !notice.kind.hasPrefix("task.") && UIApplication.shared.applicationState == .active
    let sound = direct && options?["sound"] as? Bool == true
    let vibration = direct && options?["vibration"] as? Bool == true
    let notify = enabled && (options == nil || options?["notice"] as? Bool == true)
    guard sound || vibration || notify else {return}
    lastSent[notice.identifier]=now
    if lastSent.count>128 {lastSent=lastSent.filter{now.timeIntervalSince($0.value)<60}}
    if sound {AudioServicesPlayAlertSound(1007)}
    if vibration {UINotificationFeedbackGenerator().notificationOccurred(.warning)}
    if notify {schedule(notice)}
  }
  /// System schedules the stale alert, so it can fire when app timers suspend.
  /// Refresh at most once/5s. A 20s deadline means actual alert is 15–20s after last valid raw.
  func receivedRaw(scope: String, now: Date = Date()) {
    guard !taskSilenced,!userMuted else {return}
    let options=preferences.dictionary(forKey:"neurox.feedback.channels")
    guard enabled,options == nil || options?["notice"] as? Bool == true else {return}
    let id = "neurox.\(scope).data_stalled"
    if watchdogID == id, let last = lastWatchdog, now.timeIntervalSince(last) < 5 { return }
    if watchdogID != id { cancelWatchdog() }
    watchdogID = id; lastWatchdog = now
    let notice = AppNotice(kind: "data_stalled", scope: scope, title: "采集数据已停滞",
      body: "一段时间未收到有效原始数据，请打开 NeuroX 检查连接。已收到的记录保留。")
    watchdogNotice = notice
    schedule(notice, after: 20)
  }
  func refreshLanguage(now: Date = Date()) {
    guard let notice = watchdogNotice, let scheduled = lastWatchdog else { return }
    let remaining = 20 - now.timeIntervalSince(scheduled)
    if remaining > 0 { schedule(notice, after: remaining) }
  }
  func cancelWatchdog() {
    if let id = watchdogID {
      if let testCancel = testCancel { testCancel([id]) }
      else { center.removePendingNotificationRequests(withIdentifiers: [id]) }
    }
    watchdogID = nil; lastWatchdog = nil; watchdogNotice = nil
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if taskSilenced || userMuted {completionHandler([]);return}
    completionHandler(notification.request.content.sound == nil ? [.banner] : [.banner,.sound])
  }
}
