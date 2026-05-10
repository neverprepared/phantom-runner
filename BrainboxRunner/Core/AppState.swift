import Foundation
import SwiftUI

/// Connection / work status surfaced to the menu bar and Settings.
/// Networking (R3) will mutate these as registration + polling events fire.
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
    @Published var settings: SettingsStore

    init() {
        self.settings = SettingsStore()
    }
}
