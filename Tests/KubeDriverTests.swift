import XCTest

/// Covers `KubeDriver`'s process plumbing. No `@testable import`: the
/// BrainboxRunnerTests bundle compiles the units under test directly into the
/// test module rather than linking the app, so `KubeDriver` is already in
/// scope (same as `RedactTests`).
final class KubeDriverTests: XCTestCase {

    /// A fake `kubectl` on disk, so the driver's process plumbing is exercised
    /// without a cluster. Returns the directory holding it.
    private func fakeKubectl(script: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kubedriver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("kubectl")
        try ("#!/bin/sh\n" + script).write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return bin
    }

    override func tearDown() {
        unsetenv("PHANTOM_KUBECTL")
        super.tearDown()
    }

    func test_kubectlCLIDirs_prefersHomebrew() {
        // The runner is a GUI login item with the bare launchd PATH, so the
        // Homebrew location must be searched, and first.
        XCTAssertEqual(KubeDriver.kubectlCLIDirs().first, "/opt/homebrew/bin")
    }

    func test_run_capturesStdoutStderrAndExitCode() async throws {
        let bin = try fakeKubectl(script: "echo out; echo err 1>&2; exit 0")
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let out = try await KubeDriver.run(["version"], stdin: nil, expectSuccess: true)
        XCTAssertEqual(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
        XCTAssertEqual(out.exitCode, 0)
    }

    func test_run_passesStdinThrough() async throws {
        let bin = try fakeKubectl(script: "cat")
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let manifest = "kind: Namespace\n"
        let out = try await KubeDriver.run(
            ["apply", "-f", "-"], stdin: Data(manifest.utf8), expectSuccess: true)
        XCTAssertEqual(out.stdout, manifest)
    }

    func test_run_throwsOnNonZeroWhenExpectingSuccess() async throws {
        let bin = try fakeKubectl(script: "echo boom 1>&2; exit 7")
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        do {
            _ = try await KubeDriver.run(["get", "ns"], stdin: nil, expectSuccess: true)
            XCTFail("expected KubeError.exit")
        } catch let error as KubeDriver.KubeError {
            guard case .exit(let code, _, _) = error else {
                return XCTFail("expected .exit, got \(error)")
            }
            XCTAssertEqual(code, 7)
        }
    }

    func test_run_doesNotThrowOnNonZeroWhenNotExpectingSuccess() async throws {
        let bin = try fakeKubectl(script: "exit 1")
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let out = try await KubeDriver.run(["get", "ns"], stdin: nil, expectSuccess: false)
        XCTAssertEqual(out.exitCode, 1)
    }

    func test_errorDescription_redactsCredentialsInStderr() {
        // Pin that redaction runs BEFORE truncation, not just that it runs.
        // A token placed so it straddles the `.prefix(300)` cut: 280 bytes of
        // filler, then the 64-hex token at offsets 280..<344. Truncate-first
        // would cut the token down to its first 20 characters (280..<300),
        // and that fragment is too short for `Redact`'s hex rule (it
        // requires 32+ contiguous hex digits), so it would survive
        // unredacted. Redact-first replaces the whole token with a single
        // placeholder before the cut ever happens, so no fragment of it can
        // appear in the result.
        let token = String(repeating: "a1b2c3d4", count: 8)  // 64 hex chars
        // The separator before the token is non-alphanumeric so the token
        // still sits on a word boundary -- Redact's hex rule requires one on
        // both sides (`(?<![0-9A-Za-z])...(?![0-9A-Za-z])`), and abutting it
        // directly against alphanumeric filler would make the real
        // implementation fail to match for an unrelated reason.
        let filler = String(repeating: "x", count: 279) + ":"
        let stderr = filler + token + " trailing context pushed past the cut"
        let error = KubeDriver.KubeError.exit(code: 1, stderr: stderr, cmd: ["get", "ns"])
        let description = error.description

        // Check every 8-char-aligned prefix of the token, from the full
        // token down to its shortest possible leaked fragment. None may
        // appear — not just the full token.
        for length in stride(from: token.count, through: 8, by: -8) {
            let fragment = String(token.prefix(length))
            XCTAssertFalse(
                description.contains(fragment),
                "description leaked a \(length)-char fragment of the token: \(fragment)")
        }
    }

    func test_run_drainsLargeStderrConcurrentlyWithStdout() async throws {
        // A sequential stdout-then-stderr read deadlocks once the child
        // writes more than the pipe buffer (~64KB) to the stream read
        // second: the child blocks writing stderr while the parent blocks
        // reading stdout to EOF (which never comes, because the child is
        // stuck). This writes to stdout too, so a reintroduced sequential
        // read hangs here, while the concurrent drain completes promptly.
        let bin = try fakeKubectl(
            script: "echo out; head -c 200000 /dev/zero | tr '\\0' x 1>&2; echo done 1>&2")
        setenv("PHANTOM_KUBECTL", bin.path, 1)

        // Explicit timeout so a reintroduced deadlock fails the test loudly
        // in seconds instead of hanging the suite indefinitely.
        let out = try await withTimeout(seconds: 10) {
            try await KubeDriver.run(["get", "ns"], stdin: nil, expectSuccess: true)
        }
        XCTAssertEqual(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertGreaterThan(out.stderr.utf8.count, 200_000)
        XCTAssertTrue(out.stderr.hasSuffix("done\n"))
    }
}

private struct TimeoutError: Error {}

/// Races `operation` against a deadline so a hang fails the test instead of
/// the whole suite.
private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
