import SwiftUI

/// The popover shown when the user clicks the menu-bar icon.
struct MenuView: View {
    @ObservedObject var state = AppState.shared
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private let systemDefaultTag = "__system_default__"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if !state.routingSupported {
                unsupportedNotice
            } else if state.processes.isEmpty {
                emptyNotice
            } else {
                appList
            }

            if let error = state.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
            Text("MacHole")
                .font(.headline)
            Spacer()
            Button {
                state.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh app and device list")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var appList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(state.processes) { process in
                    AppRow(
                        process: process,
                        devices: state.devices,
                        defaultName: state.defaultDevice?.name,
                        selection: binding(for: process),
                        systemDefaultTag: systemDefaultTag
                    )
                    if process.id != state.processes.last?.id {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .frame(maxHeight: 360)
    }

    private var emptyNotice: some View {
        VStack(spacing: 6) {
            Text("No audio apps found")
                .font(.subheadline)
            Text("Open an app that plays sound, then refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 14)
    }

    private var unsupportedNotice: some View {
        VStack(spacing: 6) {
            Text("Unsupported macOS version")
                .font(.subheadline)
            Text("Per-app audio routing needs macOS 14.4 or later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 14)
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: onOpenSettings)
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Binding

    private func binding(for process: AppProcessAlias) -> Binding<String> {
        Binding(
            get: { state.assignedDeviceUID(for: process) ?? systemDefaultTag },
            set: { newValue in
                state.assign(process, toDeviceUID: newValue == systemDefaultTag ? nil : newValue)
            }
        )
    }
}

/// Type alias kept local so the row view reads clearly.
private typealias AppProcessAlias = AudioProcess

/// A single app row: icon, name, and an output-device picker.
private struct AppRow: View {
    let process: AudioProcess
    let devices: [AudioDevice]
    let defaultName: String?
    @Binding var selection: String
    let systemDefaultTag: String

    private var isRunning: Bool { !process.audioObjectIDs.isEmpty || process.isPlaying }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .opacity(isRunning ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if process.isPlaying {
                    Text("Playing")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if !isRunning {
                    Text("Not running · routed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Picker("", selection: $selection) {
                Text(defaultName.map { "Default (\($0))" } ?? "System Default")
                    .tag(systemDefaultTag)
                if !devices.isEmpty { Divider() }
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var icon: some View {
        Group {
            if let nsImage = process.icon {
                Image(nsImage: nsImage).resizable()
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .frame(width: 24, height: 24)
    }
}
