import XCTest

/// ProfileEnv is a port of the desktop app's resolveProfileEnv, and the things
/// worth pinning are the ones that bit the original: literal `$VAR` reaching a
/// tool as a path, a profile name escaping the workspaces root, and a missing
/// profile silently resolving to a bare environment.
final class ProfileEnvTests: XCTestCase {

    // MARK: - dotenv parsing

    func testParsesKeyValuePairs() {
        let env = ProfileEnv.parseEnvFile("A=1\nB=two\n")
        XCTAssertEqual(env["A"], "1")
        XCTAssertEqual(env["B"], "two")
    }

    func testSkipsCommentsAndBlankLines() {
        let env = ProfileEnv.parseEnvFile("# a comment\n\n  \nA=1\n")
        XCTAssertEqual(env.count, 1)
        XCTAssertEqual(env["A"], "1")
    }

    func testStripsExportPrefixAndSurroundingQuotes() {
        let env = ProfileEnv.parseEnvFile("export A=\"quoted\"\nB='single'\n")
        XCTAssertEqual(env["A"], "quoted")
        XCTAssertEqual(env["B"], "single")
    }

    func testKeepsInnerEqualsSigns() {
        // A base64 secret or a connection string routinely contains '='.
        let env = ProfileEnv.parseEnvFile("TOKEN=abc=def==\n")
        XCTAssertEqual(env["TOKEN"], "abc=def==")
    }

    func testIgnoresLinesWithoutAnEquals() {
        XCTAssertTrue(ProfileEnv.parseEnvFile("just a sentence\n").isEmpty)
    }

    // MARK: - expansion

    func testExpandsReferencesBetweenValues() {
        // The real case: every profile has AZURE_CONFIG_DIR="$WORKSPACE_HOME/.azure".
        // Left literal, `az` created a directory named '$WORKSPACE_HOME' holding
        // live tokens — which is why expansion exists at all.
        let out = ProfileEnv.expand(
            ["WORKSPACE_HOME": "/w/personal", "AZURE_CONFIG_DIR": "$WORKSPACE_HOME/.azure"],
            base: [:]
        )
        XCTAssertEqual(out["AZURE_CONFIG_DIR"], "/w/personal/.azure")
    }

    func testExpandsBracedForm() {
        let out = ProfileEnv.expand(["A": "/root", "B": "${A}/sub"], base: [:])
        XCTAssertEqual(out["B"], "/root/sub")
    }

    func testExpandsFromTheBaseEnvironment() {
        let out = ProfileEnv.expand(["P": "$HOME/bin"], base: ["HOME": "/Users/x"])
        XCTAssertEqual(out["P"], "/Users/x/bin")
    }

    func testReachesAFixedPointRegardlessOfOrder() {
        // C depends on B depends on A; dictionary order is nondeterministic, so
        // a single pass would resolve this only by luck.
        let out = ProfileEnv.expand(
            ["A": "/a", "B": "$A/b", "C": "$B/c"], base: [:]
        )
        XCTAssertEqual(out["C"], "/a/b/c")
    }

    func testTerminatesOnASelfReferentialCycle() {
        // Must not hang. Partially expanded is visible; spinning is not.
        let out = ProfileEnv.expand(["A": "$B", "B": "$A"], base: [:])
        XCTAssertNotNil(out["A"])
    }

    func testUnknownNameExpandsToEmpty() {
        XCTAssertEqual(ProfileEnv.expandOne("[$NOPE]", [:]), "[]")
    }

    func testALoneDollarIsLiteral() {
        XCTAssertEqual(ProfileEnv.expandOne("cost: $", [:]), "cost: $")
    }

    // MARK: - profile name safety

    func testRejectsProfileNamesThatCouldEscapeTheRoot() {
        for bad in ["../other", "a/b", "", "a b", "a;rm", "a$b", String(repeating: "x", count: 65)] {
            XCTAssertFalse(ProfileEnv.isSafeProfileName(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testAcceptsOrdinaryProfileNames() {
        for good in ["personal", "gsa", "lakeview", "my-profile_2"] {
            XCTAssertTrue(ProfileEnv.isSafeProfileName(good), "should accept \(good)")
        }
    }

    func testWorkspaceHomeRefusesAnUnsafeName() {
        XCTAssertNil(ProfileEnv.workspaceHome(profile: "../escape", root: "/w",
                                              fileExists: { _ in true }))
    }

    func testWorkspaceHomeIsNilWhenTheDirectoryIsAbsent() {
        XCTAssertNil(ProfileEnv.workspaceHome(profile: "ghost", root: "/w",
                                              fileExists: { _ in false }))
    }

    // MARK: - full resolution

    private func resolve(
        profile: String,
        files: [String: String],
        dirs: Set<String>
    ) -> [String: String]? {
        ProfileEnv.resolve(
            profile: profile,
            home: "/Users/x",
            root: "/w",
            readFile: { files[$0] },
            dirExists: { dirs.contains($0) }
        )
    }

    func testResolveLayersIdentityThenDotenv() {
        let env = resolve(
            profile: "personal",
            files: ["/w/personal/.env": "FOO=bar\nAZURE_CONFIG_DIR=$WORKSPACE_HOME/.azure\n"],
            dirs: ["/w/personal"]
        )
        XCTAssertEqual(env?["WORKSPACE_PROFILE"], "personal")
        XCTAssertEqual(env?["WORKSPACE_HOME"], "/w/personal")
        XCTAssertEqual(env?["FOO"], "bar")
        XCTAssertEqual(env?["AZURE_CONFIG_DIR"], "/w/personal/.azure")
    }

    func testEnvrcLocalWinsOverEnv() {
        let env = resolve(
            profile: "personal",
            files: ["/w/personal/.env": "K=from-env\n",
                    "/w/personal/.envrc.local": "K=from-local\n"],
            dirs: ["/w/personal"]
        )
        XCTAssertEqual(env?["K"], "from-local")
    }

    func testPrependsProfileBinToPath() {
        let env = resolve(profile: "personal", files: [:],
                          dirs: ["/w/personal", "/w/personal/bin"])
        XCTAssertTrue(env?["PATH"]?.hasPrefix("/w/personal/bin:") == true,
                      "PATH should start with the profile bin dir, got \(env?["PATH"] ?? "nil")")
    }

    func testPathKeepsHomebrewSoLaunchdProcessesFindBrewTools() {
        // A launchd process gets no login shell, so without this every
        // brew-installed tool a collector calls is simply not found.
        let env = resolve(profile: "personal", files: [:], dirs: ["/w/personal"])
        XCTAssertTrue(env?["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    func testResolveIsNilForAnUnknownProfile() {
        // The caller must refuse to run: a collector with the wrong
        // credentials usually succeeds and emits quietly wrong output.
        XCTAssertNil(resolve(profile: "ghost", files: [:], dirs: []))
    }

    func testDoesNotInheritTheRunnerEnvironment() {
        // The runner holds its own API key and possibly a materialized cloud
        // credential bundle; a scheduled command must not read those by
        // accident. Only an explicit base plus the profile's dotenv.
        let env = resolve(profile: "personal", files: [:], dirs: ["/w/personal"])
        XCTAssertNotNil(env)
        let allowed: Set<String> = ["HOME", "USER", "SHELL", "LANG", "PATH", "TMPDIR",
                                    "WORKSPACE_PROFILE", "WORKSPACE_HOME"]
        XCTAssertTrue(Set(env!.keys).isSubset(of: allowed),
                      "unexpected inherited vars: \(Set(env!.keys).subtracting(allowed))")
    }
}
