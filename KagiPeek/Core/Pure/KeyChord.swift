import Foundation

// MARK: - ModifierSet

/// A set of keyboard modifiers.
///
/// Ordering follows the macOS convention (Control, Option, Shift, Command) so that
/// `⌃⌥⇧⌘` renders exactly the way the system renders it.
nonisolated struct ModifierSet: OptionSet, Hashable, Codable, Sendable, ExpressibleByArrayLiteral {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(arrayLiteral elements: ModifierSet...) {
        self = elements.reduce(ModifierSet(rawValue: 0)) { $0.union($1) }
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let control = ModifierSet(rawValue: 1 << 0)
    static let option = ModifierSet(rawValue: 1 << 1)
    static let shift = ModifierSet(rawValue: 1 << 2)
    static let command = ModifierSet(rawValue: 1 << 3)

    /// Canonical macOS modifier order: Control, Option, Shift, Command.
    static let canonicalOrder: [ModifierSet] = [.control, .option, .shift, .command]
    static let all: ModifierSet = [.control, .option, .shift, .command]

    var isEmpty: Bool { rawValue == 0 }

    /// True when every modifier in `other` is present in `self`.
    func isSuperset(of other: ModifierSet) -> Bool {
        rawValue & other.rawValue == other.rawValue
    }

    /// This set without the modifiers in `other`.
    ///
    /// Used to strip the modifiers the user is *holding to narrow the panel* from a key
    /// event: while ⌘ is down every event carries ⌘, so an exact match would never see the
    /// bare run key and Return would stop working precisely while the list is narrowed.
    func subtracting(_ other: ModifierSet) -> ModifierSet {
        ModifierSet(rawValue: rawValue & ~other.rawValue)
    }

    /// Modifiers in canonical display order.
    var ordered: [ModifierSet] {
        ModifierSet.canonicalOrder.filter { contains($0) }
    }

    var count: Int { ordered.count }
}

// MARK: - KeyToken

/// The non-modifier part of one key press, normalised to a stable token:
/// `"a"`, `"3"`, `"["`, `"left"`, `"f5"`, `"return"`, ...
nonisolated struct KeyToken: Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral {
    let raw: String

    init(_ raw: String) {
        self.raw = raw.lowercased()
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self).lowercased()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    static func < (lhs: KeyToken, rhs: KeyToken) -> Bool {
        KeyOrder.compare(lhs, rhs)
    }

    static let escape = KeyToken("esc")
    static let backspace = KeyToken("delete")
    static let forwardDelete = KeyToken("fdelete")
    static let space = KeyToken("space")
}

/// Determines the order in which keys are listed for one prefix group.
///
/// Four blocks, and the user reads them top to bottom: letters (with the function keys in
/// their alphabetical place — `f`, `f1`, `f2`, … `g`), digits, other printable keys, and the
/// named keys (Return, Tab, arrows) last. A function key is a word, not a class: sorting
/// `F1` in a block of its own put it a screen away from `F`, which is the one place a reader
/// would look for it.
nonisolated enum KeyOrder {
    private static let specialRank: [String: Int] = [
        "return": 0, "tab": 1, "space": 2, "delete": 3, "fdelete": 4, "esc": 5,
        "left": 6, "right": 7, "up": 8, "down": 9,
        "home": 10, "end": 11, "pageup": 12, "pagedown": 13, "help": 14
    ]

    static func category(_ token: KeyToken) -> Int {
        let raw = token.raw
        if raw.count == 1, let character = raw.first {
            if character.isLetter { return 0 }
            if character.isNumber { return 1 }
            return 2
        }
        if letterWord(raw) != nil { return 0 }
        return 3
    }

    static func compare(_ lhs: KeyToken, _ rhs: KeyToken) -> Bool {
        // A letter and a function key order as words of the same alphabet: base first, then
        // the bare key before its numbered siblings, then the numbers as numbers (`f9`
        // before `f10`, which a plain string compare gets wrong).
        if let left = letterWord(lhs.raw), let right = letterWord(rhs.raw) {
            if left.base != right.base { return left.base < right.base }
            switch (left.number, right.number) {
            case (nil, nil):
                return false
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            case let (.some(l), .some(r)):
                if l != r { return l < r }
                return false
            }
        }
        let left = category(lhs)
        let right = category(rhs)
        if left != right { return left < right }
        if left == 3 {
            let l = specialRank[lhs.raw] ?? 99
            let r = specialRank[rhs.raw] ?? 99
            if l != r { return l < r }
        }
        return lhs.raw < rhs.raw
    }

    /// `"f3"` → `("f", 3)`, `"f"` → `("f", nil)`, anything else → nil.
    private static func letterWord(_ raw: String) -> (base: String, number: Int?)? {
        if raw.count == 1, let character = raw.first, character.isLetter {
            return (raw, nil)
        }
        guard raw.count > 1, raw.count <= 3, raw.hasPrefix("f") else { return nil }
        guard let number = Int(raw.dropFirst()) else { return nil }
        return ("f", number)
    }
}

// MARK: - KeyStep

/// One step of a chord: a modifier set plus (optionally) the key that completes it.
/// A step with `key == nil` is the "modifiers are being held" state.
nonisolated struct KeyStep: Hashable, Codable, Sendable {
    var modifiers: ModifierSet
    var key: KeyToken?
    /// Alternative spellings accepted for the same physical key (layout robustness).
    var alternates: [KeyToken]

    init(modifiers: ModifierSet = [], key: KeyToken? = nil, alternates: [KeyToken] = []) {
        self.modifiers = modifiers
        self.key = key
        self.alternates = alternates
    }

    static func modifiersOnly(_ modifiers: ModifierSet) -> KeyStep {
        KeyStep(modifiers: modifiers, key: nil)
    }

    static func combo(_ modifiers: ModifierSet, _ key: KeyToken, alternates: [KeyToken] = []) -> KeyStep {
        KeyStep(modifiers: modifiers, key: key, alternates: alternates)
    }

    var isModifierOnly: Bool { key == nil }

    func matchesKey(_ token: KeyToken) -> Bool {
        guard let key else { return false }
        return key == token || alternates.contains(token)
    }

    /// Exact step identity (ignoring alternates, which are only spellings).
    func matches(_ other: KeyStep) -> Bool {
        guard modifiers == other.modifiers, let lhs = key, let rhs = other.key else { return false }
        return lhs == rhs || alternates.contains(rhs) || other.alternates.contains(lhs)
    }
}

// MARK: - KeyChord

/// A shortcut as a sequence of steps.
///
/// `⌘C` is one step, `⌘K ⌘C` (VS Code style) is two steps, and a bare modifier set
/// (the state while the user is holding ⌘) is one step with no key.
nonisolated struct KeyChord: Hashable, Codable, Sendable {
    var steps: [KeyStep]

    init(_ steps: [KeyStep]) {
        self.steps = steps
    }

    static let empty = KeyChord([])

    static func modifiers(_ modifiers: ModifierSet) -> KeyChord {
        KeyChord([.modifiersOnly(modifiers)])
    }

    static func combo(_ modifiers: ModifierSet, _ key: KeyToken, alternates: [KeyToken] = []) -> KeyChord {
        KeyChord([.combo(modifiers, key, alternates: alternates)])
    }

    /// Parses `"cmd+shift+3"` / `"opt+left"` style descriptors (used by the built-in catalog).
    ///
    /// Deliberately not `SearchCorpus.modifierAlias`: a non-modifier component here is a
    /// KEY, not an unmatched term, and the alias sets differ (no `com`/`sft` shorthands).
    init(descriptor: String) {
        var modifiers: ModifierSet = []
        var tokens: [KeyToken] = []
        for component in descriptor.split(separator: "+") {
            switch component.lowercased() {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "shift", "⇧": modifiers.insert(.shift)
            default:
                tokens.append(KeyToken(String(component)))
            }
        }
        if let key = tokens.first {
            steps = [.combo(modifiers, key)]
        } else {
            steps = [.modifiersOnly(modifiers)]
        }
    }

    var isEmpty: Bool { steps.isEmpty }
    var isModifierOnly: Bool { steps.count == 1 && steps[0].isModifierOnly }

    /// Stable identity used for caches and session comparison.
    var cacheKey: String {
        steps.map { step in
            let mods = String(step.modifiers.rawValue)
            let key = step.key?.raw ?? "-"
            return "\(mods):\(key)"
        }.joined(separator: "/")
    }

    /// Appends a key press to this prefix.
    func appending(modifiers: ModifierSet, key: KeyToken, alternates: [KeyToken] = []) -> KeyChord {
        KeyChord(steps + [.combo(modifiers, key, alternates: alternates)])
    }

    /// Rebuilds a chord from its `cacheKey`.
    ///
    /// Usage statistics keep the key and nothing else. Without this, a shortcut belonging to
    /// an app the scan has not seen this session — another day, another machine state — could
    /// not be rendered at all, and the statistics list would show counts with no shortcut.
    ///
    /// Returns nil for identities that are not chords: a command with no shortcut is keyed by
    /// its menu path (`path:…`), which has no keystroke to show.
    static func from(cacheKey: String) -> KeyChord? {
        guard !cacheKey.isEmpty, !cacheKey.hasPrefix("path:") else { return nil }
        var steps: [KeyStep] = []
        for piece in cacheKey.split(separator: "/") {
            let parts = piece.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let modifiers = Int(parts[0]),
                  parts[1] != "-" else { return nil }
            steps.append(KeyStep(
                modifiers: ModifierSet(rawValue: modifiers),
                key: KeyToken(String(parts[1]))
            ))
        }
        return steps.isEmpty ? nil : KeyChord(steps)
    }

    /// Drops the last step (⌫ / Esc while browsing).
    func droppingLastStep() -> KeyChord {
        guard !steps.isEmpty else { return self }
        return KeyChord(Array(steps.dropLast()))
    }

    // MARK: Matching

    /// How this shortcut relates to what the user has typed so far.
    func relation(to prefix: KeyChord) -> PrefixRelation {
        if prefix.steps.isEmpty { return .candidate }
        guard steps.count >= prefix.steps.count else { return .unrelated }

        let count = prefix.steps.count
        if count > 1 {
            for index in 0..<(count - 1) where !steps[index].matches(prefix.steps[index]) {
                return .unrelated
            }
        }

        let lastPrefixStep = prefix.steps[count - 1]
        let myStep = steps[count - 1]

        guard myStep.key != nil else { return .unrelated }

        if lastPrefixStep.key == nil {
            // Modifiers are held: every shortcut whose modifiers contain them is a candidate.
            guard myStep.modifiers.isSuperset(of: lastPrefixStep.modifiers) else { return .unrelated }
            return .candidate
        }

        guard myStep.matches(lastPrefixStep) else { return .unrelated }
        return steps.count == count ? .exact : .descend
    }

    /// The key the user has to press next, given the current prefix.
    func nextKey(after prefix: KeyChord) -> KeyToken? {
        if prefix.steps.isEmpty { return steps.first?.key }
        let count = prefix.steps.count
        guard steps.count >= count else { return nil }
        if prefix.steps[count - 1].key == nil {
            return steps[count - 1].key
        }
        return steps.count > count ? steps[count].key : nil
    }

    /// The step the user would type next, given the prefix.
    func step(after prefix: KeyChord) -> KeyStep? {
        if prefix.steps.isEmpty { return steps.first }
        if prefix.steps[prefix.steps.count - 1].key == nil {
            return steps.count >= prefix.steps.count ? steps[prefix.steps.count - 1] : nil
        }
        return steps.count > prefix.steps.count ? steps[prefix.steps.count] : nil
    }

    /// Number of steps still missing after this prefix.
    func remainingSteps(after prefix: KeyChord) -> Int {
        let count = prefix.steps.count
        guard count > 0, steps.count >= count else { return max(0, steps.count - count) }
        return steps.count - count
    }
}

extension KeyChord {
    /// True when the stroke the panel is about to show is the last one: pressing it finishes
    /// the shortcut.
    ///
    /// `remainingSteps(after:)` counts the strokes still missing **including the one being
    /// shown**, so `1` means "this one, and then it is done" — not "one more level below".
    /// Reading it the other way round is what made both the chevron and the click wrong:
    /// a leaf row was treated as a group row and descending it pushed the prefix onto the
    /// complete chord, which `hits` then filtered out of the panel entirely.
    func isFinalStroke(after prefix: KeyChord) -> Bool {
        remainingSteps(after: prefix) <= 1
    }
}

/// Relationship between a shortcut and the prefix the user has typed.
enum PrefixRelation: String, Hashable, Sendable {
    /// The typed prefix *is* this shortcut.
    case exact
    /// The shortcut starts with the typed prefix and needs more keys (drill down).
    case descend
    /// Modifiers are held; this shortcut is a candidate for the next key.
    case candidate
    /// Not reachable from this prefix.
    case unrelated
}
