import Foundation

/// Scrubs secret-looking material out of text before it is logged, relayed to
/// the router, or returned in a session result.
///
/// The runner shells out to `docker create` with the whole session environment
/// on the command line (`-e BRAINBOX_TOKEN=…`, `-e GITHUB_TOKEN=…`). When that
/// command fails the argv is the single most useful thing to report — and also
/// the most dangerous, because it carries live credentials. The router scrubs
/// what it receives (`phantom_router.redact`), but by then the raw string has
/// already been written to *this* host's unified log, where it persists and is
/// readable by anyone who can run `log show`. So we redact at the source too.
///
/// Deliberately mirrors the router's Python `redact_secrets` so the two layers
/// agree on what counts as a secret. Idempotent — re-running over already
/// redacted text rewrites the placeholder whole rather than clipping it.
enum Redact {
    static let placeholder = "[REDACTED]"

    // MARK: - Public API

    /// Redact secrets in free-form text (an error message, stderr, a log line).
    static func text(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var out = input
        out = sub(vendorRE, in: out, template: placeholder)
        out = sub(jwtRE, in: out, template: placeholder)
        out = sub(bearerRE, in: out, template: "$1 \(placeholder)")
        out = sub(assignRE, in: out, template: "$1=\(placeholder)")
        out = sub(flagRE, in: out, template: "$1 \(placeholder)")
        out = sub(colonRE, in: out, template: "$1\(placeholder)")
        out = redactHex(in: out)
        return out
    }

    /// Render a command line for display with its secrets removed.
    ///
    /// Tokens are joined the way a shell would show them, then scrubbed as
    /// text — `["-e", "BRAINBOX_TOKEN=abc"]` becomes `-e BRAINBOX_TOKEN=[REDACTED]`.
    static func argv(_ argv: [String]) -> String {
        text(argv.joined(separator: " "))
    }

    // MARK: - Patterns

    /// Fragments that mark an identifier as naming a secret. Matched
    /// case-insensitively anywhere inside a longer name, so `BRAINBOX_TOKEN`,
    /// `CL_REGISTRY__PASSWORD` and `registry_password` all hit.
    private static let sensitiveWord = [
        "tokens?", "secrets?", "passwords?", "passwd", "pwd",
        "api[_-]?keys?", "apikey", "access[_-]?keys?", "private[_-]?keys?",
        "session[_-]?keys?", "signing[_-]?keys?", "credentials?", "creds",
        "authorization", "bearer", "signature",
    ].joined(separator: "|")

    /// A full identifier containing one of the sensitive words.
    private static let name = "[A-Za-z0-9_.\\-]*(?:\(sensitiveWord))[A-Za-z0-9_.\\-]*"

    /// A value that may be bare, single-quoted or double-quoted. The bare form
    /// stops at whitespace and at the punctuation that ends a JSON/YAML scalar.
    /// An already-substituted placeholder is matched first so re-running the
    /// redaction rewrites it whole instead of clipping its trailing bracket.
    private static let value = #"(?:\[REDACTED\]|"[^"]*"|'[^']*'|[^\s'",;)\]}]+)"#

    /// `KEY=value` — docker `-e`, shell exports, connection strings.
    private static let assignRE = re("\\b(\(name))\\s*=\\s*\(value)")

    /// `--token value` (the `--token=value` form is already an assignment).
    /// The value must not itself look like a flag, or we would swallow the next one.
    private static let flagRE = re(#"(--(?:\#(name)))\s+(?:\[REDACTED\]|"[^"]*"|'[^']*'|[^\s'"-][^\s'"]*)"#)

    /// `Bearer <token>` wherever it appears, header or prose.
    private static let bearerRE = re(#"\b(bearer)\s+(?:\[REDACTED\]|[A-Za-z0-9._~+/=-]{8,})"#)

    /// `"key": "value"` / `key: value`. The value may carry a `Bearer` prefix
    /// left over from `bearerRE`, which we consume so only one placeholder remains.
    private static let colonRE = re(
        #"(["']?(?:\#(name))["']?\s*:\s*)"#
        + #"(?:\[REDACTED\]|"[^"]*"|'[^']*'|(?:Bearer\s+)?(?:\[REDACTED\]|[^\s,;"'}\]]+))"#
    )

    /// Vendor-issued credentials, recognisable by prefix alone. Case-sensitive:
    /// these prefixes are issued in a fixed case, and matching loosely would
    /// start swallowing ordinary words.
    private static let vendorRE = re(
        #"\b(?:github_pat_[A-Za-z0-9_]{20,}"#
        + #"|gh[pousr]_[A-Za-z0-9]{20,}"#
        + #"|sk-(?:ant-)?[A-Za-z0-9_-]{16,}"#
        + #"|xox[abprs]-[A-Za-z0-9-]{10,}"#
        + #"|AKIA[0-9A-Z]{16}"#
        + #"|ops_[A-Za-z0-9_-]{20,}"#
        + #"|glpat-[A-Za-z0-9_-]{16,})"#,
        []
    )

    /// JSON Web Tokens.
    private static let jwtRE = re(#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#, [])

    /// Long single-case hex runs — the fleet's 64-hex unified-token convention
    /// and `secrets.token_hex` API keys. Content digests are exempted below.
    /// Case-sensitive on purpose: a *single-case* run is the signal, so matching
    /// case-insensitively would also catch mixed-case identifiers that are not
    /// secrets.
    private static let hexRE = re(#"(?<![0-9A-Za-z])(?:[0-9a-f]{32,}|[0-9A-F]{32,})(?![0-9A-Za-z])"#, [])

    /// Digest prefixes whose hex payload is not a secret and is worth keeping —
    /// an image or layer digest is exactly what you need to debug a bad pull.
    private static let digestPrefixes = ["sha256:", "sha512:", "sha1:", "md5:", "blake3:"]

    // MARK: - Engine

    /// Compile a constant pattern. A failure here is a programmer error, but the
    /// runner must never crash over a log line — fall back to a regex that can
    /// never match rather than trapping.
    private static func re(
        _ pattern: String,
        _ options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
            return regex
        }
        // swiftlint:disable:next force_try - "(?!)" is a valid never-matching pattern.
        return try! NSRegularExpression(pattern: "(?!)", options: [])
    }

    private static func sub(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// Replace long hex runs, leaving content-addressed digests (`sha256:<hex>`)
    /// intact. Walks matches back-to-front so earlier ranges stay valid.
    private static func redactHex(in text: String) -> String {
        let ns = text as NSString
        let matches = hexRE.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let head = ns.substring(to: match.range.location)
            if digestPrefixes.contains(where: { head.hasSuffix($0) }) { continue }
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: placeholder)
        }
        return out
    }
}
