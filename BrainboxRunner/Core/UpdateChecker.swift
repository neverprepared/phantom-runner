import AppKit
import Foundation
import os.log

private let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "update")

enum UpdateError: LocalizedError {
    case noAsset
    case mountFailed(String)
    case appNotFound
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAsset: return "No DMG asset found in the release."
        case .mountFailed(let s): return "Failed to mount update: \(s)"
        case .appNotFound: return "BrainboxRunner.app not found in DMG."
        case .installFailed(let s): return "Install failed: \(s)"
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, assetID: Int, notes: String)
        case downloading
        case error(String)
    }

    @Published var state: State = .idle

    private var client: APIClient?
    private var periodicTask: Task<Void, Never>?

    func configure(client: APIClient, autoUpdate: Bool) {
        self.client = client
        periodicTask?.cancel()
        if autoUpdate {
            periodicTask = Task { [weak self] in
                // Check on startup after a short delay (let registration settle).
                try? await Task.sleep(for: .seconds(10))
                await self?.check()
                // Then every 6 hours.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(6 * 3600))
                    await self?.check()
                }
            }
        }
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    func check() async {
        guard let client else { return }
        state = .checking
        do {
            let latest = try await client.runnerLatest()
            guard let remoteVersion = latest.version, let assetID = latest.asset_id else {
                state = .upToDate
                return
            }
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if isNewer(remoteVersion, than: current) {
                state = .available(version: remoteVersion, assetID: assetID, notes: latest.notes ?? "")
                log.info("Update available: \(remoteVersion, privacy: .public)")
            } else {
                state = .upToDate
            }
        } catch {
            state = .error(error.localizedDescription)
            log.error("Update check failed: \(error, privacy: .public)")
        }
    }

    func installAndRestart(assetID: Int) async {
        guard let client else { return }
        state = .downloading
        do {
            log.info("Downloading update asset \(assetID, privacy: .public)")
            let data = try await client.runnerAsset(assetID: assetID)
            try await applyUpdate(dmgData: data)
        } catch {
            state = .error(error.localizedDescription)
            log.error("Update install failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Install

    private func applyUpdate(dmgData: Data) async throws {
        let tmp = FileManager.default.temporaryDirectory
        let dmgPath = tmp.appendingPathComponent("BrainboxRunner-update-\(UUID().uuidString).dmg")
        try dmgData.write(to: dmgPath)

        // Mount the DMG.
        let mountPoint = tmp.appendingPathComponent("BrainboxRunner-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attachResult = shell("/usr/bin/hdiutil attach '\(dmgPath.path)' -mountpoint '\(mountPoint.path)' -nobrowse -quiet")
        guard attachResult == 0 else {
            throw UpdateError.mountFailed("hdiutil exit \(attachResult)")
        }

        // Find the .app inside the mounted volume.
        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appInDMG = contents.first(where: { $0.pathExtension == "app" }) else {
            _ = shell("/usr/bin/hdiutil detach '\(mountPoint.path)' -quiet")
            throw UpdateError.appNotFound
        }

        // Current bundle location — replace in-place.
        let destination = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        // Write a self-deleting updater script that runs after we quit.
        let scriptPath = tmp.appendingPathComponent("brainbox-runner-update.sh").path
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(destination)"
        cp -R "\(appInDMG.path)" "\(destination)"
        /usr/bin/hdiutil detach "\(mountPoint.path)" -quiet 2>/dev/null || true
        rm -f "\(dmgPath.path)"
        open "\(destination)"
        rm -- "$0"
        """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // Launch script detached so it outlives us.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath]
        try proc.run()

        log.info("Updater script launched — quitting for replacement")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    /// Returns true if `remote` is strictly newer than `current` using semver
    /// component comparison (major.minor.patch). Falls back to string compare.
    private func isNewer(_ remote: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").compactMap { Int($0) } }
        let r = parts(remote), c = parts(current)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    @discardableResult
    private func shell(_ command: String) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
