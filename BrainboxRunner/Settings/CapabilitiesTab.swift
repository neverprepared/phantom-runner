import SwiftUI

struct CapabilitiesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("docker (containers)", isOn: $state.settings.dockerEnabled)
                Toggle("utm (virtual machines)", isOn: $state.settings.utmEnabled)
                Toggle("ollama (local LLM inference)", isOn: $state.settings.ollamaEnabled)
            } header: {
                Text("Compute capabilities")
            } footer: {
                Text("Enabled capabilities are advertised at registration so the API knows what work this agent can pick up. Ollama is only advertised when it is reachable on this machine's LAN IP — set OLLAMA_HOST=0.0.0.0 before starting Ollama.")
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
