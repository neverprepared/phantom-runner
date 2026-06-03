import SwiftUI

struct APITab: View {
    @EnvironmentObject var state: AppState
    @State private var newTag = ""
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var hostText: String = ""

    private enum TestResult { case success, failure(String) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: state.status.systemImage)
                        .foregroundColor(statusColor)
                    Text(state.status.label).bold()
                    Spacer()
                }
                if state.status == .disconnected, let err = state.lastError, !err.isEmpty {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                        .lineLimit(3)
                }
            }
            Section {
                TextField("API URL", text: $state.settings.apiURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                if isUnroutableURL(state.settings.apiURL) {
                    Label("URL contains an unroutable host (0.0.0.0 or localhost). Update to the LAN IP of the API server.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                TextField("Runner name", text: $state.settings.runnerName)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    TextField(
                        SettingsStore.detectLANIP() ?? "e.g. 192.168.1.42",
                        text: $hostText
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .onChange(of: hostText) { _ in state.settings.runnerHost = hostText }
                    .onAppear { hostText = state.settings.runnerHost }
                    Button("LAN") {
                        if let ip = SettingsStore.detectLANIP() {
                            hostText = ip
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let tsIP = SettingsStore.detectTailscaleIP() {
                        Button("Tailscale") {
                            hostText = tsIP
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.blue)
                    }
                }
                Text("IP this Mac is reachable at from the API server. Used to build the correct ttyd URL for remote sessions. Same-host setups can leave this blank.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Tags") {
                ForEach(state.settings.tags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Button(role: .destructive) {
                            state.settings.tags.removeAll { $0 == tag }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                HStack {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if testing { ProgressView().controlSize(.small) }
                        else { Text("Test connection") }
                    }
                    .disabled(testing || state.settings.apiURL.isEmpty)

                    switch testResult {
                    case .success:
                        Label("OK", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.octagon.fill")
                            .foregroundColor(.red)
                            .lineLimit(2)
                    case .none:
                        EmptyView()
                    }
                }

                Button("Apply & restart runner") {
                    Task { await state.reloadRunner() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func runTest() async {
        testing = true
        testResult = nil
        switch await state.runner.testConnection() {
        case .success:
            testResult = .success
        case .failure(let e):
            testResult = .failure(e.description)
        }
        testing = false
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !state.settings.tags.contains(trimmed) else { return }
        state.settings.tags.append(trimmed)
        newTag = ""
    }

    private func isUnroutableURL(_ raw: String) -> Bool {
        guard let host = URLComponents(string: raw)?.host else { return false }
        return host == "0.0.0.0" || host == "127.0.0.1" || host == "localhost"
    }

    private var statusColor: Color {
        switch state.status {
        case .disconnected: return .red
        case .connected:    return .green
        case .busy:         return .yellow
        case .paused:       return .secondary
        }
    }
}
