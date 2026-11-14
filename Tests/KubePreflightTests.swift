import XCTest

/// Covers `KubePreflight.resolve`, the whole kube.* dispatch gate as a pure
/// function. No `@testable import` — same as `KubeDriverTests` and
/// `KubeCapabilityTests`: the BrainboxRunnerTests bundle compiles the unit
/// under test directly into the test module.
///
/// `RunnerCore.kubePreflight` cannot be exercised here — it reaches through
/// `owner?.settings` (`AppState`/`SettingsStore`, deliberately outside this
/// logic-test bundle) and the brief's own verification step dispatches a
/// real `kube.get` through a running app + router, which this environment
/// has neither of. This file is the full substitute: it pins the decision
/// `RunnerCore.kubePreflight` is a thin wrapper over.
final class KubePreflightTests: XCTestCase {

    func test_disabled_fails() {
        let result = KubePreflight.resolve(
            enabled: false,
            advertised: ["k3d-phantom-local"],
            context: "k3d-phantom-local",
            namespace: "default"
        )
        XCTAssertEqual(result, KubePreflight.Outcome.failure("k8s capability disabled in runner settings on this machine"))
    }

    func test_missingContext_fails() {
        let result = KubePreflight.resolve(
            enabled: true,
            advertised: ["k3d-phantom-local"],
            context: nil,
            namespace: "default"
        )
        XCTAssertEqual(result, KubePreflight.Outcome.failure("context required"))
    }

    func test_emptyContext_fails() {
        let result = KubePreflight.resolve(
            enabled: true,
            advertised: ["k3d-phantom-local"],
            context: "",
            namespace: "default"
        )
        XCTAssertEqual(result, KubePreflight.Outcome.failure("context required"))
    }

    /// The security-relevant rule: a context not in this runner's advertised
    /// list is refused even though it is otherwise well-formed, so a
    /// kubeconfig on disk cannot widen what the control plane can reach. If
    /// the membership check were removed (e.g. `resolve` fell through to
    /// success whenever `context` was merely non-empty), this would pass a
    /// cluster this runner never advertised and the assertion below would
    /// fail by returning `.success` instead of the refusal.
    func test_unadvertisedContext_fails() {
        let result = KubePreflight.resolve(
            enabled: true,
            advertised: ["k3d-phantom-local"],
            context: "some-other-cluster",
            namespace: "default"
        )
        XCTAssertEqual(
            result,
            KubePreflight.Outcome.failure("context some-other-cluster is not advertised by this runner")
        )
    }

    func test_missingNamespace_fails() {
        let result = KubePreflight.resolve(
            enabled: true,
            advertised: ["k3d-phantom-local"],
            context: "k3d-phantom-local",
            namespace: nil
        )
        XCTAssertEqual(result, KubePreflight.Outcome.failure("namespace required"))
    }

    func test_emptyNamespace_fails() {
        let result = KubePreflight.resolve(
            enabled: true,
            advertised: ["k3d-phantom-local"],
            context: "k3d-phantom-local",
            namespace: ""
        )
        XCTAssertEqual(result, KubePreflight.Outcome.failure("namespace required"))
    }

    func test_allValid_succeeds() {
        let result = KubePreflight.resolve(
            enabled: true,
            advertised: ["k3d-phantom-local"],
            context: "k3d-phantom-local",
            namespace: "default"
        )
        XCTAssertEqual(
            result,
            KubePreflight.Outcome.success(KubePreflight.Target(context: "k3d-phantom-local", namespace: "default"))
        )
    }

    /// An advertised entry with incidental surrounding whitespace (e.g. a
    /// stale UserDefaults value from before the settings UI trimmed on
    /// input) still matches the trimmed context, consistent with how
    /// `KubeCapability.isAdvertised` treats the same list.
    func test_advertisedEntryWithWhitespace_stillMatches() {
        let result = KubePreflight.resolve(
            enabled: true,
            advertised: ["  k3d-phantom-local  "],
            context: "k3d-phantom-local",
            namespace: "default"
        )
        XCTAssertEqual(
            result,
            KubePreflight.Outcome.success(KubePreflight.Target(context: "k3d-phantom-local", namespace: "default"))
        )
    }
}
