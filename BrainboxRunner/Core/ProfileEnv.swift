import Foundation

/// Resolves a workspace profile's environment from THIS machine's disk.
///
/// A deliberate port of the desktop app's `resolveProfileEnv`
/// (phantom-ink `app/app_dashboard.go`), which is what used to assemble the
/// environment for a scheduled collector before scheduling moved to the
/// platform. Host-bound jobs still need exactly that environment, with real
/// host paths — `$WORKSPACE_HOME` has to be `/Users/you/workspaces/...`, not a
/// container path — so the resolution belongs on the machine that will run it.
///
/// Resolving here rather than having the control plane ship a credential bundle
/// over the wire is the point: the profile's secrets never leave this machine.
///
/// Notably it does NOT use direnv. `.envrc` approvals live in a per-profile
/// `$XDG_DATA_HOME/direnv/allow`, so `direnv exec <other-profile>` fails closed
/// with "is blocked" and re-breaks on every `.envrc` edit. This replicates what
/// those files *do* (identity vars, dotenv layering, PATH_add bin) instead.
/// The tradeoff is the same one the app accepted: dynamic `.envrc` logic beyond
/// dotenv and PATH_add does not run, so a profile sourcing secrets dynamically
/// must put them in `.env`.
///
/// Dependency-free on purpose, so it can sit in the logic-test target.
enum ProfileEnv {
    /// Where profiles live. Mirrors the app's `config.WorkspacesRoot`.
    static func defaultWorkspacesRoot(home: String) -> String {
        (home as NSString).appendingPathComponent("workspaces/profiles")
    }

    /// The profile's workspace home, or nil when there is no such directory.
    ///
    /// Returning nil rather than guessing matters: running a host command with
    /// the wrong profile's environment is worse than refusing to run it.
    static func workspaceHome(
        profile: String,
        root: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard !profile.isEmpty, isSafeProfileName(profile) else { return nil }
        let candidate = (root as NSString).appendingPathComponent(profile)
        return fileExists(candidate) ? candidate : nil
    }

