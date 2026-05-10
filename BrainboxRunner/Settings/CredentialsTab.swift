import SwiftUI

struct CredentialsTab: View {
    @EnvironmentObject var state: AppState
    @State private var apiKey: String = ""
    @State private var saved: Bool = false
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("API key") {
                SecureField("Paste API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save to Keychain") { saveKey() }
                        .disabled(apiKey.isEmpty)
                    if saved {
                        Label("Saved", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    }
                    if let err = saveError {
                        Text(err).foregroundColor(.red).font(.caption)
                    }
                }
                if KeychainStore.hasAPIKey() && apiKey.isEmpty {
                    Text("A key is already stored. Paste a new value above to replace it.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            Section("Pairing") {
                // R7 will hook this up — paste a pairing token (or scan QR
                // from the Wails app) and the runner fetches api_url + key.
                Button("Pair with a brainbox API…") { /* R7 */ }
                    .disabled(true)
                Text("Pairing is the easier setup path — the Wails app generates a one-time token and the runner claims it.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding()
    }

    private func saveKey() {
        saved = false
        saveError = nil
        do {
            try KeychainStore.saveAPIKey(apiKey)
            apiKey = ""
            saved = true
        } catch {
            saveError = "save failed: \(error)"
        }
    }
}
