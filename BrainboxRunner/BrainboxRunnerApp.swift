import SwiftUI

@main
struct BrainboxRunnerApp: App {
    @StateObject private var state = AppState()

    init() {
        // Ignore SIGPIPE process-wide, once, before anything can write to a
        // pipe. Writing to a pipe whose read end has closed delivers SIGPIPE,
        // and its DEFAULT ACTION TERMINATES THE PROCESS — for a menu-bar app
        // that means silently vanishing from the status bar, with no crash
        // the user can act on.
        //
        // This is reachable on an ordinary failure, not an exotic one:
        // `KubeDriver.apply`/`delete` always write a manifest to kubectl's
        // stdin from a background queue, and a context whose cluster is
        // stopped makes kubectl exit before reading any of it. Ignoring the
        // signal turns that into an EPIPE error return, which the writer
        // handles (see `KubeDriver.run`).
        //
        // It belongs here rather than in the driver: it is process-wide
        // state, so setting it per-invocation would be both redundant and a
        // surprising side effect of running a command.
        signal(SIGPIPE, SIG_IGN)
    }

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
