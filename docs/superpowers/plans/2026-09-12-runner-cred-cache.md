# Runner Credential Cache + Bind-Mount Implementation Plan (Piece 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On session-create, the runner pulls the profile's credential bundle from the router, caches it per-profile on the host (last-good fallback when the broker is down), and bind-mounts the cred dirs into the container — so `az`/`aws`/`kubectl` work in remote runner sessions with no image rebuild.

**Architecture:** Four small pieces in the Swift menu-bar runner. (1) `SettingsStore` gains `credentialCacheEnabled` + `credentialCacheMaxAgeHours`. (2) `APIClient` gains `fetchCredentialBundle(runnerName:profile:)` returning the tar.gz `Data` (or a typed "unavailable"/"none" outcome from 503/404). (3) A new `CredentialCache` type with a **pure decision function** (`decide(outcome:cacheAge:maxAge) -> CacheAction`) plus fetch + atomic untar-to-cache. (4) `SessionExecutor.executeDocker` calls it and appends the cached cred dirs to the existing `volumes` array before `DockerDriver.create`.

**Tech Stack:** Swift 5 / SwiftUI (macOS menu-bar app), Foundation `URLSession`, system `tar` via `Process`, XcodeGen (`project.yml`) + `xcodebuild`. Shells out to `docker` CLI (existing `DockerDriver`).

**Spec:** `../../../../phantom-router/docs/superpowers/specs/2026-09-12-runner-credential-delivery-design.md` (§5 Piece 2, §6 cache state machine, §7 defaults, §9 security). *(The spec lives in the phantom-router repo; read it alongside this plan.)*

**Consumes (Piece 1, phantom-router — already planned):** `GET /api/runners/{name}/cred-bundle?profile={profile}`, `X-API-Key` auth. Status semantics this plan keys on: **200** fresh tar.gz (write + mount); **404** authoritative no-bundle (clear cache); **503** broker unreachable (serve stale cache within max-age); **400** profile missing.

## Global Constraints

- **No bundled binaries** — pure Swift + Foundation + shelling to system `tar`/`docker`. Preserves the hardened-runtime + notarization build unchanged (`release.yml`).
- **Feature-flagged, default OFF** — all new behavior gated on `settings.credentialCacheEnabled`; when off, `executeDocker` is byte-for-byte unchanged.
- **Fail-soft** — a cache miss/`noCreds` never aborts the session; the container still launches (it may prompt for login inside). Log via the existing `Self.log` OSLog pattern and `api.postEvent(...)` for observability.
- **Cache at rest** — cache dir mode `0700`; the design accepts plaintext creds on hosts that have run the profile (spec §9).
- **Testing reality:** phantom-runner has **no XCTest target today.** This plan verifies each task with `xcodebuild -project BrainboxRunner.xcodeproj -scheme BrainboxRunner build` (compiles) and gates the feature on a **functional acceptance test on a fleet host** (Task 5). The one piece of nontrivial logic — the cache decision — is written as a **pure function** so it is unit-testable; standing up an XCTest target to cover `CredentialCache.decide(...)` is a recommended fast-follow (Task 6, optional).

## File Structure

- `BrainboxRunner/Core/SettingsStore.swift` — add two settings (Key enum + `@Published` properties), mirroring the existing `dockerEnabled` pattern.
- `BrainboxRunner/Core/APIClient.swift` — add `fetchCredentialBundle(runnerName:profile:)` mirroring `getJSON` (reuses `buildURL`, `addAuth`, `URLSession.shared.data(for:)`), but returns `Data`/typed outcome, not JSON.
- `BrainboxRunner/Core/CredentialCache.swift` — **new.** The `CacheAction` enum, the pure `decide(...)` function, and `materialize(profile:api:runnerName:maxAgeHours:) -> [(String,String,String)]` (fetch → decide → atomic untar → return mount tuples).
- `BrainboxRunner/Core/SessionExecutor.swift` — in `executeDocker`, make `volumes` a `var` and append `CredentialCache.materialize(...)` results before `DockerDriver.create` (~lines 87-98).
- `BrainboxRunner/Settings/CapabilitiesTab.swift` — add a toggle + max-age field (UI; non-blocking for the core feature).

---

### Task 1: Settings — `credentialCacheEnabled` + `credentialCacheMaxAgeHours`

