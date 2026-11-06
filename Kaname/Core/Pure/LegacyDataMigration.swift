import Foundation

/// One-time, idempotent copy of the data left by the app's previous name.
///
/// The app used to keep everything in `~/Library/Application Support/Kaname`; the folder is
/// now `Kaname`. Nothing may be overwritten: the user's current data always wins, and a
/// partially copied tree is completed on the next launch. The old folder is never touched or
/// deleted, so it stays usable for rollback and for a manual comparison.
///
/// The 164 MB backup folder is copied by the app on a background queue; the small files
/// (settings, statistics, logs, crash reports, signing material) are copied before any store
/// reads them. A marker records which half is done, so a failed backup copy is retried on the
/// next launch instead of being forgotten.
nonisolated enum LegacyDataMigration {
    static let legacyFolderName = "KagiPeek"
    static let markerFileName = ".migrated-from-kagi-peek"
    static let legacyLogPrefix = "kagipeek-"
    static let legacyCrashPrefix = "kagipeek-crash-"

    /// Files copied before any of the app's stores read from the new folder.
    static let criticalFiles = ["settings.json", "usage.json", "conflicts-cache.json"]
    /// Directories whose contents are small enough to copy before launch continues.
    static let criticalDirectories = ["menu-cache", "logs", "crash", "signing"]
    /// Copied in the background because the installed app bundles are large.
    static let deferredDirectories = ["backups"]

    struct State: Codable, Equatable, Sendable {
        var criticalComplete: Bool
        var backupsComplete: Bool

        static let initial = State(criticalComplete: false, backupsComplete: false)
    }

    struct Outcome: Equatable, Sendable {
        /// True when every critical item was present at the destination when migration ended.
        var criticalComplete: Bool
        /// True when legacy backups still need to be copied.
        var backupsPending: Bool
        /// File names that could not be copied or verified. Empty on a clean pass.
        var failures: [String]
    }

    // MARK: - Marker

    static func markerURL(destination: URL) -> URL {
        destination.appendingPathComponent(markerFileName)
    }

    static func readState(destination: URL) -> State? {
        guard let data = try? Data(contentsOf: markerURL(destination: destination)) else {
            return nil
        }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// Atomic so a crash mid-write cannot leave a half-written marker that suppresses a retry.
    static func writeState(_ state: State, destination: URL) {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: markerURL(destination: destination), options: [.atomic])
        } catch {
            // The marker is an optimisation, not a source of truth: without it the next launch
            // simply re-runs the copy, which skips every already-present file.
        }
    }

    // MARK: - Critical pass

    /// Copies the settings/statistics/logs/crash/signing material the app needs before it
    /// starts reading. Re-running after a partial failure only fills the missing entries.
    static func migrateCritical(
        legacy: URL,
        destination: URL,
        fileManager: FileManager = .default
    ) -> Outcome {
        let legacyExists = fileManager.fileExists(atPath: legacy.path)
        var failures: [String] = []

        if !legacyExists {
            return Outcome(criticalComplete: true, backupsPending: false, failures: [])
        }

        let previous = readState(destination: destination)
        if previous?.criticalComplete != true {
            try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in criticalFiles {
                copyFileIfMissing(named: name, from: legacy, to: destination,
                                  fileManager: fileManager, failures: &failures)
            }
            for name in criticalDirectories {
                copyDirectoryIfMissing(named: name, from: legacy, to: destination,
                                       fileManager: fileManager, failures: &failures,
                                       transform: transformForCriticalDirectory(name))
            }
            verifySigning(at: destination, fileManager: fileManager, failures: &failures)
        }

        let criticalComplete: Bool
        if previous?.criticalComplete == true {
            // The migration already succeeded once. A file the user has since deleted is their
            // decision, not a reason to copy it back from the old folder.
            criticalComplete = true
        } else {
            criticalComplete = failures.isEmpty
                && criticalFilesArePresent(at: destination, fileManager: fileManager)
        }
        let backupsPending = backupsExist(at: legacy, fileManager: fileManager)
            && previous?.backupsComplete != true

        let state = State(
            criticalComplete: criticalComplete,
            backupsComplete: previous?.backupsComplete ?? false
        )
        writeState(state, destination: destination)
        return Outcome(criticalComplete: criticalComplete,
                       backupsPending: backupsPending,
                       failures: failures)
    }

    // MARK: - Backups

    /// Copies the large `backups/` tree. Safe to call repeatedly; only missing entries move.
    /// Returns false when at least one entry could not be copied, which leaves the marker
    /// `backupsComplete = false` so the next launch tries again.
    static func copyBackups(
        legacy: URL,
        destination: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let source = legacy.appendingPathComponent("backups", isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return true }
        var failures: [String] = []
        copyDirectoryIfMissing(named: "backups", from: legacy, to: destination,
                               fileManager: fileManager, failures: &failures,
                               transform: nil)
        return failures.isEmpty
    }

    static func markBackupsComplete(destination: URL) {
        var state = readState(destination: destination) ?? .initial
        state.backupsComplete = true
        writeState(state, destination: destination)
    }

    // MARK: - Copy primitives

    private static func copyFileIfMissing(
        named name: String,
        from legacy: URL,
        to destination: URL,
        fileManager: FileManager,
        failures: inout [String]
    ) {
        let source = legacy.appendingPathComponent(name)
        let target = destination.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard !fileManager.fileExists(atPath: target.path) else { return }
        do {
            try fileManager.copyItem(at: source, to: target)
        } catch {
            failures.append(name)
        }
    }

    /// Recursively unions a directory: existing destination entries are never replaced.
    private static func copyDirectoryIfMissing(
        named name: String,
        from legacy: URL,
        to destination: URL,
        fileManager: FileManager,
        failures: inout [String],
        transform: ((String) -> String?)?
    ) {
        let source = legacy.appendingPathComponent(name, isDirectory: true)
        let target = destination.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return }
        if !fileManager.fileExists(atPath: target.path) {
            do {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                failures.append(name)
                return
            }
        }
        copyChildren(from: source, to: target, relativeTo: name,
                     fileManager: fileManager, failures: &failures, transform: transform)
    }

    private static func copyChildren(
        from source: URL,
        to target: URL,
        relativeTo prefix: String,
        fileManager: FileManager,
        failures: inout [String],
        transform: ((String) -> String?)?
    ) {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            failures.append(prefix)
            return
        }

        for child in children {
            let name = child.lastPathComponent
            let relative = "\(prefix)/\(name)"
            let finalName: String
            if let transform {
                guard let renamed = transform(name) else { continue }
                finalName = renamed
            } else {
                finalName = name
            }
            let destinationChild = target.appendingPathComponent(finalName)

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                if !fileManager.fileExists(atPath: destinationChild.path) {
                    do {
                        try fileManager.createDirectory(
                            at: destinationChild,
                            withIntermediateDirectories: true
                        )
                    } catch {
                        failures.append(relative)
                        continue
                    }
                }
                copyChildren(from: child, to: destinationChild, relativeTo: relative,
                             fileManager: fileManager, failures: &failures, transform: transform)
            } else if !fileManager.fileExists(atPath: destinationChild.path) {
                do {
                    try fileManager.copyItem(at: child, to: destinationChild)
                } catch {
                    failures.append(relative)
                }
            }
        }
    }

    private static func transformForCriticalDirectory(_ name: String) -> ((String) -> String?)? {
        switch name {
        case "logs":
            return { childName in
                if childName == "session.active" { return nil }
                if childName == "last-actions.json" { return childName }
                guard childName.hasPrefix(legacyLogPrefix), childName.hasSuffix(".log") else {
                    return nil
                }
                return "kaname-" + String(childName.dropFirst(legacyLogPrefix.count))
            }
        case "crash":
            return { childName in
                childName.hasSuffix(".json") ? childName : nil
            }
        default:
            return { $0 }
        }
    }

    // MARK: - Verification

    private static func criticalFilesArePresent(at destination: URL, fileManager: FileManager) -> Bool {
        for name in criticalFiles where
            !fileManager.fileExists(atPath: destination.appendingPathComponent(name).path) {
            return false
        }
        return true
    }

    private static func backupsExist(at legacy: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let path = legacy.appendingPathComponent("backups", isDirectory: true).path
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Signing material is copied first and checked afterwards: a truncated password file
    /// would otherwise make every later signing attempt fail with an unrelated error.
    private static func verifySigning(
        at destination: URL,
        fileManager: FileManager,
        failures: inout [String]
    ) {
        let signing = destination.appendingPathComponent("signing", isDirectory: true)
        guard fileManager.fileExists(atPath: signing.path) else { return }
        let children = (try? fileManager.contentsOfDirectory(
            at: signing,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        )) ?? []
        for child in children {
            let name = child.lastPathComponent
            guard let attributes = try? fileManager.attributesOfItem(atPath: child.path),
                  let size = attributes[.size] as? NSNumber else {
                failures.append("signing/\(name)")
                continue
            }
            if size.intValue == 0 {
                failures.append("signing/\(name)")
                continue
            }
            if name == "keychain-pass" || name == "p12-pass" {
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                if mode != 0o600 {
                    // The copy should preserve 600; if the volume did not, restore it rather
                    // than leaving key material readable by other accounts.
                    do {
                        try fileManager.setAttributes(
                            [.posixPermissions: NSNumber(value: 0o600)],
                            ofItemAtPath: child.path
                        )
                    } catch {
                        failures.append("signing/\(name)")
                    }
                }
            }
        }
    }
}
