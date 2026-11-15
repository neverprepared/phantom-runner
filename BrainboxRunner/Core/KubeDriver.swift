import Foundation
import OSLog

/// Thin shell-out to the `kubectl` CLI, mirroring DockerDriver. The runner
/// links no Kubernetes client — `kubectl` is all we need, and keeping this
/// Foundation-only is what makes it testable without hosting the menu-bar app.
struct KubeDriver {
    private static let log = Logger(
        subsystem: "com.neverprepared.brainbox-runner", category: "kube")

    enum KubeError: Error, CustomStringConvertible {
        case binaryNotFound
        case exit(code: Int32, stderr: String, cmd: [String])

        var description: String {
            switch self {
            case .binaryNotFound:
                return "`kubectl` not on PATH"
            case .exit(let c, let e, let cmd):
                // Redact BEFORE truncating — clipping first can strand half a
                // live token. Same rule as DockerDriver.
                let cmdText = Redact.argv(cmd)
                let stderrText = Redact.text(e).prefix(300)
                return "kubectl \(cmdText) exit \(c): \(stderrText)"
            }
        }
    }

    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Directories where `kubectl` is commonly installed, most-preferred
    /// first. The runner is a GUI login-item with the bare launchd PATH, so it
    /// CANNOT rely on the shell PATH — resolve by absolute path.
    static func kubectlCLIDirs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",             // Homebrew (kubectl, k3d)
            "/usr/local/bin",                // Intel Homebrew / manual install
            "\(home)/.rd/bin",               // Rancher Desktop
            "\(home)/.orbstack/bin",         // OrbStack-provided kubectl
        ]
    }

    static func kubectlBinary() -> URL? {
        // An explicit override wins: it makes the driver testable with a fake
        // kubectl, and lets an operator pin an unusual per-host location
        // without a new release.
        if let override = ProcessInfo.processInfo.environment["PHANTOM_KUBECTL"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for dir in kubectlCLIDirs() {
            let path = dir + "/kubectl"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    @discardableResult
    static func run(
        _ args: [String],
        stdin: Data? = nil,
        expectSuccess: Bool
    ) async throws -> Output {
        guard let bin = kubectlBinary() else { throw KubeError.binaryNotFound }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (kubectlCLIDirs() + [basePath]).joined(separator: ":")
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var stdinHandle: FileHandle?
        if stdin != nil {
            let stdinPipe = Pipe()
            proc.standardInput = stdinPipe
            stdinHandle = stdinPipe.fileHandleForWriting
        } else {
            // Without this, `proc.standardInput` is left unset and the child
            // INHERITS the host process's real stdin. For a GUI login item
            // that is whatever fd launchd handed the app, and it never
            // closes — a `kubectl` invocation with no stdin (e.g. `get`)
            // that reads stdin for any reason would hang forever rather than
            // seeing EOF.
            proc.standardInput = FileHandle.nullDevice
        }

        log.debug("kubectl \(Redact.argv(args), privacy: .public)")

        // Register the termination callback BEFORE `run()`, and let the box
        // absorb either arrival order.
        //
        // Measured on macOS 27.0.1 / Swift 6.4.2, Darwin Foundation DOES
        // invoke a handler assigned after the child has already exited and
        // been reaped (checked across four orderings, including after
        // `waitUntilExit()`; it fires exactly once each time). So late
        // registration is not broken here today. It is also not documented
        // anywhere, which makes it the wrong thing to depend on for the one
        // callback that decides whether this function ever returns: if a
        // future Foundation stops back-firing, every invocation of a
        // fast-exiting `kubectl` would hang forever with no test able to see
        // it coming.
        //
        // Registering first costs nothing and removes the dependency
        // entirely. It also removes a second, real problem: assigning the
        // handler from inside an `async let` child task (the previous shape)
        // queues the assignment onto the cooperative pool, so the delay
        // before the process is even observable is bounded only by pool
        // scheduling — the same pool this whole construction is about not
        // starving.
        //
        // Registering first means termination can be reported before anyone
        // is waiting for it. `KubeProcessTermination` handles that by parking
        // the status until a continuation attaches, so both orders resume
        // exactly once.
        let termination = KubeProcessTermination()
        proc.terminationHandler = { [termination] p in
            termination.complete(p.terminationStatus)
        }

        try proc.run()

        // Write stdin AFTER run() so the child can drain the pipe; a manifest
        // larger than the ~64KB pipe buffer deadlocks otherwise.
        if let stdinHandle, let stdin {
            let handle = KubeUnchecked(stdinHandle)
            DispatchQueue.global(qos: .userInitiated).async {
                // `try?` on the THROWING variant, never `write(_:)`. The read
                // end closing under us is the ordinary case, not the exotic
                // one: `apply`/`delete` always pass stdin, and any context
                // whose cluster is stopped makes kubectl exit before reading
                // it. `FileHandle.write(_:)` reports that EPIPE as an
                // ObjC exception, which Swift cannot catch — it would
                // terminate the menu-bar app. `write(contentsOf:)` throws it
                // as a Swift error instead, and dropping it is right here:
                // the child is already gone, its exit status is on its way
                // through `termination`, and that is what the caller should
                // see rather than a write error about a doomed pipe.
                //
                // The throwing call is only half the fix — the kernel also
                // sends SIGPIPE, whose default action terminates the process
                // before any error can be returned. The app ignores SIGPIPE
                // at startup (see `BrainboxRunnerApp.init`); without that,
                // this line still dies.
                try? handle.value.write(contentsOf: stdin)
                try? handle.value.close()
            }
        }

        // Drain both pipes on libdispatch's global queue and take the exit
        // status from the callback registered above. Nothing blocking runs on
        // a Swift concurrency thread.
        //
        // `Task.detached` is NOT the way to do this: a detached task still
        // runs on the global concurrent executor, which is the same bounded
        // cooperative pool — one thread per core, and it does not grow when a
        // thread blocks. Draining there parked TWO pool threads per `run()`
        // in `readDataToEndOfFile()`, so it freed the caller's task only by
        // consuming more of the resource it was protecting. `DispatchQueue`
        // has its own pool, which does grow, and is where a blocking read
        // belongs — the same reason the stdin writer above uses it.
        //
        // The two reads still run CONCURRENTLY with each other. Reading them
        // sequentially deadlocks once the child writes more than the ~64KB
        // pipe buffer to the stream read second: the parent blocks reading
        // the first pipe while the child blocks writing the other (`kubectl
        // get -o json` over a populated namespace routinely exceeds 64KB on
        // stderr).
        async let exitCode: Int32 = termination.exitStatus()
        async let outData = drain(KubeUnchecked(stdoutPipe.fileHandleForReading))
        async let errData = drain(KubeUnchecked(stderrPipe.fileHandleForReading))

        let (stdoutData, stderrData, code) = await (outData, errData, exitCode)

        let out = Output(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: code
        )
        if expectSuccess && out.exitCode != 0 {
            throw KubeError.exit(code: out.exitCode, stderr: out.stderr, cmd: args)
        }
        return out
    }

    /// Reads one pipe to EOF on a `DispatchQueue` thread, bridged back as a
    /// suspension. The blocking read is deliberately NOT on a Swift
    /// concurrency thread — see the call site.
    ///
    /// Exactly-once holds ON THE RETURN PATH: the queue block runs once per
    /// call, and `resume` is its only statement.
    ///
    /// It does NOT hold if `readDataToEndOfFile()` RAISES. That is an ObjC
    /// exception (a bad or already-closed fd), it unwinds past `resume`, and
    /// the continuation is then abandoned. What follows depends on who is
    /// catching: with nothing installed the uncaught exception aborts the
    /// process, and anywhere it is trapped — XCTest does — `run()` awaits a
    /// continuation that will never be resumed and hangs forever. Both
    /// outcomes were observed from the sibling `write` path during the EPIPE
    /// work: abort standalone, trapped under XCTest.
    ///
    /// Left as is deliberately: the only handles passed here are the read
    /// ends of pipes this function just created and has not closed, so the
    /// raise is unreachable rather than merely unlikely. Written down
    /// because the next person to pass a handle from somewhere else needs to
    /// know this bridge has no error path.
    private static func drain(_ handle: KubeUnchecked<FileHandle>) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.value.readDataToEndOfFile())
            }
        }
    }

    // MARK: - Object operations

    /// `kubectl --context=<ctx> -n <ns> apply -f -`, manifest on STDIN.
    /// Idempotent, so a retried placement is safe — unlike `docker create`,
    /// which can leave an orphaned half-created container.
    static func apply(
        context: String, namespace: String, manifestYAML: String
    ) async throws -> Output {
        try await run(
            ["--context=\(context)", "-n", namespace, "apply", "-f", "-"],
            stdin: Data(manifestYAML.utf8),
            expectSuccess: true
        )
    }

    /// `kubectl --context=<ctx> -n <ns> get <kinds> -o json [-l <selector>]`.
    /// Non-fatal: an absent object means "not running", not an error.
    static func get(
        context: String, namespace: String, kinds: String, selector: String?
    ) async throws -> Output {
        var args = ["--context=\(context)", "-n", namespace, "get", kinds, "-o", "json"]
        if let selector, !selector.isEmpty {
            args += ["-l", selector]
        }
        return try await run(args, stdin: nil, expectSuccess: false)
    }

    /// `kubectl --context=<ctx> -n <ns> delete -f - --ignore-not-found=true`.
    /// Already-absent objects satisfy desired=off rather than failing.
    /// `kubectl --context=<ctx> -n <ns> exec <pod> -- /bin/sh -c <command>`.
    ///
    /// WHY THIS EXISTS, rather than the control plane shelling out to kubectl
    /// through `host.command`: that path runs commands with the PROFILE's
    /// environment, where `HOME` is the workspace home. kubectl then looks for
    /// `$WORKSPACE_HOME/.kube/config`, finds nothing, and reports the context
    /// missing — so every exec failed with `context "<name>" does not exist`
    /// while apply/get/delete worked fine, because those come through this
    /// driver and `run()` uses the app's real environment.
    ///
    /// `expectSuccess: false` is deliberate and is the whole point of the
    /// signature: a command that runs and exits non-zero is a RESULT the caller
    /// must see, not a driver error. Throwing would collapse "the pod said no"
    /// into "kubectl broke", which is the same conflation that turned every
    /// best-effort injection into a hard session-create failure on the other
    /// side of the wire.
    ///
    /// `--request-timeout` bounds the API request because `run()` has no
    /// timeout of its own: without it a wedged exec would hold a work item
    /// open forever. It bounds the REQUEST, not the command, so a long-running
    /// command still needs the caller to background it.
    static func exec(
        context: String, namespace: String, pod: String, command: String,
        requestTimeoutSeconds: Int = 60
    ) async throws -> Output {
        try await run(
            ["--context=\(context)", "-n", namespace,
             "--request-timeout=\(requestTimeoutSeconds)s",
             "exec", pod, "--", "/bin/sh", "-c", command],
            expectSuccess: false
        )
    }

    static func delete(
        context: String, namespace: String, manifestYAML: String
    ) async throws -> Output {
        try await run(
            ["--context=\(context)", "-n", namespace, "delete", "-f", "-",
             "--ignore-not-found=true"],
            stdin: Data(manifestYAML.utf8),
            expectSuccess: true
        )
    }
}


