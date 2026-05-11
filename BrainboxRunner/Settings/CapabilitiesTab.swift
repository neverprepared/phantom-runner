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
                Toggle("This Mac holds my credentials (secret authority)",
                       isOn: $state.settings.secretAuthorityEnabled)
            } header: {
                Text("Credential authority")
            } footer: {
                Text("Enable on the laptop where your plaintext credentials live. The agent registers the secret_authority capability so the API knows where to route credential-sealing requests. Active sealing lands in the next release — for now this just advertises.")
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
