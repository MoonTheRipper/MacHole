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
        processes = showOnlyPlaying ? all.filter(\.isPlaying) : all
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
            if let deviceUID {
                if let message = AudioRouter.shared.route(process: process, toDeviceUID: deviceUID) {
                    lastError = message
                    return
                }
                assignments[process.routingKey] = deviceUID
            } else {
                AudioRouter.shared.removeRoute(forKey: process.routingKey)
                assignments.removeValue(forKey: process.routingKey)
            }
            lastError = nil
            persistAssignments()
        }
    }

    func clearAll() {
        if #available(macOS 14.4, *) { AudioRouter.shared.removeAll() }
        assignments.removeAll()
        persistAssignments()
    }

    private func persistAssignments() {
        defaults.set(assignments, forKey: Keys.assignments)
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
                if self.reapplyAutomatically { self.reapplySavedRoutes() }
            }
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
