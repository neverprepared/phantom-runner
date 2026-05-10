import Foundation

/// `osascript -e` subprocess wrapper. Pure inline AppleScript — fine for the
/// short UTM commands we need; longer scripts can be piped via stdin later.
enum AppleScriptRunner {
    enum AppleScriptError: Error, CustomStringConvertible {
        case exit(code: Int32, stderr: String)
        var description: String {
            switch self {
            case .exit(let c, let s): return "osascript exit \(c): \(s.prefix(300))"
            }
        }
    }

    /// Runs the script and returns trimmed stdout. Throws on non-zero exit.
    static func run(_ script: String, timeout: TimeInterval = 60) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()

        // Best-effort timeout: kill if it overruns. Process.waitUntilExit blocks
        // the current thread; we set up a watchdog with DispatchQueue.global().
        let watchdog = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw AppleScriptError.exit(code: proc.terminationStatus, stderr: stderr)
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escape a string for safe interpolation into an AppleScript literal.
    /// Doubles backslashes and quotes — matches mcp-utm's _esc().
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
