import EventKit
import Foundation
import OSLog

#if canImport(AppKit)
import AppKit
#endif

/// EventKit side of `RemindersAccess`. The Foundation-only half — the
/// status mapping and the tccutil argv — lives in RemindersAccessState.swift
/// so the test bundle can compile it without EventKit.
///
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
extension RemindersAccess {

    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner",
                                    category: "reminders-access")

    static func current() -> State {
        state(fromRawValue: EKEventStore.authorizationStatus(for: .reminder).rawValue)
    }

    /// Ask macOS for access, from THIS process, so the prompt is attributable.
    ///
    /// Activates the app first because the runner is `LSUIElement: true` — no
    /// dock icon and no activation — so the dialog can otherwise appear behind
    /// whatever is in front. That is a likely reason a prompt was never noticed
    /// on a machine nobody is looking at.
    @discardableResult
    static func request() async -> State {
        #if canImport(AppKit)
        await MainActor.run { NSApp?.activate(ignoringOtherApps: true) }
        #endif

        let store = EKEventStore()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // The completion-handler form on both paths rather than the async
            // overload: it exists identically on 13 and 14+, so there is one
            // code path and no bridging surprises.
            // @Sendable: EventKit's completion parameter is @Sendable, and a
            // plain local closure converts with a data-race warning that becomes
            // an error under Swift 6. Everything captured here (the continuation
            // and the Logger) is already Sendable.
            let done: @Sendable (Bool, Error?) -> Void = { granted, err in
                if let err { log.error("reminders request failed: \(err.localizedDescription)") }
                log.info("reminders request returned granted=\(granted)")
                cont.resume()
            }
            if #available(macOS 14.0, *) {
                store.requestFullAccessToReminders(completion: done)
            } else {
                store.requestAccess(to: .reminder, completion: done)
            }
        }

        // Deliberately re-read the status rather than trusting the callback's
        // Bool: on 14+ a write-only grant reports granted=true, which is not
        // the access the inbox needs.
        let after = current()
        log.info("reminders access now \(after.label, privacy: .public)")
        return after
    }

    /// Clear this app's grant so the next `request()` prompts again.
    ///
    /// After a reset the status returns to `notDetermined`, which is the only
    /// state macOS will show a dialog for — hence "reset and re-request" rather
    /// than a bare retry, which would silently do nothing once denied.
    static func reset(bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        let argv = try resetArgv(bundleIdentifier: bundleIdentifier ?? "")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = argv
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard proc.terminationStatus == 0 else {
            log.error("tccutil reset failed (\(proc.terminationStatus)): \(out, privacy: .public)")
            throw ResetError.failed(status: proc.terminationStatus, output: out)
        }
        log.info("reminders grant reset; status now \(current().label, privacy: .public)")
    }
}
