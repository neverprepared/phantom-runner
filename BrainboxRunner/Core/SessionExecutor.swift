import Foundation
import OSLog

/// Executes a `session.create` work item on the local Docker daemon and
/// returns a SessionContext-shaped result dict that the central API can
/// hydrate back into its own SessionContext model.
///
/// Scope: create + start container, bootstrap the agent (decrypt creds, fetch
/// task, launch claude via a direct wrapper exec), then attach ttyd. Still skips
/// cosign, hardening, repo handling — those can land incrementally.
struct SessionExecutor {
    let runnerName: String
    let runnerHost: String?
    let api: APIClient
    let imageName: String

    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "session")
    private static let webTermPort = 7681
    private static let defaultTTL = 3600
    /// Env for direct wrapper execs. The wrapper self-sets PATH, but `docker
    /// exec` starts from a minimal PATH, so seed the uv-managed ~/.local/bin
    /// (python3, tmux) up front — mirrors the Python backend's _exec_env. Without
    /// python3 the .claude.enc decrypt pipe dies silently and the session lands
    /// at /login.
    private static let wrapperExecEnv = [
        "PATH": "/home/developer/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ]

    init(runnerName: String, runnerHost: String? = nil, api: APIClient, imageName: String = "brainbox") {
        self.runnerName = runnerName
        self.runnerHost = runnerHost
        self.api = api
        self.imageName = imageName
    }

    func execute(payload: [String: AnyDecodable]) async -> APIClient.ResultPayload {
        let req = SessionRequest(payload: payload)
        if req.backend == "utm" {
            return await executeUTM(req: req)
        }
        return await executeDocker(req: req)
    }

    private func executeDocker(req: SessionRequest) async -> APIClient.ResultPayload {
        let containerName = "\(req.role)-\(req.sessionName)"
        let effectiveImage = req.image ?? imageName

        do {
            Self.log.info("session.create start: name=\(req.sessionName, privacy: .public) image=\(effectiveImage, privacy: .public)")

            // 1. Pull the image (no-op if local). Best-effort: log and proceed
            //    if the registry isn't reachable; local cached image still works.
            do {
                await api.postEvent(runnerName: runnerName, message: "pulling image \(effectiveImage)…", session: req.sessionName)
                try await DockerDriver.pull(image: effectiveImage, username: req.registryUsername, password: req.registryPassword)
                await api.postEvent(runnerName: runnerName, message: "image ready", session: req.sessionName)
            } catch {
                Self.log.warning("image pull failed (continuing with local): \(String(describing: error), privacy: .public)")
                await api.postEvent(runnerName: runnerName, message: "image pull failed, using cache", session: req.sessionName)
            }

            // 2. Build create args.
            var env: [String: String] = [
                "BRAINBOX_ROLE": req.role,
                "OLLAMA_HOST": "http://host.docker.internal:11434",
            ]
            env.merge(req.extraEnv) { _, new in new }
            let labels: [String: String] = [
                "brainbox.managed": "true",
                "brainbox.session_name": req.sessionName,
                "brainbox.role": req.role,
                "brainbox.runner": runnerName,
                "brainbox.workspace_profile": (req.workspaceProfile ?? "").lowercased(),
            ]
            let sessionsDir = sessionDataDir(name: req.sessionName)
            try? FileManager.default.createDirectory(
                atPath: sessionsDir, withIntermediateDirectories: true, attributes: nil
            )
            let volumes: [(String, String, String)] = [
                (sessionsDir, "/home/developer/.claude/projects", "rw")
            ]

            _ = try await DockerDriver.create(
                name: containerName,
                image: effectiveImage,
                command: ["sleep", "infinity"],
                env: env,
                labels: labels,
                portMappings: [(0, Self.webTermPort)],  // 0 = auto-assigned by Docker
                volumes: volumes,
                tmpfs: []
            )

            // 3. Start.
            try await DockerDriver.start(name: containerName)

            // 4. Bootstrap the agent: run the wrapper ONCE directly (detached),
            //    mirroring the Python docker backend's start(). This creates the
            //    tmux `main` session, decrypts the profile creds (OAuth/.env/.codex),
            //    fetches the task from the hub store, and launches claude. An
            //    autonomous worker never starts otherwise — ttyd (-W) only spawns
            //    its command on a browser connection, which an unattended session
            //    never receives, so the wrapper (and thus claude + task) never run.
            //    ttyd (step 6) then just attaches to the existing `main`.
            do {
                _ = try await DockerDriver.exec(
                    name: containerName,
                    cmd: ["/home/developer/ttyd-wrapper.sh"],
                    user: "developer",
                    detach: true,
                    env: Self.wrapperExecEnv
                )
                // Let the wrapper create tmux `main` before ttyd attaches.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                Self.log.warning("agent bootstrap exec failed (continuing): \(String(describing: error), privacy: .public)")
            }

            // 5. Discover the host port Docker picked.
            let hostPort = (try? await DockerDriver.hostPort(name: containerName, containerPort: Self.webTermPort)) ?? 0

            // 6. Launch the web terminal (ttyd) so the Wails app + the
            //    /url returned in the response actually shows something. Since the
            //    wrapper already created `main`, ttyd just attaches on connect.
            try await launchWebTerminal(
                containerName: containerName,
                sessionName: req.sessionName,
                title: "\(req.role.capitalized) - \(req.sessionName)"
            )

            // 6. Return SessionContext-shaped data. SessionContext is a Pydantic
            //    model on the Python side — the API rebuilds it via **kwargs.
            let ctx: [String: AnyEncodable] = [
                "session_name": AnyEncodable(req.sessionName),
                "container_name": AnyEncodable(containerName),
                "port": AnyEncodable(hostPort),
                "role": AnyEncodable(req.role),
                "state": AnyEncodable("running"),
                "created_at": AnyEncodable(Int(Date().timeIntervalSince1970 * 1000)),
                "ttl": AnyEncodable(req.ttl ?? Self.defaultTTL),
                "hardened": AnyEncodable(req.hardened),
                "backend": AnyEncodable("docker"),
                "llm_provider": AnyEncodable(req.llmProvider),
                "workspace_profile": AnyEncodable(req.workspaceProfile ?? NSNull()),
                "workspace_home": AnyEncodable(req.workspaceHome ?? NSNull()),
                "delivery": AnyEncodable(req.delivery),
                "runner_name": AnyEncodable(runnerName),
                "runner_host": AnyEncodable(runnerHost ?? NSNull()),
            ]
            Self.log.info("session.create done: \(containerName, privacy: .public) port=\(hostPort)")
            return APIClient.ResultPayload(ok: true, error: nil, data: ctx)

        } catch {
            // Best-effort cleanup so we don't leak the half-created container.
            try? await DockerDriver.remove(name: containerName, force: true)
            Self.log.error("session.create failed: \(String(describing: error), privacy: .public)")
            return APIClient.ResultPayload(
                ok: false,
                error: "\(error)",
                data: nil
            )
        }
    }

    // MARK: - UTM execution

    private func executeUTM(req: SessionRequest) async -> APIClient.ResultPayload {
        let vmName = "\(req.role)-\(req.sessionName)"
        let template = req.vmTemplate ?? "brainbox-template"
        let sshUser = req.sshUser ?? "developer"

        do {
            Self.log.info("session.create utm start: name=\(req.sessionName, privacy: .public) template=\(template, privacy: .public)")
            try UTMDriver.clone(template: template, newName: vmName)
            let mac = try UTMDriver.assignRandomMAC(name: vmName)
            try UTMDriver.start(name: vmName)
            _ = try await UTMDriver.waitForStatus(name: vmName, target: "started", timeout: 180)

            let ip = try await UTMDriver.resolveIP(forMAC: mac, timeout: 90)
            try await SSHDriver.waitForReachable(host: ip, user: sshUser, timeout: 180)

            let ctx: [String: AnyEncodable] = [
                "session_name": AnyEncodable(req.sessionName),
                "container_name": AnyEncodable(vmName),
                "port": AnyEncodable(0),
                "role": AnyEncodable(req.role),
                "state": AnyEncodable("running"),
                "created_at": AnyEncodable(Int(Date().timeIntervalSince1970 * 1000)),
                "ttl": AnyEncodable(req.ttl ?? Self.defaultTTL),
                "hardened": AnyEncodable(req.hardened),
                "backend": AnyEncodable("utm"),
                "llm_provider": AnyEncodable(req.llmProvider),
                "workspace_profile": AnyEncodable(req.workspaceProfile ?? NSNull()),
                "workspace_home": AnyEncodable(req.workspaceHome ?? NSNull()),
                "delivery": AnyEncodable(req.delivery),
                "runner_name": AnyEncodable(runnerName),
                "runner_host": AnyEncodable(runnerHost ?? NSNull()),
                "vm_template": AnyEncodable(template),
                "vm_ip": AnyEncodable(ip),
                "mac_address": AnyEncodable(mac),
                "ssh_user": AnyEncodable(sshUser),
                "guest_os": AnyEncodable(req.guestOS),
            ]
            Self.log.info("session.create utm done: \(vmName, privacy: .public) ip=\(ip, privacy: .public)")
            return APIClient.ResultPayload(ok: true, error: nil, data: ctx)

        } catch {
            // Best-effort: stop the VM but leave it for inspection — UTM keeps
            // VM bundles even after clone, deleting on failure surprises users.
            try? UTMDriver.stop(name: vmName)
            Self.log.error("session.create utm failed: \(String(describing: error), privacy: .public)")
            return APIClient.ResultPayload(ok: false, error: "\(error)", data: nil)
        }
    }

    // MARK: - Web terminal

    /// Launch ttyd inside the container, detached, bound to port 7681
    /// (which the host maps to the random port we reported back).
    /// Matches the Python lifecycle.start() invocation. Best-effort —
    /// container is live and creds are applied; ttyd starting late is
    /// a UX issue, not a session failure.
    private func launchWebTerminal(containerName: String, sessionName: String, title: String) async throws {
        _ = try await DockerDriver.exec(
            name: containerName,
            cmd: [
                "ttyd",
                "-W",
                "-t", "titleFixed=\(title)",
                "-p", "7681",
                "--base-path", "/t/\(sessionName)",
                "/home/developer/ttyd-wrapper.sh",
            ],
            user: "developer",
            detach: true,
            env: Self.wrapperExecEnv
        )
    }

    // MARK: - Helpers

    private func sessionDataDir(name: String) -> String {
        // Match the Python lifecycle path so DooD container mounts work
        // when host and runner share the same `~/.config/phantom-ink/brainbox/sessions/`.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/phantom-ink/brainbox/sessions/\(name)"
    }
}

