import AppKit
import CoreAudio
import Foundation

/// An application that Core Audio knows about as an audio process.
struct AudioProcess: Identifiable, Hashable {
    /// The Core Audio process object id (used to build taps).
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let displayName: String
    /// Whether the process is currently producing output audio.
    let isPlaying: Bool

    /// A stable key we persist routing choices against (survives relaunches).
    var routingKey: String { bundleID.isEmpty ? "pid:\(pid)" : bundleID }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool { lhs.routingKey == rhs.routingKey }
    func hash(into hasher: inout Hasher) { hasher.combine(routingKey) }
}

enum AudioProcesses {
    /// Lists every process Core Audio is currently tracking for audio.
    /// Requires macOS 14.0+ (the process-object API). Returns `[]` otherwise.
    static func all() -> [AudioProcess] {
        guard #available(macOS 14.0, *) else { return [] }

        let address = CA.address(kAudioHardwarePropertyProcessObjectList)
        let ids: [AudioObjectID]
        do {
            ids = try CA.array(CA.systemObject, address, of: AudioObjectID.self)
        } catch {
            CA.log.error("Could not list audio processes: \(String(describing: error))")
            return []
        }

        let processes = ids.compactMap { process(for: $0) }

        // Collapse to one entry per app and prefer the playing instance.
        var byKey: [String: AudioProcess] = [:]
        for proc in processes {
            if let existing = byKey[proc.routingKey], existing.isPlaying, !proc.isPlaying { continue }
            byKey[proc.routingKey] = proc
        }
        return byKey.values
            .filter { !$0.displayName.isEmpty }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying && !rhs.isPlaying }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    @available(macOS 14.0, *)
    static func process(for id: AudioObjectID) -> AudioProcess? {
        let pid = (try? CA.value(id, CA.address(kAudioProcessPropertyPID), default: pid_t(-1))) ?? -1
        guard pid > 0 else { return nil }

        let bundleID = (try? CA.string(id, CA.address(kAudioProcessPropertyBundleID))) ?? ""
        let isPlaying = ((try? CA.value(id, CA.address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0) != 0

        let running = NSRunningApplication(processIdentifier: pid)
        let name = running?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? "PID \(pid)"

        // Skip our own process and the system "coreaudiod" plumbing.
        if running?.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        return AudioProcess(id: id, pid: pid, bundleID: bundleID, displayName: name, isPlaying: isPlaying)
    }

    /// Resolves a routing key (bundle id or `pid:`) back to a live process.
    static func process(forRoutingKey key: String) -> AudioProcess? {
        all().first { $0.routingKey == key }
    }
}
