import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text("Brainbox Runner")
                .font(.system(size: 12, weight: .semibold))

            Divider()

            Text(state.status.label)
                .foregroundColor(statusColor)

            if state.status == .disconnected, let err = state.lastError, !err.isEmpty {
                Text(err)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            if !state.settings.runnerName.isEmpty {
                Text("Runner: \(state.settings.runnerName)")
                    .foregroundColor(.secondary)
            }

            Text(capabilityLine)
                .foregroundColor(.secondary)

            Divider()

            if state.status == .disconnected {
                Button("Reconnect") {
                    Task { await state.reloadRunner() }
                }
                .keyboardShortcut("r")
            } else if state.status == .paused {
                Button("Resume") { state.runner.resume() }
                    .keyboardShortcut("p")
            } else {
                Button("Pause") { state.runner.pause() }
                    .keyboardShortcut("p")
            }

            if let url = dashboardURL {
                Button("Open dashboard") { NSWorkspace.shared.open(url) }
            }

            if !state.settings.runnerName.isEmpty {
                Button("Copy runner name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.settings.runnerName, forType: .string)
                }
            }

            Divider()

            Button("Settings…") { openSettingsWindow() }
                .keyboardShortcut(",")

            Button("Quit Runner") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        // First-launch flag: open settings automatically when set.
        // Single-arg .onChange for macOS 13 compatibility.
        .onChange(of: state.shouldOpenSettings) { shouldOpen in
            if shouldOpen {
                openSettingsWindow()
                state.shouldOpenSettings = false
            }
        }
        .task {
            // onChange doesn't fire on initial value; check once on appear.
            if state.shouldOpenSettings {
                openSettingsWindow()
                state.shouldOpenSettings = false
            }
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .disconnected: return .red
        case .connected:    return .green
        case .busy:         return .yellow
        case .paused:       return .secondary
        }
    }

    private var capabilityLine: String {
        var caps: [String] = []
        if state.settings.dockerEnabled { caps.append("docker") }
        if state.settings.utmEnabled    { caps.append("utm") }
        if caps.isEmpty { return "Capabilities: none" }
        return "Capabilities: " + caps.joined(separator: " · ")
    }

    private var dashboardURL: URL? {
        URL(string: state.settings.apiURL)
    }

    /// Opens the settings window via SwiftUI's openWindow action. LSUIElement
    /// apps default to .accessory policy which keeps windows from becoming
    /// the key window — temporarily switch to .regular so the window appears
    /// and accepts focus. Activation policy is left at .regular while
    /// settings is open; it'll flip back to .accessory next time the menu
    /// bar is the only thing visible (Apple handles this transparently when
    /// the user closes the last window).
    private func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }
}
