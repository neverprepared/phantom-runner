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

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }

    /// Auto-open Settings on first launch (no key yet) so the user lands
    /// directly on the Pair screen; otherwise auto-start the runner.
    @MainActor
    private func firstLaunchSetup() async {
        if !KeychainStore.hasAPIKey() {
            // Open Settings → Credentials. The user can click Pair…
            let selectorName: String
            if #available(macOS 14, *) {
                selectorName = "showSettingsWindow:"
            } else {
                selectorName = "showPreferencesWindow:"
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector((selectorName)), to: nil, from: nil)
            return
        }
        await state.startRunnerIfConfigured()
    }
}
