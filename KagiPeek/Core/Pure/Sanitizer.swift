import Foundation

/// Redacts sensitive values from a diagnostic message before it reaches a file.
///
/// Everything written to the file log passes through `redact` exactly once, at the write
/// boundary (`FileLogStore`) — call sites never have to remember to sanitise. The rules are
/// deliberately conservative: a false positive costs a debugging detail, a false negative
/// costs the user's token.
enum Sanitizer {
    /// Marker inserted in place of a redacted value.
    static let redactedMarker = "<redacted>"

    // MARK: - Regex table (applied in order)

    private static let rules: [(pattern: String, template: String)] = [
        // 1. Sensitive URL query keys: `?api_key=…`, `&token=…`.
        (
            "(?i)([?&](?:api[_-]?key|access[_-]?token|token|secret|client[_-]?secret|password|passwd|signature|sig|session[_-]?id|auth)[a-z0-9_]*=)[^&\\s]*",
            "$1\(redactedMarker)"
        ),
        // 2. Any other URL query segment, wholesale: `?x=1&y=2` → `?<query>`. Requiring an
        //    `=` keeps prose like "what?no" untouched.
        (
            "\\?[^\\s]*=[^\\s]*",
            "?<query>"
        ),
        // 3. Bearer / Basic credentials.
        (
            "(?i)\\b(bearer|basic)\\s+[a-z0-9._~+/=-]{8,}",
            "$1 \(redactedMarker)"
        ),
        // 4. Bare `key=value` / `key: value` pairs.
        (
            "(?i)\\b((?:api[_-]?key|access[_-]?token|token|secret|password|passwd|credential)[a-z0-9_]*\\s*[:=]\\s*)\\S+",
            "$1\(redactedMarker)"
        ),
        // 5. E-mail addresses.
        (
            "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            "<email>"
        ),
        // 6. Long hex strings (hashes, digests).
        (
            "\\b[0-9a-fA-F]{32,}\\b",
            "<hex>"
        ),
        // 7. Long base64 blobs.
        (
            "\\b[A-Za-z0-9+/]{40,}={0,2}\\b",
            "<b64>"
        )
    ]

    private static let compiled: [NSRegularExpression] = rules.map { rule in
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: rule.pattern)
    }

    // MARK: - API

    /// The full pipeline a message goes through before it is appended to a log file:
    /// control characters neutralised (one line stays one line), then the redaction rules.
    ///
    /// `homePrefix` — the user's home directory — is replaced with `~` so file paths in the
    /// log stop advertising the account name. Passed in because this type lives in the pure
    /// target, which should not know how to ask for a home directory.
    static func prepare(_ message: String, homePrefix: String? = nil) -> String {
        var result = stripControlCharacters(message)
        if let homePrefix, !homePrefix.isEmpty {
            result = result.replacingOccurrences(of: homePrefix, with: "~")
        }
        return redact(result)
    }

    /// Applies the redaction rules. Idempotent: an already-redacted line survives a second
    /// pass unchanged (the markers contain no `=`-bearing payloads the rules could re-match).
    ///
    /// The range is recomputed for every rule: each replacement changes the string's length,
    /// and an `NSRange` taken from the previous edition is exactly how a sanitizer crashes on
    /// the one input it was written for.
    static func redact(_ line: String) -> String {
        var result = line
        for (index, regex) in compiled.enumerated() {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rules[index].template
            )
        }
        return result
    }

    /// Replaces control characters (except tab) with spaces so a message can never smuggle
    /// a second log line in via a newline, and never carries terminal escapes.
    static func stripControlCharacters(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            if (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F {
                return " "
            }
            return Character(scalar)
        })
    }

    /// Clamps a string to `limit` characters, appending an ellipsis when it was cut.
    /// Menu item titles ride along in log messages and can be arbitrarily long.
    static func clamp(_ text: String, limit: Int = 80) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
