import SwiftUI
import ServiceManagement

struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let err = launchAtLoginError {
                    Text(err).foregroundColor(.red).font(.caption)
                }
            }
            Section("Logging") {
                Toggle("Verbose log output", isOn: $state.settings.logVerbose)
                Text("Logs to OSLog under com.neverprepared.brainbox-runner — view with the Console app or `log stream`.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "unknown")
            }
        }
        .padding()
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.settings.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    state.settings.launchAtLogin = newValue
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = "\(error.localizedDescription)"
                }
            }
        )
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
