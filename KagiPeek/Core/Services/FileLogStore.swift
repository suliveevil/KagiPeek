import Foundation

/// The daily-rolling file log: one file per day, batched appends, retention and size caps.
///
/// Everything here runs on a private serial queue. Callers — including the event-tap callback
/// on the main thread — only enqueue, so no diagnostics code can ever put a disk seek between
/// the user's key press and the app receiving it.
///
/// A failure inside this type is a no-op, never an error: the log exists to explain problems,
/// and a logger that can break the app it observes is worse than no logger at all.
final class FileLogStore {
    static let shared = FileLogStore()

    /// Lines held before a flush. Small enough that a crash loses only a handful of entries.
    private static let batchSize = 32
    /// How long a partial batch may sit in memory.
    private static let flushInterval: TimeInterval = 0.2

    private let queue = DispatchQueue(label: "com.voltline.kagipeek.diag.file", qos: .utility)
    private let directory: URL
    private let nowProvider: () -> Date
    private let timeZone: TimeZone

    // State owned by `queue`.
    private var pending: [String] = []
    private var flushScheduled = false
    private var handle: FileHandle?
    private var openFileName: String?
    private var openFileSize = 0
    private var droppedBelowWarning = 0
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

    /// The file the next line would go to, for the settings panel and the crash report.
    func currentFileURL(now: Date = Date()) -> URL {
        directory.appendingPathComponent(LogRotationPolicy.fileName(for: now, timeZone: timeZone))
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
            return
        }

        let clean = Sanitizer.prepare(message, homePrefix: NSHomeDirectory())
        let line = "\(lineFormatter.string(from: now)) \(level.character) \(tag.keyword) \(clean)\n"
        pending.append(line)
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
            pending.append("\(lineFormatter.string(from: nowProvider())) W [settings] dropped \(droppedBelowWarning) verbose lines (daily size cap)\n")
            droppedBelowWarning = 0
        }
        let text = pending.joined()
        pending.removeAll(keepingCapacity: true)

        guard let handle else { return }
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            // Nothing sensible to do: a log that cannot write must not recurse into logging.
            self.handle = nil
            openFileName = nil
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
    func tail(of date: Date, lines count: Int = 200) -> [String] {
        let url = directory.appendingPathComponent(
            LogRotationPolicy.fileName(for: date, timeZone: timeZone)
        )
        // Read through the queue so a pending batch is on disk before the tail is taken.
        flushNow(timeout: 0.2)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(count).map(String.init)
    }

    /// Every log file currently on disk, newest first.
    func existingFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == LogRotationPolicy.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
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
