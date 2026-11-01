import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension DeviceKind {
    var color: Color {
        switch self {
        case .builtInSpeakers, .builtInHeadphones: return .gray
        case .externalDisplay: return .blue
        case .audioInterface: return .orange
        case .headphones, .bluetooth: return .pink
        case .airplay: return .teal
        case .virtual: return .purple
        case .aggregate: return .indigo
        case .notConnected: return .secondary
        }
    }
}

// MARK: - App info

struct AppInfo: Identifiable, Hashable {
    let id: String      // bundle ID used for ignoring (prefix match)
    let name: String
    let icon: NSImage
}

func resolveApp(_ bundle: String) -> AppInfo {
    let parts = bundle.split(separator: ".").map(String.init)
    if parts.count >= 2 {
        for n in min(3, parts.count)...parts.count {
            let b = parts.prefix(n).joined(separator: ".")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                let name = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
                return AppInfo(id: b, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
            }
        }
    }
    if bundle.hasPrefix("com.apple.WebKit") {
        return AppInfo(id: bundle, name: "Web content (WebKit)",
                       icon: NSWorkspace.shared.icon(for: .html))
    }
    return AppInfo(id: bundle, name: bundle.isEmpty ? "Unknown app" : bundle,
                   icon: NSWorkspace.shared.icon(for: .application))
}

/// The app a helper process (e.g. com.apple.WebKit.GPU) works for, via the private
/// responsibility API. WebKit plays web audio from its own GPU process, so CoreAudio
/// reports that process instead of the app showing the page.
private let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
}()

func ownerApp(of pid: pid_t) -> NSRunningApplication? {
    guard let f = responsiblePID else { return nil }
    let owner = f(pid)
    guard owner > 0, owner != pid else { return nil }
    return NSRunningApplication(processIdentifier: owner)
}

