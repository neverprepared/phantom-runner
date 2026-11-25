import Foundation

/// Decides whether a control-plane HTTP status means this runner was EVICTED,
/// i.e. the router or fleet no longer has a registration for it, so the only fix
/// is to register again.
///
/// Dependency-free on purpose, so the policy is unit-testable without hosting
/// the menu-bar app (see the BrainboxRunnerTests target in project.yml).
///
/// Why it exists: until 2026-11-25 a runner registered once at startup. After a
/// network outage, fleet's reap_stale evicted every runner; each one then polled
/// /pending and sent heartbeats into 404s indefinitely, and fleet showed zero
/// runners for over an hour while all of them were still running.
enum RunnerEviction {
    /// 404 is the control plane saying "I don't know this runner". 401 is a bad
    /// key: re-registering with the same key cannot fix it. Anything else (5xx,
    /// 429, ...) is transient and is retried in place.
    static func isEviction(status: Int) -> Bool {
        status == 404
    }
}
