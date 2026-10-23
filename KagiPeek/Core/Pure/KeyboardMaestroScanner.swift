import Foundation

/// Reads Keyboard Maestro's macro library and extracts every enabled hot key trigger.
///
/// The library is `Keyboard Maestro Macros.plist`: `MacroGroups` nests groups, then
/// macros, then triggers. A hot key trigger is the one with
/// `MacroTriggerType == "HotKey"`, carrying a macOS virtual `KeyCode` and a Carbon-mask
/// `Modifiers` field — the same masks `RegisterEventHotKey` takes.
///
/// Disabled groups and macros are skipped: KM only registers a hot key while both the
/// macro and its group are active, so reporting an inactive one would claim a conflict
/// that is not live. Group-targeted macros still count; their hot keys are registered
/// globally whenever that app runs, which is exactly the kind of surprise this is for.
nonisolated enum KeyboardMaestroScanner {

    static func scan(homeDirectory: URL, fileManager: FileManager = .default) -> [ConfigBinding] {
        guard let path = ConfigFileScanner.firstExistingPath(
            ConfigTool.keyboardMaestro.relativeSearchPaths,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else { return [] }
        guard let data = ConfigFileScanner.readData(atPath: path, fileManager: fileManager),
              let plist = ConfigFileScanner.propertyList(from: data) else { return [] }
        return bindings(fromPlist: plist)
    }

    /// Accepts both the on-disk shape (a dictionary with `MacroGroups`) and the bare
    /// group array a `.kmmacros` export uses, since they share the group schema.
    static func bindings(fromPlist plist: Any) -> [ConfigBinding] {
        let groups: [[String: Any]]
        if let dictionary = plist as? [String: Any],
           let macroGroups = dictionary["MacroGroups"] as? [[String: Any]] {
            groups = macroGroups
        } else if let array = plist as? [[String: Any]] {
            groups = array
        } else {
            return []
        }

        var bindings: [ConfigBinding] = []
        for group in groups {
            guard group["IsActive"] as? Bool != false else { continue }
            let groupName = group["Name"] as? String
            guard let macros = group["Macros"] as? [[String: Any]] else { continue }

            for macro in macros {
                guard macro["IsActive"] as? Bool != false else { continue }
                let macroName = macro["Name"] as? String ?? "Keyboard Maestro macro"
                guard let triggers = macro["Triggers"] as? [[String: Any]] else { continue }

                for trigger in triggers {
                    guard trigger["MacroTriggerType"] as? String == "HotKey",
                          let rawKeyCode = trigger["KeyCode"] as? Int,
                          rawKeyCode >= 0, rawKeyCode <= Int(UInt16.max),
                          let token = KeyMapper.token(forKeyCode: UInt16(rawKeyCode)) else { continue }

                    let modifiers = CarbonModifierMask.modifierSet(
                        fromCarbonMask: trigger["Modifiers"] as? Int ?? 0
                    )
                    bindings.append(ConfigBinding(
                        chord: .combo(modifiers, token),
                        title: title(groupName: groupName, macroName: macroName)
                    ))
                }
            }
        }
        return bindings
    }

    private static func title(groupName: String?, macroName: String) -> String {
        guard let groupName, !groupName.isEmpty else { return macroName }
        return "\(groupName) › \(macroName)"
    }
}
