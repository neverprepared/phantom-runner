import Foundation
import OSLog

enum CredentialCache {
    static let log = Logger(subsystem: "com.neverprepared.BrainboxRunner", category: "cred-cache")

    /// What to do given the fetch outcome and the current on-disk cache state.
    /// Pure — no I/O — so it is unit-testable. Encodes spec §6:
    ///  - fresh bytes            → replace cache and mount it
    ///  - authoritative none     → clear cache, mount nothing (revocation honored)
    ///  - broker unavailable     → mount the last-good cache IFF within max-age, else nothing
    enum CacheAction: Equatable { case writeAndMount, mountStale, clearAndSkip }

    static func decide(outcome: APIClient.BundleOutcome,
                       cacheAgeSeconds: TimeInterval?,
                       maxAgeSeconds: TimeInterval) -> CacheAction {
        switch outcome {
        case .bundle:      return .writeAndMount
        case .none:        return .clearAndSkip
        case .unavailable:
            guard let age = cacheAgeSeconds, age <= maxAgeSeconds else { return .clearAndSkip }
            return .mountStale
        }
    }

    /// Host cache dir for a profile: ~/.config/phantom-ink/brainbox/credentials/<profile>
    static func cacheDir(profile: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/phantom-ink/brainbox/credentials/\(profile)", isDirectory: true)
    }

    private static func ageSeconds(of dir: URL) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(mtime)
    }

    /// Fetch + apply the §6 decision. Returns docker volume tuples for the cred
    /// dirs now present in the cache (e.g. .azure, .aws), or [] when nothing to mount.
    static func materialize(profile: String, api: APIClient,
                            runnerName: String, maxAgeHours: Int) async -> [(String, String, String)] {
        let dir = cacheDir(profile: profile)
        let outcome = await api.fetchCredentialBundle(runnerName: runnerName, profile: profile)
        let action = decide(outcome: outcome,
                            cacheAgeSeconds: ageSeconds(of: dir),
                            maxAgeSeconds: TimeInterval(maxAgeHours) * 3600)
        switch action {
        case .writeAndMount:
            if case let .bundle(data) = outcome { writeAtomically(data, to: dir) }
        case .mountStale:
            log.warning("cred-cache: broker unavailable for \(profile, privacy: .public) — mounting last-good cache")
        case .clearAndSkip:
            try? FileManager.default.removeItem(at: dir)
            return []
        }
        return mountTuples(from: dir)
    }

    /// Untar the bundle into a temp dir, then atomically swap it into place.
    private static func writeAtomically(_ tarGz: Data, to dir: URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("credcache-\(UUID().uuidString)", isDirectory: true)
        let tarball = tmp.appendingPathComponent("bundle.tgz")
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try tarGz.write(to: tarball)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", tarball.path, "-C", tmp.path]
            try p.run(); p.waitUntilExit()
            try? fm.removeItem(at: tarball)
            guard p.terminationStatus == 0 else { log.error("cred-cache: tar failed"); return }
            // atomic-ish swap: remove old, move new into place
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir.deletingLastPathComponent(),
                                   withIntermediateDirectories: true, attributes: nil)
            try fm.moveItem(at: tmp, to: dir)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            log.error("cred-cache: write failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: tmp)
        }
    }

    /// Map each cred dir present in the cache to a docker -v tuple. The bundle's
    /// top-level entries are dot-dirs (.azure, .aws, ...) captured from the
    /// operator home; mount each to /home/developer/<name> read-only.
    private static func mountTuples(from dir: URL) -> [(String, String, String)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries
            .filter { $0.hasPrefix(".") }
            .map { (dir.appendingPathComponent($0).path, "/home/developer/\($0)", "ro") }
    }
}
