import Foundation
import UserNotifications

// Background helper (lives in the app bundle as AudioOutputSchedulerHelper.app, launched by launchd at each scheduled time).
// Switches to the output that should be active now. If "wait until audio stops" is on and something
// is playing, it waits and switches 3 s after playback stops. With the system-audio permission it
// listens to the output level, so apps that only keep the device open don't count as playing. Posts a notification when it switches.

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}
func setStatus(_ s: String?) {
    if let s { try? s.write(to: statusURL, atomically: true, encoding: .utf8) }
    else { try? FileManager.default.removeItem(at: statusURL) }
}
@discardableResult
func authorize() -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
        ok = granted
        if let err { log("Notification permission error: \(err.localizedDescription)") }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 60)
    return ok
}
/// Shows notifications as banners even if the system treats this helper as the foreground app.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
let notificationDelegate = NotificationDelegate()
UNUserNotificationCenter.current().delegate = notificationDelegate

func notify(_ title: String, _ body: String, force: Bool = false) {
    guard force || ConfigIO.load().notify else { return }
    guard authorize() else { log("Notifications are not allowed."); return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.interruptionLevel = .active
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    var done = false
    UNUserNotificationCenter.current().add(req) { err in
        if let err { log("Notification error: \(err.localizedDescription)") }
        done = true
    }
    // keep the process (and its run loop) alive briefly so the banner can be presented
    let until = Date().addingTimeInterval(3)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        if done && Date() > until.addingTimeInterval(-1.5) { break }
    }
}

let args = CommandLine.arguments
if args.contains("--authorize") { exit(authorize() ? 0 : 1) }
CapturePermission.saveStatus()

signal(SIGTERM) { _ in
    unlink(statusURL.path)
    exit(0)
}

let detector = PlaybackDetector()
if args.contains("--check") {
    // read-only: prints what the detector hears for a few seconds, without switching anything
    let config = ConfigIO.load()
    for _ in 0..<6 {
        if let dev = Audio.defaultOutput() {
            let apps = Audio.activeClients(on: dev, ignoring: config.ignoredApps).map(\.bundleID)
            log("permission=\(CapturePermission.granted.map(String.init) ?? "unknown") open=\(apps) playing=\(detector.isPlaying(on: dev, ignoring: config.ignoredApps))")
        }
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}
var waiting = false
var quietSince: Date?

while true {
    let config = ConfigIO.load()
    guard let target = Scheduler.target(config) else { log("No active schedule."); break }
    guard let dev = Audio.deviceID(named: target.device) else {
        log("\(target.device) is not connected; skipped.")
        notify("Couldn't switch sound output", "\(target.device) is not connected (\(target.time) schedule).")
        break
    }
    guard let cur = Audio.defaultOutput() else { log("No current output device."); break }
    if cur == dev {
        if waiting { log("\(target.device) is already the output; nothing to do.") }
        break
    }
    if config.waitForSilence && detector.isPlaying(on: cur, ignoring: config.ignoredApps) {
        quietSince = nil
        if !waiting { log("Audio is playing on \(Audio.name(cur)); waiting to switch to \(target.device).") }
        waiting = true
        setStatus("\(target.time)\t\(target.device)")
    } else if config.waitForSilence && waiting && Date().timeIntervalSince(quietSince ?? Date()) < 3 {
        if quietSince == nil { quietSince = Date() }
    } else {
        if Audio.setDefaultOutput(dev) {
            log("Switched to \(target.device).")
            setStatus(nil)
            notify("Sound output switched",
                   "Now playing through \(target.device)" + (waiting ? " (after playback stopped)." : "."))
        } else {
            log("Failed to switch to \(target.device).")
            notify("Couldn't switch sound output", "Switching to \(target.device) failed.")
        }
        break
    }
    Thread.sleep(forTimeInterval: 1)
}
setStatus(nil)
