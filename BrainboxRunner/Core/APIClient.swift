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
    }

    struct RegisterResponse: Decodable {
        let ok: Bool
        let poll_interval: Int?
    }

    func register(_ req: RegisterRequest) async throws -> RegisterResponse {
        try await postJSON(path: "/api/runners/register", body: req, timeout: 10)
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

    struct SealRequestBody: Encodable {
        let workspace_profile: String?
        let workspace_home: String?
        let recipient: String
        let timeout: Int
    }

    /// Ask the central API to seal a credential bundle for the given recipient
    /// pubkey. Blocks until the laptop's cc poll daemon (or inline seal, if
    /// the API is on the laptop) posts the ciphertext back. Returns the
    /// sealed bundle bytes.
    func sealRequest(
        workspaceProfile: String?,
        workspaceHome: String?,
        recipient: String,
        timeoutSeconds: Int = 90
    ) async throws -> Data {
        let url = try buildURL("/api/credentials/seal-request")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
        let body = SealRequestBody(
            workspace_profile: workspaceProfile,
            workspace_home: workspaceHome,
            recipient: recipient,
            timeout: timeoutSeconds
        )
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session(timeout: TimeInterval(timeoutSeconds + 10)).data(for: req)
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
        return data
    }

    // MARK: - Secret authority (credential queue) endpoints

    struct PendingCredentialRequest: Decodable {
        let id: String
        let workspace_profile: String?
        let workspace_home: String?
        let recipient: String
    }

    /// Long-poll for the next pending credential request when this agent
    /// is acting as the secret authority. Returns nil on 204 (no work
    /// within the server's poll window — call again).
    /// `as:` identifies us so the API can touch last_seen for the
    /// secret_authority capability.
    func pollPendingCredentialRequest(as runnerName: String) async throws -> PendingCredentialRequest? {
        var components = URLComponents(
            url: try buildURL("/api/credentials/pending"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "as", value: runnerName)]
        guard let url = components?.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        let (data, resp) = try await session(timeout: 40).data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 204 { return nil }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(PendingCredentialRequest.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    /// Post sealed ciphertext back to the API to fulfill a credential
    /// request. Body is the raw bytes.
    func postSealedCredentials(requestID: String, sealed: Data) async throws {
        let url = try buildURL("/api/credentials/\(percentEncoded(requestID))/sealed")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
        req.httpBody = sealed
        let (data, resp) = try await session(timeout: 30).data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
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
