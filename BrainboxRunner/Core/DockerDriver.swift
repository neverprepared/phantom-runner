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

    /// Directories where a `docker` CLI is commonly installed, most-preferred
    /// first. The runner is a GUI login-item with the bare launchd PATH
    /// (`/usr/bin:/bin:...`), so it CANNOT rely on the shell PATH — we resolve
    /// docker by absolute path here. OrbStack (the current macOS default) lives
    /// under the user's home; Docker Desktop / Homebrew are kept as fallbacks.
    static func dockerCLIDirs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.orbstack/bin",                              // OrbStack (current)
            "/usr/local/bin",                                     // Docker Desktop symlink / manual
            "/opt/homebrew/bin",                                  // Homebrew
            "/Applications/Docker.app/Contents/Resources/bin",    // Docker Desktop bundle
        ]
    }

    static func dockerBinary() -> URL? {
        for dir in dockerCLIDirs() {
            let path = dir + "/docker"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // Last-resort: rely on PATH (Process resolves via env).
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    static func isAvailable() async -> Bool {
        (try? await run(["version", "--format", "{{.Server.Version}}"], expectSuccess: true)) != nil
    }

    /// Pull an image. When registry credentials are supplied, pull through an
    /// ISOLATED docker config dir carrying an inline base64 `auths` entry (and no
    /// credsStore), so the pull authenticates without routing through OrbStack's
    /// macOS keychain helper — which fails with `-25308` outside a GUI session
    /// and leaves the daemon unable to fetch a freshly-rebuilt profile image.
    static func pull(image: String, username: String? = nil, password: String? = nil) async throws {
        guard let username, let password, !username.isEmpty, !password.isEmpty else {
            _ = try await run(["pull", image], expectSuccess: true)
            return
        }
        let registry = registryHost(from: image)
        let dir = NSTemporaryDirectory() + "brainbox-dockercfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        let cfg: [String: Any] = ["auths": [registry: ["auth": token]]]
        let cfgData = try JSONSerialization.data(withJSONObject: cfg)
        try cfgData.write(to: URL(fileURLWithPath: dir + "/config.json"))
        _ = try await run(["--config", dir, "pull", image], expectSuccess: true)
    }

    /// Registry host = the ref segment before the first `/` when it looks like a
    /// hostname (has a `.` or `:`); otherwise it's a Docker Hub namespace.
    private static func registryHost(from image: String) -> String {
        guard let slash = image.firstIndex(of: "/") else { return "docker.io" }
        let head = String(image[image.startIndex..<slash])
        return (head.contains(".") || head.contains(":")) ? head : "docker.io"
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
            // Bind on all interfaces so the central API can reach ttyd from
            // a remote network when the runner is not on the same host.
            args += ["-p", "0.0.0.0:\(host):\(container)"]
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
        detach: Bool = false,
        env: [String: String]? = nil
    ) async throws -> Output {
        var args: [String] = ["exec"]
        if detach { args.append("-d") }
        if let u = user { args += ["-u", u] }
        if let env = env {
            for (k, v) in env { args += ["-e", "\(k)=\(v)"] }
        }
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

    // MARK: - Compose (integrations)

    /// `docker compose -p <project> -f <dir>/docker-compose.yml up -d`. Runs with
    /// the integration dir as cwd so a sibling `.env` auto-loads, and passes
    /// `env` through so `${VAR}` references in the compose interpolate. Detached.
    @discardableResult
    static func composeUp(project: String, dir: URL, env: [String: String]) async throws -> Output {
        let file = dir.appendingPathComponent("docker-compose.yml").path
        return try await run(
            ["compose", "-p", project, "-f", file, "up", "-d", "--remove-orphans"],
            expectSuccess: true, cwd: dir, extraEnv: env
        )
    }

    /// `docker compose -p <project> -f <file> down`. Idempotent — a project that
    /// isn't up still exits 0.
    @discardableResult
    static func composeDown(project: String, dir: URL) async throws -> Output {
        let file = dir.appendingPathComponent("docker-compose.yml").path
        return try await run(
            ["compose", "-p", project, "-f", file, "down"],
            expectSuccess: true, cwd: dir
        )
    }

    /// `docker compose -p <project> -f <file> ps --format json --all` — per-service
    /// status as JSON. Non-fatal (`expectSuccess: false`) so an absent project
    /// yields empty output rather than throwing.
    static func composeStatus(project: String, dir: URL) async throws -> Output {
        let file = dir.appendingPathComponent("docker-compose.yml").path
        return try await run(
            ["compose", "-p", project, "-f", file, "ps", "--format", "json", "--all"],
            expectSuccess: false, cwd: dir
        )
    }

    // MARK: - Process plumbing

    @discardableResult
    private static func run(
        _ args: [String],
        stdin: Data? = nil,
        expectSuccess: Bool,
        cwd: URL? = nil,
        extraEnv: [String: String] = [:]
    ) async throws -> Output {
        guard let bin = dockerBinary() else { throw DockerError.binaryNotFound }
        let proc = Process()
        proc.executableURL = bin
        if let cwd { proc.currentDirectoryURL = cwd }
        // If bin is /usr/bin/env, prepend "docker" so env resolves it via PATH.
        if bin.lastPathComponent == "env" {
            proc.arguments = ["docker"] + args
        } else {
            proc.arguments = args
        }
        // The runner is a GUI login-item, so its inherited PATH is the bare
        // launchd default and lacks the dirs where docker + its `compose` plugin
        // live. Prepend the known CLI locations (OrbStack first) so `docker` and
        // `docker compose` resolve regardless of the inherited PATH — this also
        // covers the /usr/bin/env fallback and docker's own plugin lookup.
        var env = ProcessInfo.processInfo.environment
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (dockerCLIDirs() + [basePath]).joined(separator: ":")
        // Caller-supplied env (e.g. an integration's `${VAR}` values for compose
        // interpolation) wins over the inherited environment.
        for (k, v) in extraEnv { env[k] = v }
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

        log.debug("docker \((proc.arguments ?? []).joined(separator: " "), privacy: .public)")
        try proc.run()

        // Write stdin AFTER proc.run() so the child can drain the pipe.
        // For large payloads (sealed bundles run ~30MB) the default pipe
        // buffer is ~64KB; writing before run() deadlocks. Stream from a
        // background thread so this call doesn't block while the child reads.
        if let stdinHandle, let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                stdinHandle.write(stdin)
                try? stdinHandle.close()
            }
        }

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

    // MARK: - Platform stack (an existing compose project, discovered by label)

    /// `docker ps -a --filter label=com.docker.compose.project=<project>`, one
    /// TSV row per container: service, state, status, ports. Mirrors what the
    /// app used to run locally, so the control plane parses the same shape.
    /// Non-fatal so an absent stack yields empty output rather than throwing.
    static func platformPs(project: String) async throws -> Output {
        try await run(
            ["ps", "-a",
             "--filter", "label=com.docker.compose.project=\(project)",
             "--format", #"{{.Label "com.docker.compose.service"}}\t{{.State}}\t{{.Status}}\t{{.Ports}}"#],
            expectSuccess: false
        )
    }

    /// Discover the compose project's working dir + config file(s) off a running
    /// container's labels, so `docker compose` runs with the right project + .env
    /// without a hardcoded path. Returns (workdir, configFiles) or nil if the
    /// stack has no running containers.
    static func platformComposeCtx(project: String) async throws -> (workdir: String, configFiles: String)? {
        let out = try await run(
            ["ps",
             "--filter", "label=com.docker.compose.project=\(project)",
             "--format", #"{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "com.docker.compose.project.config_files"}}"#],
            expectSuccess: false
        )
        for line in out.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                return (String(parts[0]), String(parts[1]))
            }
        }
        return nil
    }

    /// The id of the running platform postgres container, discovered by compose
    /// label. Prefers the `<project>` one when several postgres containers exist.
    static func postgresContainer(project: String) async throws -> String? {
        let out = try await run(
            ["ps",
             "--filter", "label=com.docker.compose.service=postgres",
             "--format", "{{.ID}} {{.Names}}"],
            expectSuccess: false
        )
        var first: String?
        for line in out.stdout.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard let id = f.first.map(String.init) else { continue }
            if first == nil { first = id }
            if f.count >= 2 && f[1].contains(project) { return id }
        }
        return first
    }

    /// `docker exec <cid> psql -c <query>` against the platform postgres, with
    /// unaligned `|`-separated rows. Read-only listing; the query is caller-fixed
    /// (RunnerCore), never taken from the wire.
    static func psqlQuery(container: String, query: String) async throws -> Output {
        try await run(
            ["exec", container, "psql", "-U", "phantom", "-At", "-F", "|", "-c", query],
            expectSuccess: true
        )
    }

    /// `docker compose --project-directory <wd> -f <cfg> <action> [service]`.
    /// `action` is up|stop|restart; `up` gets `-d`. Targets one service when
    /// `service` is non-nil, else the whole stack.
    @discardableResult
    static func platformCompose(action: String, workdir: String, configFiles: String, service: String?) async throws -> Output {
        var args = ["compose", "--project-directory", workdir]
        for cfg in configFiles.split(separator: ",") {
            args += ["-f", cfg.trimmingCharacters(in: .whitespaces)]
        }
        args.append(action)
        if action == "up" { args.append("-d") }
        if let service, !service.isEmpty { args.append(service) }
        return try await run(args, expectSuccess: true, cwd: URL(fileURLWithPath: workdir))
    }
}
