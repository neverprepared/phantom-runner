import SwiftUI

@main
struct BrainboxRunnerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .task { await firstLaunchSetup() }
        } label: {
            Image(systemName: state.status.systemImage)
        }
        .menuBarExtraStyle(.menu)

        // Window (not Settings scene): in LSUIElement / menu-bar apps the
        // Settings selector dance (showSettingsWindow:/showPreferencesWindow:)
        // is unreliable on macOS 13. A regular Window + openWindow(id:) is
        // the durable pattern.
        Window("Brainbox Runner", id: "settings") {
            SettingsView()
                .environmentObject(state)
                .frame(minWidth: 520, minHeight: 380)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// On first launch with no Keychain key, flag the settings window
    /// to open. MenuBarView watches this and uses @Environment(\.openWindow)
    /// from inside the view tree, which is the only context where SwiftUI
    /// reliably routes window opens for LSUIElement / menu-bar apps.
    @MainActor
    private func firstLaunchSetup() async {
        if !KeychainStore.hasAPIKey() {
            state.shouldOpenSettings = true
            return
        }
        await state.startRunnerIfConfigured()
    }
}
