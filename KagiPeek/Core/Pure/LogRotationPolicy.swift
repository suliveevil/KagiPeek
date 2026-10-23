import Foundation

/// One log file on disk, as the rotation policy sees it.
struct LogFileEntry: Equatable, Sendable {
    /// File name including extension: `kagipeek-2026-10-23.log`.
    var name: String
    /// The day the file belongs to (parsed from the name).
    var date: Date
    var size: Int
}

/// Pure decisions for the daily-file rotation, retention and size cap of the file log.
///
/// A file's name *is* its day, and that day is the user's calendar day: rolling at local
/// midnight is what "按日期滚动" means to the person reading the log. The time zone is a
/// parameter (defaulting to the current one) so tests can pin it instead of depending on
/// where the machine happens to be. `now` is injected in the style of `MenuCachePolicy`.
enum LogRotationPolicy {
    static let filePrefix = "kagipeek-"
    static let fileExtension = "log"

    /// Default retention: files older than this many days are pruned.
    static let retentionDays = 7
    /// Default total cap across all log files.
    static let totalLimitBytes = 20 * 1024 * 1024
    /// A single day's file above this degrades to warnings-and-errors only.
    static let dailyFileLimitBytes = 5 * 1024 * 1024

    private static let formatterLock = NSLock()
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(for timeZone: TimeZone) -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let existing = formatters[timeZone.identifier] { return existing }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatters[timeZone.identifier] = formatter
        return formatter
    }

    private static func calendar(for timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // MARK: - Names

    /// `kagipeek-YYYY-MM-DD.log` for the day containing `date`.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        "\(filePrefix)\(formatter(for: timeZone).string(from: date)).\(fileExtension)"
    }

    /// The day a log file name encodes, nil when the name does not match the pattern.
    static func date(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        guard name.hasPrefix(filePrefix), name.hasSuffix(".\(fileExtension)") else { return nil }
        let stem = name.dropFirst(filePrefix.count)
        let day = stem.dropLast(fileExtension.count + 1)
        guard day.count == 10 else { return nil }
        return formatter(for: timeZone).date(from: String(day))
    }

    /// Whether `now` has crossed into a day whose file is not `currentFileName`.
    /// Non-matching names (nil, foreign files) always roll over, so the writer converges on
    /// a correct file name instead of appending to something it cannot reason about.
    static func shouldRollover(
        currentFileName: String,
        now: Date,
        timeZone: TimeZone = .current
    ) -> Bool {
        currentFileName != fileName(for: now, timeZone: timeZone)
    }

    // MARK: - Pruning

    /// Which files to delete, given the full set of log files on disk.
    ///
    /// Two independent rules, applied in order:
    /// 1. retention — a file whose day is `retentionDays` or more before `now`'s day goes;
    /// 2. total size — while the byte total (today's file included) exceeds `totalLimit`, the
    ///    oldest remaining file goes.
    ///
    /// Today's own file is never a deletion candidate: dropping the file that is being
    /// written would not stop the writes, only orphan them.
    /// A future-dated file is not expired by rule 1 (negative age) but still counts toward
    /// the size cap, so a runaway clock cannot grow the folder forever.
    static func filesToPrune(
        entries: [LogFileEntry],
        totalLimit: Int = LogRotationPolicy.totalLimitBytes,
        retentionDays: Int = LogRotationPolicy.retentionDays,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> [LogFileEntry] {
        let todayName = fileName(for: now, timeZone: timeZone)
        let calendar = calendar(for: timeZone)
        let today = calendar.startOfDay(for: now)
        let candidates = entries.filter { $0.name != todayName }
        let todaySize = entries.first { $0.name == todayName }?.size ?? 0

        // Rule 1: retention. Age is measured in whole days.
        let survivors = candidates.filter { entry in
            let age = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: entry.date),
                to: today
            ).day ?? 0
            return age < retentionDays
        }
        let expired = candidates.filter { candidate in !survivors.contains(candidate) }

        // Rule 2: size. Oldest first until the total (with today's file) fits.
        var remaining = survivors.sorted { $0.date < $1.date }
        var runningTotal = todaySize + remaining.reduce(0) { $0 + $1.size }
        var oversized: [LogFileEntry] = []
        while runningTotal > totalLimit, !remaining.isEmpty {
            let oldest = remaining.removeFirst()
            oversized.append(oldest)
            runningTotal -= oldest.size
        }
        return expired + oversized
    }
}
