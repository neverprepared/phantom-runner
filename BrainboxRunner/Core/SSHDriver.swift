import Foundation
import OSLog

/// Thin shell-out around `ssh` and `scp`. Used by UTM session execution to
/// push the credential bundle into the guest and run brainbox-init there.
/// Assumes key-based auth — the runner's developer key (or whatever the
/// template VM trusts) must already be configured.
enum SSHDriver {
    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "ssh")

    enum SSHError: Error, CustomStringConvertible {
        case exit(code: Int32, stderr: String)
        var description: String {
            switch self {
            case .exit(let c, let s): return "ssh exit \(c): \(s.prefix(300))"
            }
        }
    }

    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Run a single command on a remote host.
    @discardableResult
    static func exec(
        host: String,
        user: String,
        command: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> Output {
        var args = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "\(user)@\(host)",
            command,
        ]
        return try await runProc(
            URL(fileURLWithPath: "/usr/bin/ssh"),
            args: &args,
            stdin: stdin,
            timeout: timeout
        )
    }

    /// Block until SSH login succeeds — used after VM start to wait for the
    /// guest OS to bring up sshd.
    static func waitForReachable(
        host: String,
        user: String,
        timeout: TimeInterval = 120,
        pollEvery: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "unreachable"
        while Date() < deadline {
            do {
                let r = try await exec(host: host, user: user, command: "true", timeout: 8)
                if r.exitCode == 0 { return }
                lastError = "exit \(r.exitCode): \(r.stderr.prefix(120))"
            } catch {
                lastError = "\(error)"
            }
            try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
        throw SSHError.exit(code: -1, stderr: "SSH never reachable: \(lastError)")
    }

    // MARK: - Internal

    private static func runProc(
        _ url: URL,
        args: inout [String],
        stdin: Data?,
        timeout: TimeInterval
    ) async throws -> Output {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if let stdin {
            let stdinPipe = Pipe()
            proc.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        log.debug("ssh \((proc.arguments ?? []).joined(separator: " "), privacy: .public)")
        try proc.run()

        let watchdog = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return Output(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
    }
}
