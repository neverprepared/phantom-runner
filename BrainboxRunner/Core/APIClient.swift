import Foundation

/// Thin URLSession wrapper for the runner-facing brainbox API endpoints.
/// Authentication is `X-API-Key`. Long-poll calls use a longer URLSession
/// timeout than other requests.
struct APIClient {
    let baseURL: URL
    let apiKey: String

    enum APIError: Error, CustomStringConvertible {
        case invalidURL
        case unauthorized
        case http(status: Int, body: String)
        case decoding(String)
        case transport(Error)

        var description: String {
            switch self {
            case .invalidURL: return "invalid URL"
            case .unauthorized: return "unauthorized (check API key)"
            case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
            case .decoding(let m): return "decode: \(m)"
            case .transport(let e): return "transport: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Endpoints

    struct RegisterRequest: Encodable {
        let name: String
        let capabilities: [String: Bool]
        let tags: [String]
        let version: String
        /// Advertised host/IP for this runner machine. Sent to the API so it
        /// can build correct ttyd URLs for remote sessions.
        let host: String?
        /// Stable UUID for this machine. Allows the API to rename an existing
        /// runner when the user changes the name in Settings instead of
        /// creating a duplicate entry.
        let machine_id: String?
        /// Ollama port advertised when capabilities["ollama"] is true. The API
        /// uses this to add the runner to its Ollama instance pool.
        let ollama_port: Int?
    }

    struct RegisterResponse: Decodable {
        let ok: Bool
        let poll_interval: Int?
    }

    func register(_ req: RegisterRequest) async throws -> RegisterResponse {
        try await postJSON(path: "/api/runners/register", body: req, timeout: 10)
    }

    struct RunnerLatestResponse: Decodable {
        let version: String?
        let tag: String?
        let asset_id: Int?
        let asset_name: String?
        let published_at: String?
        let notes: String?
    }

    func runnerLatest() async throws -> RunnerLatestResponse {
        try await getJSON(path: "/api/runner/latest", timeout: 15)
    }

    /// Download a release asset via the brainbox proxy. Returns raw DMG bytes.
    func runnerAsset(assetID: Int) async throws -> Data {
        try await getData(path: "/api/runner/asset/\(assetID)", timeout: 300)
    }

    struct WorkItem: Decodable {
        let id: String
        let kind: String
        let payload: [String: AnyDecodable]
    }

    /// Long-poll. Returns nil on 204 (no work).
    func pollPending(runnerName: String) async throws -> WorkItem? {
        let url = try buildURL("/api/runners/\(percentEncoded(runnerName))/pending")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        let (data, resp) = try await session(timeout: 40).data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
        if http.statusCode == 204 { return nil }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(WorkItem.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    struct ResultPayload: Encodable {
        let ok: Bool
        let error: String?
        let data: [String: AnyEncodable]?
    }

    func postResult(runnerName: String, workID: String, result: ResultPayload) async throws {
        let path = "/api/runners/\(percentEncoded(runnerName))/result/\(percentEncoded(workID))"
        let _: EmptyResponse = try await postJSON(path: path, body: result, timeout: 30)
    }

    /// Post a pre-encoded JSON payload as a result. Used by ResultQueue when
    /// retrying deferred results whose payload was serialised before the outage.
    func postResultRaw(runnerName: String, workID: String, jsonData: Data) async throws {
        let path = "/api/runners/\(percentEncoded(runnerName))/result/\(percentEncoded(workID))"
        let url = try buildURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
        req.httpBody = jsonData
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session(timeout: 30).data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    struct HeartbeatRequest: Encodable {
        let in_flight: Int
        let max_concurrent: Int
    }

    func heartbeat(runnerName: String, inFlight: Int, maxConcurrent: Int) async throws {
        let path = "/api/runners/\(percentEncoded(runnerName))/heartbeat"
        let body = HeartbeatRequest(in_flight: inFlight, max_concurrent: maxConcurrent)
        let _: EmptyResponse = try await postJSON(path: path, body: body, timeout: 10)
    }

    struct EventPayload: Encodable {
        let message: String
        let session: String?
    }

    /// Post a status event (e.g. image pull progress) to be broadcast to SSE clients.
    /// Failures are silently swallowed — this is best-effort telemetry.
    func postEvent(runnerName: String, message: String, session: String? = nil) async {
        let body = EventPayload(message: message, session: session)
        let path = "/api/runners/\(percentEncoded(runnerName))/event"
        let _: EmptyResponse? = try? await postJSON(path: path, body: body, timeout: 5)
    }

    /// Quick reachability check — used by the Settings "Test connection" button.
    /// Hits the runners list endpoint with the configured key.
    func ping() async throws {
        let url = try buildURL("/api/runners")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        let (data, resp) = try await session(timeout: 8).data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Helpers

    private struct EmptyResponse: Decodable {}

    func getJSON<Resp: Decodable>(path: String, timeout: TimeInterval) async throws -> Resp {
        let url = try buildURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session(timeout: timeout).data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    func getData(path: String, timeout: TimeInterval) async throws -> Data {
        let url = try buildURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session(timeout: timeout).data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: "")
        }
        return data
    }

    private func postJSON<Body: Encodable, Resp: Decodable>(
        path: String, body: Body, timeout: TimeInterval
    ) async throws -> Resp {
        let url = try buildURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session(timeout: timeout).data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        if Resp.self == EmptyResponse.self {
            // Body may be empty or JSON — caller doesn't care.
            return EmptyResponse() as! Resp
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    private func buildURL(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }
        return url
    }

    private func addAuth(_ req: inout URLRequest) {
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    }

    private func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    private func percentEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

// MARK: - Type-erased JSON values

/// Type-erased Decodable for arbitrary JSON values inside a work item's payload.
struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            value = b
        } else if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let arr = try? c.decode([AnyDecodable].self) {
            value = arr.map(\.value)
        } else if let obj = try? c.decode([String: AnyDecodable].self) {
            value = obj.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }
}

/// Type-erased Encodable for the result payload's `data` field. Accepts
/// Strings, numbers, bools, [Any], [String: Any], and NSNull.
struct AnyEncodable: Encodable {
    let value: Any

    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyEncodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyEncodable.init))
        default:
            try c.encodeNil()
        }
    }
}
