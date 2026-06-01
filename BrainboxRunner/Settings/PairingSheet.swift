import SwiftUI

struct PairingSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var apiURL: String = ""
    @State private var token: String = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case claiming
        case success(name: String)
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair with a brainbox API")
                    .font(.title3).bold()
                Text("Generate a one-time token in the Wails app's “Pair a Runner” screen, then paste it below. The runner will fetch its API URL + key and start.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Form {
                Section("Claim from") {
                    TextField("https://api.example.com", text: $apiURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                    Text("Where the token was issued. The Wails app shows this on the Pair a Runner screen.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Pairing token") {
                    TextField("paste token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .onSubmit { Task { await claim() } }
                }

                switch status {
                case .idle:
                    EmptyView()
                case .claiming:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Claiming…").foregroundColor(.secondary)
                    }
                case .success(let name):
                    Label("Paired. Suggested name: \(name.isEmpty ? "(none)" : name)", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                case .error(let msg):
                    Label(msg, systemImage: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .lineLimit(3)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { Task { await claim() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClaim)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if apiURL.isEmpty {
                let stored = state.settings.apiURL
                let host = URLComponents(string: stored)?.host ?? ""
                let unroutable = host == "0.0.0.0" || host == "127.0.0.1" || host == "localhost"
                if !stored.isEmpty && !unroutable {
                    apiURL = stored
                }
            }
        }
    }

    private var canClaim: Bool {
        if case .claiming = status { return false }
        let url = apiURL.trimmingCharacters(in: .whitespaces)
        let tok = token.trimmingCharacters(in: .whitespaces)
        return URL(string: url) != nil && !tok.isEmpty
    }

    private func claim() async {
        let url = apiURL.trimmingCharacters(in: .whitespaces)
        let tok = token.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: url) else {
            status = .error("API URL is malformed")
            return
        }
        status = .claiming
        do {
            let claimed = try await PairingClient.claim(baseURL: base, token: tok)
            // Use the "Claim from" URL — the runner just proved it can reach
            // the API there. The token's api_url may have been issued with an
            // unroutable host (0.0.0.0) before the issuing side was fixed.
            state.settings.apiURL = url
            if state.settings.runnerName.isEmpty || state.settings.runnerName == Host.current().localizedName {
                if !claimed.runnerNameSuggestion.isEmpty {
                    state.settings.runnerName = claimed.runnerNameSuggestion
                }
            }
            try KeychainStore.saveAPIKey(claimed.apiKey)
            status = .success(name: claimed.runnerNameSuggestion)
            // Restart the runner with the new credentials so the menu icon
            // flips from disconnected → connected once registration succeeds.
            await state.reloadRunner()
        } catch let e as PairingClient.PairingError {
            status = .error(e.description)
        } catch {
            status = .error("\(error)")
        }
    }
}
