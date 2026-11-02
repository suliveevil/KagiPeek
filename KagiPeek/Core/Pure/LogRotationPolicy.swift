import Foundation

/// One log file on disk, as the rotation policy sees it.
nonisolated struct LogFileEntry: Equatable, Sendable {
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
///
/// Nothing here is shared or mutable: the day is stamped from calendar components, so there
/// is no formatter to cache and no lock to hold. That is how it should stay — this enum is
/// called from the file log's own queue, and purity is the only thing making that safe.
nonisolated enum LogRotationPolicy {
    static let filePrefix = "kagipeek-"
    static let fileExtension = "log"

    /// Default retention: files older than this many days are pruned.
    static let retentionDays = 7
    /// Default total cap across all log files.
    static let totalLimitBytes = 20 * 1024 * 1024
    /// A single day's file above this degrades to warnings-and-errors only.
    static let dailyFileLimitBytes = 5 * 1024 * 1024

    private static func calendar(for timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // MARK: - Names

    /// `yyyy-MM-dd` for the day containing `date`.
    ///
    /// Built from integers rather than a `DateFormatter`. The format is fixed, the calendar
    /// is already a parameter of everything here, and zero-padding is all the format
    /// actually needs. The formatter cost this file its purity: `DateFormatter` is not
    /// `Sendable`, so it had to be cached, and the cache had to be locked, which made
    /// `LogRotationPolicy` the one type in `Core/Pure` carrying shared mutable state — a
    /// lock and a `nonisolated(unsafe)` both spent on formatting a day.
    static func dayStamp(for date: Date, timeZone: TimeZone = .current) -> String {
        let parts = calendar(for: timeZone).dateComponents([.year, .month, .day], from: date)
        // A Gregorian calendar always resolves these three for any `Date`; the fallbacks
        // match the `?? 0` this file already uses when it reads `.day` for the retention age.
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The day a `yyyy-MM-dd` stamp names, nil when the stamp does not name a real day.
    ///
    /// The components are read back off the date that was built and compared: `Calendar`
    /// will turn 2026-02-30 into March 2 without complaint, and a log file named for a day
    /// that never happened is not a file of ours. This is at least as strict as the
    /// non-lenient parser it replaces. No test covers that case either way, so the check is
    /// here because it is true, not because a test asked for it.
    static func date(fromDayStamp stamp: String, timeZone: TimeZone = .current) -> Date? {
        let calendar = calendar(for: timeZone)
        let parts = stamp.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        let readBack = calendar.dateComponents([.year, .month, .day], from: date)
        return readBack.year == year && readBack.month == month && readBack.day == day ? date : nil
    }

    /// `kagipeek-YYYY-MM-DD.log` for the day containing `date`.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        "\(filePrefix)\(dayStamp(for: date, timeZone: timeZone)).\(fileExtension)"
    }

    /// The day a log file name encodes, nil when the name does not match the pattern.
    static func date(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        guard name.hasPrefix(filePrefix), name.hasSuffix(".\(fileExtension)") else { return nil }
        let stem = name.dropFirst(filePrefix.count)
        let day = stem.dropLast(fileExtension.count + 1)
        guard day.count == 10 else { return nil }
        return date(fromDayStamp: String(day), timeZone: timeZone)
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