    /// A profile name must not be able to escape the workspaces root or inject
    /// a path. It names a directory, so the charset is deliberately narrow.
    static func isSafeProfileName(_ profile: String) -> Bool {
        guard !profile.isEmpty, profile.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return profile.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Parse a KEY=VALUE dotenv file. Blank lines and `#` comments are skipped,
    /// an optional `export ` prefix is stripped, and one layer of surrounding
    /// quotes is removed. Literal — `$VAR` is expanded later, not here.
    static func parseEnvFile(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
            if value.count >= 2 {
                let f = value.first!, l = value.last!
                if (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// Expand `$VAR` / `${VAR}` between values, iterating to a fixed point.
    ///
    /// These files are written to be sourced by direnv, so values routinely
    /// reference each other — every profile has
    /// `AZURE_CONFIG_DIR="$WORKSPACE_HOME/.azure"`. Without this the literal
    /// string reaches the tool as a path; in the app that made `az` create a
    /// directory literally named `$WORKSPACE_HOME` containing live tokens.
    ///
    /// The pass cap terminates a self-referential cycle (A=$B, B=$A) by leaving
    /// the value partially expanded, which is visible, rather than spinning.
    static func expand(_ values: [String: String], base: [String: String]) -> [String: String] {
        var values = values
        var lookup = base
        let maxPasses = 4
        for _ in 0..<maxPasses {
            for (k, v) in values { lookup[k] = v }
            var changed = false
            for (k, v) in values where v.contains("$") {
                let expanded = expandOne(v, lookup)
                if expanded != v {
                    values[k] = expanded
                    changed = true
                }
            }
            if !changed { break }
        }
        return values
    }

    /// Expand `${VAR}` and `$VAR` (letters, digits, underscore) from `env`.
    /// An unknown name expands to empty, matching `os.Expand`.
    static func expandOne(_ s: String, _ env: [String: String]) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "$" else { out.append(s[i]); i = s.index(after: i); continue }
            var j = s.index(after: i)
            if j < s.endIndex, s[j] == "{" {
                j = s.index(after: j)
                var name = ""
                while j < s.endIndex, s[j] != "}" { name.append(s[j]); j = s.index(after: j) }
                if j < s.endIndex { j = s.index(after: j) }  // consume }
                out += env[name] ?? ""
                i = j
            } else {
                var name = ""
                while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" {
                    name.append(s[j]); j = s.index(after: j)
                }
                if name.isEmpty {
                    out.append("$")          // a lone "$" is literal
                    i = s.index(after: i)
                } else {
                    out += env[name] ?? ""
                    i = j
                }
            }
        }
        return out
    }

    /// A deliberately minimal base environment.
    ///
    /// Unlike the app — which started from its own `os.Environ()` — this does
    /// NOT inherit the runner's environment. The runner is a launchd GUI
    /// process holding its own API key and, when the credential cache is on, a
    /// materialized bundle of cloud credentials; a scheduled command has no
    /// business reading any of that by accident. Everything a command needs
    /// arrives from the profile's own dotenv instead.
    static func baseEnvironment(home: String) -> [String: String] {
        [
            "HOME": home,
            "USER": (home as NSString).lastPathComponent,
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            // Homebrew first: a launchd process does not get a login shell, so
            // /opt/homebrew/bin is otherwise absent and every brew-installed
            // tool a collector calls is simply not found.
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }

    /// Layer a control-plane-supplied environment over the locally resolved one.
    ///
    /// The broker is the one source of truth for a profile's secrets, because
    /// two env sources drift: the live m3-64 host `.env` carried 30 keys and
    /// none of the five the Drive inbox reads, while the broker bundle for the
    /// same profile carried 114 and did. A collector on the thinner env runs,
    /// reports success, and files nothing — the worst failure mode available.
    ///
    /// So `supplied` wins over the host dotenv. The exception is the identity
    /// pair: `WORKSPACE_HOME` is a path on THIS machine, which the control
    /// plane cannot know, and `WORKSPACE_PROFILE` is already settled by
    /// whichever profile we resolved. Letting a remote value override those
    /// would point the command at a directory that does not exist here.
    static func merging(_ local: [String: String], supplied: [String: String]?) -> [String: String] {
        guard let supplied, !supplied.isEmpty else { return local }
        var merged = local
        for (k, v) in supplied where k != "WORKSPACE_HOME" && k != "WORKSPACE_PROFILE" {
            merged[k] = v
        }
        return merged
    }

    /// The full environment for a host command run under `profile`.
    ///
    /// Returns nil when the profile has no workspace home on this machine —
    /// the caller must refuse to run rather than fall back to a bare
    /// environment, because a collector with the wrong credentials usually
    /// succeeds and emits quietly wrong output.
    static func resolve(
        profile: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        root: String? = nil,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        dirExists: (String) -> Bool = { p in
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            return ok && isDir.boolValue
        }
    ) -> [String: String]? {
        let rootPath = root ?? defaultWorkspacesRoot(home: home)
        guard let wh = workspaceHome(profile: profile, root: rootPath,
                                     fileExists: { dirExists($0) }) else {
            return nil
        }

        let base = baseEnvironment(home: home)
        var overrides: [String: String] = [
            "WORKSPACE_PROFILE": profile,
            "WORKSPACE_HOME": wh,
        ]
        // dotenv files in .envrc order; later wins.
        for name in [".env", ".envrc.local"] {
            let path = (wh as NSString).appendingPathComponent(name)
            if let text = readFile(path) {
                for (k, v) in parseEnvFile(text) { overrides[k] = v }
            }
        }
        overrides = expand(overrides, base: base)

        var merged = base
        for (k, v) in overrides { merged[k] = v }

        // PATH_add bin: profile-local scripts must be callable by bare name.
        let binDir = (wh as NSString).appendingPathComponent("bin")
        if dirExists(binDir) {
            merged["PATH"] = binDir + ":" + (merged["PATH"] ?? "")
        }
        return merged
    }
}
