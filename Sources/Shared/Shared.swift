import Foundation
import CoreAudio

let home = FileManager.default.homeDirectoryForCurrentUser
let supportURL = home.appendingPathComponent("Library/Application Support/AudioOutputScheduler")
let configURL = supportURL.appendingPathComponent("schedule.json")
let statusURL = supportURL.appendingPathComponent("status.txt")
let agentLabel = "io.github.chibik1.audiooutputscheduler"
let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

// MARK: - Device kinds

enum DeviceKind {
    case builtInSpeakers, builtInHeadphones, externalDisplay, audioInterface
    case headphones, bluetooth, airplay, virtual, aggregate, notConnected

    var label: String {
        switch self {
        case .builtInSpeakers: return "Built-in Speakers"
        case .builtInHeadphones: return "Built-in Headphones"
        case .externalDisplay: return "External Display"
        case .audioInterface: return "Audio Interface"
        case .headphones: return "Headphones"
        case .bluetooth: return "Bluetooth"
        case .airplay: return "AirPlay"
        case .virtual: return "Virtual Output"
        case .aggregate: return "Multi-Output Device"
        case .notConnected: return "Not connected"
        }
    }
    var symbol: String {
        switch self {
        case .builtInSpeakers: return "laptopcomputer"
        case .builtInHeadphones, .headphones, .bluetooth: return "headphones"
        case .externalDisplay: return "display"
        case .audioInterface: return "slider.vertical.3"
        case .airplay: return "airplayaudio"
        case .virtual: return "waveform"
        case .aggregate: return "square.stack.3d.up.fill"
        case .notConnected: return "questionmark"
        }
    }
}

struct OutputDevice: Identifiable, Hashable {
    let name: String
    let kind: DeviceKind
    var id: String { name }
}

// MARK: - CoreAudio

enum Audio {
    static let sys = AudioObjectID(kAudioObjectSystemObject)
    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func name(_ id: AudioObjectID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr,
              let v = value?.takeRetainedValue() else { return "" }
        return v as String
    }
    static func transport(_ id: AudioObjectID) -> UInt32 {
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        return t
    }
    static func hasOutput(_ id: AudioObjectID) -> Bool {
        var a = addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
        return size > 0
    }
    static func classify(name: String, transport t: UInt32) -> DeviceKind {
        let n = name.lowercased()
        let isPhones = n.contains("headphone") || n.contains("headset") || n.contains("ヘッドフォン") || n.contains("airpods")
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return isPhones ? .builtInHeadphones : .builtInSpeakers
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return .externalDisplay
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return isPhones ? .headphones : .audioInterface
        }
    }
    static func outputIDs() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids)
        return ids.filter(hasOutput)
    }
    static func outputDevices() -> [OutputDevice] {
        var seen = Set<String>()
        return outputIDs().compactMap { id in
            let n = name(id)
            guard !n.isEmpty, seen.insert(n).inserted else { return nil }
            return OutputDevice(name: n, kind: classify(name: n, transport: transport(id)))
        }
    }
    static func deviceID(named n: String) -> AudioObjectID? {
        outputIDs().first { name($0) == n }
    }
    static func defaultOutput() -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
    static func currentOutputName() -> String? { defaultOutput().map(name) }
    static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        return AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev) == noErr
    }
    struct Client: Hashable { let pid: Int32; let bundleID: String }
    /// Apps that currently have audio output running on the given device.
    static func outputClients(on dev: AudioObjectID) -> [Client] {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &procs)
        return procs.compactMap { p in
            var ra = addr(kAudioProcessPropertyIsRunningOutput)
            var running: UInt32 = 0
            var rs = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(p, &ra, 0, nil, &rs, &running) == noErr, running != 0 else { return nil }
            var da = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
            var ds: UInt32 = 0
            AudioObjectGetPropertyDataSize(p, &da, 0, nil, &ds)
            var devs = [AudioObjectID](repeating: 0, count: Int(ds) / MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(p, &da, 0, nil, &ds, &devs)
            guard devs.contains(dev) else { return nil }
            var pa = addr(kAudioProcessPropertyPID)
            var pid: Int32 = 0
            var ps = UInt32(MemoryLayout<Int32>.size)
            AudioObjectGetPropertyData(p, &pa, 0, nil, &ps, &pid)
            var ba = addr(kAudioProcessPropertyBundleID)
            var bs = UInt32(MemoryLayout<CFString?>.size)
            var b: Unmanaged<CFString>?
            let bundle = AudioObjectGetPropertyData(p, &ba, 0, nil, &bs, &b) == noErr
                ? (b?.takeRetainedValue() as String? ?? "") : ""
            return Client(pid: pid, bundleID: bundle)
        }
    }
    /// Something is playing on the device, not counting apps on the ignore list.
    static func isPlaying(on dev: AudioObjectID, ignoring ignored: [String]) -> Bool {
        outputClients(on: dev).contains { c in
            !ignored.contains { !$0.isEmpty && c.bundleID.hasPrefix($0) }
        }
    }
    /// true while any app has audio running on the device
    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return false }
        return v != 0
    }
}

