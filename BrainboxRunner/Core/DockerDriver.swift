import Foundation
import OSLog

/// Thin shell-out to the `docker` CLI. The runner does not link any Swift
/// Docker SDK — `docker` on PATH is the only thing we need.
struct DockerDriver {
    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "docker")

    enum DockerError: Error, CustomStringConvertible {
        case binaryNotFound
        case exit(code: Int32, stderr: String, cmd: [String])

        var description: String {
            switch self {
            case .binaryNotFound:
                return "`docker` not on PATH"
            case .exit(let c, let e, let cmd):
                return "docker \(cmd.joined(separator: " ")) exit \(c): \(e.prefix(300))"
            }
        }
    }

    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func dockerBinary() -> URL? {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Last-resort: rely on PATH (Process resolves via env).
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    static func isAvailable() async -> Bool {
        (try? await run(["version", "--format", "{{.Server.Version}}"], expectSuccess: true)) != nil
    }

    static func pull(image: String) async throws {
        _ = try await run(["pull", image], expectSuccess: true)
    }

    /// Create (but do not start) a container. Returns the container ID.
    /// Caller hands us already-rendered flag arrays for env, mounts, tmpfs.
    /// Forces `--platform linux/arm64` since the brainbox image is arm64-only.
    static func create(
        name: String,
        image: String,
        command: [String],
        env: [String: String],
        labels: [String: String],
        portMappings: [(hostPort: Int, containerPort: Int)],
        volumes: [(hostPath: String, containerPath: String, mode: String)],
        tmpfs: [(target: String, options: String)]
    ) async throws -> String {
        // Remove any prior container with the same name (force).
        _ = try? await run(["rm", "-f", name], expectSuccess: false)

        var args: [String] = ["create", "--name", name]
        for (k, v) in env {
            args += ["-e", "\(k)=\(v)"]
        }
        for (k, v) in labels {
            args += ["--label", "\(k)=\(v)"]
        }
        for (host, container) in portMappings {
            args += ["-p", "127.0.0.1:\(host):\(container)"]
        }
        for v in volumes {
            args += ["-v", "\(v.hostPath):\(v.containerPath):\(v.mode)"]
        }
        for t in tmpfs {
            args += ["--tmpfs", "\(t.target):\(t.options)"]
        }
        args.append(image)
        args.append(contentsOf: command)

        let out = try await run(args, expectSuccess: true)
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func start(name: String) async throws {
        _ = try await run(["start", name], expectSuccess: true)
    }

    @discardableResult
    static func exec(
        name: String,
        cmd: [String],
        user: String? = nil,
        detach: Bool = false
    ) async throws -> Output {
        var args: [String] = ["exec"]
        if detach { args.append("-d") }
        if let u = user { args += ["-u", u] }
        args.append(name)
        args.append(contentsOf: cmd)
        return try await run(args, expectSuccess: !detach)
    }

    /// `docker exec -i <name> sh -c '<inline>'` with bytes piped on stdin.
    /// Used to write the sealed bundle into the container's /run/brainbox tmpfs
    /// — put_archive on Docker Desktop trips a bug when bind-mounted sockets
    /// are present (see the Python docker backend for the long story).
    static func execStdin(
        name: String,
        shell: String,
        user: String? = nil,
        stdin: Data
    ) async throws -> Output {
        var args: [String] = ["exec", "-i"]
        if let u = user { args += ["-u", u] }
        args.append(name)
        args += ["sh", "-c", shell]
        return try await run(args, stdin: stdin, expectSuccess: true)
    }

    static func remove(name: String, force: Bool = true) async throws {
        var args: [String] = ["rm"]
        if force { args.append("-f") }
        args.append(name)
        _ = try? await run(args, expectSuccess: false)
    }

    /// Returns the host port currently bound to a given container port.
    /// `docker inspect --format '{{(index .NetworkSettings.Ports "<port>/tcp" 0).HostPort}}' <name>`
    static func hostPort(name: String, containerPort: Int) async throws -> Int? {
        let format = "{{(index (index .NetworkSettings.Ports \"\(containerPort)/tcp\") 0).HostPort}}"
        let out = try await run(["inspect", "--format", format, name], expectSuccess: true)
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    // MARK: - Process plumbing

    @discardableResult
    private static func run(
        _ args: [String],
        stdin: Data? = nil,
        expectSuccess: Bool
    ) async throws -> Output {
        guard let bin = dockerBinary() else { throw DockerError.binaryNotFound }
        let proc = Process()
        proc.executableURL = bin
        // If bin is /usr/bin/env, prepend "docker" so env resolves it via PATH.
        if bin.lastPathComponent == "env" {
            proc.arguments = ["docker"] + args
        } else {
            proc.arguments = args
        }
        // Inherit PATH; Docker Desktop adds /Applications/Docker.app/Contents/Resources/bin
        // which is typically already on the user shell PATH.
        var env = ProcessInfo.processInfo.environment
        if let path = env["PATH"], !path.contains("/Applications/Docker.app/Contents/Resources/bin") {
            env["PATH"] = path + ":/Applications/Docker.app/Contents/Resources/bin"
        }
        proc.environment = env

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

        log.debug("docker \((proc.arguments ?? []).joined(separator: " "), privacy: .public)")
        try proc.run()
        proc.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let result = Output(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
        if expectSuccess && result.exitCode != 0 {
            throw DockerError.exit(
                code: result.exitCode,
                stderr: result.stderr,
                cmd: proc.arguments ?? []
            )
        }
        return result
    }
}
