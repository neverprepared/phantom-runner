import Foundation

/// Envelope is the wire shape POSTed to brainbox /api/agent_events.
/// Mirrors `brainbox/src/brainbox/agent_store.py:AgentEnvelope` and
/// `app/internal/outbox/outbox.go:Envelope`. Snake_case JSON keys match the
/// brainbox contract.
struct Envelope: Codable {
    let id: String
    let kind: String                 // "metric" | "event"
    let title: String
    var source: String?
    var type: String?
    var status: String?
    var subtitle: String?
    var workspace: String?
    var parent_id: String?
    var url: String?
    var start_at: Int64?
    var end_at: Int64?
    var tags: [String]?
    var metadata: [String: AnyCodableValue]?
    var actions: [[String: AnyCodableValue]]?
    var outcome: Outcome?

    struct Outcome: Codable {
        let ok: Bool
        let actor: String
        var error: String?
        var duration_ms: Int64?
    }

    init(
        id: String,
        kind: String = "event",
        title: String,
        source: String? = nil,
        type: String? = nil,
        status: String? = nil,
        subtitle: String? = nil,
        workspace: String? = nil,
        parent_id: String? = nil,
        url: String? = nil,
        start_at: Int64? = nil,
        end_at: Int64? = nil,
        tags: [String]? = nil,
        metadata: [String: AnyCodableValue]? = nil,
        actions: [[String: AnyCodableValue]]? = nil,
        outcome: Outcome? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.source = source
        self.type = type
        self.status = status
        self.subtitle = subtitle
        self.workspace = workspace
        self.parent_id = parent_id
        self.url = url
        self.start_at = start_at
        self.end_at = end_at
        self.tags = tags
        self.metadata = metadata
        self.actions = actions
        self.outcome = outcome
    }
}

/// AnyCodableValue is a small JSON-value type so envelope metadata can hold
/// arbitrary primitives without sprinkling AnyEncodable through the codebase.
/// Supports nil, bool, int, double, string, [AnyCodableValue],
/// [String: AnyCodableValue].
enum AnyCodableValue: Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyCodableValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyCodableValue].self) { self = .object(o); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Convenience constructors for common types.
    static func of(_ s: String) -> AnyCodableValue { .string(s) }
    static func of(_ i: Int) -> AnyCodableValue { .int(Int64(i)) }
    static func of(_ i: Int64) -> AnyCodableValue { .int(i) }
    static func of(_ b: Bool) -> AnyCodableValue { .bool(b) }
    static func of(_ d: Double) -> AnyCodableValue { .double(d) }
}