// MARK: - Schedule model

/// weekday numbers follow Calendar: 1 = Sunday … 7 = Saturday
let weekdayLabels: [(Int, String)] = [(1, "Su"), (2, "Mo"), (3, "Tu"), (4, "We"), (5, "Th"), (6, "Fr"), (7, "Sa")]

struct Entry: Codable, Identifiable, Hashable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var device: String
    var weekdays: Set<Int> = Set(1...7)
    var minutes: Int { hour * 60 + minute }
    var time: String { String(format: "%02d:%02d", hour, minute) }
}

/// Apps that keep the audio device open even when silent (DAWs). Matched as bundle-ID prefixes.
let defaultIgnoredApps = ["com.apple.garageband10", "com.apple.logic10", "com.apple.mainstage3",
                          "com.steinberg.cubase", "com.ableton.live"]

struct Config: Codable {
    var waitForSilence = true
    var entries: [Entry] = []
    var ignoredApps: [String] = defaultIgnoredApps
    var notify = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waitForSilence = try c.decodeIfPresent(Bool.self, forKey: .waitForSilence) ?? true
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? defaultIgnoredApps
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
    }
}

enum ConfigIO {
    static func load() -> Config {
        if let data = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(Config.self, from: data) { return c }
        // no saved schedule yet
        return Config()
    }
    static func save(_ c: Config) throws {
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(c).write(to: configURL, options: .atomic)
    }
}

enum Scheduler {
    /// The schedule entry that should be in effect right now (most recent past occurrence).
    static func target(_ c: Config, now: Date = Date()) -> Entry? {
        let cal = Calendar.current
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let wd = cal.component(.weekday, from: day)
            let cands = c.entries.filter { $0.weekdays.contains(wd) && (offset > 0 || $0.minutes <= nowMin) }
            if let best = cands.max(by: { $0.minutes < $1.minutes }) { return best }
        }
        return nil
    }
}

// MARK: - launchd agent

enum LaunchAgent {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    /// Writes the launchd job for the current schedule. Only reloads when something changed,
    /// so a switch that is waiting for audio to stop is not interrupted by unrelated edits.
    /// Returns an error message, or nil on success.
    static func install(runner: String, config: Config) -> String? {
        let domain = "gui/\(getuid())"
        let times = Set(config.entries.filter { !$0.weekdays.isEmpty }.map { $0.minutes }).sorted()
        if times.isEmpty {
            run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
            try? FileManager.default.removeItem(at: agentURL)
            return nil
        }
        let dict: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [runner],
            "StartCalendarInterval": times.map { ["Hour": $0 / 60, "Minute": $0 % 60] },
            "ProcessType": "Background",
            "StandardOutPath": "/tmp/audio-switch.log",
            "StandardErrorPath": "/tmp/audio-switch.log",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return "Couldn't create the background job."
        }
        if let old = try? Data(contentsOf: agentURL), old == data,
           run("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"]) == 0 {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: agentURL, options: .atomic)
        } catch {
            return "Couldn't write the background job: \(error.localizedDescription)"
        }
        run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
        return run("/bin/launchctl", ["bootstrap", domain, agentURL.path]) == 0
            ? nil : "Couldn't register the background job."
    }
}
