import XCTest

/// Pins the eviction policy behind re-registration. The wiring (RunnerCore's poll
/// and heartbeat catch clauses) needs the app host; it is proven end to end by
/// deregistering a live runner and watching it come back on its own.
final class RunnerEvictionTests: XCTestCase {

    func testNotFoundIsAnEviction() {
        XCTAssertTrue(RunnerEviction.isEviction(status: 404),
                      "a 404 from /pending or /heartbeat means fleet forgot this runner; it must re-register")
    }

    func testUnauthorizedIsNotAnEviction() {
        // Re-registering with the same bad key cannot help, and looping on it
        // would hammer the control plane.
        XCTAssertFalse(RunnerEviction.isEviction(status: 401))
        XCTAssertFalse(RunnerEviction.isEviction(status: 403))
    }

    func testTransientFailuresAreRetriedInPlace() {
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertFalse(RunnerEviction.isEviction(status: status), "\(status) is transient, not an eviction")
        }
    }

    func testSuccessIsNotAnEviction() {
        for status in [200, 201, 204] {
            XCTAssertFalse(RunnerEviction.isEviction(status: status))
        }
    }
}
