import Foundation

/// Keeps the last few things the user did, so a crash report can answer "what was happening"
/// instead of only "it died".
///
/// Records are deliberately thin: the action's name and the app it was aimed at. Menu item
/// text, typed characters and filter strings never enter this buffer — a diagnostic that
/// doubles as a keylogger is not a diagnostic.
///
/// The buffer is mirrored to disk on a short debounce because a signal handler cannot read
/// Swift memory: by the time the process dies, the last seconds already exist as JSON that
/// the next launch can pick up.
///
/// `nonisolated` + `@unchecked Sendable`: `Diag.action` is called from the event-tap thread
/// and the crash handler as well as the main actor, and all mutable state below is owned by
/// one private serial queue (the mirror) or a value-semantic ring buffer. Under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unmarked class would make `static let
/// shared` a global-mutable-state error and every call from a non-main thread an isolation
/// error. The conformance is the same contract as `FileLogStore`: the queue owns the state.
nonisolated final class ActionRecorder: @unchecked Sendable {
    static let shared = ActionRecorder()

    private let capacity = 30
    private let buffer: RingBuffer<ActionRecord>
    private let queue = DispatchQueue(label: "com.voltline.kagipeek.diag.actions", qos: .utility)
    private var pendingMirror: DispatchWorkItem?
    private let mirrorURL: URL
    /// The last write failure, owned by `queue`. Carried into diagnostics reports so a crash
    /// report with no recent actions can say whether the session was quiet or the mirror was
    /// broken.
    private var lastMirrorError: String?
    /// Suppresses the same warning once per distinct failure: the mirror retries on every
    /// recorded action, and a read-only folder would otherwise fill the log it cannot write.
    private var reportedMirrorError: String?

    init(mirrorURL: URL = ActionRecorder.defaultMirrorURL) {
        self.mirrorURL = mirrorURL
        self.buffer = RingBuffer<ActionRecord>(capacity: capacity)
    }

    /// Why the last mirror write failed, if it did. `nil` means the mirror is current.
    var mirrorError: String? {
        queue.sync { lastMirrorError }
    }

    static var defaultMirrorURL: URL {
        DataDirectory.url(for: "logs").appendingPathComponent("last-actions.json")
    }

    func record(_ action: String, target: String? = nil) {
        buffer.append(ActionRecord(ts: Date().timeIntervalSince1970, action: action, target: target))
        scheduleMirror()
    }

    func snapshot() -> [ActionRecord] {
        buffer.snapshot()
    }

    /// Called on a clean exit: nothing from this session is worth keeping.
    func clear() {
        buffer.removeAll()
        queue.async { [mirrorURL] in
            do {
                try FileManager.default.removeItem(at: mirrorURL)
            } catch CocoaError.fileNoSuchFile {
                // The normal case: no action was recorded, so no mirror was written.
            } catch {
                // A stale mirror would be attached to the next crash as if it belonged to
                // that session. Nothing can fix it here, but the failure must not be silent.
                Diag.warning(.crash, """
                    could not remove the action mirror \(mirrorURL.lastPathComponent): \
                    \(error.localizedDescription)
                    """)
            }
        }
    }

    // MARK: - Mirror

    private func scheduleMirror() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingMirror?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.writeMirror()
            }
            self.pendingMirror = item
            self.queue.asyncAfter(deadline: .now() + 1.0, execute: item)
        }
    }

    private func writeMirror() {
        let records = buffer.snapshot()
        do {
            let data = try JSONEncoder().encode(records)
            try FileManager.default.createDirectory(
                at: mirrorURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: mirrorURL, options: [.atomic])
            lastMirrorError = nil
            reportedMirrorError = nil
        } catch {
            let detail = "the recent-action mirror could not be written: \(error.localizedDescription)"
            lastMirrorError = detail
            if reportedMirrorError != detail {
                reportedMirrorError = detail
                Diag.warning(.crash, detail)
            }
        }
    }

    /// Reads what a previous (crashed) session left behind.
    ///
    /// The error is separate from the records because the caller writes a crash report:
    /// "the user did nothing before the crash" and "the mirror could not be read" produce the
    /// same empty array but are very different answers for whoever reads the report.
    static func loadMirror(at url: URL = ActionRecorder.defaultMirrorURL) -> (records: [ActionRecord], error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: url)
            do {
                return (try JSONDecoder().decode([ActionRecord].self, from: data), nil)
            } catch {
                return ([], "the action mirror could not be decoded: \(error.localizedDescription)")
            }
        } catch {
            return ([], "the action mirror could not be read: \(error.localizedDescription)")
        }
    }
}
