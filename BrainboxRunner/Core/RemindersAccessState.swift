import Foundation

/// Reminders (EventKit) access for the runner itself.
///
/// WHY THIS LIVES IN THE APP AND NOT IN THE TOOL THAT NEEDS IT: a macOS TCC
/// grant attaches to the RESPONSIBLE PROCESS — the top-level app of the
/// subprocess chain — not to the binary making the request. The Drive inbox
/// reaches Reminders through `macos-mcp`, several levels down
/// (BrainboxRunner → sh → uv → python → macos-mcp), so the grant that matters
/// is BrainboxRunner's.
///
/// Measured on m3 on 2026-11-05, same machine and same binary, varying only the
/// responsible process:
///
///     Terminal.app launches the chain       → reminder lists visible
///     BrainboxRunner.app launches the chain → "No reminder lists found."
///     plain SSH launches the chain          → empty (sshd cannot show a dialog)
///
/// Priming the grant from a terminal — which the inbox README used to advise —
/// therefore grants Terminal and does nothing for scheduled work. And a request
/// originating deep in the chain is not promptable: firing it through the runner
/// produced NO dialog at all, silently denied. So the app has to ask in its own
/// process, which is what this type exists to do.
///
/// The failure is also invisible without help: EventKit returns EMPTY
/// COLLECTIONS under denial rather than erroring, and `macos-mcp` logs
/// "EventKit permissions granted" regardless. That is why `current()` is
/// surfaced in the UI — a denial should be readable at a glance instead of
/// presenting as "the inbox found nothing".
///
/// SPLIT ON PURPOSE: this file is Foundation-only so the test bundle can
/// compile it directly. The test target deliberately does not host the
/// menu-bar app (see project.yml), so anything importing EventKit or AppKit is
/// untestable there — and the parts worth testing are exactly the ones here:
/// the status mapping, and the tccutil argv where a mistake is destructive.
/// The EventKit side lives in RemindersAccess+EventKit.swift.
enum RemindersAccess {

    /// What TCC currently thinks, in terms this app can act on.
    enum State: Equatable {
        case notDetermined
        case restricted
        case denied
        /// macOS 14+: may add but not read. Enough to file a reminder, not to
        /// confirm the target list exists — which the inbox does check.
        case writeOnly
        case granted
        /// A status this build does not know about: report it rather than
        /// guessing, so a future OS adding a case does not read as "denied".
        case unknown(Int)

        var label: String {
            switch self {
            case .notDetermined: return "not requested yet"
            case .restricted:    return "restricted by policy"
            case .denied:        return "denied"
            case .writeOnly:     return "write-only"
            case .granted:       return "granted"
            case .unknown(let raw): return "unknown (status \(raw))"
            }
        }

        /// True only for full access. Write-only is deliberately NOT granted
        /// here: the inbox verifies the list it wrote to, which needs a read.
        var isGranted: Bool { self == .granted }

        /// Whether asking again can plausibly change anything. A denial cannot
        /// be re-prompted — macOS only shows the dialog once — so the UI has to
        /// offer a reset instead of a second request that would silently no-op.
        var isRequestable: Bool { self == .notDetermined }
    }

    /// Mapped from the raw value rather than the enum cases on purpose: the
    /// EventKit cases are split across OS versions (`.authorized` on 13,
    /// `.fullAccess`/`.writeOnly` on 14+), and a raw mapping is both
    /// version-agnostic and testable without an EKEventStore — which cannot be
    /// constructed meaningfully in a headless test.
    static func state(fromRawValue raw: Int) -> State {
        switch raw {
        case 0: return .notDetermined
        case 1: return .restricted
        case 2: return .denied
        case 3: return .granted      // .authorized (<=13) / .fullAccess (14+)
        case 4: return .writeOnly    // 14+
        default: return .unknown(raw)
        }
    }

    // MARK: - Reset

    enum ResetError: Error, Equatable {
        case missingBundleIdentifier
        case failed(status: Int32, output: String)
    }

    /// `tccutil` argv for clearing THIS app's Reminders grant.
    ///
    /// No API can revoke an app's own TCC grant, so a reset means shelling out.
    /// The bundle identifier is REQUIRED and validated: a bare
    /// `tccutil reset Reminders` resets the grant for EVERY app on the machine,
    /// which would be an appalling thing to do from a button labelled "reset".
    ///
    /// Returned as argv, never a shell string — the same rule the host-command
    /// path follows, so nothing here is ever interpreted by a shell.
    static func resetArgv(bundleIdentifier: String) throws -> [String] {
        let id = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ResetError.missingBundleIdentifier }
        return ["reset", "Reminders", id]
    }

}
