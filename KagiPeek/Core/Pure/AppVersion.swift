import Foundation

/// The one spelling of the app's version, for every surface that shows it.
///
/// A build is identified by the source it was built from, not by a monotonic build number
/// that only repeats the marketing version. `scripts/stamp_commit.sh` writes the short
/// commit into `Info.plist` as `KagiPeekCommit`; the parentheses carry it.
///
/// A bundle built outside that script (an Xcode Run, a downloaded release without the key)
/// has no commit to show. It says `unknown` rather than falling back to `CFBundleVersion`:
/// the build number was the thing this format exists to stop displaying.
nonisolated enum AppVersion {
    /// The short form git itself prints: seven characters.
    static let shortCommitLength = 7

    /// `v<marketing version> (<short commit>)`, e.g. `v2.2.0 (66e5582)`.
    static func display(shortVersion: String?, commit: String?) -> String {
        let version = trimmed(shortVersion) ?? "?"
        let hash = shortCommit(commit) ?? "unknown"
        return "v\(version) (\(hash))"
    }

    /// The short hash, or nil when there is no commit to shorten.
    static func shortCommit(_ commit: String?) -> String? {
        guard let commit = trimmed(commit) else { return nil }
        return String(commit.prefix(shortCommitLength))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Bundle {
    /// The version line every surface should show. Reads the bundle once so the About tab,
    /// the launch log, the diagnostics export and the crash report cannot drift apart.
    nonisolated var kagiPeekVersionDisplay: String {
        AppVersion.display(
            shortVersion: object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            commit: object(forInfoDictionaryKey: "KagiPeekCommit") as? String
        )
    }
}
