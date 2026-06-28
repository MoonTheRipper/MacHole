import AppKit
import CoreAudio
import Foundation

/// One routable audio "app" as the user thinks of it: a friendly name + icon,
/// backed by one or more Core Audio process objects that actually produce the
/// sound (an app and its audio helpers are merged into a single entry).
struct AudioProcess: Identifiable, Hashable {
    /// Stable identity that survives relaunches (used for SwiftUI and persistence).
    let id: String
    let pid: pid_t
    let bundleID: String
    let displayName: String
    /// Whether any backing process is currently producing output audio.
    let isPlaying: Bool
    /// Whether the owner is a normal, user-facing GUI app (has a Dock presence).
    let isRegularApp: Bool
    /// The Core Audio process objects to tap when routing this app.
    let audioObjectIDs: [AudioObjectID]

    var routingKey: String { id }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AudioProcesses {
    /// Bundle ids of terminal emulators. We never attribute a CLI audio tool to
    /// the terminal that launched it — it should appear as itself instead.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper"
    ]

    /// A raw Core Audio process object before it's grouped into an app.
    private struct RawProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isPlaying: Bool
    }

    /// The app a raw process belongs to (itself, or a parent it was spawned by).
    private struct Owner {
        let pid: pid_t
        let bundleID: String
        let name: String
        let isRegularApp: Bool
        var key: String { bundleID.isEmpty ? "proc:\(name)" : bundleID }
    }

    /// Lists routable audio apps.
    /// - Parameter includeAll: when false (default), keeps only real GUI apps and
    ///   anything actively producing audio, hiding idle daemons/helpers/PIDs.
    static func all(includeAll: Bool = false) -> [AudioProcess] {
        guard #available(macOS 14.0, *) else { return [] }

        let address = CA.address(kAudioHardwarePropertyProcessObjectList)
        let ids: [AudioObjectID]
        do {
            ids = try CA.array(CA.systemObject, address, of: AudioObjectID.self)
        } catch {
            CA.log.error("Could not list audio processes: \(String(describing: error))")
            return []
        }

        let raws = ids.compactMap { rawProcess(for: $0) }

        // Group raw processes under the app that owns them.
        var grouped: [String: (owner: Owner, objects: [AudioObjectID], playing: Bool)] = [:]
        for raw in raws {
            let owner = resolveOwner(pid: raw.pid, bundleID: raw.bundleID)
            if var entry = grouped[owner.key] {
                entry.objects.append(raw.objectID)
                entry.playing = entry.playing || raw.isPlaying
                grouped[owner.key] = entry
            } else {
                grouped[owner.key] = (owner, [raw.objectID], raw.isPlaying)
            }
        }

        let apps = grouped.values.map { value in
            AudioProcess(
                id: value.owner.key,
                pid: value.owner.pid,
                bundleID: value.owner.bundleID,
                displayName: value.owner.name,
                isPlaying: value.playing,
                isRegularApp: value.owner.isRegularApp,
                audioObjectIDs: value.objects.sorted()
            )
        }

        return apps
            .filter { includeAll || $0.isRegularApp || $0.isPlaying }
            .filter { !$0.displayName.isEmpty }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying && !rhs.isPlaying }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    @available(macOS 14.0, *)
    private static func rawProcess(for objectID: AudioObjectID) -> RawProcess? {
        let pid = (try? CA.value(objectID, CA.address(kAudioProcessPropertyPID), default: pid_t(-1))) ?? -1
        guard pid > 0 else { return nil }

        // Never list ourselves.
        if let running = NSRunningApplication(processIdentifier: pid),
           running.bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
        }

        let bundleID = (try? CA.string(objectID, CA.address(kAudioProcessPropertyBundleID))) ?? ""
        let isPlaying = ((try? CA.value(objectID, CA.address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0) != 0
        return RawProcess(objectID: objectID, pid: pid, bundleID: bundleID, isPlaying: isPlaying)
    }

    /// Resolves the app that owns a process: the process itself if it's a regular
    /// GUI app, otherwise the nearest regular-app ancestor that isn't a terminal,
    /// otherwise the process standing on its own (named by its command).
    private static func resolveOwner(pid: pid_t, bundleID: String) -> Owner {
        if let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular,
           let bid = app.bundleIdentifier {
            return Owner(pid: pid, bundleID: bid, name: app.localizedName ?? bid, isRegularApp: true)
        }

        // Climb the parent chain looking for the launching app.
        var current = pid
        var depth = 0
        while depth < 8, let parent = ProcessTree.parentPID(of: current), parent > 1 {
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular,
               let bid = app.bundleIdentifier {
                if terminalBundleIDs.contains(bid) { break } // don't blame the terminal
                return Owner(pid: parent, bundleID: bid, name: app.localizedName ?? bid, isRegularApp: true)
            }
            current = parent
            depth += 1
        }

        // Standalone process (CLI player, game subprocess with no GUI ancestor).
        let running = NSRunningApplication(processIdentifier: pid)
        let command = ProcessTree.command(of: pid)
        let name = running?.localizedName
            ?? (command.isEmpty ? (bundleID.isEmpty ? "PID \(pid)" : bundleID) : command)
        return Owner(
            pid: pid,
            bundleID: running?.bundleIdentifier ?? "",
            name: name,
            isRegularApp: running?.activationPolicy == .regular
        )
    }
}
