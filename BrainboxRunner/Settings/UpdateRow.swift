import SwiftUI

struct UpdateRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            statusLabel
            Spacer()
            actionButton
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state.updater.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let version, _, _):
            Label("Update available: v\(version)", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Downloading…").foregroundStyle(.secondary)
            }
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state.updater.state {
        case .idle, .upToDate, .error:
            Button("Check Now") {
                Task { await state.updater.check() }
            }
        case .available(_, let assetID, _):
            Button("Install & Restart") {
                Task { await state.updater.installAndRestart(assetID: assetID) }
            }
            .buttonStyle(.borderedProminent)
        case .checking, .downloading:
            EmptyView()
        }
    }
}