/// Shows WebKit helpers as the app(s) they play for: "MenubarX (Web)" with that app's icon.
/// The id stays the WebKit bundle ID, since that is what the ignore list matches.
func resolveWebKit(_ base: AppInfo, owners: [NSRunningApplication]) -> AppInfo {
    let names = owners.compactMap(\.localizedName)
    guard !names.isEmpty else { return base }
    return AppInfo(id: base.id, name: names.joined(separator: ", ") + " (Web)",
                   icon: owners.first?.icon ?? base.icon)
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var config = Config()
    @Published var devices: [OutputDevice] = []
    @Published var current: String?
    @Published var pending: (time: String, device: String)?
    @Published var error: String?
    @Published var audioApps: [AppInfo] = []   // apps using the current output right now
    @Published var capture = "unknown"          // helper's system-audio permission: granted / denied / unknown
    let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/Helpers/AudioOutputSchedulerHelper.app")
    var runnerPath: String { helperURL.appendingPathComponent("Contents/MacOS/AudioOutputSchedulerHelper").path }
    private var timer: Timer?

    init() {
        config = ConfigIO.load()
        refresh()
        error = LaunchAgent.install(runner: runnerPath, config: config)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        if config.notify { runHelper("--authorize") }
    }
    /// Runs the background helper with an argument (asks for notification permission, sends a test, …).
    func runHelper(_ arg: String) {
        let path = runnerPath
        DispatchQueue.global().async { LaunchAgent.run(path, [arg]) }
    }
    func setNotify(_ v: Bool) {
        config.notify = v
        save()
        if v { runHelper("--authorize") }
    }
    /// macOS doesn't show a permission prompt for the background helper, and it judges the helper by
    /// the app that contains it, so the user adds this app by hand: opens Screen & System Audio
    /// Recording and shows the app in Finder to drag into the list.
    func allowCapture() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    /// Lets the user pick any app to add to the ignore list.
    func addIgnoredApps() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to ignore"
        panel.prompt = "Ignore"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var added = false
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !isIgnored(id) {
                config.ignoredApps.append(id)
                added = true
            }
        }
        if added { save() }
    }
    var entries: [Entry] { config.entries.sorted { $0.minutes < $1.minutes } }

    func poll() {
        let raw = (try? String(contentsOf: statusURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = raw.split(separator: "\t", maxSplits: 1).map(String.init)
        let p = parts.count == 2 ? (time: parts[0], device: parts[1]) : nil
        if p?.time != pending?.time || p?.device != pending?.device { pending = p }
        let cap = (try? String(contentsOf: captureStatusURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        if cap != capture { capture = cap }
        let c = Audio.currentOutputName()
        if c != current { current = c }
        var apps: [AppInfo] = []
        var webOwners: [String: [NSRunningApplication]] = [:]
        if let dev = Audio.defaultOutput() {
            for client in Audio.outputClients(on: dev) {
                let info = resolveApp(client.bundleID)
                if !apps.contains(where: { $0.id == info.id }) { apps.append(info) }
                if client.bundleID.hasPrefix("com.apple.WebKit"), let owner = ownerApp(of: client.pid),
                   !(webOwners[info.id]?.contains(owner) ?? false) {
                    webOwners[info.id, default: []].append(owner)
                }
            }
        }
        apps = apps.map { app in webOwners[app.id].map { resolveWebKit(app, owners: $0) } ?? app }
        if apps.map(\.id) != audioApps.map(\.id) || apps.map(\.name) != audioApps.map(\.name) {
            audioApps = apps
        }
    }
    /// Apps shown in the ignore list: those using audio now plus those already ignored.
    var appRows: [AppInfo] {
        var rows = audioApps
        for id in config.ignoredApps where !rows.contains(where: { $0.id == id }) {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
                || audioApps.contains(where: { $0.id.hasPrefix(id) }) {
                let info = resolveApp(id)
                if !rows.contains(where: { $0.id == info.id }) { rows.append(info) }
            }
        }
        return rows
    }
    func isIgnored(_ id: String) -> Bool { config.ignoredApps.contains { id.hasPrefix($0) } }
    func setIgnored(_ id: String, _ on: Bool) {
        if on { if !isIgnored(id) { config.ignoredApps.append(id) } }
        else { config.ignoredApps.removeAll { id.hasPrefix($0) } }
        save()
    }
    func refresh() {
        devices = Audio.outputDevices()
        poll()
    }
    func kind(_ name: String) -> DeviceKind {
        devices.first { $0.name == name }?.kind ?? .notConnected
    }
    func save() {
        do {
            try ConfigIO.save(config)
            error = LaunchAgent.install(runner: runnerPath, config: config)
        } catch {
            self.error = "Couldn't save the schedule: \(error.localizedDescription)"
        }
    }
    /// Adds or updates an entry. Other entries at the same time lose the overlapping days.
    func upsert(_ e: Entry, replacing original: Entry?) {
        var list = config.entries.filter { $0.id != original?.id && $0.id != e.id }
        list = list.compactMap { o in
            guard o.minutes == e.minutes else { return o }
            var o2 = o
            o2.weekdays.subtract(e.weekdays)
            return o2.weekdays.isEmpty ? nil : o2
        }
        list.append(e)
        config.entries = list
        save()
    }
    func delete(_ e: Entry) {
        config.entries.removeAll { $0.id == e.id }
        save()
    }
    func toggle(_ e: Entry, weekday wd: Int) {
        var e2 = e
        if e2.weekdays.contains(wd) { e2.weekdays.remove(wd) } else { e2.weekdays.insert(wd) }
        upsert(e2, replacing: e)
    }
    func setWait(_ v: Bool) {
        config.waitForSilence = v
        save()
    }
}

// MARK: - Small views

struct DeviceIcon: View {
    let kind: DeviceKind
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(kind.color.gradient)
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct WeekdayChips: View {
    let selected: Set<Int>
    var size: CGFloat = 24
    let toggle: (Int) -> Void
    var body: some View {
        HStack(spacing: 3) {
            ForEach(weekdayLabels, id: \.0) { item in
                let on = selected.contains(item.0)
                Button { toggle(item.0) } label: {
                    Text(item.1)
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .frame(width: size, height: size * 0.82)
                        .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on ? "Turn off for this day" : "Turn on for this day")
            }
        }
    }
}

struct SpinField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(String(format: "%02d", value))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 56)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                Stepper("", onIncrement: {
                    value = value >= range.upperBound ? range.lowerBound : value + 1
                }, onDecrement: {
                    value = value <= range.lowerBound ? range.upperBound : value - 1
                })
                .labelsHidden()
                .controlSize(.large)
            }
        }
    }
}

