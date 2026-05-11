import Foundation
import SwiftUI

/// Connection / work status surfaced to the menu bar and Settings.
enum RunnerStatus: String, Codable {
    case disconnected
    case connected
    case busy
    case paused

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connected:    return "Connected · Idle"
        case .busy:         return "Busy"
        case .paused:       return "Paused"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: return "circle.slash"
        case .connected:    return "circle.fill"
        case .busy:         return "circle.dotted"
        case .paused:       return "pause.circle"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: RunnerStatus = .disconnected
    @Published var lastError: String?
    @Published var settings: SettingsStore
    /// Set to true to request the settings window be opened. MenuBarView
    /// observes this and calls openWindow; it resets the flag to false.
    @Published var shouldOpenSettings: Bool = false
    private(set) lazy var runner: RunnerCore = RunnerCore(owner: self)

    init() {
        self.settings = SettingsStore()
    }

    /// Called once from the App's onAppear after Keychain is reachable.
    func startRunnerIfConfigured() async {
        guard !settings.apiURL.isEmpty, KeychainStore.hasAPIKey() else { return }
        await runner.start()
    }

    /// Called when the user saves new URL / name / capabilities — restart so
    /// the registration picks up the change.
    func reloadRunner() async {
        await runner.restart()
    }
}
