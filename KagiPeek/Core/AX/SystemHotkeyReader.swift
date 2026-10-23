import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts registered with the window server (Spotlight, Mission Control,
/// screenshots, input-source switching, …).
///
/// They are not part of any app's menu bar, so they are read once and kept as an
/// "external" set that only feeds conflict detection.
enum SystemHotkeyReader {
    static func read(language: AppLanguage) -> [BindingItem] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let array = unmanaged?.takeRetainedValue() else {
            return []
        }

        let count = CFArrayGetCount(array)
        var items: [BindingItem] = []
        items.reserveCapacity(count)
        var seenChords = Set<String>()

        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let info = Unmanaged<NSDictionary>.fromOpaque(raw).takeUnretainedValue() as? [String: Any]
            guard let info, let keyCode = (info[kHISymbolicHotKeyCode] as? NSNumber)?.intValue else { continue }
            let enabled = (info[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue ?? true
            guard enabled else { continue }
            guard let token = KeyMapper.token(forKeyCode: Int64(keyCode)) else { continue }

            let modifierBits = (info[kHISymbolicHotKeyModifiers] as? NSNumber)?.intValue ?? 0
            var modifiers: ModifierSet = []
            if modifierBits & cmdKey != 0 { modifiers.insert(.command) }
            if modifierBits & shiftKey != 0 { modifiers.insert(.shift) }
            if modifierBits & optionKey != 0 { modifiers.insert(.option) }
            if modifierBits & controlKey != 0 { modifiers.insert(.control) }
            guard !modifiers.isEmpty else { continue }

            let chord = KeyChord.combo(modifiers, token)
            guard seenChords.insert(chord.cacheKey).inserted else { continue }

            // The description constant is not imported into Swift; the dictionary key is stable.
            var title = (info["kHISymbolicHotKeyDescription"] as? String) ?? ""
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                // macOS leaves `kHISymbolicHotKeyDescription` empty for every entry on every
                // machine, so the name has to come from us. What we cannot name stays empty:
                // `DescriptionCleaner` turns that into "—", which says "no name known" — the
                // title column already had the chord next to it, and printing it twice is
                // what made these rows look like they had lost their description.
                title = SystemHotkeyNames.name(for: chord, language: language) ?? ""
            }

            items.append(BindingItem(
                chord: chord,
                title: title,
                group: [L10n.string(.groupSystemHotkeys, language: language)],
                isEnabled: true,
                source: .system,
                appBundleID: nil
            ))
        }
        return items
    }
}
