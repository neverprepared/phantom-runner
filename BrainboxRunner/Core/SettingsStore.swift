import Foundation
import Darwin  // getifaddrs

/// UserDefaults-backed persistent settings. The API key is intentionally
/// NOT here — it lives in the Keychain (see KeychainStore).
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let apiURL = "apiURL"
        static let runnerName = "runnerName"
        static let runnerHost = "runnerHost"
        static let tags = "tags"
        static let dockerEnabled = "capabilities.docker.enabled"
        static let utmEnabled = "capabilities.utm.enabled"
        static let ollamaEnabled = "capabilities.ollama.enabled"
        static let autoUpdate = "autoUpdate"
        static let maxConcurrent = "maxConcurrent"
        static let launchAtLogin = "launchAtLogin"
        static let logVerbose = "logVerbose"
        static let machineID = "machineID"
        static let ollamaProxyPort = "ollamaProxyPort"
    }

    @Published var apiURL: String {
        didSet { UserDefaults.standard.set(apiURL, forKey: Key.apiURL) }
    }
    @Published var runnerName: String {
        didSet { UserDefaults.standard.set(runnerName, forKey: Key.runnerName) }
    }
    /// The IP or hostname this machine is reachable at from the API server's
    /// network. Sent on register so the API can build correct ttyd URLs.
    /// Auto-detected from the primary LAN interface on first launch; editable.
    @Published var runnerHost: String {
        didSet { UserDefaults.standard.set(runnerHost, forKey: Key.runnerHost) }
    }
    @Published var tags: [String] {
        didSet { UserDefaults.standard.set(tags, forKey: Key.tags) }
    }
    @Published var dockerEnabled: Bool {
        didSet { UserDefaults.standard.set(dockerEnabled, forKey: Key.dockerEnabled) }
    }
    @Published var utmEnabled: Bool {
        didSet { UserDefaults.standard.set(utmEnabled, forKey: Key.utmEnabled) }
    }
    @Published var ollamaEnabled: Bool {
        didSet { UserDefaults.standard.set(ollamaEnabled, forKey: Key.ollamaEnabled) }
    }
    @Published var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: Key.autoUpdate) }
    }
    @Published var maxConcurrent: Int {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: Key.maxConcurrent) }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published var logVerbose: Bool {
        didSet { UserDefaults.standard.set(logVerbose, forKey: Key.logVerbose) }
    }
    /// Port the local Ollama HTTPS proxy listens on. Brainbox connects to
    /// `https://<runnerHost>:<ollamaProxyPort>` and the runner forwards to
    /// 127.0.0.1:11434.
    @Published var ollamaProxyPort: Int {
        didSet { UserDefaults.standard.set(ollamaProxyPort, forKey: Key.ollamaProxyPort) }
    }

    /// Stable UUID for this machine. Generated once on first launch, never changes.
    /// Sent to the API on register so it can rename an existing runner instead of
    /// creating a duplicate when the user changes the runner name in Settings.
    let machineID: String

    init() {
        let d = UserDefaults.standard
        // Stable machine ID — generate once, persist forever.
        if let stored = d.string(forKey: Key.machineID), !stored.isEmpty {
            self.machineID = stored
        } else {
            let id = UUID().uuidString
            d.set(id, forKey: Key.machineID)
            self.machineID = id
        }
        self.apiURL = d.string(forKey: Key.apiURL) ?? "http://127.0.0.1:9999"
        self.runnerName = d.string(forKey: Key.runnerName) ?? Host.current().localizedName ?? "runner"
        // Use stored host, or auto-detect on first launch (empty string = same-host).
        self.runnerHost = d.string(forKey: Key.runnerHost) ?? SettingsStore.detectLANIP() ?? ""
        self.tags = (d.array(forKey: Key.tags) as? [String]) ?? []
        self.dockerEnabled = d.object(forKey: Key.dockerEnabled) as? Bool ?? true
        self.utmEnabled = d.object(forKey: Key.utmEnabled) as? Bool ?? true
        self.ollamaEnabled = d.object(forKey: Key.ollamaEnabled) as? Bool ?? true
        self.autoUpdate = d.object(forKey: Key.autoUpdate) as? Bool ?? true
        self.maxConcurrent = d.integer(forKey: Key.maxConcurrent) > 0
            ? d.integer(forKey: Key.maxConcurrent) : 1
        self.launchAtLogin = d.bool(forKey: Key.launchAtLogin)
        self.logVerbose = d.bool(forKey: Key.logVerbose)
        self.ollamaProxyPort = d.integer(forKey: Key.ollamaProxyPort) > 0
            ? d.integer(forKey: Key.ollamaProxyPort) : 11435
    }

    /// Detect the primary LAN IPv4 address. Prefers en0 (Wi-Fi / Ethernet on
    /// Apple Silicon), then the first non-loopback IPv4 interface. Returns nil
    /// when no suitable interface is found (e.g. no network connection).
    static func detectLANIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(iface: String, ip: String)] = []
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(NI_MAXHOST),
                        nil, 0, NI_NUMERICHOST)
            candidates.append((name, String(cString: host)))
        }
        // Prefer en0 (primary interface on Mac), then en1, then anything else.
        return candidates.first(where: { $0.iface == "en0" })?.ip
            ?? candidates.first(where: { $0.iface.hasPrefix("en") })?.ip
            ?? candidates.first?.ip
    }

    /// Probe Ollama on localhost — the proxy forwards there. Returns the
    /// detected port (11434) when reachable, nil otherwise.
    static func detectLocalOllamaPort() async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:11434/") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if (response as? HTTPURLResponse)?.statusCode == 200 { return 11434 }
        } catch {}
        return nil
    }

    /// Detect the Tailscale IPv4 address if Tailscale is running. Tailscale
    /// assigns addresses in the 100.64.0.0/10 CGNAT range on a utun interface.
    static func detectTailscaleIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(NI_MAXHOST),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            // 100.64.0.0/10 covers 100.64.x.x – 100.127.x.x
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4, parts[0] == 100, parts[1] >= 64, parts[1] <= 127 {
                return ip
            }
        }
        return nil
    }
}
