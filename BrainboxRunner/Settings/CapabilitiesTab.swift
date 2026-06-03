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
            }

            Section {
                HStack(spacing: 8) {
                    Stepper(value: $state.settings.maxConcurrent, in: 1...15) {
                        Text("\(state.settings.maxConcurrent)")
                            .monospacedDigit()
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                    Text("Max concurrent sessions")
                }
            } header: {
                Text("Concurrency")
            } footer: {
                Text("Default is 1 (serial). Higher values allow parallel session provisioning.")
            }
        }
        .formStyle(.grouped)
    }
}
