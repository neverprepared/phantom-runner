import SwiftUI

struct CredentialsTab: View {
    @EnvironmentObject var state: AppState
    @State private var apiKey: String = ""
    @State private var saved: Bool = false
    @State private var saveError: String?
    @State private var showingPairing: Bool = false

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
                Button("Pair with a brainbox API…") { showingPairing = true }
                Text("Easier than pasting a 64-char key. The Wails app's Pair-a-Runner screen generates a one-time token; paste it here and the runner pulls its API URL + key over a single round-trip.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPairing) {
            PairingSheet().environmentObject(state)
        }
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
