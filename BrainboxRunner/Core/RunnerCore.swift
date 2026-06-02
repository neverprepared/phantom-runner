import Foundation
import OSLog

/// Owns the registration + long-poll loop. Lives on the main actor so menu-bar
/// status updates are free; URLSession calls are async and don't block the UI.
@MainActor
final class RunnerCore {
    weak var owner: AppState?
    private let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "core")

    private var pollTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var sealTask: Task<Void, Never>?
    private var paused: Bool = false
    private var lastError: String?

    /// Count of work items currently being provisioned. Reported to the API
    /// via heartbeat so it can make accurate scheduling decisions.
    private var inFlight: Int = 0

    /// Durable queue for results that couldn't be delivered while the API
    /// was unreachable. Drained on reconnect and on each heartbeat tick.
    private let resultQueue = ResultQueue()

    init(owner: AppState) {
        self.owner = owner
    }

    var isRunning: Bool { pollTask != nil }
    var pausedFlag: Bool { paused }
    var lastErrorMessage: String? { lastError }

    /// Stop any in-flight loop, then start a fresh one using the current settings.
    func restart() async {
        await stop()
        await start()
    }

    func start() async {
        guard pollTask == nil else { return }
        guard let owner else { return }
        let settings = owner.settings
        guard !settings.apiURL.isEmpty else {
            updateStatus(.disconnected, error: "API URL not configured")
            return
        }
        guard let baseURL = URL(string: settings.apiURL) else {
            updateStatus(.disconnected, error: "API URL is malformed")
            return
        }
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            updateStatus(.disconnected, error: "API key not in Keychain")
            return
        }

        let client = APIClient(baseURL: baseURL, apiKey: apiKey)
        let name = settings.runnerName.isEmpty ? "runner" : settings.runnerName
        let machineID = settings.machineID
        let caps: [String: Bool] = [
            "docker": settings.dockerEnabled,
            "utm": settings.utmEnabled,
            "secret_authority": settings.secretAuthorityEnabled,
        ]
        let tags = settings.tags
        let maxConcurrent = settings.maxConcurrent
        let host = settings.runnerHost.isEmpty ? nil : settings.runnerHost
        paused = false

        pollTask = Task { [weak self] in
            await self?.loop(client: client, name: name, machineID: machineID, caps: caps, tags: tags, host: host, maxConcurrent: maxConcurrent)
        }
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop(client: client, name: name, maxConcurrent: maxConcurrent)
        }
        if settings.secretAuthorityEnabled {
            sealTask = Task { [weak self] in
                await self?.sealLoop(client: client, name: name)
            }
        }
    }

    func stop() async {
        for task in [pollTask, heartbeatTask, sealTask].compactMap({ $0 }) {
            task.cancel()
            _ = await task.value
        }
        pollTask = nil
        heartbeatTask = nil
        sealTask = nil
        inFlight = 0
        updateStatus(.disconnected, error: nil)
    }

    func pause() {
        paused = true
        if owner?.status == .connected { updateStatus(.paused, error: nil) }
    }

    func resume() {
        paused = false
        if owner?.status == .paused { updateStatus(.connected, error: nil) }
    }

    /// One-shot reachability check used by Settings → Test connection.
    func testConnection() async -> Result<Void, APIClient.APIError> {
        guard let owner else { return .failure(.invalidURL) }
        guard let baseURL = URL(string: owner.settings.apiURL) else {
            return .failure(.invalidURL)
        }
        let key = KeychainStore.loadAPIKey() ?? ""
        let client = APIClient(baseURL: baseURL, apiKey: key)
        do {
            try await client.ping()
            return .success(())
        } catch let e as APIClient.APIError {
            return .failure(e)
        } catch {
            return .failure(.transport(error))
        }
    }

    // MARK: - Main loop

    private func loop(
        client: APIClient,
        name: String,
        machineID: String,
        caps: [String: Bool],
        tags: [String],
        host: String?,
        maxConcurrent: Int
    ) async {
        // Phase 1: register, with retry on transport failure.
        let register = APIClient.RegisterRequest(
            name: name,
            capabilities: caps,
            tags: tags,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.7",
            host: host,
            machine_id: machineID
        )
        while !Task.isCancelled {
            do {
                _ = try await client.register(register)
                updateStatus(.connected, error: nil)
                log.info("registered as \(name, privacy: .public)")
                // Drain results queued during the last outage
                await resultQueue.drain(client: client)
                break
            } catch APIClient.APIError.unauthorized {
                updateStatus(.disconnected, error: "unauthorized")
                log.error("register: unauthorized")
                return
            } catch {
                updateStatus(.disconnected, error: "register: \(error)")
                log.warning("register failed, retrying: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        // Phase 2: concurrent work dispatch.
        // Each work item is handled in its own unstructured Task so the poll
        // loop can immediately fetch the next item without waiting for the
        // current one to finish (Docker pull + create can take 30-90s).
        while !Task.isCancelled {
            if paused {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            // Throttle: stop polling when we're already at capacity.
            if inFlight >= maxConcurrent {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            do {
                guard let work = try await client.pollPending(runnerName: name) else { continue }
                log.info("work received id=\(work.id, privacy: .public) kind=\(work.kind, privacy: .public) in_flight=\(self.inFlight + 1)/\(maxConcurrent)")
                inFlight += 1
                updateStatus(inFlight >= maxConcurrent ? .busy : .connected, error: nil)

                // Unstructured task — don't await it, so the poll loop
                // continues immediately and can pick up more work.
                Task { [weak self, name] in
                    guard let self else { return }
                    let result = await self.handle(work: work)

                    if let jsonData = try? JSONEncoder().encode(result) {
                        do {
                            try await client.postResultRaw(
                                runnerName: name,
                                workID: work.id,
                                jsonData: jsonData
                            )
                            self.log.info("result posted: work=\(work.id, privacy: .public)")
                        } catch {
                            // API unreachable — queue for deferred delivery
                            await self.resultQueue.add(
                                runnerName: name,
                                workID: work.id,
                                jsonData: jsonData
                            )
                            self.log.warning("result queued (post failed): work=\(work.id, privacy: .public)")
                        }
                    }

                    self.inFlight -= 1
                    if self.inFlight == 0 && !self.paused {
                        self.updateStatus(.connected, error: nil)
                    }
                }

            } catch APIClient.APIError.unauthorized {
                updateStatus(.disconnected, error: "unauthorized")
                log.error("poll: unauthorized")
                return
            } catch {
                updateStatus(.disconnected, error: "poll: \(error)")
                log.warning("poll failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { updateStatus(.connected, error: nil) }
            }
        }
    }

    // MARK: - Heartbeat loop

    /// Sends a heartbeat every 30s with current load metrics, and drains
    /// any queued results whose retry window has elapsed.
    private func heartbeatLoop(client: APIClient, name: String, maxConcurrent: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await client.heartbeat(
                    runnerName: name,
                    inFlight: inFlight,
                    maxConcurrent: maxConcurrent
                )
            } catch {
                log.warning("heartbeat failed: \(String(describing: error), privacy: .public)")
            }
            await resultQueue.drain(client: client)
        }
    }

    // MARK: - Secret authority loop

    private func sealLoop(client: APIClient, name: String) async {
        log.info("seal loop starting (authority=\(name, privacy: .public))")
        while !Task.isCancelled {
            do {
                guard let req = try await client.pollPendingCredentialRequest(as: name) else {
                    continue
                }
                log.info("seal request id=\(req.id, privacy: .public) recipient=\(req.recipient.prefix(20), privacy: .public)…")
                let sealed = try await BundleBuilder.build(
                    workspaceProfile: req.workspace_profile,
                    workspaceHome: req.workspace_home,
                    recipient: req.recipient
                )
                try await client.postSealedCredentials(requestID: req.id, sealed: sealed)
                log.info("seal request id=\(req.id, privacy: .public) delivered (\(sealed.count) bytes)")
            } catch APIClient.APIError.unauthorized {
                log.error("seal loop: unauthorized — stopping")
                return
            } catch {
                log.warning("seal loop error: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Dispatch a work item to the matching executor.
    private func handle(work: APIClient.WorkItem) async -> APIClient.ResultPayload {
        switch work.kind {
        case "session.create":
            return await handleSessionCreate(payload: work.payload)
        case "session.stop":
            return await handleSessionStop(payload: work.payload)
        case "session.delete":
            return await handleSessionDelete(payload: work.payload)
        case "session.exec":
            return await handleSessionExec(payload: work.payload)
        case "session.query":
            return await handleSessionQuery(payload: work.payload)
        default:
            return APIClient.ResultPayload(
                ok: false,
                error: "runner not yet implemented for kind: \(work.kind)",
                data: nil
            )
        }
    }

    private func handleSessionStop(payload: [String: AnyDecodable]) async -> APIClient.ResultPayload {
        guard let containerName = payload["container_name"]?.value as? String, !containerName.isEmpty else {
            return APIClient.ResultPayload(ok: false, error: "container_name required", data: nil)
        }
        do {
            _ = try await DockerDriver.exec(name: containerName, cmd: ["sh", "-c", "kill 1 2>/dev/null; true"], detach: true)
            log.info("session.stop done: \(containerName, privacy: .public)")
            return APIClient.ResultPayload(ok: true, error: nil, data: nil)
        } catch {
            log.warning("session.stop failed: \(String(describing: error), privacy: .public)")
            return APIClient.ResultPayload(ok: false, error: "\(error)", data: nil)
        }
    }

    private func handleSessionDelete(payload: [String: AnyDecodable]) async -> APIClient.ResultPayload {
        guard let containerName = payload["container_name"]?.value as? String, !containerName.isEmpty else {
            return APIClient.ResultPayload(ok: false, error: "container_name required", data: nil)
        }
        do {
            try await DockerDriver.remove(name: containerName, force: true)
            log.info("session.delete done: \(containerName, privacy: .public)")
            return APIClient.ResultPayload(ok: true, error: nil, data: nil)
        } catch {
            log.warning("session.delete failed: \(String(describing: error), privacy: .public)")
            return APIClient.ResultPayload(ok: false, error: "\(error)", data: nil)
        }
    }

    private func handleSessionExec(payload: [String: AnyDecodable]) async -> APIClient.ResultPayload {
        guard let containerName = payload["container_name"]?.value as? String, !containerName.isEmpty else {
            return APIClient.ResultPayload(ok: false, error: "container_name required", data: nil)
        }
        guard let command = payload["command"]?.value as? String, !command.isEmpty else {
            return APIClient.ResultPayload(ok: false, error: "command required", data: nil)
        }
        do {
            let out = try await DockerDriver.exec(name: containerName, cmd: ["sh", "-c", command])
            let data: [String: AnyEncodable] = [
                "success": AnyEncodable(out.exitCode == 0),
                "exit_code": AnyEncodable(Int(out.exitCode)),
                "output": AnyEncodable(out.stdout),
            ]
            return APIClient.ResultPayload(ok: true, error: nil, data: data)
        } catch {
            return APIClient.ResultPayload(ok: false, error: "\(error)", data: nil)
        }
    }

    private func handleSessionQuery(payload: [String: AnyDecodable]) async -> APIClient.ResultPayload {
        guard let containerName = payload["container_name"]?.value as? String, !containerName.isEmpty else {
            return APIClient.ResultPayload(ok: false, error: "container_name required", data: nil)
        }
        guard let prompt = payload["prompt"]?.value as? String, !prompt.isEmpty else {
            return APIClient.ResultPayload(ok: false, error: "prompt required", data: nil)
        }
        let timeout = (payload["timeout"]?.value as? Int) ?? 60
        let workingDir = payload["working_dir"]?.value as? String

        // Send prompt via tmux (same mechanism as the Python API).
        // 1. Inject the prompt into the tmux "main" window.
        // 2. Wait for output to settle (no activity for 2s within the timeout).
        // 3. Capture the pane and return it.
        do {
            if let wd = workingDir {
                _ = try await DockerDriver.exec(name: containerName, cmd: ["tmux", "send-keys", "-t", "main", "cd \(wd)", "Enter"])
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            _ = try await DockerDriver.exec(name: containerName, cmd: ["tmux", "send-keys", "-t", "main", prompt, "Enter"])

            // Poll for activity to settle (shell prompt reappears when done).
            var settled = false
            var elapsed = 0
            while elapsed < timeout && !settled {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                elapsed += 2
                let capture = try await DockerDriver.exec(name: containerName, cmd: ["tmux", "capture-pane", "-pt", "main"])
                let lines = capture.stdout.components(separatedBy: "\n")
                let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                if last.contains(">") || last.contains("$") || last.contains("✓") {
                    settled = true
                }
            }

            let final = try await DockerDriver.exec(name: containerName, cmd: ["tmux", "capture-pane", "-pt", "main"])
            let data: [String: AnyEncodable] = [
                "success": AnyEncodable(true),
                "response": AnyEncodable(final.stdout),
                "output": AnyEncodable(final.stdout),
                "error": AnyEncodable(NSNull()),
                "exit_code": AnyEncodable(0),
            ]
            return APIClient.ResultPayload(ok: true, error: nil, data: data)
        } catch {
            return APIClient.ResultPayload(ok: false, error: "\(error)", data: nil)
        }
    }

    private func handleSessionCreate(
        payload: [String: AnyDecodable]
    ) async -> APIClient.ResultPayload {
        guard let owner else {
            return APIClient.ResultPayload(ok: false, error: "runner state lost", data: nil)
        }
        let requestedBackend = (payload["backend"]?.value as? String) ?? "docker"
        switch requestedBackend {
        case "docker":
            guard owner.settings.dockerEnabled else {
                return APIClient.ResultPayload(
                    ok: false,
                    error: "docker capability disabled in runner settings",
                    data: nil
                )
            }
        case "utm":
            guard owner.settings.utmEnabled else {
                return APIClient.ResultPayload(
                    ok: false,
                    error: "utm capability disabled in runner settings",
                    data: nil
                )
            }
        default:
            return APIClient.ResultPayload(
                ok: false,
                error: "unsupported backend: \(requestedBackend)",
                data: nil
            )
        }
        guard let baseURL = URL(string: owner.settings.apiURL),
              let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            return APIClient.ResultPayload(
                ok: false,
                error: "runner missing apiURL or API key",
                data: nil
            )
        }
        let runnerHost = owner.settings.runnerHost.isEmpty ? nil : owner.settings.runnerHost
        let exec = SessionExecutor(
            runnerName: owner.settings.runnerName,
            runnerHost: runnerHost,
            api: APIClient(baseURL: baseURL, apiKey: apiKey)
        )
        return await exec.execute(payload: payload)
    }

    // MARK: - Status

    private func updateStatus(_ s: RunnerStatus, error: String?) {
        owner?.status = s
        owner?.lastError = error
        lastError = error
    }
}
