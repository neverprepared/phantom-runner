import XCTest

/// Covers the parts of `RemindersAccess` that can be tested without EventKit.
///
/// EventKit itself cannot be exercised headlessly — a TCC status is a property
/// of the running app's identity, not something a test can set — so the real
/// acceptance test is on a host: grant via the button, then confirm a host
/// command can read reminder lists. What IS testable is the status mapping and
/// the tccutil argv, and the argv is the part where a mistake is destructive.
final class RemindersAccessTests: XCTestCase {

    // MARK: - Status mapping

    /// Mapped from raw values because the EventKit cases are split across OS
    /// versions: `.authorized` on macOS 13, `.fullAccess`/`.writeOnly` on 14+.
    func testKnownStatusesMap() {
        XCTAssertEqual(RemindersAccess.state(fromRawValue: 0), .notDetermined)
        XCTAssertEqual(RemindersAccess.state(fromRawValue: 1), .restricted)
        XCTAssertEqual(RemindersAccess.state(fromRawValue: 2), .denied)
        XCTAssertEqual(RemindersAccess.state(fromRawValue: 3), .granted)
        XCTAssertEqual(RemindersAccess.state(fromRawValue: 4), .writeOnly)
    }

    /// A future OS adding a case must not read as "denied" — that would send
    /// someone resetting a grant that was never the problem.
    func testUnknownStatusIsReportedNotGuessed() {
        XCTAssertEqual(RemindersAccess.state(fromRawValue: 99), .unknown(99))
        XCTAssertTrue(RemindersAccess.state(fromRawValue: 99).label.contains("99"))
    }

    /// Write-only is NOT good enough: the inbox verifies the list it wrote to,
    /// which needs a read. Treating it as granted would make a reminder silently
    /// land in the wrong list and report success.
    func testWriteOnlyIsNotTreatedAsGranted() {
        XCTAssertFalse(RemindersAccess.State.writeOnly.isGranted)
        XCTAssertTrue(RemindersAccess.State.granted.isGranted)
    }

    /// macOS shows the dialog only from `notDetermined`. Offering "request"
    /// after a denial would silently no-op, which is exactly the kind of dead
    /// button that cost hours on this problem already.
    func testOnlyNotDeterminedIsRequestable() {
        XCTAssertTrue(RemindersAccess.State.notDetermined.isRequestable)
        for state: RemindersAccess.State in [.denied, .restricted, .writeOnly, .granted] {
            XCTAssertFalse(state.isRequestable, "\(state.label) must not offer a bare request")
        }
    }

    func testEveryStateHasAHumanLabel() {
        let states: [RemindersAccess.State] = [
            .notDetermined, .restricted, .denied, .writeOnly, .granted, .unknown(7),
        ]
        for state in states {
            XCTAssertFalse(state.label.isEmpty, "\(state) has no label")
        }
    }

    // MARK: - tccutil argv

    func testResetArgvTargetsThisAppOnly() throws {
        let argv = try RemindersAccess.resetArgv(
            bundleIdentifier: "com.neverprepared.brainbox-runner")

        XCTAssertEqual(argv, ["reset", "Reminders", "com.neverprepared.brainbox-runner"])
    }

    /// THE important one. `tccutil reset Reminders` with no bundle identifier
    /// resets the grant for EVERY app on the machine. A button labelled "reset"
    /// must never be able to do that, so an empty identifier is refused rather
    /// than omitted from the argv.
    func testAnEmptyBundleIdentifierIsRefusedNotOmitted() {
        for bad in ["", "   ", "\n"] {
            XCTAssertThrowsError(try RemindersAccess.resetArgv(bundleIdentifier: bad)) { err in
                XCTAssertEqual(err as? RemindersAccess.ResetError, .missingBundleIdentifier)
            }
        }
    }

    func testBundleIdentifierIsTrimmed() throws {
        let argv = try RemindersAccess.resetArgv(bundleIdentifier: "  com.example.app \n")

        XCTAssertEqual(argv.last, "com.example.app")
    }

    /// argv, never a shell string: nothing in it may need quoting, and the
    /// service name must be exact — `tccutil` silently accepts an unknown
    /// service name on some releases, which would make a reset a no-op.
    func testArgvIsExactAndShellFree() throws {
        let argv = try RemindersAccess.resetArgv(bundleIdentifier: "com.example.app")

        XCTAssertEqual(argv.count, 3)
        XCTAssertEqual(argv[0], "reset")
        XCTAssertEqual(argv[1], "Reminders")
        for arg in argv {
            XCTAssertFalse(arg.contains(" "), "\(arg) would need quoting")
            XCTAssertFalse(arg.contains(";"), "\(arg) looks like a shell fragment")
        }
    }
}