**Files:**
- Modify: `BrainboxRunner/Core/SettingsStore.swift` (Key enum ~lines 8-22; properties ~lines 24-40)

**Interfaces:**
- Produces: `settings.credentialCacheEnabled: Bool` (default `false`), `settings.credentialCacheMaxAgeHours: Int` (default `24`).

- [ ] **Step 1: Add the keys and properties**

In the `Key` enum, add:

```swift
static let credentialCacheEnabled = "capabilities.credentialCache.enabled"
static let credentialCacheMaxAgeHours = "capabilities.credentialCache.maxAgeHours"
```

Add the `@Published` properties (mirror `dockerEnabled` at lines 39-41):

```swift
@Published var credentialCacheEnabled: Bool {
    didSet { UserDefaults.standard.set(credentialCacheEnabled, forKey: Key.credentialCacheEnabled) }
}
@Published var credentialCacheMaxAgeHours: Int {
    didSet { UserDefaults.standard.set(credentialCacheMaxAgeHours, forKey: Key.credentialCacheMaxAgeHours) }
}
```

In the initializer (where the other properties are read from `UserDefaults`), add:

```swift
self.credentialCacheEnabled = UserDefaults.standard.bool(forKey: Key.credentialCacheEnabled)
let ageRaw = UserDefaults.standard.integer(forKey: Key.credentialCacheMaxAgeHours)
self.credentialCacheMaxAgeHours = ageRaw == 0 ? 24 : ageRaw   // 0 (unset) → 24h default
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project BrainboxRunner.xcodeproj -scheme BrainboxRunner build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BrainboxRunner/Core/SettingsStore.swift
git commit -m "feat(settings): credentialCacheEnabled + maxAgeHours (default off, 24h)"
```

---

### Task 2: `APIClient.fetchCredentialBundle`

**Files:**
- Modify: `BrainboxRunner/Core/APIClient.swift` (add method near `getJSON`, ~line 270; reuses `buildURL`, `addAuth`, `APIError`)

**Interfaces:**
- Consumes: `buildURL(_:)`, `addAuth(_:)`, `baseURL`, `apiKey`, `APIError` (all existing).
- Produces: `enum BundleOutcome { case bundle(Data); case none; case unavailable }` and
  `func fetchCredentialBundle(runnerName: String, profile: String) async -> BundleOutcome`.
  Maps HTTP: 200 → `.bundle(data)`; 404 → `.none`; anything else / transport error → `.unavailable`. (Never throws — the caller decides via `CacheAction`.)

- [ ] **Step 1: Implement the method**

Add to `APIClient` (mirrors `getJSON` request setup; returns a typed outcome instead of decoding JSON):

```swift
enum BundleOutcome {
    case bundle(Data)   // 200 — fresh tar.gz
    case none           // 404 — authoritative: broker has no bundle for this profile
    case unavailable    // 503 / other / transport — broker down; caller may use stale cache
}

func fetchCredentialBundle(runnerName: String, profile: String) async -> BundleOutcome {
    guard let escaped = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = try? buildURL("/api/runners/\(runnerName)/cred-bundle?profile=\(escaped)") else {
        return .unavailable
    }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 30
    addAuth(&req)
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return .unavailable }
        switch http.statusCode {
        case 200: return .bundle(data)
        case 404: return .none
        default:  return .unavailable   // 503 broker-down, 400, 401, 5xx → treat as unavailable
        }
    } catch {
        return .unavailable
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project BrainboxRunner.xcodeproj -scheme BrainboxRunner build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BrainboxRunner/Core/APIClient.swift
git commit -m "feat(api): fetchCredentialBundle — typed 200/404/503 outcome"
```

---

### Task 3: `CredentialCache` — pure decision + atomic materialize

**Files:**
- Create: `BrainboxRunner/Core/CredentialCache.swift`

**Interfaces:**
- Consumes: `APIClient.BundleOutcome` (Task 2), `APIClient` instance, `FileManager`, `Process` (system `tar`).
- Produces:
  - `enum CacheAction: Equatable { case writeAndMount; case mountStale; case clearAndSkip }`
  - `static func decide(outcome: APIClient.BundleOutcome, cacheAgeSeconds: TimeInterval?, maxAgeSeconds: TimeInterval) -> CacheAction`
  - `static func materialize(profile: String, api: APIClient, runnerName: String, maxAgeHours: Int) async -> [(String, String, String)]` — returns docker volume tuples `(hostPath, containerPath, mode)` for the cached cred dirs, or `[]` when there are no creds to mount.

