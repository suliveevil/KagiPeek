import Foundation
import os

/// Durable, bundle-id-independent data location.
///
/// UserDefaults lives inside the app's preference domain and is easy to lose when the app is
/// reinstalled under a different signature or bundle identifier, so settings and statistics
/// live in `~/Library/Application Support/KagiPeek` as plain JSON files with atomic writes.
enum DataDirectory {
    static let folderName = "KagiPeek"

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static func ensureExists() {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            AppLog.storage.error("could not create \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func url(for fileName: String) -> URL {
        url.appendingPathComponent(fileName)
    }
}

/// Small JSON file store: atomic writes, corrupt files preserved next to the original.
struct JsonFileStore {
    let fileName: String

    var fileURL: URL { DataDirectory.url(for: fileName) }

    func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it: it is the only copy of the
            // user's settings or statistics, and a bug in decoding must not destroy it.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                AppLog.storage.error("""
                    \(self.fileName, privacy: .public) could not be decoded \
                    (\(error.localizedDescription, privacy: .public)); kept as \
                    \(backup.lastPathComponent, privacy: .public)
                    """)
            } catch {
                AppLog.storage.error("""
                    \(self.fileName, privacy: .public) could not be decoded and could not be moved aside: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
            return nil
        }
    }

    func save<T: Encodable>(_ value: T) {
        DataDirectory.ensureExists()
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // A failed write used to look exactly like a successful one: the setting stayed on
            // screen and reverted at the next launch, with nothing anywhere to explain it.
            AppLog.storage.error("""
                could not write \(self.fileName, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }
}
