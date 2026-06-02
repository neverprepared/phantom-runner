import SwiftUI

struct CapabilitiesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("docker (containers)", isOn: $state.settings.dockerEnabled)
                Toggle("utm (virtual machines)", isOn: $state.settings.utmEnabled)
            } header: {
                Text("Compute capabilities")
            } footer: {
                Text("Enabled capabilities are advertised at registration so the API knows what work this agent can pick up.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Section {
                Stepper(
                    "Max concurrent sessions: \(state.settings.maxConcurrent)",
                    value: $state.settings.maxConcurrent,
                    in: 1...8
                )
            } footer: {
                Text("Default is 1 (serial). Higher values land with the concurrency rework.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding()
    }
}
