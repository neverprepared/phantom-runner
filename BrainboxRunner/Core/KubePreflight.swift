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

    /// `advertised` entries are trimmed/blank-filtered the same way
    /// `KubeCapability.isAdvertised` treats `settings.kubeContexts`
    /// (`.whitespacesAndNewlines`), so a stray blank or untrimmed entry in
    /// the stored list can neither widen nor narrow what matches here. The
    /// incoming `context` from the payload is matched verbatim — it is
    /// attacker/control-plane-supplied input, not a settings field, so it is
    /// never trimmed before the membership check.
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
