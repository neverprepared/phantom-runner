import SwiftUI

struct APITab: View {
    @EnvironmentObject var state: AppState
    @State private var newTag = ""

    var body: some View {
        Form {
            Section {
                TextField("API URL", text: $state.settings.apiURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                TextField("Runner name", text: $state.settings.runnerName)
                    .textFieldStyle(.roundedBorder)
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
                // Test-connection is wired in R3; the button is here so the
                // layout is final and the muscle memory works.
                Button("Test connection") { /* R3 */ }
                    .disabled(true)
            }
        }
        .padding()
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !state.settings.tags.contains(trimmed) else { return }
        state.settings.tags.append(trimmed)
        newTag = ""
    }
}
