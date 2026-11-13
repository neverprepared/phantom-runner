import Foundation

/// Whether this machine advertises the `"k8s"` capability. Dependency-free
/// Foundation only, so it can be unit-tested directly (see
/// `KubeCapabilityTests`) without hosting the menu-bar app or touching
/// `SettingsStore` (which is `@Published`/SwiftUI and deliberately absent
/// from the logic-test bundle).
///
/// Both call sites — `RunnerCore`'s `caps` registration literal and
/// `MenuBarView`'s `capabilityLine` — call this one function rather than
/// each re-implementing the predicate.
enum KubeCapability {
    /// True only when the capability is enabled AND at least one context is
    /// a real, non-blank name. A context list of `[""]` or `["   "]` does
    /// NOT count — those are what an empty or whitespace-only settings text
    /// field produces, and advertising on them would let the control plane
    /// place Kubernetes work with no actual cluster to reach.
    static func isAdvertised(enabled: Bool, contexts: [String]) -> Bool {
        guard enabled else { return false }
        return contexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
