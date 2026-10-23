import Foundation

/// Reads Alfred's workflows and extracts every assigned hot key trigger.
///
/// Each workflow is a folder inside the `Alfred.alfredpreferences` bundle with an
/// `info.plist` describing its objects. A hot key trigger is the object whose
/// `type == "alfred.workflow.trigger.hotkey"`; its `config` carries a macOS virtual
/// keycode in `hotkey` and a `hotmod` bitmask that is the raw Cocoa modifier value.
///
/// Two things are deliberately skipped. A workflow disabled in Alfred never registers
/// its hot keys, so it is dropped whole. And a trigger that has not been assigned a
/// shortcut stores `hotkey`/`hotmod` as 0 with an empty `hotstring`; the non-empty
/// `hotstring` is the reliable "actually bound" signal, and keying off it is what keeps
/// an unconfigured trigger from masquerading as a bare "A" conflict.
///
/// Powerpack users often sync preferences to Dropbox or iCloud. `prefs.json` records
/// where the bundle really lives, so that pointer is followed first.
nonisolated enum AlfredScanner {

    static func scan(homeDirectory: URL, fileManager: FileManager = .default) -> [ConfigBinding] {
        guard let workflows = Self.workflowsDirectory(homeDirectory: homeDirectory, fileManager: fileManager) else {
            return []
        }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: workflows) else { return [] }

        var bindings: [ConfigBinding] = []
        for entry in entries {
            let path = (workflows as NSString).appendingPathComponent(entry) + "/info.plist"
            guard fileManager.fileExists(atPath: path),
                  let data = ConfigFileScanner.readData(
                    atPath: path,
                    limit: ConfigFileScanner.maxConfigBytes,
                    fileManager: fileManager
                  ),
                  let plist = ConfigFileScanner.propertyList(from: data) else { continue }
            bindings.append(contentsOf: Self.bindings(fromWorkflow: plist))
        }
        return bindings
    }

    static func workflowsDirectory(homeDirectory: URL, fileManager: FileManager = .default) -> String? {
        var candidates: [String] = []

        // prefs.json's `current` is the sync folder that holds the bundle.
        let support = homeDirectory.appendingPathComponent("Library/Application Support/Alfred").path
        let prefsPath = (support as NSString).appendingPathComponent("prefs.json")
        if let data = fileManager.contents(atPath: prefsPath),
           let json = ConfigFileScanner.jsonObject(from: data),
           let current = json["current"] as? String, !current.isEmpty {
            let base = NSString(string: current).expandingTildeInPath
            candidates.append((base as NSString).appendingPathComponent("Alfred.alfredpreferences/workflows"))
        }
        candidates.append((support as NSString).appendingPathComponent("Alfred.alfredpreferences/workflows"))
        candidates.append(contentsOf: ConfigTool.alfred.relativeSearchPaths.compactMap {
            homeDirectory.appendingPathComponent($0).appendingPathComponent("workflows").path
        })

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    static func bindings(fromWorkflow plist: Any) -> [ConfigBinding] {
        guard let workflow = plist as? [String: Any] else { return [] }
        guard workflow["disabled"] as? Bool != true else { return [] }

        let name = nonEmpty(workflow["name"] as? String)
            ?? nonEmpty(workflow["bundleid"] as? String)
            ?? "Alfred workflow"
        guard let objects = workflow["objects"] as? [[String: Any]] else { return [] }

        var bindings: [ConfigBinding] = []
        for object in objects {
            guard object["type"] as? String == "alfred.workflow.trigger.hotkey",
                  let config = object["config"] as? [String: Any],
                  nonEmpty(config["hotstring"] as? String) != nil,
                  let rawKey = config["hotkey"] as? Int,
                  rawKey >= 0, rawKey <= Int(UInt16.max),
                  let token = KeyMapper.token(forKeyCode: UInt16(rawKey)) else { continue }

            let modifiers = CarbonModifierMask.modifierSet(
                fromCocoaRawValue: config["hotmod"] as? Int ?? 0
            )
            bindings.append(ConfigBinding(chord: .combo(modifiers, token), title: name))
        }
        return bindings
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
