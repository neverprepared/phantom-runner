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

        // Drain stdout and stderr CONCURRENTLY, each on its own queue, and
        // join both before waiting on exit. Reading them sequentially
        // deadlocks once the child writes more than the ~64KB pipe buffer to
        // the stream read second: the parent blocks reading the first pipe
        // while the child blocks writing the other (`kubectl get -o json`
        // over a populated namespace routinely exceeds 64KB on stderr).
        let outputGroup = DispatchGroup()
        var outData = Data()
        var errData = Data()

        outputGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        outputGroup.wait()

        proc.waitUntilExit()

        let out = Output(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus
        )
        if expectSuccess && out.exitCode != 0 {
            throw KubeError.exit(code: out.exitCode, stderr: out.stderr, cmd: args)
        }
        return out
    }
}
