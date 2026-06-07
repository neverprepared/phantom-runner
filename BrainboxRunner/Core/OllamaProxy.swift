import Foundation
import Network
import Security
import os.log

private let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "ollama-proxy")

/// Local HTTPS proxy that fronts a localhost-bound Ollama. Lets the brainbox
/// API connect back over the LAN without requiring Ollama itself to be bound
/// to 0.0.0.0. Authenticates incoming requests against the runner's API key
/// (same secret used to talk to brainbox).
///
/// - TLS uses a self-signed cert generated on first start via openssl and
///   persisted in Application Support. Brainbox connects with verify=off
///   (identity is gated by X-API-Key, not the cert).
/// - The proxy is a byte-pump: read enough of the inbound request to grab
///   headers, check X-API-Key, then forward the rest to localhost Ollama
///   verbatim and stream the response back. No HTTP semantics on the wire
///   beyond header parsing, so streaming endpoints (chat, pull) work as-is.
@MainActor
final class OllamaProxy: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case error(String)
    }

    @Published private(set) var state: State = .stopped

    private var listener: NWListener?
    private var apiKey: String = ""
    private var upstreamPort: Int = 11434

    func start(port: UInt16, apiKey: String, ollamaPort: Int) {
        stop()
        guard !apiKey.isEmpty else {
            state = .error("API key required")
            return
        }
        self.apiKey = apiKey
        self.upstreamPort = ollamaPort
        state = .starting

        do {
            let identity = try OllamaProxy.loadOrCreateIdentity()
            let tlsOptions = NWProtocolTLS.Options()
            guard let secIdentity = sec_identity_create(identity) else {
                throw NSError(domain: "OllamaProxy", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
            }
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)

            let params = NWParameters(tls: tlsOptions, tcp: .init())
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw NSError(domain: "OllamaProxy", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "invalid port"])
            }
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                Task.detached { [weak self] in
                    guard let self else { conn.cancel(); return }
                    let key = await self.apiKey
                    let upstream = await self.upstreamPort
                    await OllamaProxy.handleConnection(conn, apiKey: key, ollamaPort: upstream)
                }
            }
            l.stateUpdateHandler = { [weak self] s in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch s {
                    case .ready: self.state = .running(port: port)
                    case .failed(let err): self.state = .error(err.localizedDescription)
                    case .cancelled: self.state = .stopped
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            self.listener = l
            log.info("ollama-proxy starting on port \(port, privacy: .public) → 127.0.0.1:\(ollamaPort, privacy: .public)")
        } catch {
            state = .error(error.localizedDescription)
            log.error("ollama-proxy start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    // MARK: - Per-connection handling

    private static func handleConnection(_ conn: NWConnection, apiKey: String, ollamaPort: Int) async {
        conn.start(queue: .global(qos: .userInitiated))

        // Read until we've buffered the full request headers (\r\n\r\n).
        guard let buffered = await readUntilHeaders(conn) else { conn.cancel(); return }
        let headerEnd = buffered.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))!.upperBound
        let headersOnly = buffered.subdata(in: 0..<headerEnd)

        // Authenticate.
        let headerStr = String(data: headersOnly, encoding: .utf8) ?? ""
        if !verifyAPIKey(in: headerStr, expected: apiKey) {
            await send(conn, string: "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            conn.cancel()
            return
        }

        // Open upstream to localhost Ollama.
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(ollamaPort)) else { conn.cancel(); return }
        let upstream = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: .tcp)
        upstream.start(queue: .global(qos: .userInitiated))

        // Replay the bytes we already consumed (headers + any partial body).
        await sendData(upstream, buffered)

        // Bidirectional byte pump until either side closes.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(from: conn, to: upstream) }
            group.addTask { await pump(from: upstream, to: conn) }
        }
        conn.cancel()
        upstream.cancel()
    }

    private static func readUntilHeaders(_ conn: NWConnection) async -> Data? {
        var buf = Data()
        let limit = 64 * 1024
        while buf.count < limit {
            guard let chunk = await receive(conn, max: 4096) else { return nil }
            if chunk.isEmpty { return nil }
            buf.append(chunk)
            if buf.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) != nil { return buf }
        }
        return nil
    }

    private static func receive(_ conn: NWConnection, max: Int) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error { _ = error; cont.resume(returning: nil); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: nil); return }
                cont.resume(returning: nil)
            }
        }
    }

    private static func sendData(_ conn: NWConnection, _ data: Data) async {
        await withCheckedContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    private static func send(_ conn: NWConnection, string: String) async {
        guard let data = string.data(using: .utf8) else { return }
        await sendData(conn, data)
    }

    private static func pump(from src: NWConnection, to dst: NWConnection) async {
        while true {
            guard let chunk = await receive(src, max: 16 * 1024) else { return }
            if chunk.isEmpty { return }
            await sendData(dst, chunk)
        }
    }

    private static func verifyAPIKey(in headers: String, expected: String) -> Bool {
        for line in headers.split(separator: "\r\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "x-api-key" {
                return value == expected
            }
        }
        return false
    }

    // MARK: - Self-signed identity

    private static func identityDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("BrainboxRunner", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // SecPKCS12Import on macOS rejects empty passphrases. We use a fixed
    // local secret for both export and import — the p12 sits in the user's
    // Application Support with default file perms; the passphrase here just
    // makes the import API happy. Not a security boundary.
    private static let p12Passphrase = "brainbox-runner-proxy"

    private static func loadOrCreateIdentity() throws -> SecIdentity {
        let dir = try identityDirectory()
        let p12 = dir.appendingPathComponent("proxy.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            let key = dir.appendingPathComponent("proxy.key")
            let crt = dir.appendingPathComponent("proxy.crt")
            try generateSelfSigned(key: key, cert: crt, p12: p12)
            // Clean up the loose PEM files — the p12 has everything we need.
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: crt)
        }
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Passphrase]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let raw = first[kSecImportItemIdentity as String]
        else {
            // If the p12 on disk was generated with the old empty passphrase,
            // wipe it and try again next launch.
            try? FileManager.default.removeItem(at: p12)
            throw NSError(domain: "OllamaProxy", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "PKCS12Import failed (\(status))"])
        }
        let identity = raw as! SecIdentity
        return identity
    }

    private static func generateSelfSigned(key: URL, cert: URL, p12: URL) throws {
        let openssl = "/usr/bin/openssl"
        let req = Process()
        req.executableURL = URL(fileURLWithPath: openssl)
        req.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key.path, "-out", cert.path,
            "-days", "3650",
            "-subj", "/CN=brainbox-runner",
        ]
        try req.run()
        req.waitUntilExit()
        guard req.terminationStatus == 0 else {
            throw NSError(domain: "OllamaProxy", code: Int(req.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl req failed"])
        }
        let pkcs = Process()
        pkcs.executableURL = URL(fileURLWithPath: openssl)
        pkcs.arguments = [
            "pkcs12", "-export", "-out", p12.path,
            "-inkey", key.path, "-in", cert.path,
            "-passout", "pass:\(p12Passphrase)",
            "-name", "brainbox-runner",
        ]
        try pkcs.run()
        pkcs.waitUntilExit()
        guard pkcs.terminationStatus == 0 else {
            throw NSError(domain: "OllamaProxy", code: Int(pkcs.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl pkcs12 failed"])
        }
    }
}
