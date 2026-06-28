import AppKit
import Combine
import CoreAudio
import Foundation
import ServiceManagement

/// The single source of truth for the UI and the routing engine.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var processes: [AudioProcess] = []
    /// App routing key -> chosen output device UID. Persisted across launches.
    @Published private(set) var assignments: [String: String] = [:]
    /// App routing key -> display name, so routed apps that aren't running can
    /// still be shown and managed.
    @Published private(set) var assignmentNames: [String: String] = [:]
    @Published var lastError: String?

    // Advanced settings (persisted).
    @Published var showOnlyPlaying: Bool {
        didSet { defaults.set(showOnlyPlaying, forKey: Keys.showOnlyPlaying); refresh() }
    }
    @Published var showAllProcesses: Bool {
        didSet { defaults.set(showAllProcesses, forKey: Keys.showAllProcesses); refresh() }
    }
    @Published var reapplyAutomatically: Bool {
        didSet { defaults.set(reapplyAutomatically, forKey: Keys.reapplyAutomatically) }
    }

    private let defaults = UserDefaults.standard
    private var refreshTimer: Timer?

    private enum Keys {
        static let assignments = "assignments"
        static let assignmentNames = "assignmentNames"
        static let showOnlyPlaying = "showOnlyPlaying"
        static let showAllProcesses = "showAllProcesses"
        static let reapplyAutomatically = "reapplyAutomatically"
    }

    var routingSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private init() {
        assignments = defaults.dictionary(forKey: Keys.assignments) as? [String: String] ?? [:]
        assignmentNames = defaults.dictionary(forKey: Keys.assignmentNames) as? [String: String] ?? [:]
        showOnlyPlaying = defaults.object(forKey: Keys.showOnlyPlaying) as? Bool ?? false
        showAllProcesses = defaults.object(forKey: Keys.showAllProcesses) as? Bool ?? false
        reapplyAutomatically = defaults.object(forKey: Keys.reapplyAutomatically) as? Bool ?? true

        refresh()
        startObserving()
        reapplySavedRoutes()
    }

    // MARK: - Enumeration

    func refresh() {
        devices = AudioDevices.allOutputDevices()
        let all = AudioProcesses.all(includeAll: showAllProcesses)
        var visible = showOnlyPlaying ? all.filter(\.isPlaying) : all

        // Always surface apps you've routed, even when they aren't running right
        // now, so you can see and undo the routing from the menu.
        let presentKeys = Set(visible.map(\.routingKey))
        let ghosts = assignments.keys
            .filter { !presentKeys.contains($0) }
            .map { key in
                AudioProcess(
                    id: key,
                    pid: -1,
                    bundleID: key.hasPrefix("proc:") ? "" : key,
                    displayName: assignmentNames[key] ?? friendlyName(forKey: key),
                    isPlaying: false,
                    isRegularApp: false,
                    audioObjectIDs: []
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        visible.append(contentsOf: ghosts)
        processes = visible
    }

    /// True when the app has no live audio process backing it (routed but closed).
    func isRunning(_ process: AudioProcess) -> Bool {
        !process.audioObjectIDs.isEmpty || process.isPlaying
    }

    private func friendlyName(forKey key: String) -> String {
        if key.hasPrefix("proc:") { return String(key.dropFirst("proc:".count)) }
        return key.split(separator: ".").last.map(String.init) ?? key
    }

    var defaultDevice: AudioDevice? { AudioDevices.defaultOutputDevice() }

    // MARK: - Assignment

    /// Returns the device a process is currently routed to, if any.
    func assignedDeviceUID(for process: AudioProcess) -> String? {
        assignments[process.routingKey]
    }

    /// Assign a process to a device UID, or pass `nil` to clear (use system default).
    func assign(_ process: AudioProcess, toDeviceUID deviceUID: String?) {
        guard routingSupported else {
            lastError = "Per-app routing needs macOS 14.4 or later."
            return
        }
        if #available(macOS 14.4, *) {
            let key = process.routingKey
            if let deviceUID {
                if process.audioObjectIDs.isEmpty {
                    // Not running yet — remember the choice and apply it when the
                    // app next produces audio (handled by reapplySavedRoutes).
                    AudioRouter.shared.removeRoute(forKey: key)
                } else if let message = AudioRouter.shared.route(process: process, toDeviceUID: deviceUID) {
                    lastError = message
                    return
                }
                assignments[key] = deviceUID
                assignmentNames[key] = process.displayName
            } else {
                AudioRouter.shared.removeRoute(forKey: key)
                assignments.removeValue(forKey: key)
                assignmentNames.removeValue(forKey: key)
            }
            lastError = nil
            persistAssignments()
            refresh()
        }
    }

    func clearAll() {
        if #available(macOS 14.4, *) { AudioRouter.shared.removeAll() }
        assignments.removeAll()
        assignmentNames.removeAll()
        persistAssignments()
        refresh()
    }

    private func persistAssignments() {
        defaults.set(assignments, forKey: Keys.assignments)
        defaults.set(assignmentNames, forKey: Keys.assignmentNames)
    }

    /// On launch (and when apps reappear), restore routes for known apps.
    private func reapplySavedRoutes() {
        guard routingSupported, !assignments.isEmpty else { return }
        if #available(macOS 14.4, *) {
            let live = AudioProcesses.all(includeAll: true)
            for proc in live {
                guard let deviceUID = assignments[proc.routingKey],
                      AudioRouter.shared.activeDeviceUID(forKey: proc.routingKey) == nil,
                      AudioDevices.device(withUID: deviceUID) != nil else { continue }
                _ = AudioRouter.shared.route(process: proc, toDeviceUID: deviceUID)
            }
        }
    }

    // MARK: - Observation

    private func startObserving() {
        // Re-enumerate when devices or audio processes change, and periodically
        // so newly-launched apps appear and saved routes get re-applied.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                self.pruneDeadRoutes()
                if self.reapplyAutomatically { self.reapplySavedRoutes() }
            }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, DispatchQueue.main, listener)
        }
        if #available(macOS 14.0, *) {
            var address = CA.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, DispatchQueue.main, listener)
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.pruneDeadRoutes()
                if self.reapplyAutomatically { self.reapplySavedRoutes() }
            }
        }
    }

    /// Tears down routes whose destination device has gone away.
    private func pruneDeadRoutes() {
        guard routingSupported else { return }
        if #available(macOS 14.4, *) {
            AudioRouter.shared.dropRoutes(whereDeviceMissing: Set(devices.map(\.uid)))
        }
    }

    // MARK: - Launch at login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
        } catch {
            lastError = "Could not update Login Item: \(error.localizedDescription)"
        }
    }
}
