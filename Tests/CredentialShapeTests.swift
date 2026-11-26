import XCTest

/// Pins the guard that keeps a pairing code out of the Keychain's credential slot.
final class CredentialShapeTests: XCTestCase {

    private let token = String(repeating: "a1b2c3d4", count: 8)  // 64 lowercase hex

    func testA64HexCredentialIsAnAPIKey() {
        XCTAssertEqual(CredentialShape.classify(token), .apiKey)
        XCTAssertEqual(CredentialShape.normalizedAPIKey("  \(token)\n"), token,
                       "surrounding whitespace from a paste must not make a good key unusable")
    }

    func testAPairingCodeIsNotAnAPIKey() {
        // The exact shape the Wails app shows on its Pair-a-Runner screen.
        XCTAssertEqual(CredentialShape.classify("dWRxaEDtPXrQ"), .pairingCode)
        XCTAssertEqual(CredentialShape.classify("aB3-x_9Qz0Kp"), .pairingCode)
        XCTAssertNil(CredentialShape.normalizedAPIKey("dWRxaEDtPXrQ"))
    }

    func testNearMissesAreRejected() {
        XCTAssertEqual(CredentialShape.classify(String(token.dropLast())), .invalid, "63 chars")
        XCTAssertEqual(CredentialShape.classify(token + "0"), .invalid, "65 chars")
        XCTAssertEqual(CredentialShape.classify(token.uppercased()), .invalid,
                       "the router mints lowercase hex; uppercase is not something it issued")
        XCTAssertEqual(CredentialShape.classify(String(repeating: "g", count: 64)), .invalid)
        XCTAssertEqual(CredentialShape.classify(""), .invalid)
        XCTAssertEqual(CredentialShape.classify("Bearer \(token)"), .invalid)
    }
}
