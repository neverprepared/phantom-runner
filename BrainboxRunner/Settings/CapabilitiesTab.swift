import SwiftUI

struct CapabilitiesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Advertised to API") {
                Toggle("docker (containers)", isOn: $state.settings.dockerEnabled)
                Toggle("utm (virtual machines)", isOn: $state.settings.utmEnabled)
            }

            Section {
                Stepper(
                    "Max concurrent sessions: \(state.settings.maxConcurrent)",
                    value: $state.settings.maxConcurrent,
                    in: 1...8
                )
            } footer: {
                Text("R2 default is 1 (serial). Higher values land with the concurrency rework.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding()
    }
}
