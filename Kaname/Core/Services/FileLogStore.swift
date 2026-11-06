import Foundation

/// The daily-rolling file log: one file per day, batched appends, retention and size caps.
///
/// Everything here runs on a private serial queue. Callers — including the event-tap callback
/// on the main thread — only enqueue, so no diagnostics code can ever put a disk seek between
/// the user's key press and the app receiving it.
///
/// A failure inside this type is a no-op, never an error: the log exists to explain problems,
/// and a logger that can break the app it observes is worse than no logger at all.
nonisolated final class FileLogStore: @unchecked Sendable {
    /// The one shared instance. `FileLogStore` is safe to share because every mutable
    /// property below is touched only from the private serial `queue`; `enqueue`, `flushNow`
    /// and `tail` are the only entry points and none of them touch state off that queue.
    /// Under Swift 6 a `static let` of a non-`Sendable` class is a global-mutable-state
    /// error, so the conformance is load-bearing, not decoration.
    static let shared = FileLogStore()

    /// Lines held before a flush. Small enough that a crash loses only a handful of entries.
    private static let batchSize = 32
    /// How long a partial batch may sit in memory.
    private static let flushInterval: TimeInterval = 0.2

    private let queue = DispatchQueue(label: "com.suliveevil.kaname.diag.file", qos: .utility)
    private let directory: URL
    private let nowProvider: () -> Date
    private let timeZone: TimeZone

    /// A line waiting for the next write, with the level kept alongside it.
    ///
    /// The level survives the buffer because a failed write has to decide what is worth
    /// keeping without parsing the rendered line back apart. `isSummary` marks the line this
    /// store writes about its own losses, so repeated failures do not accumulate summaries.
    private struct PendingLine {
        var text: String
        var level: DiagLevel
        var isSummary = false
    }

    /// How many warning/error lines are retained after a write failure. The failed batch is
    /// otherwise dropped: retrying it forever would turn a full disk into an I/O storm, and
    /// the lines that explain the failure are exactly the ones worth a bounded retry.
    private static let retainedFailureLines = batchSize * 2

    // State owned by `queue`.
    private var pending: [PendingLine] = []
    private var flushScheduled = false
    private var handle: FileHandle?
    private var openFileName: String?
    private var openFileSize = 0
    private var droppedBelowWarning = 0
    /// Lines that never reached disk, for either the daily size cap or a failed write. Never
    /// reset: the diagnostics report needs the session total, not the last batch's.
    private var droppedLineCountTotal = 0
    private var lastPreparedDay: String?
    /// When the last attempt to open a file for the day happened. A failed open (read-only
    /// folder, full disk) is retried at most once a minute — retrying per line would turn a
    /// storage problem into an I/O storm exactly when the disk is already unhappy.
    private var lastOpenAttempt: Date?
    private static let openRetryInterval: TimeInterval = 60

    private let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    init(
        directory: URL = DataDirectory.url(for: "logs"),
        timeZone: TimeZone = .current,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.timeZone = timeZone
        self.nowProvider = nowProvider
        lineFormatter.timeZone = timeZone
    }

    var folderURL: URL { directory }

    /// Lines this session could not write. Exposed so a diagnostics report can say the log
    /// is incomplete instead of presenting a gap as if nothing had happened.
    var droppedLineCount: Int {
        queue.sync { droppedLineCountTotal }
    }

    // MARK: - Writing

    func enqueue(level: DiagLevel, tag: DiagTag, message: String) {
        queue.async { [weak self] in
            self?.append(level: level, tag: tag, message: message)
        }
    }

    private func append(level: DiagLevel, tag: DiagTag, message: String) {
        let now = nowProvider()
        prepareIfNeeded(now: now)

        // A runaway single-day file stops accepting chatter but keeps the lines that explain
        // a failure. The alternative — dropping errors too — would silence the one thing the
        // cap exists to preserve.
        if openFileSize > LogRotationPolicy.dailyFileLimitBytes, level < .warning {
            droppedBelowWarning += 1
            droppedLineCountTotal += 1
            return
        }

        let clean = Sanitizer.prepare(message, homePrefix: NSHomeDirectory())
        let line = "\(lineFormatter.string(from: now)) \(level.character) \(tag.keyword) \(clean)\n"
        pending.append(PendingLine(text: line, level: level))
        openFileSize += line.utf8.count

        if pending.count >= Self.batchSize {
            flush()
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    /// Writes the batch to disk. Called on `queue` only.
    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        if droppedBelowWarning > 0 {
            let count = droppedBelowWarning
            droppedBelowWarning = 0
            pending.append(PendingLine(
                text: "\(lineFormatter.string(from: nowProvider())) W [settings] dropped \(count) verbose lines (daily size cap)\n",
                level: .warning
            ))
        }

        guard let handle else {
            // No file is open: the open failed, or the previous write broke the handle.
            // Keeping every line until the folder recovers would grow without bound, so the
            // batch is reduced to what explains a failure and the rest is counted.
            dropPending(reason: "the log file is not open")
            return
        }

        let text = pending.map(\.text).joined()
        do {
            try handle.write(contentsOf: Data(text.utf8))
            pending.removeAll(keepingCapacity: true)
        } catch {
            // The handle is no longer trustworthy. `prepareIfNeeded` reopens at most once a
            // minute; until then the lines below are the bounded retry.
            self.handle = nil
            openFileName = nil
            openFileSize = 0
            dropPending(reason: error.localizedDescription)
        }
    }

    /// Discards the part of `pending` that is not worth retrying, and leaves a line that says
    /// how much was lost.
    ///
    /// Warning and error lines are kept (bounded by `retainedFailureLines`) because they are
    /// the ones that explain the failure; everything else is counted in `droppedLineCountTotal`
    /// and reported. The summary line is itself `isSummary`, so a long outage leaves one
    /// explanation rather than one per failed batch.
    private func dropPending(reason: String) {
        let priorSummary = pending.last(where: \.isSummary)
        let retained = pending
            .filter { $0.level >= .warning && !$0.isSummary }
            .suffix(Self.retainedFailureLines)
        let realLost = pending.filter { !$0.isSummary }.count - retained.count
        droppedLineCountTotal += max(0, realLost)

        pending = Array(retained)
        if realLost > 0 {
            pending.append(PendingLine(
                text: "\(lineFormatter.string(from: nowProvider())) W [settings] dropped \(realLost) diagnostic lines: \(reason)\n",
                level: .warning,
                isSummary: true
            ))
        } else if let priorSummary {
            // Nothing new was lost, but the existing explanation has not reached disk yet.
            pending.append(priorSummary)
        }
    }

    /// Flushes synchronously, with a bound. Used on termination, where a debounced write would
    /// never fire — but where a stuck disk must not stop the app from quitting.
    func flushNow(timeout: TimeInterval = 0.5) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.flush()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Last `count` lines of the file for `date`, for the crash report's tail.
    ///
    /// The result separates "no log file that day" from "the file could not be read": a crash
    /// report with no tail is ambiguous otherwise, and the ambiguous version is the one that
    /// hides a broken log folder.
    func tail(of date: Date, lines count: Int = 200) -> LogTailResult {
        let url = directory.appendingPathComponent(
            LogRotationPolicy.fileName(for: date, timeZone: timeZone)
        )
        // Read through the queue so a pending batch is on disk before the tail is taken.
        flushNow(timeout: 0.2)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return .unreadable("the file is not valid UTF-8")
            }
            let all = text.split(separator: "\n", omittingEmptySubsequences: true)
            return .lines(all.suffix(count).map(String.init))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    // MARK: - Opening, rolling, pruning (queue only)

    private func prepareIfNeeded(now: Date) {
        let todayName = LogRotationPolicy.fileName(for: now, timeZone: timeZone)
        if lastPreparedDay != todayName {
            lastPreparedDay = todayName
            openFile(named: todayName)
            lastOpenAttempt = now
            prune(now: now)
            return
        }
        // A previous attempt failed: stay quiet until the retry window has passed.
        if handle == nil, let attempt = lastOpenAttempt, now.timeIntervalSince(attempt) < Self.openRetryInterval {
            return
        }
        if LogRotationPolicy.shouldRollover(
            currentFileName: openFileName ?? "",
            now: now,
            timeZone: timeZone
        ) {
            openFile(named: todayName)
            lastOpenAttempt = now
        }
    }

    private func openFile(named name: String) {
        handle?.closeFile()
        handle = nil
        openFileName = nil
        openFileSize = 0

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: url)
            _ = try opened.seekToEnd()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            openFileSize = (attributes?[.size] as? Int) ?? 0
            handle = opened
            openFileName = name
        } catch {
            handle = nil
            openFileName = nil
            // Without a file the log is silent, and "my log is empty" is indistinguishable
            // from "the folder is read-only". One warning per retry window says which; the
            // retry gate in `prepareIfNeeded` keeps a bad folder from becoming a storm.
            Diag.warning(.settings, """
                could not open the log file \(name): \(error.localizedDescription)
                """)
        }
    }

    private func prune(now: Date) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let entries: [LogFileEntry] = contents.compactMap { url in
            guard let date = LogRotationPolicy.date(
                fromFileName: url.lastPathComponent,
                timeZone: timeZone
            ) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return LogFileEntry(name: url.lastPathComponent, date: date, size: size)
        }
        for entry in LogRotationPolicy.filesToPrune(entries: entries, timeZone: timeZone, now: now) {
            // Never delete the file this store is currently appending to.
            guard entry.name != openFileName else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.name))
        }
    }
}