- [ ] **Step 1: Write the pure decision function + a `main()`-runnable assertion harness**

Since there is no XCTest target, embed a tiny self-check the executor runs via `swift` to prove the pure logic before wiring I/O. Create `BrainboxRunner/Core/CredentialCache.swift`:

```swift
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
}
```

Create a scratch verifier `/tmp/creddecide.swift` (NOT committed) that pastes the enum + `decide` and asserts:

```swift
// fresh → writeAndMount
assert(decide(.bundle, nil, 3600) == .writeAndMount)
// authoritative none → clearAndSkip even if a cache exists
assert(decide(.none, 10, 86400) == .clearAndSkip)
// unavailable + fresh-enough cache → mountStale
assert(decide(.unavailable, 3600, 86400) == .mountStale)
// unavailable + too-old cache → clearAndSkip
assert(decide(.unavailable, 90000, 86400) == .clearAndSkip)
// unavailable + no cache → clearAndSkip
assert(decide(.unavailable, nil, 86400) == .clearAndSkip)
print("decide OK")
```

- [ ] **Step 2: Run the decision self-check**

Run: `swift /tmp/creddecide.swift`
Expected: prints `decide OK` (all asserts pass).

- [ ] **Step 3: Implement `materialize` (fetch → decide → atomic untar → mount tuples)**

Append to `CredentialCache`:

```swift
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
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project BrainboxRunner.xcodeproj -scheme BrainboxRunner build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add BrainboxRunner/Core/CredentialCache.swift
git commit -m "feat(runner): CredentialCache — pure §6 decision + atomic untar-to-cache"
```

---

### Task 4: Wire into `SessionExecutor.executeDocker`

**Files:**
- Modify: `BrainboxRunner/Core/SessionExecutor.swift` (the `volumes` assembly + `DockerDriver.create` call, ~lines 87-98)

**Interfaces:**
- Consumes: `CredentialCache.materialize` (Task 3), `settings.credentialCacheEnabled` / `.credentialCacheMaxAgeHours` (Task 1 — read from the `SettingsStore` instance the executor already holds via `RunnerCore`/`AppState`; confirm the reference name in-file), `req.workspaceProfile`, `api`, `runnerName`.

- [ ] **Step 1: Make `volumes` mutable and append cred mounts**

Change the existing block (currently `let volumes: [(String, String, String)] = [(sessionsDir, "/home/developer/.claude/projects", "rw")]`) to:

```swift
            var volumes: [(String, String, String)] = [
                (sessionsDir, "/home/developer/.claude/projects", "rw")
            ]

            // Credential cache: pull the profile's cred bundle, cache it per-profile,
            // and bind-mount the cred dirs (~/.azure, ~/.aws, ...) into the container.
            // Fail-soft: on no-creds the container still launches. Feature-flagged.
            if settings.credentialCacheEnabled, let profile = req.workspaceProfile, !profile.isEmpty {
                let credMounts = await CredentialCache.materialize(
                    profile: profile, api: api, runnerName: runnerName,
                    maxAgeHours: settings.credentialCacheMaxAgeHours)
                if !credMounts.isEmpty {
                    volumes.append(contentsOf: credMounts)
                    await api.postEvent(runnerName: runnerName,
                                        message: "credential cache: mounted \(credMounts.count) dir(s)",
                                        session: req.sessionName)
                }
            }
```

(The existing `DockerDriver.create(..., volumes: volumes, ...)` call needs no change — it already renders every tuple as a `-v` flag.)

- [ ] **Step 2: Confirm the settings reference**

The executor must reach `settings` (the `SettingsStore`). Grep the file for how it already accesses settings/config (`grep -n "settings\|SettingsStore\|AppState\|\.runnerName" BrainboxRunner/Core/SessionExecutor.swift`). If the executor holds no `settings` reference, thread it in from `RunnerCore` (where `SessionExecutor` is constructed) as an init parameter — a one-line constructor change. Use the exact property name found.

