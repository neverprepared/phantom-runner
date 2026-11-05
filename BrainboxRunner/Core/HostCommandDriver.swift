import Foundation
import OSLog

/// Runs a command on THIS machine's host, outside any container.
///
/// The third execution locale for scheduled work. The other two already exist:
/// a portable command runs in a container on the platform (`run_profile_command`
/// there), and a dashboard-widget job runs inside the desktop app. Neither can
/// run work that is bound to a specific Mac — Homebrew binaries, macOS
/// frameworks like EventKit, OAuth token files in the user's home — which is
/// what this is for.
///
/// Crucially this runner is a launchd/menu-bar process independent of the
/// desktop app, so a schedule dispatched here survives the app being closed or
/// restarted. That, not surviving the machine, is the actual requirement for
/// host-bound work: a job needing *this* Mac cannot run anywhere else.
///
/// **Never takes a shell string.** `argv` is a fixed array, matching the
/// posture of every other handler here (`platform.action` validates against a
/// regex, `db.list` hardcodes its SQL, and `session.exec` only accepts a wire
/// command because it runs inside a container). A wire-sourced host shell
/// string would be the first in this system, and `argv` costs nothing: an
/// environment is passed as a map rather than smuggled through `VAR=x cmd`.
enum HostCommandDriver {
    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner",
                                   category: "hostcmd")

    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        /// True when the output hit the cap and was truncated.
        let truncated: Bool
        /// True when the watchdog killed the process.
        let timedOut: Bool
    }

    enum HostCommandError: Error, CustomStringConvertible {
        case emptyArgv
        case notExecutable(String)
        case launchFailed(String)

        var description: String {
            switch self {
            case .emptyArgv:
                return "argv is empty"
            case .notExecutable(let p):
                return "not an executable file: \(p)"
            case .launchFailed(let m):
                return "could not launch: \(m)"
            }
        }
    }

    /// Default cap per stream. Nothing downstream truncates — the fleet imposes
    /// no payload limit at all — so the cap has to live here, at the source.
    static let defaultOutputCap = 16_384

    /// One-way boolean across queues, for the same async-locking reason as Sink.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Bounded, thread-safe accumulation of one stream.
    ///
    /// A plain class rather than inline locking because NSLock's lock()/unlock()
    /// are unavailable from an async context (a hard error under Swift 6), and
    /// the readability handlers fire on an arbitrary queue while the awaiting
    /// side needs to read the result afterwards.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var didTruncate = false
        private let cap: Int

        init(cap: Int) { self.cap = cap }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard data.count < cap else { didTruncate = true; return }
            data.append(chunk.prefix(cap - data.count))
            if data.count >= cap, chunk.count > cap - data.count { didTruncate = true }
        }

        func snapshot() -> (Data, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, didTruncate)
        }
    }

    /// Execute `argv` on this host.
    ///
    /// - Parameters:
    ///   - argv: executable followed by its arguments. Resolved through
    ///     `/usr/bin/env` when the first element is not an absolute path, so a
    ///     bare `uv` still finds Homebrew via the supplied PATH.
    ///   - env: the complete environment. Replaces rather than extends the
    ///     runner's own, so a command cannot inherit the runner's secrets by
    ///     accident.
    ///   - cwd: working directory, or nil for the user's home.
    ///   - timeout: seconds before the process is terminated.
    ///   - outputCap: bytes retained per stream.
    static func run(
        argv: [String],
        env: [String: String],
        cwd: String?,
        timeout: TimeInterval,
        outputCap: Int = defaultOutputCap
    ) async throws -> Output {
        guard let first = argv.first, !first.isEmpty else { throw HostCommandError.emptyArgv }

        let proc = Process()
        if first.hasPrefix("/") {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: first, isDirectory: &isDir),
                  !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: first) else {
                throw HostCommandError.notExecutable(first)
            }
            proc.executableURL = URL(fileURLWithPath: first)
            proc.arguments = Array(argv.dropFirst())
        } else {
            // `env` performs PATH resolution using the environment we set, which
            // is what lets a relative `uv` resolve to /opt/homebrew/bin/uv.
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = argv
        }
        proc.environment = env
        proc.currentDirectoryURL = URL(
            fileURLWithPath: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            isDirectory: true
        )

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Explicitly closed: a child inheriting the runner's stdin can block
        // forever waiting for input nobody will send.
        proc.standardInput = FileHandle.nullDevice

        // Drain BOTH pipes concurrently with the process running. Reading only
        // after waitUntilExit (as SSHDriver does) deadlocks as soon as a child
        // writes more than the pipe buffer holds — fine for an ssh one-liner,
        // not for a collector emitting a JSON array.
        let outSink = Sink(cap: outputCap)
        let errSink = Sink(cap: outputCap)
        for (pipe, sink) in [(outPipe, outSink), (errPipe, errSink)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                sink.append(chunk)
            }
        }

        do {
            try proc.run()
        } catch {
            throw HostCommandError.launchFailed("\(error)")
        }
        log.debug("host exec \(argv.first ?? "?", privacy: .public) (\(argv.count) args)")

        // SIGTERM at the deadline, then SIGKILL if it ignores that — a process
        // that traps SIGTERM would otherwise hold the work slot open forever.
        let killedFlag = Flag()
        let watchdog = DispatchWorkItem {
            guard proc.isRunning else { return }
            killedFlag.set()
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }
        watchdog.cancel()

        // Collect whatever the handlers had not picked up before exit.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outSink.append(outPipe.fileHandleForReading.availableData)
        errSink.append(errPipe.fileHandleForReading.availableData)
        let (finalOut, outTruncated) = outSink.snapshot()
        let (finalErr, errTruncated) = errSink.snapshot()

        return Output(
            stdout: Self.text(finalOut),
            stderr: Self.text(finalErr),
            exitCode: proc.terminationStatus,
            truncated: outTruncated || errTruncated,
            timedOut: killedFlag.value
        )
    }

    /// Lossy on purpose: a collector emitting a stray non-UTF8 byte should not
    /// turn its whole output into nil.
    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
