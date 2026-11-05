import Foundation

/// What the launch-time sweep of crash fragments could not turn into a report.
///
/// A crash fragment (`.partial`) is the only thing a fatal signal leaves behind. The sweep
/// that completes it runs once per launch, and it used to answer every failure the same way:
/// delete the file and move on. That made three different situations indistinguishable in
/// the diagnostics report — the folder could not be listed, the fragment could not be read,
/// or the completed report could not be written — while the evidence disappeared either way.
///
/// This value is the "partial success" record for that sweep, in the same spirit as
/// `settingsError` / `logFilesError`: nothing here fails the launch, but nothing here is
/// silent either. It is plain data so the report builder can carry it without knowing where
/// the files came from.
nonisolated struct CrashRecoveryStatus: Equatable, Sendable {
    struct FragmentIssue: Equatable, Sendable {
        /// File name, not a path: the name is what a reader can find in the folder.
        var name: String
        /// What went wrong, in the words of the layer that failed.
        var detail: String
    }

    /// The crash folder itself could not be listed. When set, the three lists below were
    /// never populated because no fragment was seen.
    var folderError: String?
    /// Fragments that were found and could not be read. Deliberately kept on disk.
    var unreadable: [FragmentIssue] = []
    /// Fragments that were read but did not contain the fields the formatter needs. These
    /// are deleted: they cannot become a report, so keeping them only postpones the decision.
    var discarded: [FragmentIssue] = []
    /// Fragments that parsed but whose report could not be written or whose file could not
    /// be removed. The fragment is kept, so the next launch can try again.
    var failedToComplete: [FragmentIssue] = []

    var isEmpty: Bool {
        folderError == nil && unreadable.isEmpty && discarded.isEmpty && failedToComplete.isEmpty
    }

    /// One sentence per fact, ready for a diagnostics report. Kept flat on purpose: a reader
    /// scanning `session-info.json` should not have to open a second level to learn that the
    /// only crash evidence on disk was left unread.
    var messages: [String] {
        var result: [String] = []
        if let folderError {
            result.append("crash folder could not be listed: \(folderError)")
        }
        for issue in unreadable {
            result.append("\(issue.name) could not be read and was kept: \(issue.detail)")
        }
        for issue in discarded {
            result.append("\(issue.name) was discarded: \(issue.detail)")
        }
        for issue in failedToComplete {
            result.append("\(issue.name) was kept but not completed: \(issue.detail)")
        }
        return result
    }
}
