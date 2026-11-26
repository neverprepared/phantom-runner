import Foundation

/// What a pasted value is, by shape alone.
///
/// The runner's credential (the operator key from older pairings, or the scoped
/// runner token pairing mints now) is always 64 lowercase hex characters. The
/// one-time PAIRING CODE the Wails app shows is short URL-safe text (12 chars).
///
/// On 2026-11-25 a pairing code was saved to the Keychain as the API key twice in
/// one hour. The running loop kept working on the real token it held in memory,
/// while every fresh Keychain read (each session create, then the next relaunch)
/// got the code, so the runner went 401 and dropped offline. Nothing may be saved
/// as the credential unless it has the credential's shape.
enum CredentialShape: Equatable {
    case apiKey
    case pairingCode
    case invalid

    static func classify(_ raw: String) -> CredentialShape {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count == 64, s.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return .apiKey
        }
        let urlSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if (8...24).contains(s.count),
           s.unicodeScalars.allSatisfy({ $0.isASCII && urlSafe.contains($0) }) {
            return .pairingCode
        }
        return .invalid
    }

    /// The trimmed value, if it is a credential.
    static func normalizedAPIKey(_ raw: String) -> String? {
        classify(raw) == .apiKey ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
