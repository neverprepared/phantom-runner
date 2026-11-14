import Foundation

/// Pure decision logic for the `kube.*` RPC verbs' preflight gate: capability
/// opt-in, plus a context this machine actually advertised. Refusing an
/// unadvertised context stops the control plane from reaching a cluster this
/// runner never offered, even if a kubeconfig on disk happens to contain it.
///
/// Dependency-free Foundation only (no SwiftUI, no `AppState`, no
/// `SettingsStore`) — same shape as `KubeCapability`/`KubeDriver` — so the
/// whole decision can be unit-tested directly without hosting the menu-bar
/// app. `RunnerCore` is the only call site and supplies `enabled` and
/// `advertised` from `owner.settings`.
enum KubePreflight {
    struct Target: Equatable {
        let context: String
        let namespace: String
    }

    /// Mirrors `Result<Target, String>`'s shape. A plain `Result` can't be
    /// used here without a `String: Error` conformance, which nothing else
    /// in this codebase adds (every other driver defines its own `Error`
    /// enum — see `KubeDriver.KubeError`); introducing a global one just for
    /// this type would be a bigger footprint than this four-line stand-in.
    enum Outcome: Equatable {
        case success(Target)
        case failure(String)
    }

    /// `advertised` entries are trimmed the same way `KubeCapability
    /// .isAdvertised` treats `settings.kubeContexts` (`.whitespacesAndNewlines`),
    /// so a stored context with incidental surrounding whitespace (e.g. a
    /// stale UserDefaults value predating the settings UI trimming on input)
    /// still matches a well-formed `context` from the payload. The incoming
    /// `context` itself is matched verbatim — it is attacker/control-plane-
    /// supplied input, not a settings field, so it is never trimmed.
    ///
    /// The accompanying blank filter is defense-in-depth, not a reachable
    /// path: the `context` guard just above already refuses an empty
    /// `context` before this runs, so a normalized-to-empty `advertised`
    /// entry could only ever match an empty `context`, which can't reach
    /// here. It stays so a future reordering of these guards doesn't quietly
    /// make a blank entry matchable; it is intentionally untested for that
    /// reason — there is no reachable `context` value that would let a test
    /// distinguish "filtered" from "not filtered" here.
    static func resolve(
        enabled: Bool,
        advertised: [String],
        context: String?,
        namespace: String?
    ) -> Outcome {
        guard enabled else {
            return .failure("k8s capability disabled in runner settings on this machine")
        }
        guard let context, !context.isEmpty else {
            return .failure("context required")
        }
        let normalizedAdvertised = advertised
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard normalizedAdvertised.contains(context) else {
            return .failure("context \(context) is not advertised by this runner")
        }
        guard let namespace, !namespace.isEmpty else {
            return .failure("namespace required")
        }
        return .success(Target(context: context, namespace: namespace))
    }
}
