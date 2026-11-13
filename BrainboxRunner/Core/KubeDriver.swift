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
                handle.value.write(stdin)
                try? handle.value.close()
            }
        }

        // Drain stdout/stderr on detached tasks and take the exit status from
        // the callback registered above, rather than blocking this task.
        // `waitUntilExit()` and a synchronous `readDataToEndOfFile()` both
        // park whatever thread calls them for the lifetime of the kubectl
        // invocation; since `run()` is `async`, that thread is one of the
        // Swift concurrency cooperative pool's bounded set, so several
        // concurrent `run()` calls could starve it. `async let` frees the
        // calling task's thread back to the pool while these await.
        //
        // The two reads still run CONCURRENTLY — the deviation from the
        // brief. Reading them sequentially deadlocks once the child writes
        // more than the ~64KB pipe buffer to the stream read second: the
        // parent blocks reading the first pipe while the child blocks
        // writing the other (`kubectl get -o json` over a populated
        // namespace routinely exceeds 64KB on stderr).
        let outHandle = KubeUnchecked(stdoutPipe.fileHandleForReading)
        let errHandle = KubeUnchecked(stderrPipe.fileHandleForReading)
        async let exitCode: Int32 = termination.exitStatus()
        async let outData = Task.detached { outHandle.value.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.value.readDataToEndOfFile() }.value

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
}


/// Carries a non-`Sendable` Foundation value across a task or queue boundary.
///
/// Sound for every use in `KubeDriver.run()` because each boxed `FileHandle`
/// is handed to exactly one task, which is the only thing that ever touches
/// it: the stdin writer owns the write end until it closes it, and each drain
/// task owns one read end until EOF. No handle is shared between the boxes,
/// and the parent never touches a handle after boxing it.
struct KubeUnchecked<T>: @unchecked Sendable {
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
