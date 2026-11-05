import Foundation

/// Applies `Sanitizer` to every string in the diagnostics payload, once, at the point where the
/// payload becomes a file.
///
/// The report is the log's sibling, not a second channel with its own rules: it quotes window
/// titles, the whole settings blob (including whatever the user typed into `ignoredCommands`)
/// and the data-folder path, and the user then attaches it to a bug report. Redaction belongs at
/// the same kind of boundary `FileLogStore` uses — one pass over everything the file will
/// contain — rather than at twenty call sites that each have to remember, because the first one
/// somebody forgets is the one that leaks.
///
/// **What it will not do is stay silent.** Every field the rules changed is named in
/// `redactedFields`, so whoever reads the report can tell "the title was removed before you got
/// it" from "the app really had no title". Same reasoning as `sanitizerFailedPatterns`: a
/// redaction the reader cannot see is indistinguishable from a report with a hole in it.
///
/// The home-prefix replacement is deliberately *not* counted as a redaction. Every report from
/// every user has a home directory in it, so naming `dataFolder` every time would turn the field
/// into noise and hide the case that matters; `~` speaks for itself.
nonisolated enum DiagnosticsRedactor {
    struct Outcome {
        var payload: [String: Any]
        /// Dotted paths of the fields the rules changed, sorted. Empty when nothing was cut.
        var redactedFields: [String]
    }

    /// - Parameter homePrefix: the user's home directory, replaced with `~`. Passed in because
    ///   this type lives in the pure target, which should not know how to ask for one.
    static func redact(_ payload: [String: Any], homePrefix: String? = nil) -> Outcome {
        var changed: Set<String> = []
        let cleaned = walk(payload, path: "", homePrefix: homePrefix, changed: &changed) as? [String: Any]
        return Outcome(payload: cleaned ?? payload, redactedFields: changed.sorted())
    }

    /// The same pass, followed by serialisation — the shape both report writers need.
    ///
    /// `redactedFields` is inserted after the walk so it describes the file the reader is
    /// holding, and stays absent when nothing was cut, in the same shape as `settingsError`.
    static func jsonData(_ payload: [String: Any], homePrefix: String? = nil) throws -> Data {
        var outcome = redact(payload, homePrefix: homePrefix)
        if !outcome.redactedFields.isEmpty {
            outcome.payload["redactedFields"] = outcome.redactedFields
        }
        return try JSONSerialization.data(
            withJSONObject: outcome.payload,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func walk(
        _ value: Any,
        path: String,
        homePrefix: String?,
        changed: inout Set<String>
    ) -> Any {
        if let text = value as? String {
            let redacted = Sanitizer.redact(text)
            if redacted != text {
                // A top-level value has no key of its own; "?" is honest about that rather
                // than inventing a name.
                changed.insert(path.isEmpty ? "?" : path)
            }
            guard let homePrefix, !homePrefix.isEmpty else { return redacted }
            return redacted.replacingOccurrences(of: homePrefix, with: "~")
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                // Keys are this project's own vocabulary, never user data. Only values are
                // walked, which is also why a field named "token" cannot break the JSON.
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                result[key] = walk(child, path: childPath, homePrefix: homePrefix, changed: &changed)
            }
            return result
        }
        if let array = value as? [Any] {
            // No index in the path: `windowTitles` is the field a reader has to understand, and
            // which element was cut does not change what happened to it.
            return array.map { walk($0, path: path, homePrefix: homePrefix, changed: &changed) }
        }
        // Numbers, booleans and null carry no text and are left exactly as they are.
        return value
    }
}