/// Carries a non-`Sendable` Foundation value across a task or queue boundary.
///
/// Sound for every use in `KubeDriver.run()` because each boxed `FileHandle`
/// is handed to exactly one task, which is the only thing that ever touches
/// it: the stdin writer owns the write end until it closes it, and each drain
/// task owns one read end until EOF. No handle is shared between the boxes,
/// and the parent never touches a handle after boxing it.
///
/// `fileprivate` on purpose. The soundness argument above is about THIS
/// file's four use sites, not about the type — it is generic over any `T` and
/// asserts `Sendable` unconditionally, so it would launder a real data race
/// anywhere the sole-ownership invariant does not hold. `DockerDriver` is the
/// obvious next reach and would not satisfy it. Anyone who needs this
/// elsewhere should restate the invariant for their own use sites.
fileprivate struct KubeUnchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Bridges `Process.terminationHandler` — a callback that fires at most once,
/// on a Foundation-owned queue — to a single `CheckedContinuation`, with no
/// ordering requirement between the two.
///
/// The handler must be installed before `Process.run()` (see the call site),
/// which means termination can be reported before any waiter exists. So this
/// box accepts the two events in EITHER order: whichever arrives first is
/// parked, and the second one resumes the continuation. The continuation is
/// resumed exactly once on both paths — it is cleared under the lock before
/// being resumed, and a second `complete` is ignored because `status` is
/// already set.
///
/// `@unchecked Sendable` is sound because every mutable field is read and
/// written only while `lock` is held, and the only values that escape the
/// lock are ones the holding thread has exclusive ownership of.
///
/// CONTRACT: at most ONE waiter. A second concurrent `exitStatus()` call on
/// the same box would overwrite `waiter` and leak the first continuation,
/// hanging whoever held it. `KubeDriver.run()` creates one box per
/// invocation and awaits it once, so this is not reachable today — but a box
/// shared between waiters needs a queue of continuations, not this.
final class KubeProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    /// Called from `Process.terminationHandler`, possibly before `exitStatus()`.
    func complete(_ code: Int32) {
        lock.lock()
        guard status == nil else { return lock.unlock() }
        status = code
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: code)
    }

    /// Awaits the child's exit status. Returns immediately if the process has
    /// already terminated.
    func exitStatus() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code = status {
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
