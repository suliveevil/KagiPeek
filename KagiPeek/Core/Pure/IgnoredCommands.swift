import Foundation

/// One command the user asked KagiPeek to hide.
///
/// `appBundleID` is nil for a rule that applies everywhere. The same title is not the same
/// command in two apps — every app has “Settings…”, while “Reload Page” belongs to a browser —
/// so a rule that names an app only matches inside that app.
struct IgnoredCommand: Codable, Hashable, Sendable, Identifiable {
    var title: String
    /// nil = applies to every app.
    var appBundleID: String?

    /// Identity used by the settings list: two rules with the same identity would render
    /// twice and need two deletions.
    var id: String { "\(appBundleID ?? "*")|\(title.lowercased())" }

    /// Grouping key in the settings list; `*` is the global group.
    var scopeKey: String { appBundleID ?? "*" }
}

enum IgnoredCommands {
    /// Whether a command should be hidden.
    ///
    /// Title matching is case-insensitive because menu titles come from many sources (an
    /// app's own menu, a third-party config file, the built-in catalog) and they do not agree
    /// on capitalisation.
    static func isIgnored(_ title: String, bundleID: String?, in commands: [IgnoredCommand]) -> Bool {
        guard !commands.isEmpty else { return false }
        let needle = title.lowercased()
        return commands.contains { command in
            guard command.title.lowercased() == needle else { return false }
            guard let scope = command.appBundleID else { return true }
            return scope == bundleID
        }
    }

    /// Trims, drops empties and de-duplicates, then orders by scope and title so the settings
    /// list does not reshuffle itself after every edit.
    static func normalized(_ commands: [IgnoredCommand]) -> [IgnoredCommand] {
        var seen = Set<String>()
        var result: [IgnoredCommand] = []
        for command in commands {
            let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let scope = command.appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = IgnoredCommand(
                title: title,
                appBundleID: (scope?.isEmpty ?? true) ? nil : scope
            )
            guard seen.insert(entry.id).inserted else { continue }
            result.append(entry)
        }
        return result.sorted { lhs, rhs in
            if lhs.scopeKey != rhs.scopeKey { return lhs.scopeKey < rhs.scopeKey }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Every scope that has at least one rule, global (`nil`) first.
    static func scopes(in commands: [IgnoredCommand]) -> [String?] {
        var scopes: [String?] = []
        if commands.contains(where: { $0.appBundleID == nil }) {
            scopes.append(nil)
        }
        let appScopes = Set(commands.compactMap(\.appBundleID)).sorted()
        scopes.append(contentsOf: appScopes.map { Optional($0) })
        return scopes
    }
}
