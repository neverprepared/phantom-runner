import XCTest

/// Covers `Redact` and the `DockerDriver.DockerError` message that motivated it:
/// a failed `docker create` used to relay the whole argv — including
/// `-e BRAINBOX_TOKEN=<live token>` — into this host's unified log and into the
/// router's HTTP 500 body.
final class RedactTests: XCTestCase {

    private let placeholder = "[REDACTED]"

    // MARK: - The reported leak

    /// The exact shape reported from the field: a `session.create` failure on
    /// m3-64 whose error carried a live hub token.
    func testDockerCreateErrorDropsTheHubToken() {
        let token = "11111111-2222-3333-4444-555555555555"
        let argv = [
            "create", "--name", "worker-probe",
            "-e", "BRAINBOX_ROLE=worker",
            "-e", "BRAINBOX_TOKEN=\(token)",
            "brainbox:latest", "sleep", "infinity",
        ]
        let error = DockerDriver.DockerError.exit(
            code: 125,
            stderr: "Unable to find image 'brainbox:latest' locally\npull access denied for brainbox",
            cmd: argv
        )
        let message = error.description

        XCTAssertFalse(message.contains(token), "live hub token must not survive: \(message)")
        XCTAssertTrue(message.contains("BRAINBOX_TOKEN=\(placeholder)"))
        // The diagnostics that make the error worth reporting must survive.
        XCTAssertTrue(message.contains("BRAINBOX_ROLE=worker"), "non-secret env is diagnostic")
        XCTAssertTrue(message.contains("brainbox:latest"))
        XCTAssertTrue(message.contains("exit 125"))
        XCTAssertTrue(message.contains("pull access denied"))
    }

    /// Redaction happens before the 300-char stderr clip, so a token near the
    /// truncation boundary can never be half-emitted.
    func testStderrIsRedactedBeforeTruncation() {
        let token = "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456"
        let stderr = String(repeating: "x", count: 290) + " token=\(token) trailing"
        let error = DockerDriver.DockerError.exit(code: 1, stderr: stderr, cmd: ["create"])

        let message = error.description
        XCTAssertFalse(message.contains(token))
        XCTAssertFalse(message.contains("ghp_AbCd"), "no partial token may leak past the clip")
    }

    func testBinaryNotFoundIsUnchanged() {
        XCTAssertEqual(
            DockerDriver.DockerError.binaryNotFound.description,
            "`docker` not on PATH"
        )
    }

    // MARK: - argv

    func testArgvRedactsEverySecretEnvPair() {
        let argv = [
            "create",
            "-e", "GITHUB_TOKEN=ghp_000000000000000000000000000000000000",
            "-e", "CL_BRAIN_API_TOKEN=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            "-e", "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnop",
            "-e", "OLLAMA_HOST=http://host.docker.internal:11434",
        ]
        let out = Redact.argv(argv)

        XCTAssertFalse(out.contains("ghp_0"))
        XCTAssertFalse(out.contains("deadbeef"))
        XCTAssertFalse(out.contains("sk-ant-api03"))
        XCTAssertTrue(out.contains("OLLAMA_HOST=http://host.docker.internal:11434"),
                      "a non-secret env pair stays readable")
    }

    // MARK: - text patterns

    func testNamedAssignmentsAreRedactedCaseInsensitively() {
        for pair in ["PASSWORD=hunter2hunter2", "registry_password=swordfish123",
                     "CL_REGISTRY__PASSWORD=abc12345", "my-api-key=abcdefghijkl"] {
            let out = Redact.text(pair)
            XCTAssertTrue(out.hasSuffix("=\(placeholder)"), "\(pair) → \(out)")
        }
    }

    func testBearerHeaderIsRedacted() {
        let out = Redact.text("Authorization: Bearer abcdefghijklmnop")
        XCTAssertFalse(out.contains("abcdefghijklmnop"))
    }

    func testJSONColonFormIsRedacted() {
        let out = Redact.text(#"{"registry_password": "swordfish", "role": "worker"}"#)
        XCTAssertFalse(out.contains("swordfish"))
        XCTAssertTrue(out.contains("worker"), "non-secret JSON fields survive")
    }

    func testVendorPrefixesAreRedactedWithoutNamingContext() {
        // No `KEY=` around them — recognised by prefix alone.
        for secret in ["ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
                       "github_pat_11ABCDEFG0abcdefghijklmnop",
                       "xoxb-1234567890-abcdef",
                       "AKIAIOSFODNN7EXAMPLE",
                       "glpat-abcdefghijklmnopqr"] {
            let out = Redact.text("failed with \(secret) here")
            XCTAssertFalse(out.contains(secret), "\(secret) survived as \(out)")
        }
    }

    func testJWTIsRedacted() {
        // The public jwt.io sample token — a fixture, not a credential.
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk" // gitleaks:allow
        XCTAssertFalse(Redact.text("token \(jwt)").contains(jwt))
    }

    func testBare64HexTokenIsRedacted() {
        let hex = "0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de"
        XCTAssertFalse(Redact.text("value \(hex)").contains(hex))
    }

    // MARK: - what must NOT be redacted

    func testContentDigestsSurvive() {
        let digest = "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        XCTAssertEqual(Redact.text("pulled \(digest)"), "pulled \(digest)")
    }

    func testOrdinaryTextIsUntouched() {
        let plain = "docker create --name worker-probe brainbox:latest sleep infinity"
        XCTAssertEqual(Redact.text(plain), plain)
    }

    func testMixedCaseIdentifierIsNotMistakenForAHexToken() {
        // 32+ chars but mixed case → not the single-case hex shape we redact.
        let identifier = "AbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCdEf"
        XCTAssertEqual(Redact.text(identifier), identifier)
    }

    // MARK: - idempotency

    func testRedactionIsIdempotent() {
        let once = Redact.text("BRAINBOX_TOKEN=11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(Redact.text(once), once)
        XCTAssertEqual(once, "BRAINBOX_TOKEN=\(placeholder)")
    }

    func testEmptyStringIsHandled() {
        XCTAssertEqual(Redact.text(""), "")
        XCTAssertEqual(Redact.argv([]), "")
    }
}
