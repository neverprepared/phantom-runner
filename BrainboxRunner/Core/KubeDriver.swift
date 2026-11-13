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
        try proc.run()

        // Write stdin AFTER run() so the child can drain the pipe; a manifest
        // larger than the ~64KB pipe buffer deadlocks otherwise.
        if let stdinHandle, let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                stdinHandle.write(stdin)
                try? stdinHandle.close()
            }
        }

        // Wait for exit via the termination callback instead of
        // `waitUntilExit()`, and drain stdout/stderr on detached child tasks
        // instead of blocking reads on this task. `waitUntilExit()` and a
        // synchronous `readDataToEndOfFile()` both park whatever thread call
        // them for the lifetime of the kubectl invocation; since `run()` is
        // `async`, that thread is one of the Swift concurrency cooperative
        // pool's bounded set, so several concurrent `run()` calls could
        // starve it. Structured concurrency (`async let`) frees the calling
        // task's thread back to the pool while these await.
        //
        // The two reads still run CONCURRENTLY — the deviation from the
        // brief. Reading them sequentially deadlocks once the child writes
        // more than the ~64KB pipe buffer to the stream read second: the
        // parent blocks reading the first pipe while the child blocks
        // writing the other (`kubectl get -o json` over a populated
        // namespace routinely exceeds 64KB on stderr).
        //
        // Registering `terminationHandler` after `run()` is safe: Foundation
        // invokes it immediately, from wherever it's set, if the process has
        // already exited by that point — there is no race with a
        // fast-exiting child.
        async let exitCode: Int32 = withCheckedContinuation { continuation in
            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
        }
        async let outData = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let errData = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

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
