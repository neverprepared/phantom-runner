import Foundation

/// Standalone claim-side client for the /api/runners/pair/claim endpoint.
/// Separate from APIClient because pairing happens before we have an API key
/// — auth is the pairing token itself.
enum PairingClient {
    enum PairingError: Error, CustomStringConvertible {
        case invalidURL
        case http(status: Int, body: String)
        case transport(Error)
        case decoding(String)

        var description: String {
            switch self {
            case .invalidURL: return "invalid URL"
            case .http(404, _): return "token not found, expired, or already used"
            case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
            case .transport(let e): return "transport: \(e.localizedDescription)"
            case .decoding(let m): return "decode: \(m)"
            }
        }
    }

    struct ClaimResponse: Decodable {
        let apiKey: String
        let apiURL: String
        let runnerNameSuggestion: String

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case apiURL = "api_url"
            case runnerNameSuggestion = "runner_name_suggestion"
        }
    }

    static func claim(baseURL: URL, token: String) async throws -> ClaimResponse {
        guard let url = URL(string: "/api/runners/pair/claim", relativeTo: baseURL)?.absoluteURL else {
            throw PairingError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["token": token])

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw PairingError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw PairingError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PairingError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(ClaimResponse.self, from: data)
        } catch {
            throw PairingError.decoding("\(error)")
        }
    }
}
