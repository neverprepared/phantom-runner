import XCTest

/// `IntegrationEngine.resolve` is the whole engine-selection decision for
/// `integration.{up,down,status}`. Each test below pins a choice that, if
/// reverted, breaks something specific — noted per test.
final class IntegrationEngineTests: XCTestCase {

    /// The backward-compatibility requirement: an older control plane sends no
    /// `engine` at all and must keep placing compose stacks. Fails against any
    /// resolve that drops the `?? "docker"` default (e.g. one that returns
    /// `.unsupported("")` or refuses a nil engine outright).
    func test_absentEngine_defaultsToDocker() {
        XCTAssertEqual(IntegrationEngine.resolve(nil), .docker)
    }

    /// The Task 4 regression, in its new home: `(x as? String) ?? "docker"`
    /// defaults only on nil, so a present-but-blank `engine` falls through to
    /// the unsupported branch and fails a request the control plane plainly
    /// meant as the default. Fails against exactly that implementation —
    /// it returns `.unsupported("")` here.
    func test_blankEngine_isTreatedAsAbsent() {
        XCTAssertEqual(IntegrationEngine.resolve(""), .docker)
    }

    /// Fails against a resolve missing the k8s case, which would send a
    /// Kubernetes placement down the compose path (or reject it).
    func test_k8sEngine_resolvesToK8s() {
        XCTAssertEqual(IntegrationEngine.resolve("k8s"), .k8s)
    }

    /// An unknown engine must be REFUSED, not quietly defaulted. Fails against
    /// a resolve whose `default:` returns `.docker` — which would place a
    /// compose stack for a request that asked for some other engine entirely.
    /// The associated value is asserted because the handler puts it in the
    /// operator-facing error; a resolve that discarded it would fail here.
    func test_unknownEngine_isUnsupportedAndNamed() {
        XCTAssertEqual(IntegrationEngine.resolve("nomad"), .unsupported("nomad"))
    }

    /// Payload-supplied values are matched verbatim, the same treatment
    /// `KubePreflight` gives an incoming `context`: no trimming, so a
    /// whitespace-padded engine is refused by name rather than silently
    /// accepted. Fails against a resolve that added
    /// `.trimmingCharacters(in: .whitespaces)` — that returns `.docker`.
    func test_paddedEngine_isNotTrimmed() {
        XCTAssertEqual(IntegrationEngine.resolve(" docker"), .unsupported(" docker"))
    }

    /// Same verbatim rule for case: `Docker` is not `docker`. Fails against a
    /// resolve that lowercased the input.
    func test_engineMatchIsCaseSensitive() {
        XCTAssertEqual(IntegrationEngine.resolve("Docker"), .unsupported("Docker"))
    }
}
