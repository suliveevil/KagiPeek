import Foundation

/// Search corpus built once per catalog so typing stays cheap: titles (latin and pinyin),
/// pinyin initials, menu path levels, chords, key names and modifier names are all
/// precomputed.
struct SearchCorpus {
    struct Document {
        let item: BindingItem
        let titleHaystacks: [String]
        let haystacks: [String]
        /// Menu path, nearest ancestor first: `["Appearance", "View"]` for
        /// View › Appearance › ….
        ///
        /// One haystack per level instead of one joined string, because the weight of a
        /// match depends on which level it happened in — see `score(token:document:)`.
        let groupLevels: [String]
        let modifiers: ModifierSet
        let keyTokens: Set<String>
    }

    let documents: [Document]

    init(items: [BindingItem], style: KeyFormatter.Style) {
        documents = items.map { Self.makeDocument($0, style: style) }
    }

    func search(_ query: String, limit: Int = 60) -> [BindingItem] {
        let tokens = Self.tokens(in: query)
        guard !tokens.isEmpty else { return documents.prefix(limit).map(\.item) }

        var scored: [(item: BindingItem, score: Int)] = []
        for document in documents {
            guard let score = Self.score(tokens: tokens, document: document) else { continue }
            scored.append((document.item, score))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
        }
        return scored.prefix(limit).map(\.item)
    }

    // MARK: - Tokens

    /// Splits a query into unordered AND terms. `+` works as a separator too, so
    /// "cmd+opt+x" and "op cm x" both work.
    static func tokens(in query: String) -> [String] {
        query
            .lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    static func modifierAlias(_ token: String) -> ModifierSet? {
        switch token {
        case "cmd", "command", "cm", "com", "⌘": return .command
        case "opt", "option", "alt", "op", "⌥": return .option
        case "ctrl", "control", "ctl", "ct", "⌃": return .control
        case "shift", "sft", "sh", "⇧": return .shift
        default: return nil
        }
    }

    // MARK: - Scoring

    static func score(tokens: [String], document: Document) -> Int? {
        var total = 0
        for token in tokens {
            guard let value = score(token: token, document: document) else { return nil }
            total += value
        }
        return total
    }

    static func score(token: String, document: Document) -> Int? {
        var best: Int?

        if let modifier = modifierAlias(token), document.modifiers.contains(modifier) {
            best = 600
        }
        if document.keyTokens.contains(token) {
            best = max(best ?? 0, 550)
        }
        for haystack in document.titleHaystacks {
            if let value = fuzzy(token: token, in: haystack) {
                best = max(best ?? 0, value + 90)
            }
        }
        // The menu path still counts, but a match in it never outranks a match in the
        // command's own name: the leaf is what the user is looking for, an ancestor only
        // says where it lives. Even the nearest level is halved, and each level further
        // up halves again ("View › Appearance › …" scores its "View" at a quarter) —
        // Menu-Bar-Search weights ancestors the same way, `levelAdjust *= 2` per level.
        for (level, haystack) in document.groupLevels.enumerated() {
            if let value = fuzzy(token: token, in: haystack) {
                best = max(best ?? 0, Int((Double(value) / pow(2.0, Double(level + 1))).rounded()))
            }
        }
        for haystack in document.haystacks {
            if let value = fuzzy(token: token, in: haystack) {
                best = max(best ?? 0, value)
            }
        }
        return best
    }

    static func fuzzy(token: String, in haystack: String) -> Int? {
        guard !haystack.isEmpty, !token.isEmpty else { return nil }
        if haystack == token { return 2_000 }
        if haystack.hasPrefix(token) { return 1_500 }
        if let range = haystack.range(of: token) {
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return 1_200 - min(offset, 200)
        }
        var gaps = 0
        var cursor = haystack.startIndex
        for character in token {
            guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
            gaps += haystack.distance(from: cursor, to: found)
            cursor = haystack.index(after: found)
        }
        return max(50, 600 - gaps * 4)
    }

    // MARK: - Documents

    static func makeDocument(_ item: BindingItem, style: KeyFormatter.Style) -> Document {
        var titleHaystacks: [String] = [item.title.lowercased()]
        titleHaystacks.append(contentsOf: Pinyin.forms(of: item.title))
        titleHaystacks.append(latinInitials(of: item.title))

        var haystacks = titleHaystacks
        haystacks.append(KeyFormatter.render(item.chord, style: style).lowercased())
        haystacks.append(item.chord.steps.compactMap { $0.key?.raw }.joined(separator: " "))

        let modifiers = item.chord.steps.first?.modifiers ?? []
        var modifierWords: [String] = []
        for modifier in modifiers.ordered {
            modifierWords.append(KeyFormatter.word(for: modifier))
            modifierWords.append(KeyFormatter.symbol(for: modifier))
        }
        haystacks.append(modifierWords.joined(separator: " "))

        // The path used to be one joined haystack, which scored "View › Appearance" in
        // the same bucket as the command's own title. Per level instead, nearest first.
        let groupLevels = item.group
            .reversed()
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }

        let keyTokens = Set(item.chord.steps.compactMap { $0.key?.raw })
        return Document(
            item: item,
            titleHaystacks: titleHaystacks.filter { !$0.isEmpty },
            haystacks: haystacks.filter { !$0.isEmpty },
            groupLevels: groupLevels,
            modifiers: modifiers,
            keyTokens: keyTokens
        )
    }

    private static func latinInitials(of title: String) -> String {
        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count > 1 else { return "" }
        return words.compactMap { $0.first }.map(String.init).joined().lowercased()
    }
}

/// Chinese → pinyin forms used by the search corpus.
enum Pinyin {
    static func forms(of text: String) -> [String] {
        guard text.unicodeScalars.contains(where: { $0.value > 0x2E80 }) else { return [] }
        guard let latin = text.applyingTransform(.mandarinToLatin, reverse: false) else { return [] }
        let folded = latin.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US")
        )
        let syllables = folded
            .split(whereSeparator: { $0.isWhitespace || $0 == "'" })
            .map(String.init)
        guard !syllables.isEmpty else { return [] }
        let full = syllables.joined().lowercased()
        let spaced = syllables.joined(separator: " ").lowercased()
        let initials = syllables.compactMap { $0.first }.map(String.init).joined().lowercased()
        return [full, spaced, initials].filter { !$0.isEmpty }
    }
}
