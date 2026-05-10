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
    let api: APIClient
    let imageName: String

    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "session")
    private static let webTermPort = 7681
    private static let defaultTTL = 3600

    init(runnerName: String, api: APIClient, imageName: String = "brainbox") {
        self.runnerName = runnerName
        self.api = api
        self.imageName = imageName
    }

    func execute(payload: [String: AnyDecodable]) async -> APIClient.ResultPayload {
        let req = SessionRequest(payload: payload)
        let containerName = "\(req.role)-\(req.sessionName)"

        do {
            Self.log.info("session.create start: name=\(req.sessionName, privacy: .public) bundle=\(req.delivery == "bundle", privacy: .public)")

            // 1. Pull the image (no-op if local). Best-effort: log and proceed
            //    if the registry isn't reachable; local cached image still works.
            do {
                try await DockerDriver.pull(image: imageName)
            } catch {
                Self.log.warning("image pull failed (continuing with local): \(String(describing: error), privacy: .public)")
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
                image: imageName,
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

            // 5. Credential bundle injection (bundle mode only).
            if req.delivery == "bundle" {
                try await injectBundle(
                    containerName: containerName,
                    workspaceProfile: req.workspaceProfile,
                    workspaceHome: req.workspaceHome
                )
            }

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

    // MARK: - Bundle injection

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

        // 4. Docker auto-creates parent dirs for any bind mounts as root, so
        //    reclaim ownership for `developer` before apply writes files there.
        _ = try await DockerDriver.exec(
            name: containerName,
            cmd: ["sh", "-c", "chown -R developer:developer /home/developer"],
            user: "root"
        )

        // 5. Apply — unseal and lay down credentials.
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
    }
}
