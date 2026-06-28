import AppKit
import Combine
import SwiftUI

@main
enum MacHoleMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar only: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        // Warm up shared state so observers and saved routes activate immediately.
        _ = AppState.shared

        // Reflect active routing in the menu-bar icon.
        AppState.shared.$assignments
            .receive(on: RunLoop.main)
            .sink { [weak self] assignments in
                self?.updateStatusIcon(active: !assignments.isEmpty)
            }
            .store(in: &cancellables)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateStatusIcon(active: !AppState.shared.assignments.isEmpty)
    }

    /// A subtle filled icon when routes are active, an outline when idle.
    private func updateStatusIcon(active: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = active ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacHole")
        image?.isTemplate = true
        button.image = image
        button.toolTip = active ? "MacHole — routing active" : "MacHole"
    }

    private func setUpPopover() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuView(
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            AppState.shared.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openSettings() {
        popover.performClose(nil)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacHole Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
