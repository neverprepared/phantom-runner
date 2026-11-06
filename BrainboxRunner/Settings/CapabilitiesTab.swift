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

/// Reminders (EventKit) grant for THIS app.
///
/// Shown next to host commands because that is the capability it gates: the
/// Drive inbox files reminders through macos-mcp, and a macOS TCC grant
/// attaches to the responsible process — this app — not to the tool making the
/// request. See Core/RemindersAccess.swift for the measurements.
///
/// The STATUS LINE is the point as much as the buttons are. A denial is
/// otherwise invisible: EventKit returns empty collections rather than
/// erroring, so the symptom is "the inbox found nothing" rather than anything
/// resembling a permission problem. It cost most of a day to identify once.
private struct RemindersAccessRow: View {
    @State private var status: RemindersAccess.State = RemindersAccess.current()
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reminders access")
                Spacer()
                Text(status.label)
                    .font(.callout.monospaced())
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                // Only offered from notDetermined: macOS shows the dialog once,
                // so after a denial this would silently no-op — a dead button
                // being exactly the failure mode this whole feature exists to
                // remove.
                if status.isRequestable {
                    Button("Request access") { Task { await request() } }
                        .disabled(busy)
                }
                // Always available, including when granted: re-requesting is how
                // you recover a wrong answer, and the only route is a reset.
                Button(status.isRequestable ? "Reset" : "Reset & re-request") {
                    Task { await resetThenRequest() }
                }
                .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        // Re-read on appear: the grant can change in System Settings while this
        // window is open, and a stale "denied" would send someone chasing a
        // problem they already fixed.
        .onAppear { status = RemindersAccess.current() }
    }

    private var tint: Color {
        switch status {
        case .granted: return .green
        case .notDetermined: return .secondary
        default: return .orange
        }
    }

    private func request() async {
        busy = true
        problem = nil
        status = await RemindersAccess.request()
        if status == .denied {
            problem = "Denied. macOS will not ask again — use Reset & re-request, "
                + "or enable Brainbox Runner under Privacy & Security › Reminders."
        }
        busy = false
    }

    private func resetThenRequest() async {
        busy = true
        problem = nil
        do {
            try RemindersAccess.reset()
            status = RemindersAccess.current()
        } catch {
            problem = "Reset failed: \(error)"
            busy = false
            return
        }
        busy = false
        await request()
    }
}

struct CapabilitiesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("docker (containers)", isOn: $state.settings.dockerEnabled)
                Toggle("utm (virtual machines)", isOn: $state.settings.utmEnabled)
                Toggle("host commands (scheduled work on this Mac)", isOn: $state.settings.hostExecEnabled)
                Toggle("ollama (local LLM inference)", isOn: $state.settings.ollamaEnabled)
                if state.settings.hostExecEnabled {
                    RemindersAccessRow()
                }
                if state.settings.ollamaEnabled {
                    OllamaProxyStatusRow(proxy: state.ollamaProxy)
                }
            } header: {
                Text("Compute capabilities")
            } footer: {
                Text("Enabled capabilities are advertised at registration so the API knows what work this agent can pick up. Host commands run OUTSIDE any container, as you, with this profile's environment — enable it only for scheduled work that genuinely needs this Mac (Homebrew tools, Reminders, Drive credentials). Ollama is fronted by a local HTTPS proxy (port 11435) authenticated with the runner's API key — no need to bind Ollama to 0.0.0.0. Reminders access is granted to THIS APP, not to the tool that uses it: macOS attaches the permission to the launching process, so priming it from a terminal grants the terminal and does nothing for scheduled work.")
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
