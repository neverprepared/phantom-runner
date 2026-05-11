import Foundation
import OSLog

/// Wraps the bundled `brainbox-bundler` Go helper. The Swift agent passes a
/// JSON request on stdin and reads the sealed bundle bytes on stdout.
/// The helper does all the heavy lifting (filesystem walk, tar, zstd, age)
/// so the Swift side stays focused on networking + orchestration.
enum BundleBuilder {
    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "bundler")

    enum BundlerError: Error, CustomStringConvertible {
        case binaryMissing
        case exit(code: Int32, stderr: String)
        case empty

        var description: String {
            switch self {
            case .binaryMissing:
                return "brainbox-bundler helper not found in app bundle Resources"
            case .exit(let c, let s):
                return "brainbox-bundler exit \(c): \(s.prefix(300))"
            case .empty:
                return "brainbox-bundler produced no output"
            }
        }
    }

    /// Locate the helper inside the .app bundle. Falls back to PATH for dev
    /// builds where the binary may have been copied next to the executable.
    static func binaryURL() -> URL? {
        if let path = Bundle.main.path(forResource: "brainbox-bundler", ofType: nil) {
            return URL(fileURLWithPath: path)
        }
        // Dev convenience: look in /usr/local/bin or alongside the executable.
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("brainbox-bundler"),
            URL(fileURLWithPath: "/usr/local/bin/brainbox-bundler"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Build a sealed bundle for the given workspace + recipient. Blocks
    /// for the duration of the helper run. The helper itself is fast
    /// (~1-2s for a typical profile); callers can run this from a background
    /// Task with no timeout babysitting.
    static func build(
        workspaceProfile: String?,
        workspaceHome: String?,
        recipient: String
    ) async throws -> Data {
        guard let bin = binaryURL() else {
            throw BundlerError.binaryMissing
        }

        let body: [String: Any] = [
            "workspace_profile": workspaceProfile ?? "",
            "workspace_home": workspaceHome ?? "",
            "recipient": recipient,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        return try await Task.detached(priority: .userInitiated) {
            try runHelper(bin: bin, stdin: payload)
        }.value
    }

    private static func runHelper(bin: URL, stdin: Data) throws -> Data {
        let proc = Process()
        proc.executableURL = bin

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        // Same lesson as DockerDriver: write stdin AFTER run() so the child
        // can drain. Small payload here (a few hundred bytes), but the
        // pattern is the right default.
        DispatchQueue.global(qos: .userInitiated).async {
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if proc.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw BundlerError.exit(code: proc.terminationStatus, stderr: stderr)
        }
        guard !stdoutData.isEmpty else { throw BundlerError.empty }
        log.info("bundler sealed \(stdoutData.count) bytes")
        return stdoutData
    }
}
