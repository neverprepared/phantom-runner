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

    /// Derives the tag set `RunnerCore` should advertise at registration: the
    /// operator's own tags, in their original order, followed by one
    /// `kube:<context>` entry per advertised context.
    ///
    /// A bool capability (`"k8s": true`) can say a machine runs Kubernetes
    /// but cannot name which cluster — the control plane needs the context
    /// name itself to build a placement request `KubePreflight` will accept,
    /// since preflight refuses any context the runner did not advertise.
    /// Tags already flow unmodified through registration, so folding the
    /// context names into tags needs no protocol change.
    static func advertisedTags(operatorTags: [String], enabled: Bool, contexts: [String]) -> [String] {
        guard enabled else { return operatorTags }

        var seen = Set(operatorTags)
        var result = operatorTags
        for context in contexts {
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let tag = "kube:\(trimmed)"
            guard !seen.contains(tag) else { continue }
            seen.insert(tag)
            result.append(tag)
        }
        return result
    }
}
