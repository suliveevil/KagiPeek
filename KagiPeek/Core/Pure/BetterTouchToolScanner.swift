import Foundation
import SQLite3

/// Reads BetterTouchTool's data store and extracts enabled keyboard shortcut triggers.
///
/// BTT persists everything in a Core Data SQLite store whose filename changes with each
/// version (`btt_data_store.version_3_386_build_1609` and the like), so the newest file is
/// globbed rather than hardcoded. Every trigger row in `ZBTTBASEENTITY` carries a JSON blob
/// in `ZACTIONDATA`; that JSON uses the documented `BTT*` field names, so it is the source
/// of truth and the version-fragile columns are only used to fetch it and to walk the parent
/// chain for app scoping.
///
/// The store is opened read-only, so a running BTT is never interfered with and no WAL
/// checkpoint is ever forced.
nonisolated enum BetterTouchToolScanner {

    /// One row of interest: its primary key, its parent row, and the trigger JSON blob.
    ///
    /// A plain value type so the parsing stage stays testable without a database.
    struct Row: Hashable, Sendable {
        let pk: Int64
        let parent: Int64?
        let json: Data
    }

    static func scan(homeDirectory: URL, fileManager: FileManager = .default) -> [ConfigBinding] {
        guard let storePath = newestStorePath(homeDirectory: homeDirectory, fileManager: fileManager) else {
            return []
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: storePath),
           let size = attributes[.size] as? Int,
           size > ConfigFileScanner.maxConfigBytes {
            return []
        }
        return bindings(from: fetchRows(fromStoreAt: storePath))
    }

    // MARK: - Store discovery

    /// The most recently modified store, skipping `-shm`/`-wal` sidecars and backups.
    static func newestStorePath(homeDirectory: URL, fileManager: FileManager = .default) -> String? {
        guard let directory = ConfigFileScanner.firstExistingPath(
            ConfigTool.betterTouchTool.relativeSearchPaths,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else { return nil }
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }

        let candidates = names.filter { name in
            (name.hasPrefix("btt_data_store.version_") || name == "btt_data_store.v2")
                && !name.hasSuffix("-shm") && !name.hasSuffix("-wal")
        }
        func modificationDate(_ path: String) -> Date {
            (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        }
        return candidates
            .map { "\(directory)/\($0)" }
            .max { modificationDate($0) < modificationDate($1) }
    }

    // MARK: - SQLite

    static func fetchRows(fromStoreAt path: String) -> [Row] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT Z_PK, ZPARENT, ZACTIONDATA FROM ZBTTBASEENTITY WHERE ZACTIONDATA IS NOT NULL"
        var statement: OpaquePointer?
        // Core Data schemas drift between BTT versions; a missing table or column means this
        // is a layout we do not know how to read, not an error worth surfacing.
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let pk = sqlite3_column_int64(statement, 0)
            let parent: Int64? = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 1)
            guard let bytes = sqlite3_column_blob(statement, 2) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 2))
            rows.append(Row(pk: pk, parent: parent, json: Data(bytes: bytes, count: count)))
        }
        return rows
    }

    // MARK: - Parsing

    /// Keyboard shortcuts are the rows whose JSON declares
    /// `BTTTriggerClass == "BTTTriggerTypeKeyboardShortcut"`.
    ///
    /// App scoping comes from walking `ZPARENT` up to the container row carrying a
    /// `BTTAppBundleIdentifier`: `BT.G` is BTT's global container and a real bundle ID means
    /// the shortcut only fires in that app. App-scoped rows are skipped so they cannot
    /// masquerade as always-on conflicts; rows whose chain resolves to nothing are kept,
    /// because most BTT keyboard shortcuts are global.
    static func bindings(from rows: [Row]) -> [ConfigBinding] {
        var jsonByPK: [Int64: [String: Any]] = [:]
        var parentByPK: [Int64: Int64] = [:]
        for row in rows {
            guard let json = ConfigFileScanner.jsonObject(from: row.json) else { continue }
            jsonByPK[row.pk] = json
            if let parent = row.parent { parentByPK[row.pk] = parent }
        }

        var bindings: [ConfigBinding] = []
        for row in rows {
            guard let json = jsonByPK[row.pk],
                  json["BTTTriggerClass"] as? String == "BTTTriggerTypeKeyboardShortcut" else { continue }

            // Both enabled flags default to on when absent; a zero in either means the user
            // switched the trigger off.
            if let enabled = json["BTTEnabled"] as? Int, enabled == 0 { continue }
            if let enabled = json["BTTEnabled2"] as? Int, enabled == 0 { continue }

            if let scope = containerBundleID(of: row.pk, jsonByPK: jsonByPK, parentByPK: parentByPK),
               scope != "BT.G" {
                continue
            }

            // Key code -1 marks a layout-adaptive shortcut, whose key then lives only in
            // `BTTLayoutIndependentChar`.
            var resolved: KeyToken?
            if let raw = json["BTTShortcutKeyCode"] as? Int,
               raw >= 0, raw <= Int(UInt16.max),
               let mapped = KeyMapper.token(forKeyCode: UInt16(raw)) {
                resolved = mapped
            } else if let character = json["BTTLayoutIndependentChar"] as? String {
                resolved = token(forLayoutIndependentChar: character)
            }
            guard let resolved else { continue }

            guard let rawModifiers = json["BTTShortcutModifierKeys"] as? Int, rawModifiers >= 0 else { continue }
            let modifiers = CarbonModifierMask.modifierSet(fromCocoaRawValue: rawModifiers)

            let title = (json["BTTTriggerTypeDescription"] as? String)
                ?? (json["BTTGestureNotes"] as? String)
                ?? (json["BTTPredefinedActionName"] as? String)
                ?? "BetterTouchTool trigger"
            bindings.append(ConfigBinding(chord: .combo(modifiers, resolved), title: title))
        }
        return bindings
    }

    /// Walks the parent chain until a row names an app container, giving up after a sane
    /// number of hops so a cyclic chain cannot hang the scan.
    static func containerBundleID(
        of pk: Int64,
        jsonByPK: [Int64: [String: Any]],
        parentByPK: [Int64: Int64]
    ) -> String? {
        var current = parentByPK[pk]
        var hops = 0
        while let currentPK = current, hops < 32 {
            if let bundleID = jsonByPK[currentPK]?["BTTAppBundleIdentifier"] as? String {
                return bundleID
            }
            current = parentByPK[currentPK]
            hops += 1
        }
        return nil
    }

    /// BTT's layout-independent character names: uppercased words for the named keys, and
    /// a lowercased single character otherwise.
    static func token(forLayoutIndependentChar character: String) -> KeyToken? {
        switch character.uppercased() {
        case "SPACE": return "space"
        case "RETURN", "ENTER": return "return"
        case "TAB": return "tab"
        case "ESCAPE", "ESC": return "esc"
        case "DELETE", "BACKSPACE": return "delete"
        default: break
        }
        guard character.count == 1 else { return nil }
        return ConfigFileScanner.token(forCharacter: character)
    }
}
