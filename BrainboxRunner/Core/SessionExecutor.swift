import Foundation
import OSLog

/// Executes a `session.create` work item on the local Docker daemon and
/// returns a SessionContext-shaped result dict that the central API can
/// hydrate back into its own SessionContext model.
///
/// Scope (MVP): create + start container, lay down credential bundle when
/// delivery=bundle. Deliberately skips cosign, hardening, ttyd, role prompts,
/// claude config bundle, task injection, repo handling, monitoring — those
/// can land incrementally without changing this shape.
struct SessionExecutor {
    let runnerName: String
    let runnerHost: String?
    let api: APIClient
    let imageName: String

    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "session")
    private static let webTermPort = 7681
    private static let defaultTTL = 3600

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
            Self.log.info("session.create start: name=\(req.sessionName, privacy: .public) bundle=\(req.delivery == "bundle", privacy: .public) image=\(effectiveImage, privacy: .public)")

            // 1. Pull the image (no-op if local). Best-effort: log and proceed
            //    if the registry isn't reachable; local cached image still works.
            do {
                await api.postEvent(runnerName: runnerName, message: "pulling image \(effectiveImage)…", session: req.sessionName)
                try await DockerDriver.pull(image: effectiveImage)
                await api.postEvent(runnerName: runnerName, message: "image ready", session: req.sessionName)
            } catch {
                Self.log.warning("image pull failed (continuing with local): \(String(describing: error), privacy: .public)")
                await api.postEvent(runnerName: runnerName, message: "image pull failed, using cache", session: req.sessionName)
            }

            // 2. Build create args.
            let env: [String: String] = [
                "BRAINBOX_ROLE": req.role,
                "OLLAMA_HOST": "http://host.docker.internal:11434",
            ]
            let labels: [String: String] = [
                "brainbox.managed": "true",
                "brainbox.session_name": req.sessionName,
                "brainbox.role": req.role,
                "brainbox.runner": runnerName,
                "brainbox.workspace_profile": (req.workspaceProfile ?? "").lowercased(),
            ]
            let tmpfs: [(String, String)] = (req.delivery == "bundle")
                ? [("/run/brainbox", "size=64m,mode=1777")]
                : []

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
                tmpfs: tmpfs
            )

            // 3. Start.
            try await DockerDriver.start(name: containerName)

            // 4. Discover the host port Docker picked.
            let hostPort = (try? await DockerDriver.hostPort(name: containerName, containerPort: Self.webTermPort)) ?? 0

            // 5. Launch the web terminal (ttyd) so the Wails app + the
            //    /url returned in the response actually shows something.
            //    Detached so we don't block on it; ttyd binds 7681 and
            //    runs until the container stops.
            try await launchWebTerminal(
                containerName: containerName,
                title: "\(req.role.capitalized) - \(req.sessionName)"
            )

            // 7. Return SessionContext-shaped data. SessionContext is a Pydantic
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

            if req.delivery == "bundle" {
                try await injectBundleOverSSH(
                    host: ip,
                    user: sshUser,
                    workspaceProfile: req.workspaceProfile,
                    workspaceHome: req.workspaceHome
                )
            }

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

    /// SSH-based bundle injection: same chain as the Docker path, but every
    /// hop is an `ssh` invocation against the guest. Assumes the guest image
    /// has `brainbox-init` on PATH and the developer user can write to
    /// /run/brainbox (or we mkdir it ourselves first).
    private func injectBundleOverSSH(
        host: String,
        user: String,
        workspaceProfile: String?,
        workspaceHome: String?
    ) async throws {
        // Prepare /run/brainbox with sane perms. This is tmpfs by convention
        // (Docker side) but on a VM we have to create the dir ourselves.
        _ = try await SSHDriver.exec(
            host: host, user: user,
            command: "sudo mkdir -p /run/brainbox && sudo chown $USER /run/brainbox && chmod 0700 /run/brainbox"
        )

        // 1. Keygen on the guest.
        _ = try await SSHDriver.exec(
            host: host, user: user,
            command: "brainbox-init keygen --identity-out /run/brainbox/identity.key --recipient-out /run/brainbox/recipient.txt"
        )
        let recipientOut = try await SSHDriver.exec(
            host: host, user: user,
            command: "cat /run/brainbox/recipient.txt"
        )
        let recipient = recipientOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recipient.hasPrefix("age1") else {
            throw NSError(domain: "SessionExecutor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "recipient pubkey malformed: \(recipient.prefix(40))"
            ])
        }

        // 2. Seal via central API.
        let sealed = try await api.sealRequest(
            workspaceProfile: workspaceProfile,
            workspaceHome: workspaceHome,
            recipient: recipient
        )

        // 3. Stream bundle into the guest via ssh stdin → base64 -d → file.
        let base64 = sealed.base64EncodedData()
        _ = try await SSHDriver.exec(
            host: host, user: user,
            command: "base64 -d > /run/brainbox/bundle.age && chmod 0600 /run/brainbox/bundle.age",
            stdin: base64,
            timeout: 120
        )

        // 4. Apply on the guest.
        _ = try await SSHDriver.exec(
            host: host, user: user,
            command: "brainbox-init apply --identity /run/brainbox/identity.key --bundle /run/brainbox/bundle.age --home $HOME"
        )
    }

    // MARK: - Web terminal

    /// Launch ttyd inside the container, detached, bound to port 7681
    /// (which the host maps to the random port we reported back).
    /// Matches the Python lifecycle.start() invocation. Best-effort —
    /// container is live and creds are applied; ttyd starting late is
    /// a UX issue, not a session failure.
    private func launchWebTerminal(containerName: String, title: String) async throws {
        _ = try await DockerDriver.exec(
            name: containerName,
            cmd: [
                "ttyd",
                "-W",
                "-t", "titleFixed=\(title)",
                "-p", "7681",
                "/home/developer/ttyd-wrapper.sh",
            ],
            user: "developer",
            detach: true
        )
    }

    // MARK: - Bundle injection (docker path)

    private func injectBundle(
        containerName: String,
        workspaceProfile: String?,
        workspaceHome: String?
    ) async throws {
        // 1. Keygen — generates /run/brainbox/identity.key + recipient.txt.
        _ = try await DockerDriver.exec(
            name: containerName,
            cmd: ["brainbox-init", "keygen",
                  "--identity-out", "/run/brainbox/identity.key",
                  "--recipient-out", "/run/brainbox/recipient.txt"],
            user: "developer"
        )
        let recipientOut = try await DockerDriver.exec(
            name: containerName,
            cmd: ["cat", "/run/brainbox/recipient.txt"],
            user: "developer"
        )
        let recipient = recipientOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recipient.hasPrefix("age1") else {
            throw NSError(domain: "SessionExecutor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "recipient pubkey malformed: \(recipient.prefix(40))"
            ])
        }

        // 2. Seal via central API → laptop cc poll daemon → ciphertext bytes.
        let sealed = try await api.sealRequest(
            workspaceProfile: workspaceProfile,
            workspaceHome: workspaceHome,
            recipient: recipient
        )

        // 3. Stream the sealed bundle into the container via docker exec stdin.
        //    put_archive trips Docker Desktop on running containers with
        //    socket bind mounts; the exec API path is unaffected.
        let base64 = sealed.base64EncodedData()
        _ = try await DockerDriver.execStdin(
            name: containerName,
            shell: "base64 -d > /run/brainbox/bundle.age",
            user: nil,
            stdin: base64
        )

        // 4. Apply — unseal and lay down credentials. (No blanket `chown -R`:
        //    the brainbox image's /home/developer is already developer-owned,
        //    and our Swift runner doesn't add cred bind mounts that would
        //    cause Docker to auto-create root-owned parent dirs. The Python
        //    flow runs chown because it bind-mounts the GPG agent socket;
        //    when we add that here, do a targeted chown of the specific
        //    subdir rather than a recursive walk of millions of files in
        //    the brainbox image, which deadlocks for minutes.)
        _ = try await DockerDriver.exec(
            name: containerName,
            cmd: ["brainbox-init", "apply",
                  "--identity", "/run/brainbox/identity.key",
                  "--bundle", "/run/brainbox/bundle.age",
                  "--home", "/home/developer"],
            user: "developer"
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
        self.delivery = str("delivery") ?? "bundle"
        self.hardened = bool("hardened", default: false)
        self.llmProvider = str("llm_provider") ?? "claude"
        self.ttl = int("ttl")
        self.backend = str("backend") ?? "docker"
        self.vmTemplate = str("vm_template")
        self.guestOS = str("guest_os") ?? "linux"
        self.sshUser = str("ssh_user")
        self.image = str("image")
    }
}
