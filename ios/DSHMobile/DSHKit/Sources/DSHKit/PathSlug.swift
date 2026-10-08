import Foundation

/// Turns a host-chosen string (a session id, an attachment id, a computer scope)
/// into one safe path component.
///
/// It lives on its own because three caches use the same rule — the session list
/// snapshot, the attachment cache and the transcript store — and a second copy of
/// "which characters may appear in a filename" is exactly the kind of drift that
/// ends with one cache writing where another cannot read (constitution VI).
///
/// The rule is deliberately conservative: anything that is not a letter, a digit,
/// `-` or `_` becomes `_`, and the result is capped at 120 characters. Two
/// different ids can therefore collide in theory; in practice session and
/// attachment ids are hex/UUID text, where the mapping is the identity.
public enum PathSlug {
    public static func slug(_ value: String) -> String {
        let allowed = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "_"
        }
        let text = String(allowed)
        return text.isEmpty ? "unknown" : String(text.prefix(120))
    }
}
