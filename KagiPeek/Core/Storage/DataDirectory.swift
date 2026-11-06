import Foundation
import os

/// Durable, bundle-id-independent data location.
///
/// UserDefaults lives inside the app's preference domain and is easy to lose when the app is
/// reinstalled under a different signature or bundle identifier, so settings and statistics
/// live in `~/Library/Application Support/Kaname` as plain JSON files with atomic writes.
/// The previous name's folder (`.../Kaname`) is copied once into the new one; the old folder
/// is left untouched. `nonisolated` for the same reason as `PermissionCenter`: this is pure
/// path arithmetic (`FileManager` lookup + `appendingPathComponent`) with no mutable state,
/// and it is read from the file-log queue and the crash handler as well as the main thread.
/// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a default-argument value like
/// `DataDirectory.url(for: "logs")` in a `nonisolated` type's `init` is otherwise an error:
/// the default expression would be main-actor-isolated.
nonisolated enum DataDirectory {
    static let folderName = "Kaname"
    static let legacyFolderName = LegacyDataMigration.legacyFolderName

    static var baseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
    }

    static var url: URL {
        baseURL.appendingPathComponent(folderName, isDirectory: true)
    }

    static var legacyURL: URL {
        baseURL.appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// Runs the legacy copy exactly once per process, before any store reads the new folder.
    /// The backups tree is handed to a utility queue so a 164 MB copy does not delay launch.
    private static let migrated: Void = {
        let outcome = LegacyDataMigration.migrateCritical(legacy: legacyURL, destination: url)
        if !outcome.failures.isEmpty {
            Diag.error(.settings, """
                legacy data copy incomplete: \(outcome.failures.joined(separator: ", ")); \
                will retry on the next launch
                """)
        }
        if outcome.backupsPending {
            DispatchQueue.global(qos: .utility).async {
                let copied = LegacyDataMigration.copyBackups(legacy: legacyURL, destination: url)
                if copied {
                    LegacyDataMigration.markBackupsComplete(destination: url)
                } else {
                    Diag.error(.settings, """
                        legacy backups copy incomplete; will retry on the next launch
                        """)
                }
            }
        }
    }()

    static func ensureExists() {
        _ = migrated
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Diag.error(.settings, "could not create \(url.path): \(error.localizedDescription)")
        }
    }

    static func url(for fileName: String) -> URL {
        url.appendingPathComponent(fileName)
    }
}

/// Small JSON file store: atomic writes, corrupt files preserved next to the original.
///
/// `nonisolated` and `Sendable` on purpose: it carries no mutable state (a file name and a
/// directory), and `UsageStore` runs its writes on a background utility queue. Under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an unannotated store would be main-actor
/// isolated, so a GCD block that calls `save` off the main thread fails the runtime executor
/// check and traps. The directory is injected (defaulting to the app data folder) so tests can
/// point the store at a temporary location instead of touching Application Support.
nonisolated struct JsonFileStore: Sendable {
    let fileName: String
    let directory: URL

    init(fileName: String, directory: URL = DataDirectory.url) {
        self.fileName = fileName
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent(fileName) }

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
                Diag.error(.settings, """
                    \(self.fileName) could not be decoded \
                    (\(error.localizedDescription)); kept as \
                    \(backup.lastPathComponent)
                    """)
            } catch {
                Diag.error(.settings, """
                    \(self.fileName) could not be decoded and could not be moved aside: \
                    \(error.localizedDescription)
                    """)
            }
            return nil
        }
    }

    func save<T: Encodable>(_ value: T) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // A failed write used to look exactly like a successful one: the setting stayed on
            // screen and reverted at the next launch, with nothing anywhere to explain it.
            Diag.error(.settings, """
                could not write \(self.fileName): \
                \(error.localizedDescription)
                """)
        }
    }
}
