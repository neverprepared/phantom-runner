import Foundation
import OSLog

/// Durable queue for agent-event-bus envelopes that couldn't be delivered to
/// brainbox (network outage, API restart). Mirrors the pattern in
/// `ResultQueue`: envelopes are persisted to disk and retried on each drain.
///
/// At-least-once delivery is safe because brainbox dedupes by envelope `id`
/// in agent_state (and the audit log accepts repeats by design).
actor EnvelopeQueue {
    struct Pending: Codable {
        let id: String
        let envelopeJSON: Data
        let enqueuedAt: Double
        var attempts: Int
        var nextRetryAt: Double
    }

    private var items: [String: Pending] = [:]
    private let fileURL: URL
    private let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "envelope-queue")

    /// Retry schedule: 5s, 15s, 60s, 5m, 30m — same shape as ResultQueue.
    private static let retryDelays: [Double] = [5, 15, 60, 300, 1800]

    /// Batch ceiling per drain call. Bursts of envelopes (e.g. on reconnect
    /// after a long outage) ship in chunks so the POST stays small.
    private static let batchSize = 50

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
        fileURL = dir.appendingPathComponent("envelope-queue.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Pending].self, from: data),
           !decoded.isEmpty {
            items = decoded
        }
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Enqueue an envelope for delivery. Always queues — the caller does not
    /// distinguish "tried and failed" from "queued"; the drain loop is the
    /// single delivery path so ordering and retries stay consistent.
    func append(_ envelope: Envelope) {
        guard let data = try? JSONEncoder().encode(envelope) else {
            log.warning("failed to encode envelope id=\(envelope.id, privacy: .public)")
            return
        }
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        items[id] = Pending(
            id: id,
            envelopeJSON: data,
            enqueuedAt: now,
            attempts: 0,
            nextRetryAt: now    // immediately eligible
        )
        persist()
    }

    /// Attempt to deliver all envelopes whose retry window has elapsed, in
    /// batches of `batchSize`. Failed batches bump attempts on every row.
    func drain(client: APIClient) async {
        let now = Date().timeIntervalSince1970
        var ready = items.values.filter { $0.nextRetryAt <= now }
        guard !ready.isEmpty else { return }
        // Stable order: oldest first.
        ready.sort { $0.enqueuedAt < $1.enqueuedAt }
        log.info("draining \(ready.count) queued envelope(s)")

        var index = 0
        while index < ready.count {
            let batch = Array(ready[index..<min(index + Self.batchSize, ready.count)])
            let envelopeData = batch.map { $0.envelopeJSON }
            do {
                try await client.postEnvelopeBatch(envelopeData)
                for pending in batch {
                    items.removeValue(forKey: pending.id)
                }
                log.info("delivered envelope batch size=\(batch.count)")
            } catch {
                let now = Date().timeIntervalSince1970
                for var pending in batch {
                    pending.attempts += 1
                    let delay = Self.retryDelays[min(pending.attempts, Self.retryDelays.count - 1)]
                    pending.nextRetryAt = now + delay
                    items[pending.id] = pending
                }
                log.warning("envelope batch retry pending: \(String(describing: error), privacy: .public)")
                break // back off; next drain handles remaining batches
            }
            index += Self.batchSize
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
