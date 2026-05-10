import SwiftUI

@main
struct BrainboxRunnerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .task { await state.startRunnerIfConfigured() }
        } label: {
            Image(systemName: state.status.systemImage)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
