import SwiftUI

private struct OllamaProxyStatusRow: View {
    @ObservedObject var proxy: OllamaProxy

    var body: some View {
        HStack {
            Text("Ollama proxy")
            Spacer()
            switch proxy.state {
            case .stopped:
                Text("not running").foregroundStyle(.secondary)
            case .starting:
                Text("starting…").foregroundStyle(.secondary)
            case .running(let port):
                Text(verbatim: "https://*:\(port)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            case .error(let msg):
                Text(msg)
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }
}

struct CapabilitiesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("docker (containers)", isOn: $state.settings.dockerEnabled)
                Toggle("utm (virtual machines)", isOn: $state.settings.utmEnabled)
                Toggle("ollama (local LLM inference)", isOn: $state.settings.ollamaEnabled)
                if state.settings.ollamaEnabled {
                    OllamaProxyStatusRow(proxy: state.ollamaProxy)
                }
            } header: {
                Text("Compute capabilities")
            } footer: {
                Text("Enabled capabilities are advertised at registration so the API knows what work this agent can pick up. Ollama is fronted by a local HTTPS proxy (port 11435) authenticated with the runner's API key — no need to bind Ollama to 0.0.0.0.")
            }

            Section {
                Stepper(value: $state.settings.maxConcurrent, in: 1...15) {
                    HStack {
                        Text("Max concurrent sessions")
                        Spacer()
                        Text("\(state.settings.maxConcurrent)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
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