- [ ] **Step 3: Build**

Run: `xcodebuild -project BrainboxRunner.xcodeproj -scheme BrainboxRunner build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add BrainboxRunner/Core/SessionExecutor.swift BrainboxRunner/Core/RunnerCore.swift
git commit -m "feat(runner): bind-mount cached cred dirs into session containers (flagged)"
```

---

### Task 5: Functional acceptance (fleet host) — the real gate

**Files:** none (manual/scripted validation on a runner host).

**Interfaces:** requires Piece 1 deployed (the `/api/runners/{name}/cred-bundle` endpoint live), a profile with a stored bundle (e.g. `az`/`aws` synced via the app's bundle editor), and this runner build installed on a fleet host.

- [ ] **Step 1: Enable the flag**

In the runner menu-bar app on the fleet host, enable "credential cache" (Task 1 setting), or set the UserDefaults key directly:
`defaults write com.neverprepared.BrainboxRunner capabilities.credentialCache.enabled -bool true`

- [ ] **Step 2: Create a session and verify creds arrive**

Dispatch a session for the profile to this runner. Inside the container:

```bash
docker exec <container> az account show      # succeeds without interactive login
docker exec <container> ls -la /home/developer/.azure   # dir is present, mounted ro
```
Expected: `az account show` returns the subscription (no login prompt); `~/.azure` is populated.

- [ ] **Step 3: Verify broker-down fallback**

Stop the credentials broker (or block the router's broker path), then create a second session for the same profile. Confirm `az account show` still succeeds (served from the last-good cache) and the runner logged "broker unavailable — mounting last-good cache".

- [ ] **Step 4: Verify revocation (authoritative none)**

Delete the profile's bundle (`prouterctl`/app delete, so the endpoint returns 404), then create a session. Confirm the cache dir is cleared and no cred dirs are mounted (container prompts for login) — a revoked bundle is honored, not served stale.

- [ ] **Step 5: Record the result**

Note pass/fail per step in the PR description; this functional pass is the acceptance gate for enabling the flag on the fleet.

---

### Task 6 (optional fast-follow): XCTest target for `decide`

**Files:** `project.yml` (add a `BrainboxRunnerTests` target), `BrainboxRunnerTests/CredentialCacheTests.swift`.

- [ ] Add an XCTest target via XcodeGen (see XcodeGen target docs for `type: bundle.unit-test` + `test` scheme), port the five `decide(...)` assertions from Task 3's scratch verifier into `XCTAssertEqual` cases, and run `xcodebuild -project BrainboxRunner.xcodeproj -scheme BrainboxRunner test`. This replaces the throwaway `/tmp/creddecide.swift` check with a permanent regression test for the §6 decision logic. Deferred because standing up the first test target is unverified setup, not core to the feature.

## Self-Review

- **Spec coverage:** §5 Piece 2 (fetch + cache + bind-mount) → Tasks 2/3/4; §6 state machine (fresh/none/unavailable, atomic write, clear-on-authoritative-none, max-age fallback) → `CredentialCache.decide` (Task 3) with the 5-case self-check; §7 defaults (24h, flag) → Task 1; §9 security (0700, fail-soft) → Task 3 `writeAtomically` perms + Task 4 fail-soft guard. Functional proof of all branches → Task 5.
- **Placeholder scan:** none — all Swift is literal. Task 4 Step 2 (confirm the `settings` reference name) is a real in-file grep instruction, not a TODO; Task 6 is explicitly optional/deferred with a named XcodeGen mechanism.
- **Type consistency:** `APIClient.BundleOutcome` (Task 2: `.bundle`/`.none`/`.unavailable`) is the exact input to `CredentialCache.decide` (Task 3) and the switch in `materialize`. `materialize -> [(String,String,String)]` matches `DockerDriver.create(volumes: [(hostPath:String,containerPath:String,mode:String)])` (verified signature) and the existing `volumes` tuple shape in `executeDocker`. Status codes (200/404/503) match Piece 1's endpoint contract exactly.
- **Contract with Piece 1:** consumes `GET /api/runners/{name}/cred-bundle?profile=`; 200→writeAndMount, 404→clearAndSkip, 503(+other)→unavailable→mountStale-or-clear. Aligned with the corrected Piece 1 endpoint.
