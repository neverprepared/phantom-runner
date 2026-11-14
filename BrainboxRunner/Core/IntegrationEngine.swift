import Foundation

/// Which placement engine an `integration.{up,down,status}` payload selects.
///
/// Extracted from `RunnerCore` for the same reason as `KubePreflight`:
/// dependency-free Foundation only, so the decision is unit-testable without
/// hosting the menu-bar app. It is not trivia — it encodes a hard backward-
/// compatibility requirement across three call sites, and the blank-string
/// half of it has already regressed once (Task 4's `kinds`).
enum IntegrationEngine: Equatable {
    case docker
    case k8s
    /// Carries the offending value so the caller can name it in its error.
    case unsupported(String)

    /// An ABSENT engine means `docker`: an older control plane, which has no
    /// concept of `engine` at all, must keep placing compose stacks on a newer
    /// runner without any change. Plan 2 relies on that default.
    ///
    /// A present-but-EMPTY engine (`""`) is treated as absent for the same
    /// reason. `(x as? String) ?? "docker"` defaults only on nil, so a blank
    /// would otherwise fall through to `.unsupported("")` and fail a request
    /// that a control plane plainly meant as the default — the exact shape of
    /// the bug `handleKubeGet`'s `kinds` had.
    ///
    /// The value is matched VERBATIM otherwise — no trimming, no case folding.
    /// It is control-plane-supplied input rather than a local settings field,
    /// so it gets the same treatment `KubePreflight` gives an incoming
    /// `context`: `" docker"` is not `docker`, and is refused by name.
    static func resolve(_ raw: String?) -> IntegrationEngine {
        let engine = raw.flatMap { $0.isEmpty ? nil : $0 } ?? "docker"
        switch engine {
        case "docker": return .docker
        case "k8s": return .k8s
        default: return .unsupported(engine)
        }
    }
}
