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
        // A token echoed back by kubectl must not survive into a log line.
        let token = String(repeating: "a1b2c3d4", count: 8)  // 64 hex chars
        let error = KubeDriver.KubeError.exit(
            code: 1, stderr: "unauthorized: token \(token)", cmd: ["get", "ns"])
        XCTAssertFalse(error.description.contains(token))
    }
}
