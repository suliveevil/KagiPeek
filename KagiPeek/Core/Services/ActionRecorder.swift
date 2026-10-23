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
final class ActionRecorder {
    static let shared = ActionRecorder()

    private let capacity = 30
    private let buffer: RingBuffer<ActionRecord>
    private let queue = DispatchQueue(label: "com.voltline.kagipeek.diag.actions", qos: .utility)
    private var pendingMirror: DispatchWorkItem?
    private let mirrorURL: URL

    init(mirrorURL: URL = ActionRecorder.defaultMirrorURL) {
        self.mirrorURL = mirrorURL
        self.buffer = RingBuffer<ActionRecord>(capacity: capacity)
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
            try? FileManager.default.removeItem(at: mirrorURL)
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
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: mirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: mirrorURL, options: [.atomic])
    }

    /// Reads what a previous (crashed) session left behind.
    static func loadMirror(at url: URL = ActionRecorder.defaultMirrorURL) -> [ActionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ActionRecord].self, from: data)) ?? []
    }
}
