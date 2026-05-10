import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            Text("Brainbox Runner")
                .font(.system(size: 12, weight: .semibold))

            Divider()

            // Status block — read-only summary.
            Text(state.status.label)
                .foregroundColor(statusColor)

            if !state.settings.runnerName.isEmpty {
                Text("Runner: \(state.settings.runnerName)")
                    .foregroundColor(.secondary)
            }

            Text(capabilityLine)
                .foregroundColor(.secondary)

            Divider()

            // Controls — most are placeholders until networking lands.
            if state.status == .paused {
                Button("Resume") { state.status = .connected }
            } else {
                Button("Pause") { state.status = .paused }
                    .keyboardShortcut("p")
                    .disabled(state.status == .disconnected)
            }

            Divider()

            Button("Settings…") { openSettings() }
                .keyboardShortcut(",")

            Button("Quit Runner") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// SwiftUI's `\.openSettings` Environment value is macOS 14+; on 13 we
    /// drop down to the selector that opens the Settings scene's window.
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
}
