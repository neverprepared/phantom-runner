import XCTest

/// Covers `KubeCapability.isAdvertised`, the single predicate both
/// `RunnerCore`'s `caps` literal and `MenuBarView`'s `capabilityLine` call —
/// no `@testable import`, same as `KubeDriverTests` (see its header comment).
final class KubeCapabilityTests: XCTestCase {

    func test_disabled_withContexts_isFalse() {
        XCTAssertFalse(KubeCapability.isAdvertised(enabled: false, contexts: ["k3d-phantom-local"]))
    }

    func test_enabled_emptyArray_isFalse() {
        XCTAssertFalse(KubeCapability.isAdvertised(enabled: true, contexts: []))
    }

    func test_enabled_singleBlankString_isFalse() {
        // A UI-driven array of [""] (e.g. an empty text field split on comma)
        // must not count as a context. If the whitespace/emptiness check were
        // removed and this fell back to a bare `!contexts.isEmpty`, this
        // assertion would fail because `[""]` is non-empty.
        XCTAssertFalse(KubeCapability.isAdvertised(enabled: true, contexts: [""]))
    }

    func test_enabled_singleWhitespaceString_isFalse() {
        // Same shape as above but with actual whitespace, so a check that only
        // tests for "" (and not trimmed emptiness) would still wrongly pass.
        XCTAssertFalse(KubeCapability.isAdvertised(enabled: true, contexts: ["   "]))
    }

    func test_enabled_oneRealContext_isTrue() {
        XCTAssertTrue(KubeCapability.isAdvertised(enabled: true, contexts: ["k3d-phantom-local"]))
    }

    func test_enabled_realContextAlongsideBlank_isTrue() {
        // A real context should count even when a stray blank entry rides
        // along with it (e.g. a trailing comma in the settings text field).
        XCTAssertTrue(KubeCapability.isAdvertised(enabled: true, contexts: ["", "k3d-phantom-local", "   "]))
    }

    // MARK: - advertisedTags

    func test_advertisedTags_disabled_addsNoKubeTags() {
        // A machine that does not advertise k8s must not advertise contexts
        // either, even if contexts are configured on disk (e.g. the operator
        // flipped the toggle off without clearing the context list).
        let result = KubeCapability.advertisedTags(
            operatorTags: ["mac", "arm64"],
            enabled: false,
            contexts: ["k3d-phantom-local", "prod"]
        )
        XCTAssertEqual(result, ["mac", "arm64"])
    }

    func test_advertisedTags_blankAndWhitespaceContexts_contributeNothing() {
        let result = KubeCapability.advertisedTags(
            operatorTags: ["mac"],
            enabled: true,
            contexts: ["", "   ", "\t"]
        )
        XCTAssertEqual(result, ["mac"])
    }

    func test_advertisedTags_duplicateContexts_notEmittedTwice() {
        let result = KubeCapability.advertisedTags(
            operatorTags: ["mac"],
            enabled: true,
            contexts: ["k3d-phantom-local", "k3d-phantom-local"]
        )
        XCTAssertEqual(result, ["mac", "kube:k3d-phantom-local"])
    }

    func test_advertisedTags_operatorAlreadyTypedKubeTag_notDuplicated() {
        // The operator may have hand-typed a "kube:foo" tag before this
        // feature existed (or out of habit). The derived tag for the same
        // context must not be appended a second time.
        let result = KubeCapability.advertisedTags(
            operatorTags: ["mac", "kube:k3d-phantom-local"],
            enabled: true,
            contexts: ["k3d-phantom-local"]
        )
        XCTAssertEqual(result, ["mac", "kube:k3d-phantom-local"])
    }

    func test_advertisedTags_operatorTagsPreserveOrder_derivedAppended() {
        let result = KubeCapability.advertisedTags(
            operatorTags: ["mac", "arm64"],
            enabled: true,
            contexts: ["k3d-phantom-local", "prod"]
        )
        XCTAssertEqual(result, ["mac", "arm64", "kube:k3d-phantom-local", "kube:prod"])
    }
}
