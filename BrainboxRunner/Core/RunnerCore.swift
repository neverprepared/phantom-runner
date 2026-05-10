import Foundation
import OSLog

/// Owns the registration + long-poll loop. Lives on the main actor so menu-bar
/// status updates are free; URLSession calls are async and don't block the UI.
@MainActor
final class RunnerCore {
    weak var owner: AppState?
    private let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "core")

    private var pollTask: Task<Void, Never>?
    private var paused: Bool = false
    private var lastError: String?

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
        let caps: [String: Bool] = [
            "docker": settings.dockerEnabled,
            "utm": settings.utmEnabled,
        ]
        let tags = settings.tags
        paused = false

        pollTask = Task { [weak self] in
            await self?.loop(client: client, name: name, caps: caps, tags: tags)
        }
    }

    func stop() async {
        if let task = pollTask {
            task.cancel()
            _ = await task.value
            pollTask = nil
        }
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
        caps: [String: Bool],
        tags: [String]
    ) async {
        // Phase 1: register, with retry on transport failure.
        let register = APIClient.RegisterRequest(
            name: name,
            capabilities: caps,
            tags: tags,
            version: "0.1.0"
        )
        while !Task.isCancelled {
            do {
                _ = try await client.register(register)
                updateStatus(.connected, error: nil)
                log.info("registered as \(name, privacy: .public)")
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

        // Phase 2: long-poll for work.
        while !Task.isCancelled {
            if paused {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            do {
                let work = try await client.pollPending(runnerName: name)
                guard let work else { continue }
                log.info("work received id=\(work.id, privacy: .public) kind=\(work.kind, privacy: .public)")
                updateStatus(.busy, error: nil)
                let result = await handle(work: work)
                do {
                    try await client.postResult(runnerName: name, workID: work.id, result: result)
                } catch {
                    log.error("result post failed: \(String(describing: error), privacy: .public)")
                }
                updateStatus(paused ? .paused : .connected, error: nil)
            } catch APIClient.APIError.unauthorized {
                updateStatus(.disconnected, error: "unauthorized")
                log.error("poll: unauthorized")
                return
            } catch {
                // Network blip — degrade to disconnected briefly, then retry.
                updateStatus(.disconnected, error: "poll: \(error)")
                log.warning("poll failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // Try to bounce back to connected by re-pinging on next loop.
                if Task.isCancelled { return }
                updateStatus(.connected, error: nil)
            }
        }
    }

    /// Dispatch a work item to the matching executor. R5 wires
    /// session.create through DockerDriver + SessionExecutor; UTM/start/stop
    /// kinds remain stubs until later phases.
    private func handle(work: APIClient.WorkItem) async -> APIClient.ResultPayload {
        switch work.kind {
        case "session.create":
            return await handleSessionCreate(payload: work.payload)
        default:
            return APIClient.ResultPayload(
                ok: false,
                error: "runner not yet implemented for kind: \(work.kind)",
                data: nil
            )
        }
    }

    private func handleSessionCreate(
        payload: [String: AnyDecodable]
    ) async -> APIClient.ResultPayload {
        guard let owner else {
            return APIClient.ResultPayload(ok: false, error: "runner state lost", data: nil)
        }
        guard owner.settings.dockerEnabled else {
            return APIClient.ResultPayload(
                ok: false,
                error: "docker capability disabled in runner settings",
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
        let exec = SessionExecutor(
            runnerName: owner.settings.runnerName,
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
