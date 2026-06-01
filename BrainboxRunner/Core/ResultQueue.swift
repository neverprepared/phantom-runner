import Foundation
import OSLog

/// Durable queue for work results that couldn't be delivered to the API
/// (network outage, API restart). Results are persisted to disk and retried
/// with exponential backoff on reconnect and on each heartbeat tick.
actor ResultQueue {
    struct Pending: Codable {
        let id: String
        let runnerName: String
        let workID: String
        let jsonData: Data       // pre-encoded ResultPayload JSON
        let enqueuedAt: Double   // epoch seconds
        var attempts: Int
        var nextRetryAt: Double  // epoch seconds
    }

    private var items: [String: Pending] = [:]
    private let fileURL: URL
    private let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "result-queue")

    // Retry schedule: 5s, 15s, 60s, 5m, 30m
    private static let retryDelays: [Double] = [5, 15, 60, 300, 1800]

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = support.appendingPathComponent(
            "com.neverprepared.BrainboxRunner", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        fileURL = dir.appendingPathComponent("result-queue.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Pending].self, from: data),
           !decoded.isEmpty {
            items = decoded
            // Logging here would race with actor isolation — drain() logs on first use
        }
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Enqueue a result that failed to deliver. `jsonData` is the
    /// JSONEncoder output of an `APIClient.ResultPayload`.
    func add(runnerName: String, workID: String, jsonData: Data) {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        items[id] = Pending(
            id: id,
            runnerName: runnerName,
            workID: workID,
            jsonData: jsonData,
            enqueuedAt: now,
            attempts: 0,
            nextRetryAt: now + Self.retryDelays[0]
        )
        persist()
        log.info("result queued: work=\(workID, privacy: .public) queue_depth=\(self.items.count)")
    }

    /// Attempt to deliver all items whose retry window has elapsed.
    /// Delivered items are removed; failed items get a longer backoff.
    func drain(client: APIClient) async {
        let now = Date().timeIntervalSince1970
        let ready = items.values.filter { $0.nextRetryAt <= now }
        guard !ready.isEmpty else { return }
        log.info("draining \(ready.count) queued result(s)")

        for var pending in ready {
            do {
                try await client.postResultRaw(
                    runnerName: pending.runnerName,
                    workID: pending.workID,
                    jsonData: pending.jsonData
                )
                items.removeValue(forKey: pending.id)
                log.info("delivered deferred result: work=\(pending.workID, privacy: .public)")
            } catch {
                pending.attempts += 1
                let delay = Self.retryDelays[min(pending.attempts, Self.retryDelays.count - 1)]
                pending.nextRetryAt = now + delay
                items[pending.id] = pending
                log.warning("deferred result retry \(pending.attempts) failed work=\(pending.workID, privacy: .public) next_retry=\(Int(delay))s")
            }
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
