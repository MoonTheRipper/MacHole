import SwiftUI

/// Advanced settings, shown in a standard window.
struct SettingsView: View {
    @ObservedObject var state = AppState.shared
    @State private var launchAtLogin = AppState.shared.launchesAtLogin

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch MacHole at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = newValue
                        state.setLaunchAtLogin(newValue)
                    }
                ))
                Toggle("Only show apps that are currently playing", isOn: $state.showOnlyPlaying)
                Toggle("Automatically re-apply routes when apps relaunch", isOn: $state.reapplyAutomatically)
                Toggle("Show all audio processes (advanced)", isOn: $state.showAllProcesses)
                    .help("Includes background helpers, system processes, and unnamed processes. Leave off for a clean list of real apps.")
            }

            Section("Active routes") {
                if state.assignments.isEmpty {
                    Text("No apps are being routed right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.assignments.sorted(by: { $0.key < $1.key }), id: \.key) { key, deviceUID in
                        HStack {
                            Text(appLabel(forKey: key))
                            Spacer()
                            Text(deviceLabel(forUID: deviceUID))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear all routes", role: .destructive) {
                        state.clearAll()
                    }
                }
            }

            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Requires", value: "macOS 14.4 or later")
                Link("Visit the MacHole website",
                     destination: URL(string: "https://moontheripper.github.io/MacHole/")!)
                Link("View MacHole on GitHub",
                     destination: URL(string: "https://github.com/MoonTheRipper/MacHole")!)
            } header: {
                Text("About")
            } footer: {
                Text("MacHole redirects each app's audio using native Core Audio process taps. No kernel extensions are installed.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .onAppear { launchAtLogin = state.launchesAtLogin }
    }

    private func appLabel(forKey key: String) -> String {
        if let proc = state.processes.first(where: { $0.routingKey == key }) {
            return proc.displayName
        }
        if key.hasPrefix("pid:") { return key }
        return key.split(separator: ".").last.map(String.init) ?? key
    }

    private func deviceLabel(forUID uid: String) -> String {
        state.devices.first(where: { $0.uid == uid })?.name ?? uid
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
