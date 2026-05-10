import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

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

            Button("Settings…") { openSettings() }
                .keyboardShortcut(",")

            Button("Quit Runner") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
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

    private func openSettings() {
        let selectorName: String
        if #available(macOS 14, *) {
            selectorName = "showSettingsWindow:"
        } else {
            selectorName = "showPreferencesWindow:"
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector((selectorName)), to: nil, from: nil)
    }
}
