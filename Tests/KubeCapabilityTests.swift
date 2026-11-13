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
}