/// Parsed view of a session.create work payload. Mirrors the Python
/// CreateSessionRequest fields we care about; ignores the rest.
struct SessionRequest {
    let sessionName: String
    let role: String
    let workspaceProfile: String?
    let workspaceHome: String?
    let delivery: String
    let hardened: Bool
    let llmProvider: String
    let ttl: Int?
    let backend: String
    let vmTemplate: String?
    let guestOS: String
    let sshUser: String?
    let image: String?
    let extraEnv: [String: String]
    // Private-registry credentials the router ships so the runner can pull the
    // profile image. The runner holds no registry creds of its own, and a
    // `docker login` here can't persist over SSH (OrbStack's keychain credStore
    // → -25308), so DockerDriver.pull writes an isolated inline-auth config.
    let registryUsername: String?
    let registryPassword: String?

    init(payload: [String: AnyDecodable]) {
        func str(_ k: String) -> String? {
            (payload[k]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ k: String) -> Int? {
            (payload[k]?.value as? Int) ?? (payload[k]?.value as? Double).map(Int.init)
        }
        func bool(_ k: String, default def: Bool) -> Bool {
            (payload[k]?.value as? Bool) ?? def
        }
        self.sessionName = str("session_name") ?? str("name") ?? "default"
        self.role = str("role") ?? "assistant"
        self.workspaceProfile = str("workspace_profile")
        self.workspaceHome = str("workspace_home")
        self.delivery = str("delivery") ?? "image"
        self.hardened = bool("hardened", default: false)
        self.llmProvider = str("llm_provider") ?? "claude"
        self.ttl = int("ttl")
        self.backend = str("backend") ?? "docker"
        self.vmTemplate = str("vm_template")
        self.guestOS = str("guest_os") ?? "linux"
        self.sshUser = str("ssh_user")
        self.image = str("image")
        self.extraEnv = (payload["extra_env"]?.value as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        self.registryUsername = str("registry_username")
        self.registryPassword = str("registry_password")
    }
}
