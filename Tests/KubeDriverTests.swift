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


    // The two box tests below are the real proof of the construction's
    // contract: `exitStatus()` resumes exactly once no matter which of the
    // two events lands first. They are deliberately NOT `async` tests —
    // `wait(for:timeout:)` fails cleanly when the continuation is never
    // resumed, whereas directly awaiting a stuck `withCheckedContinuation`
    // is uncancellable and would hang the whole suite instead.

    func test_terminationBox_resumesWhenTerminationArrivesBeforeTheWaiter() {
        // The ordering a fast-exiting child actually produces: termination is
        // reported before anything awaits the exit status. The box must park
        // the status and hand it to the eventual waiter rather than drop it.
        let box = KubeProcessTermination()
        box.complete(7)
        let resumed = expectation(description: "exitStatus() resumed")
        Task {
            let code = await box.exitStatus()
            XCTAssertEqual(code, 7)
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 5)
    }

    func test_terminationBox_resumesWhenTheWaiterArrivesBeforeTermination() {
        // The other ordering: a waiter attaches while the child is still
        // running, and the later callback must resume it.
        let box = KubeProcessTermination()
        let resumed = expectation(description: "exitStatus() resumed")
        Task {
            let code = await box.exitStatus()
            XCTAssertEqual(code, 3)
            resumed.fulfill()
        }
        // Let the waiter attach first. If it has not attached yet this
        // degrades into the other ordering, which the test above covers, so
        // the sleep is a bias and not a correctness requirement.
        Thread.sleep(forTimeInterval: 0.05)
        box.complete(3)
        wait(for: [resumed], timeout: 5)
    }

    func test_terminationBox_keepsTheFirstStatusAndIgnoresASecondCompletion() {
        // Both completions land BEFORE any waiter attaches, which is what
        // makes this test able to fail for its stated purpose. With the
        // `guard status == nil` removed, the second `complete` overwrites the
        // parked status and the waiter observes 2 instead of 1. (Issuing them
        // after a waiter had attached would NOT pin the guard: `waiter` is
        // already nil by then, so the second call resumes nothing and the
        // test passes either way — it would only re-prove exactly-once,
        // which the two tests above already cover.)
        let box = KubeProcessTermination()
        box.complete(1)
        box.complete(2)
        let resumed = expectation(description: "exitStatus() resumed")
        Task {
            let code = await box.exitStatus()
            XCTAssertEqual(code, 1, "a second completion overwrote the first status")
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 5)
    }

    func test_run_manyConcurrentFastExitingInvocationsAllComplete() async throws {
        // 32 concurrent `run()` calls against a child that exits in
        // microseconds: termination is reported long before any of the parent
        // tasks awaits it, and the cooperative pool is contended the whole
        // time. This is the end-to-end check that no invocation is lost to
        // the early-termination ordering or to pool starvation. The
        // per-invocation exit code travels in argv, so a box that resumed a
        // waiter with another invocation's status fails loudly instead of
        // hanging. One fake binary serves every task because the
        // `PHANTOM_KUBECTL` override is process-global and must not be
        // written concurrently.
        //
        // HONEST LIMIT: this test does NOT distinguish registering
        // `terminationHandler` before `run()` from registering it after.
        // Probed by restoring the post-`run()` form — it still passed in
        // 0.5s, because Darwin Foundation back-fires a late handler (see the
        // note at the registration site). The deterministic proof of the
        // ordering contract is the three `terminationBox` tests above; this
        // one guards the concurrent path as a whole.
        let bin = try fakeKubectl(script: #"exit "$1""#)
        setenv("PHANTOM_KUBECTL", bin.path, 1)

        try await withTimeout(seconds: 60) {
            try await withThrowingTaskGroup(of: (Int32, Int32).self) { group in
                for i in 0..<32 {
                    let expected = Int32(i % 8)
                    group.addTask {
                        let out = try await KubeDriver.run(
                            ["\(expected)"], stdin: nil, expectSuccess: false)
                        return (expected, out.exitCode)
                    }
                }
                var seen = 0
                for try await (expected, actual) in group {
                    XCTAssertEqual(actual, expected)
                    seen += 1
                }
                XCTAssertEqual(seen, 32)
            }
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

        // NOTE ON THE BOUND: `withTimeout` canNOT rescue this test from a
        // reintroduced drain deadlock. The loser of the race is cancelled,
        // but a thread parked in `readDataToEndOfFile()` is not
        // cancellation-aware, and a throwing task group awaits its remaining
        // children before propagating — so the group never returns. Verified
        // empirically in fix round 1: with the sequential read restored, the
        // suite HUNG and had to be killed externally. A drain regression
        // therefore hangs this suite, bounded only by CI's wall clock.
        // `withTimeout` is kept because it still bounds the non-deadlock
        // failure modes — a child that is merely slow, or a fake kubectl that
        // never exits while both pipes stay readable.
        let out = try await withTimeout(seconds: 10) {
            try await KubeDriver.run(["get", "ns"], stdin: nil, expectSuccess: true)
        }
        XCTAssertEqual(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertGreaterThan(out.stderr.utf8.count, 200_000)
        XCTAssertTrue(out.stderr.hasSuffix("done\n"))
    }
}

extension KubeDriverTests {

    /// A fake kubectl that prints its own argv, so we can assert the exact
    /// command line the helpers build.
    private func argvEchoingKubectl() throws -> URL {
        try fakeKubectl(script: #"for a in "$@"; do echo "$a"; done"#)
    }

    func test_apply_passesManifestOnStdinNotArgv() async throws {
        let bin = try fakeKubectl(script: #"for a in "$@"; do echo "ARG:$a"; done; cat"#)
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let manifest = "kind: Secret\nstringData:\n  TOKEN: s3cret\n"
        let out = try await KubeDriver.apply(
            context: "k3d-phantom-local", namespace: "phantom-system",
            manifestYAML: manifest)
        // The secret must appear only in the stdin echo, never in the argv.
        let argvLines = out.stdout.split(separator: "\n").filter { $0.hasPrefix("ARG:") }
        XCTAssertFalse(argvLines.joined().contains("s3cret"))
        XCTAssertTrue(out.stdout.contains("TOKEN: s3cret"))
        XCTAssertTrue(argvLines.contains("ARG:--context=k3d-phantom-local"))
        XCTAssertTrue(argvLines.contains("ARG:-f"))
        XCTAssertTrue(argvLines.contains("ARG:-"))
    }

    func test_get_buildsJSONQueryWithSelector() async throws {
        let bin = try argvEchoingKubectl()
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let out = try await KubeDriver.get(
            context: "phantom-shared", namespace: "phantom-system",
            kinds: "deploy,sts,pod", selector: "app=kroki")
        let argv = out.stdout.split(separator: "\n").map(String.init)
        XCTAssertTrue(argv.contains("--context=phantom-shared"))
        XCTAssertTrue(argv.contains("-n"))
        XCTAssertTrue(argv.contains("phantom-system"))
        XCTAssertTrue(argv.contains("deploy,sts,pod"))
        XCTAssertTrue(argv.contains("-o"))
        XCTAssertTrue(argv.contains("json"))
        XCTAssertTrue(argv.contains("-l"))
        XCTAssertTrue(argv.contains("app=kroki"))
    }

    func test_get_omitsSelectorFlagWhenNil() async throws {
        let bin = try argvEchoingKubectl()
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let out = try await KubeDriver.get(
            context: "phantom-shared", namespace: "phantom-system",
            kinds: "pod", selector: nil)
        XCTAssertFalse(out.stdout.split(separator: "\n").map(String.init).contains("-l"))
    }

    func test_get_doesNotThrowWhenNothingFound() async throws {
        // An absent object is "not running", not an error — status must be
        // readable for an integration that was never placed here.
        let bin = try fakeKubectl(script: "echo 'no resources found' 1>&2; exit 1")
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let out = try await KubeDriver.get(
            context: "c", namespace: "n", kinds: "pod", selector: nil)
        XCTAssertEqual(out.exitCode, 1)
    }

    func test_delete_ignoresMissingObjects() async throws {
        let bin = try argvEchoingKubectl()
        setenv("PHANTOM_KUBECTL", bin.path, 1)
        let out = try await KubeDriver.delete(
            context: "c", namespace: "n", manifestYAML: "kind: Namespace\n")
        // Deleting something already gone must satisfy desired=off, not fail.
        XCTAssertTrue(out.stdout.split(separator: "\n").map(String.init)
            .contains("--ignore-not-found=true"))
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