struct DeviceChoiceRow: View {
    let device: OutputDevice
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(kind: device.kind, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(device.name).lineLimit(1)
                Text(device.kind.label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Main window

struct EntryRow: View {
    @EnvironmentObject var store: Store
    let entry: Entry
    let onEdit: () -> Void
    @State private var hover = false
    var body: some View {
        let kind = store.kind(entry.device)
        let off = entry.weekdays.isEmpty
        HStack(spacing: 14) {
            Text(entry.time)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 78, alignment: .leading)
                .opacity(off ? 0.4 : 1)
            DeviceIcon(kind: kind).opacity(off ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.device).font(.body.weight(.medium)).lineLimit(1)
                Text(off ? "Off — no days selected" : kind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            WeekdayChips(selected: entry.weekdays, size: 24) { store.toggle(entry, weekday: $0) }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Edit")
            Button { store.delete(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(hover ? 0.08 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onEdit)
    }
}

struct EditTarget: Identifiable {
    let id = UUID()
    let entry: Entry?
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var editing: EditTarget?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Output Scheduler").font(.title2.bold())
                Text("Switches the sound output at these times on the selected days.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No schedules yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.entries) { e in
                        EntryRow(entry: e, onEdit: { editing = EditTarget(entry: e) })
                    }
                }
            }
            HStack {
                Spacer()
                Button { store.refresh(); editing = EditTarget(entry: nil) } label: {
                    Label("Add Schedule", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { store.config.waitForSilence }, set: { store.setWait($0) })) {
                    Text("Wait until audio stops playing")
                }
                .toggleStyle(.switch)
                Text("If something is playing at the scheduled time, the output switches 3 seconds after playback stops.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.config.waitForSilence {
                    if store.capture == "granted" {
                        Label("Listens for actual sound, so apps that keep the output open while silent don't hold up the switch.",
                              systemImage: "waveform")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Label(store.capture == "denied"
                                  ? "System audio access is off, so any app with the output open counts as playing. Add Audio Output Scheduler under System Audio Recording Only."
                                  : "Add Audio Output Scheduler under System Audio Recording Only to tell real sound from apps that only keep the output open.",
                                  systemImage: "waveform.slash")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Open Settings…") { store.allowCapture() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            if store.config.waitForSilence {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Ignore these apps when checking for playback").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { store.addIgnoredApps() } label: { Label("Add App…", systemImage: "plus") }
                            .controlSize(.small)
                    }
                    Text(store.capture == "granted"
                         ? "Ignored apps never delay a switch, even while they make sound."
                         : "Some apps, like DAWs, keep the audio device open even when they are silent.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(store.appRows) { app in
                        let using = store.audioApps.contains { $0.id == app.id }
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                            Text(app.name).lineLimit(1)
                            if using {
                                Text("Using audio now").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.2)))
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Toggle("Ignore", isOn: Binding(get: { store.isIgnored(app.id) },
                                                           set: { store.setIgnored(app.id, $0) }))
                                .toggleStyle(.checkbox)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { store.config.notify }, set: { store.setNotify($0) })) {
                Text("Show a notification when the output switches")
            }
            .toggleStyle(.switch)
            if let p = store.pending {
                Label("Waiting for audio to stop — will switch to \(p.device) (\(p.time) schedule).", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let err = store.error {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            if let c = store.current {
                Label("Current output: \(c)", systemImage: "speaker.wave.2")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(22)
        .frame(width: 700, alignment: .top)
        .frame(minHeight: 580, alignment: .top)
        .sheet(item: $editing) { t in EditorView(original: t.entry).environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let original: Entry?
    @State private var device = ""
    @State private var hour = 8
    @State private var minute = 0
    @State private var weekdays: Set<Int> = Set(1...7)

    var choices: [OutputDevice] {
        var list = store.devices
        if let o = original, !list.contains(where: { $0.name == o.device }) {
            list.append(OutputDevice(name: o.device, kind: .notConnected))
        }
        return list
    }
    var selectedKind: DeviceKind { choices.first { $0.name == device }?.kind ?? .notConnected }
    var conflicts: [Entry] {
        store.entries.filter {
            $0.minutes == hour * 60 + minute && $0.id != original?.id && !$0.weekdays.isDisjoint(with: weekdays)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "New Schedule" : "Edit Schedule").font(.title3.bold())
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output Device").font(.headline)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(choices) { d in
                                DeviceChoiceRow(device: d, selected: d.name == device)
                                    .onTapGesture { device = d.name }
                            }
                        }
                    }
                    .frame(height: 390)
                }
                .frame(width: 290)

                Divider().frame(height: 420)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        DeviceIcon(kind: selectedKind, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.isEmpty ? "No device selected" : device)
                                .font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                            Text(selectedKind.label).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("Time").font(.headline)
                    HStack(alignment: .bottom, spacing: 10) {
                        SpinField(title: "Hour", value: $hour, range: 0...23)
                        Text(":").font(.system(size: 34, weight: .semibold, design: .rounded)).padding(.bottom, 4)
                        SpinField(title: "Minute", value: $minute, range: 0...59)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Minute presets").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach([0, 15, 30, 45], id: \.self) { m in
                                Button(String(format: ":%02d", m)) { minute = m }.controlSize(.small)
                            }
                        }
                    }
                    Divider()
                    Text("Days").font(.headline)
                    WeekdayChips(selected: weekdays, size: 32) { wd in
                        if weekdays.contains(wd) { weekdays.remove(wd) } else { weekdays.insert(wd) }
                    }
                    HStack(spacing: 6) {
                        Button("Every day") { weekdays = Set(1...7) }
                        Button("Weekdays") { weekdays = Set(2...6) }
                        Button("Weekends") { weekdays = [1, 7] }
                    }
                    .controlSize(.small)
                    if weekdays.isEmpty {
                        Text("No days selected — this schedule will be off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let c = conflicts.first {
                        Label("Overlapping days of the existing \(c.time) schedule (\(c.device)) will be replaced.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var e = original ?? Entry(hour: hour, minute: minute, device: device)
                    e.hour = hour; e.minute = minute; e.device = device; e.weekdays = weekdays
                    store.upsert(e, replacing: original)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(device.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640)
        .onAppear {
            if let o = original {
                device = o.device; hour = o.hour; minute = o.minute; weekdays = o.weekdays
            } else {
                device = store.current ?? store.devices.first?.name ?? ""
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AudioOutputSchedulerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    var body: some Scene {
        Window("Audio Output Scheduler", id: "main") {
            ContentView().environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}
