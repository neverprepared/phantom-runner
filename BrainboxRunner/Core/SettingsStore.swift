import Foundation

/// UserDefaults-backed persistent settings. The API key is intentionally
/// NOT here — it lives in the Keychain (see KeychainStore).
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let apiURL = "apiURL"
        static let runnerName = "runnerName"
        static let tags = "tags"
        static let dockerEnabled = "capabilities.docker.enabled"
        static let utmEnabled = "capabilities.utm.enabled"
        static let maxConcurrent = "maxConcurrent"
        static let launchAtLogin = "launchAtLogin"
        static let logVerbose = "logVerbose"
    }

    @Published var apiURL: String {
        didSet { UserDefaults.standard.set(apiURL, forKey: Key.apiURL) }
    }
    @Published var runnerName: String {
        didSet { UserDefaults.standard.set(runnerName, forKey: Key.runnerName) }
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
    @Published var maxConcurrent: Int {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: Key.maxConcurrent) }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published var logVerbose: Bool {
        didSet { UserDefaults.standard.set(logVerbose, forKey: Key.logVerbose) }
    }

    init() {
        let d = UserDefaults.standard
        self.apiURL = d.string(forKey: Key.apiURL) ?? "http://127.0.0.1:9999"
        self.runnerName = d.string(forKey: Key.runnerName) ?? Host.current().localizedName ?? "runner"
        self.tags = (d.array(forKey: Key.tags) as? [String]) ?? []
        // Capability detection (real probes) lives in R3; for R2 default to
        // both on so the UI behaves sensibly when a real connection lands.
        self.dockerEnabled = d.object(forKey: Key.dockerEnabled) as? Bool ?? true
        self.utmEnabled = d.object(forKey: Key.utmEnabled) as? Bool ?? true
        self.maxConcurrent = d.integer(forKey: Key.maxConcurrent) > 0
            ? d.integer(forKey: Key.maxConcurrent) : 1
        self.launchAtLogin = d.bool(forKey: Key.launchAtLogin)
        self.logVerbose = d.bool(forKey: Key.logVerbose)
    }
}
