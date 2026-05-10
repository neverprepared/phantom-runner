import Foundation
import OSLog

/// AppleScript-driven UTM operations. Cribs from mcp-utm:
///   /Users/cdowning/workspaces/profiles/personal/code/mcp/mcp-utm
/// Same primitives — clone, set MAC, start, status, list — adapted to Swift.
enum UTMDriver {
    private static let log = Logger(subsystem: "com.neverprepared.brainbox-runner", category: "utm")

    enum UTMError: Error, CustomStringConvertible {
        case ipDiscoveryTimeout(mac: String)
        case statusTimeout(name: String, last: String)
        case scriptFailed(String)

        var description: String {
            switch self {
            case .ipDiscoveryTimeout(let m): return "no ARP entry for MAC \(m) after timeout"
            case .statusTimeout(let n, let l): return "VM \(n) never reached running (last status: \(l))"
            case .scriptFailed(let s): return s
            }
        }
    }

    // MARK: - Lifecycle

    static func list() throws -> [String] {
        let out = try AppleScriptRunner.run("""
            tell application "UTM"
                set names to {}
                repeat with vm in virtual machines
                    set end of names to name of vm
                end repeat
                set AppleScript's text item delimiters to "\n"
                set joined to names as text
                set AppleScript's text item delimiters to ""
                return joined
            end tell
        """)
        return out.split(separator: "\n").map(String.init)
    }

    /// Clone a VM. Returns when UTM has finished duplicating (osascript
    /// blocks until duplicate completes).
    static func clone(template: String, newName: String) throws {
        let t = AppleScriptRunner.escape(template)
        let n = AppleScriptRunner.escape(newName)
        _ = try AppleScriptRunner.run("""
            tell application "UTM"
                set tmpl to virtual machine named "\(t)"
                duplicate tmpl with properties {configuration:{name:"\(n)"}}
            end tell
        """, timeout: 300)
        log.info("cloned \(template, privacy: .public) → \(newName, privacy: .public)")
    }

    /// Generate a locally-administered MAC and write it into the VM's
    /// primary NIC. Returns the assigned MAC so the caller can ARP-poll for it.
    @discardableResult
    static func assignRandomMAC(name: String) throws -> String {
        let mac = generateMAC()
        let n = AppleScriptRunner.escape(name)
        _ = try AppleScriptRunner.run("""
            tell application "UTM"
                set vm to virtual machine named "\(n)"
                set conf to configuration of vm
                set nic to item 1 of (network interfaces of conf)
                set address of nic to "\(mac)"
                update configuration of vm with conf
            end tell
        """)
        return mac
    }

    static func start(name: String) throws {
        let n = AppleScriptRunner.escape(name)
        _ = try AppleScriptRunner.run("""
            tell application "UTM"
                set vm to virtual machine named "\(n)"
                start vm
            end tell
        """, timeout: 120)
    }

    static func stop(name: String) throws {
        let n = AppleScriptRunner.escape(name)
        _ = try AppleScriptRunner.run("""
            tell application "UTM"
                set vm to virtual machine named "\(n)"
                stop vm
            end tell
        """, timeout: 120)
    }

    static func remove(name: String) throws {
        let n = AppleScriptRunner.escape(name)
        _ = try AppleScriptRunner.run("""
            tell application "UTM"
                set vm to virtual machine named "\(n)"
                delete vm
            end tell
        """, timeout: 60)
    }

    static func status(name: String) throws -> String {
        let n = AppleScriptRunner.escape(name)
        return try AppleScriptRunner.run("""
            tell application "UTM"
                set vm to virtual machine named "\(n)"
                return status of vm as text
            end tell
        """, timeout: 15)
    }

    /// Block until status matches `target` or timeout. Polls every `pollEvery`.
    static func waitForStatus(
        name: String,
        target: String,
        timeout: TimeInterval = 120,
        pollEvery: TimeInterval = 2
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = (try? status(name: name)) ?? last
            if last == target { return last }
            try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
        throw UTMError.statusTimeout(name: name, last: last)
    }

    // MARK: - IP discovery (ARP table polling)

    /// Resolve a MAC to an IPv4 address by reading the system ARP table.
    /// Polls until found or timeout — typical wait for a fresh VM is a few
    /// seconds after `started` status.
    static func resolveIP(
        forMAC mac: String,
        timeout: TimeInterval = 60,
        pollEvery: TimeInterval = 2
    ) async throws -> String {
        let normalized = normalizeMAC(mac)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ip = arpLookup(normalized) {
                return ip
            }
            try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
        throw UTMError.ipDiscoveryTimeout(mac: normalized)
    }

    /// Returns the first IPv4 paired with `mac` in `arp -a` output, if any.
    private static func arpLookup(_ mac: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        proc.arguments = ["-a"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // Lines look like: "? (192.168.64.5) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]"
        for line in output.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains(mac.lowercased()) else { continue }
            if let openParen = line.firstIndex(of: "("),
               let closeParen = line.firstIndex(of: ")"),
               openParen < closeParen {
                let after = line.index(after: openParen)
                let ip = String(line[after..<closeParen])
                if ip.split(separator: ".").count == 4 {
                    return ip
                }
            }
        }
        return nil
    }

    /// Read the MAC of a VM's primary NIC (used when the caller didn't
    /// assign a fresh one).
    static func macAddress(name: String) throws -> String {
        let n = AppleScriptRunner.escape(name)
        let raw = try AppleScriptRunner.run("""
            tell application "UTM"
                set vm to virtual machine named "\(n)"
                set conf to configuration of vm
                set nic to item 1 of (network interfaces of conf)
                return address of nic as text
            end tell
        """, timeout: 15)
        return normalizeMAC(raw)
    }

    // MARK: - MAC utilities

    /// Generate a random locally-administered, unicast MAC. Matches
    /// mcp-utm's generate_mac() byte layout (first octet 0x02 sets the
    /// locally-administered bit, clears the multicast bit).
    static func generateMAC() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        for i in 1...5 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[0] = 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Normalize "AA-BB-CC-DD-EE-FF" or "aabb.ccdd.eeff" → "aa:bb:cc:dd:ee:ff".
    static func normalizeMAC(_ s: String) -> String {
        let stripped = s
            .replacingOccurrences(of: "-", with: ":")
            .replacingOccurrences(of: ".", with: ":")
            .lowercased()
        // Squash multi-colon collapses produced by Cisco-style "aabb.ccdd.eeff".
        let parts = stripped.split(separator: ":").map(String.init)
        if parts.count == 6 {
            return parts.map { $0.padded(to: 2, with: "0") }.joined(separator: ":")
        }
        return stripped
    }
}

private extension String {
    func padded(to length: Int, with pad: Character) -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}
