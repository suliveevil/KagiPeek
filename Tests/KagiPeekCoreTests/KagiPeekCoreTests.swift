import XCTest
@testable import KagiPeekCore

final class KeyChordTests: XCTestCase {
    func testDescriptorParsing() {
        let chord = KeyChord(descriptor: "cmd+shift+3")
        XCTAssertEqual(chord.steps.count, 1)
        XCTAssertEqual(chord.steps[0].modifiers, [.command, .shift])
        XCTAssertEqual(chord.steps[0].key, KeyToken("3"))
        XCTAssertEqual(KeyFormatter.render(chord, style: .symbols), "⇧⌘3")
    }

    func testModifierOnlyPrefixIsCandidate() {
        let binding = KeyChord.combo([.command], KeyToken("c"))
        XCTAssertEqual(binding.relation(to: .modifiers([.command])), .candidate)
        XCTAssertEqual(binding.nextKey(after: .modifiers([.command])), KeyToken("c"))
    }

    func testNarrowingByAddingShift() {
        let plain = KeyChord.combo([.command], KeyToken("s"))
        let shifted = KeyChord.combo([.command, .shift], KeyToken("s"))
        let prefix = KeyChord.modifiers([.command, .shift])
        XCTAssertEqual(plain.relation(to: prefix), .unrelated)
        XCTAssertEqual(shifted.relation(to: prefix), .candidate)
    }

    func testChordDescent() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        let level1 = KeyChord.combo([.command], KeyToken("k"))
        let level2 = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        XCTAssertEqual(chord.relation(to: level1), .descend)
        XCTAssertEqual(chord.relation(to: level2), .exact)
        XCTAssertEqual(chord.nextKey(after: level1), KeyToken("c"))
        XCTAssertEqual(chord.remainingSteps(after: level1), 1)
        XCTAssertEqual(chord.relation(to: KeyChord.combo([.option], KeyToken("k"))), .unrelated)
    }

    func testAlternatesMatchPhysicalKey() {
        let step = KeyStep.combo([.command, .option], KeyToken("r"), alternates: [KeyToken("r")])
        XCTAssertTrue(step.matchesKey(KeyToken("r")))
        XCTAssertTrue(step.matchesKey(KeyToken("R")))
        XCTAssertFalse(step.matchesKey(KeyToken("t")))
    }

    func testDroppingLastStep() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        XCTAssertEqual(chord.droppingLastStep().steps.count, 1)
        XCTAssertEqual(KeyChord.empty.droppingLastStep(), .empty)
    }
}

final class KeyFormatterTests: XCTestCase {
    func testCanonicalModifierOrder() {
        let chord = KeyChord.combo([.command, .shift, .option, .control], KeyToken("k"))
        XCTAssertEqual(KeyFormatter.render(chord, style: .symbols), "⌃⌥⇧⌘K")
    }

    func testSpecialKeys() {
        XCTAssertEqual(KeyFormatter.render(.combo([.command], KeyToken("left")), style: .symbols), "⌘←")
        XCTAssertEqual(KeyFormatter.render(.combo([.command], KeyToken("delete")), style: .symbols), "⌘⌫")
        XCTAssertEqual(KeyFormatter.render(.combo([.command], KeyToken("f5")), style: .symbols), "⌘F5")
        XCTAssertEqual(KeyFormatter.render(.combo([.shift, .command], KeyToken("3")), style: .symbols), "⇧⌘3")
    }

    func testWordsStyle() {
        XCTAssertEqual(KeyFormatter.render(.combo([.command, .shift], KeyToken("z")), style: .words), "shift + command + Z")
    }

    func testChordStepsJoined() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        XCTAssertEqual(KeyFormatter.render(chord, style: .symbols), "⌘K ⌘C")
        XCTAssertEqual(KeyFormatter.breadcrumb(for: chord, style: .symbols), ["⌘K", "⌘C"])
    }
}

final class DescriptionCleanerTests: XCTestCase {
    func testCollapsesWhitespaceAndStripsHint() {
        XCTAssertEqual(DescriptionCleaner.clean("  Save   As…\t⌘S "), "Save As…")
        XCTAssertEqual(DescriptionCleaner.clean("Open\u{00A0}Recent"), "Open Recent")
    }

    func testKeepsMeaningfulTrailingArrow() {
        XCTAssertEqual(DescriptionCleaner.clean("Continue →"), "Continue →")
    }

    func testLeadingPlusIsRemoved() {
        XCTAssertEqual(DescriptionCleaner.clean("+file"), "file")
    }

    func testTruncation() {
        XCTAssertEqual(DescriptionCleaner.truncate("abcdefghij", maxLength: 5), "abcd…")
        XCTAssertEqual(DescriptionCleaner.truncate("abc", maxLength: 5), "abc")
        XCTAssertEqual(DescriptionCleaner.truncate("abcdefghij", maxLength: 8), "abcdefg…")
    }
}

final class PrefixResolverTests: XCTestCase {
    func makeCatalog() -> [BindingItem] {
        [
            BindingItem(chord: .combo([.command], KeyToken("c")), title: "Copy", group: ["Edit"], source: .menu),
            BindingItem(chord: .combo([.command, .shift], KeyToken("c")), title: "Copy Style", group: ["Edit"], source: .menu),
            BindingItem(chord: .combo([.option], KeyToken("left")), title: "Word Left", group: ["Edit"], source: .menu)
        ]
    }

    func testHitsAtModifierLevel() {
        let hits = PrefixResolver.hits(for: .modifiers([.command]), in: makeCatalog())
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.nextKey == KeyToken("c") })
    }

    func testProbeReplacesModifierStep() {
        let probe = PrefixResolver.probe(after: .modifiers([.command]), modifiers: [.command], key: KeyToken("c"))
        XCTAssertEqual(probe.steps.count, 1)
        XCTAssertEqual(probe.relation(to: .modifiers([.command])), .candidate)
        XCTAssertNotNil(PrefixResolver.exactMatch(in: makeCatalog(), for: probe))
    }

    func testDescendantAndExact() {
        let items = [
            BindingItem(chord: KeyChord([.combo([.command], KeyToken("k")), .combo([.command], KeyToken("c"))]), title: "Chord", group: ["Edit"], source: .menu)
        ]
        let level1 = PrefixResolver.probe(after: .modifiers([.command]), modifiers: [.command], key: KeyToken("k"))
        XCTAssertNil(PrefixResolver.exactMatch(in: items, for: level1))
        XCTAssertEqual(PrefixResolver.descendantCount(in: items, for: level1), 1)
        let level2 = PrefixResolver.probe(after: level1, modifiers: [.command], key: KeyToken("c"))
        XCTAssertNotNil(PrefixResolver.exactMatch(in: items, for: level2))
    }

    func testDisabledFiltering() {
        let disabled = BindingItem(chord: .combo([.command], KeyToken("x")), title: "Disabled", group: ["Edit"], isEnabled: false, source: .menu)
        XCTAssertEqual(PrefixResolver.hits(for: .modifiers([.command]), in: [disabled], includeDisabled: false).count, 0)
        XCTAssertEqual(PrefixResolver.hits(for: .modifiers([.command]), in: [disabled], includeDisabled: true).count, 1)
    }
}

final class ConflictDetectorTests: XCTestCase {
    func testDetectsDistinctTitlesOnSameChord() {
        let a = BindingItem(chord: .combo([.command], KeyToken("n")), title: "New", group: ["File"], source: .menu)
        let b = BindingItem(chord: .combo([.command], KeyToken("n")), title: "New Window", group: ["File"], source: .menu)
        let conflicts = ConflictDetector.conflicts(in: [a, b])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].items.count, 2)
    }

    func testIgnoresExactDuplicates() {
        let a = BindingItem(chord: .combo([.command], KeyToken("n")), title: "New", group: ["File"], source: .menu)
        XCTAssertTrue(ConflictDetector.conflicts(in: [a, a]).isEmpty)
    }
}

final class SearchIndexTests: XCTestCase {
    private let items = [
        BindingItem(chord: .combo([.command], KeyToken("p")), title: "Print", group: ["File"], source: .menu),
        BindingItem(chord: .combo([.command], KeyToken("s")), title: "Save", group: ["File"], source: .menu),
        BindingItem(chord: .combo([.command, .shift], KeyToken("3")), title: "Screenshot", group: ["System"], source: .builtIn)
    ]

    func testPrefixMatchFirst() {
        let results = SearchIndex.search("pri", in: items, style: .symbols)
        XCTAssertEqual(results.first?.title, "Print")
    }

    func testSubsequenceMatch() {
        let results = SearchIndex.search("scsh", in: items, style: .symbols)
        XCTAssertEqual(results.first?.title, "Screenshot")
    }

    func testShortcutTextMatch() {
        let results = SearchIndex.search("⇧⌘3", in: items, style: .symbols)
        XCTAssertEqual(results.first?.title, "Screenshot")
    }

    func testNoMatch() {
        XCTAssertTrue(SearchIndex.search("zzzz", in: items, style: .symbols).isEmpty)
    }
}

final class LocalizationTests: XCTestCase {
    func testEveryKeyHasBothLanguages() {
        for key in L10nKey.allCases {
            let en = L10n.string(key, language: .english)
            let zh = L10n.string(key, language: .chinese)
            XCTAssertFalse(en.isEmpty, "\(key) has no English translation")
            XCTAssertFalse(zh.isEmpty, "\(key) has no Chinese translation")
            XCTAssertNotEqual(en, key.rawValue, "\(key) fell back to its raw name")
        }
    }

    func testFormatPlaceholdersMatch() {
        for key in L10nKey.allCases {
            let en = L10n.string(key, language: .english)
            let zh = L10n.string(key, language: .chinese)
            XCTAssertEqual(placeholderCount(en), placeholderCount(zh), "\(key) placeholder mismatch")
        }
    }

    func testSystemLanguageResolution() {
        XCTAssertEqual(L10n.resolvedLanguage(.system, preferred: ["zh-Hans-CN", "en"]), .chinese)
        XCTAssertEqual(L10n.resolvedLanguage(.system, preferred: ["en-US"]), .english)
        XCTAssertEqual(L10n.resolvedLanguage(.english, preferred: ["zh-Hans"]), .english)
    }

    private func placeholderCount(_ text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: "%[@d%]")
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

final class KeyMapperTests: XCTestCase {
    func testSpecialKeys() {
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(123)), KeyToken("left"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(122)), KeyToken("f1"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(51)), KeyToken("delete"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(49)), KeyToken("space"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(53)), KeyToken("esc"))
    }

    func testOptionUsesPhysicalKey() {
        let token = KeyMapper.token(keyCode: UInt16(15), unicode: "´", modifiers: [.option])
        XCTAssertEqual(token, KeyToken("r"))
        let plain = KeyMapper.token(keyCode: UInt16(15), unicode: "r", modifiers: [])
        XCTAssertEqual(plain, KeyToken("r"))
    }

    func testPrivateUseCharactersAreRejected() {
        XCTAssertNil(KeyMapper.normalize(character: "\u{F700}"))
    }

    /// 真实按下 Esc 时事件带的是 U+001B，不是 "esc"。字符优先、键码兜底的顺序必须
    /// 让控制字符落到键码上，否则面板永远认不出 Esc（也就永远关不掉）。
    func testLiveEscapeResolvesToEscToken() {
        XCTAssertEqual(KeyMapper.token(keyCode: 53, unicode: "\u{1B}", modifiers: []), KeyToken("esc"))
    }

    /// 同一条路上的其它非打印键：Tab / Return / Delete 各自也带一个控制字符。
    func testOtherControlCharactersFallBackToKeyCode() {
        XCTAssertEqual(KeyMapper.token(keyCode: 48, unicode: "\u{9}", modifiers: []), KeyToken("tab"))
        XCTAssertEqual(KeyMapper.token(keyCode: 36, unicode: "\r", modifiers: []), KeyToken("return"))
        XCTAssertEqual(KeyMapper.token(keyCode: 51, unicode: "\u{7F}", modifiers: []), KeyToken("delete"))
    }
}

final class BuiltInCatalogTests: XCTestCase {
    func testCatalogSize() {
        XCTAssertEqual(BuiltInCatalog.entries.count, 100)
    }

    func testEveryEntryBuilds() {
        for language in [AppLanguage.english, .chinese] {
            let items = BuiltInCatalog.items(language: language)
            XCTAssertEqual(items.count, BuiltInCatalog.entries.count)
            for item in items {
                XCTAssertFalse(item.title.isEmpty)
                XCTAssertEqual(item.chord.steps.count, 1)
                XCTAssertNotNil(item.chord.steps.first?.key)
            }
        }
    }

    func testNoDuplicateChordWithinSameScope() {
        var seen: [String: String] = [:]
        for entry in BuiltInCatalog.entries {
            let key = "\(entry.bundleID ?? "*")|\(entry.descriptor)"
            XCTAssertNil(seen[key], "duplicate built-in shortcut: \(key) (\(entry.titleEN) vs \(seen[key] ?? ""))")
            seen[key] = entry.titleEN
        }
    }

    func testEnglishTitlesDifferFromChinese() {
        let pairs = BuiltInCatalog.entries.filter { $0.titleEN == $0.titleZH }
        XCTAssertTrue(pairs.isEmpty, "missing English titles: \(pairs.map(\.titleZH))")
    }
}

final class UsageStatisticsTests: XCTestCase {
    func testRecordAccumulates() {
        var stats = UsageStatistics()
        let key = "*|8:c"
        stats.record(usageKey: key, at: Date(timeIntervalSince1970: 100))
        stats.record(usageKey: key, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(stats.record(for: key)?.count, 2)
        XCTAssertEqual(stats.totalPresses, 2)
        XCTAssertEqual(stats.record(for: key)?.lastUsed, Date(timeIntervalSince1970: 200))
    }

    func testResetClearsEverything() {
        var stats = UsageStatistics()
        stats.record(usageKey: "k", at: Date())
        stats.reset()
        XCTAssertTrue(stats.records.isEmpty)
        XCTAssertEqual(stats.totalPresses, 0)
    }

    func testPruneKeepsMostRecent() {
        var stats = UsageStatistics()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<(UsageStatistics.maxRecords + 50) {
            stats.record(usageKey: "key\(index)", at: base.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(stats.records.count, UsageStatistics.maxRecords)
        // The 50 oldest entries were dropped.
        XCTAssertNil(stats.records["key0"])
        XCTAssertNotNil(stats.records["key\(UsageStatistics.maxRecords + 49)"])
    }

    func testStatisticsRoundTrip() throws {
        var stats = UsageStatistics()
        stats.record(usageKey: "a|8:c", at: Date(timeIntervalSince1970: 42))
        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(UsageStatistics.self, from: data)
        XCTAssertEqual(decoded, stats)
    }
}

final class KeySegmentTests: XCTestCase {
    /// The chord is split into glyphs so a held modifier can be lit instead of hidden. The
    /// split must therefore keep the shortcut's text intact — including the ⌘ that used to
    /// be stripped while it was held.
    func testModifierGlyphsKeepTheirIdentity() {
        let chord = KeyChord.combo([.command], KeyToken("c"))
        let segments = KeyFormatter.segments(for: chord, style: .symbols)
        XCTAssertEqual(segments.map(\.text), ["⌘", "C"])
        XCTAssertEqual(segments.first?.kind, .modifier(.command))
    }

    func testSegmentedChordRendersExactlyLikeThePlainString() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command, .shift], KeyToken("c"))
        ])
        XCTAssertEqual(
            KeyFormatter.segments(for: chord, style: .symbols).map(\.text).joined(),
            KeyFormatter.render(chord, style: .symbols)
        )
        XCTAssertEqual(
            KeyFormatter.segments(for: chord, style: .words).map(\.text).joined(),
            KeyFormatter.render(chord, style: .words)
        )
    }

    func testMultiStrokeChordsCarryASeparator() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        let kinds = KeyFormatter.segments(for: chord, style: .symbols).map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .separator }.count, 1)
    }
}

final class PanelOrderingTests: XCTestCase {
    private func item(_ modifiers: ModifierSet, _ key: String, _ title: String) -> BindingItem {
        BindingItem(
            chord: .combo(modifiers, KeyToken(key)),
            title: title,
            group: ["Edit"],
            source: .menu
        )
    }

    /// The panel is a reference card ordered by the shortcut, not by the menu it came from.
    func testOrderIsTheShortcutItself() {
        let items = [
            item([.command], "v", "Paste"),
            item([.command], "c", "Copy"),
            item([.control], "a", "Beginning of Line"),
            item([], "f5", "Reload")
        ]
        let labels = PanelOrdering.sorted(items).map { KeyFormatter.render($0.chord, style: .symbols) }
        // 无修饰键的行先（F5 没有修饰键），然后 ⌘ 优先，⌃ 最后。
        XCTAssertEqual(labels, ["F5", "⌘C", "⌘V", "⌃A"])
    }

    /// 修饰键按重要性逐位比较（⌘ → ⌥ → ⌃ → ⇧），而不是先比个数：⌘C 必须最先出现，
    /// 且带 ⌘ 的行连成一片，⌃⌥C 紧挨 ⌃C。
    ///
    /// 先比个数会把所有「两个修饰键」的行排到所有「一个修饰键」的行之后，于是 ⌃⌥C 与 ⌃C
    /// 隔着几百行，而 ⌘C 反而在上面——这不是任何人会读的一种顺序。
    func testModifiersCompareBySignificance() {
        let items = [
            item([.command], "c", "Copy"),
            item([.control], "c", "Control C"),
            item([.option], "c", "Option C"),
            item([.control, .option], "c", "Control Option C"),
            item([.shift, .command], "z", "Redo")
        ]
        let labels = PanelOrdering.sorted(items).map { KeyFormatter.render($0.chord, style: .symbols) }
        XCTAssertEqual(labels, ["⌘C", "⇧⌘Z", "⌥C", "⌃⌥C", "⌃C"])

        // 单个修饰键之间的先后：⌘ → ⌥ → ⌃ → ⇧。
        let singles = [
            item([.shift], "x", "Shift"),
            item([.control], "x", "Control"),
            item([.option], "x", "Option"),
            item([.command], "x", "Command")
        ]
        XCTAssertEqual(
            PanelOrdering.sorted(singles).map(\.title),
            ["Command", "Option", "Control", "Shift"]
        )
    }

    /// 功能键按它写出来的那个词参与排序：f、f1、f2 … f12、g，而不是单独一块「功能键」。
    func testFunctionKeysSortBesideTheirLetter() {
        let items = [
            item([], "g", "G"),
            item([], "f2", "F2"),
            item([], "f1", "F1"),
            item([], "e", "E")
        ]
        XCTAssertEqual(PanelOrdering.sorted(items).map(\.title), ["E", "F1", "F2", "G"])
        XCTAssertTrue(KeyOrder.compare(KeyToken("f2"), KeyToken("f10")))
        XCTAssertTrue(KeyOrder.compare(KeyToken("f1"), KeyToken("3")))
        XCTAssertTrue(KeyOrder.compare(KeyToken("f1"), KeyToken("return")))
    }

    /// Holding a modifier reorders rather than narrowing: every row stays, the ones that use
    /// it move to the top.
    func testHeldModifierLiftsItsRowsWithoutDroppingTheRest() {
        let items = [
            item([.command], "c", "Copy"),
            item([.control], "a", "Beginning of Line"),
            item([.command], "v", "Paste")
        ]
        let labels = PanelOrdering.sorted(items, emphasizing: [.command])
            .map { KeyFormatter.render($0.chord, style: .symbols) }
        XCTAssertEqual(labels, ["⌘C", "⌘V", "⌃A"])
    }

    func testSingleStrokeChordsComeBeforeChords() {
        let single = item([.command], "k", "Link")
        let chord = BindingItem(
            chord: KeyChord([
                KeyStep.combo([.command], KeyToken("k")),
                KeyStep.combo([.command], KeyToken("c"))
            ]),
            title: "Copy Link",
            group: ["Edit"],
            source: .menu
        )
        let ordered = PanelOrdering.sorted([chord, single])
        XCTAssertEqual(ordered.first?.title, "Link")
    }

    /// The title-bar chips keep a shortcut when any stroke carries every ticked modifier,
    /// so ⌘K ⌘C counts as a ⌘ shortcut.
    func testFilterRequiresEveryTickedModifierOnOneStroke() {
        let plain = KeyChord.combo([.command], KeyToken("c"))
        let shifted = KeyChord.combo([.command, .shift], KeyToken("s"))
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command, .shift], KeyToken("c"))
        ])
        XCTAssertTrue(PanelOrdering.uses(plain, allOf: [.command]))
        XCTAssertTrue(PanelOrdering.uses(shifted, allOf: [.command, .shift]))
        XCTAssertFalse(PanelOrdering.uses(plain, allOf: [.command, .shift]))
        XCTAssertTrue(PanelOrdering.uses(chord, allOf: [.command, .shift]))
        // An empty filter is no filter at all.
        XCTAssertTrue(PanelOrdering.uses(plain, allOf: []))
    }
}

final class SemanticVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(SemanticVersion("v1.2.0")?.description, "1.2.0")
        XCTAssertEqual(SemanticVersion("2")?.description, "2.0.0")
        XCTAssertEqual(SemanticVersion("1.2.3-beta.1")?.description, "1.2.3")
        XCTAssertNil(SemanticVersion("latest"))
    }

    func testComparison() {
        let old = SemanticVersion("1.2.0")!
        let new = SemanticVersion("2.0.0")!
        XCTAssertTrue(old < new)
        XCTAssertFalse(new < old)
        XCTAssertEqual(SemanticVersion("1.2.0"), SemanticVersion("v1.2.0"))
    }
}

final class MarkdownExporterTests: XCTestCase {
    func testRendersGroupedTable() {
        let items = [
            BindingItem(chord: .combo([.command], KeyToken("c")), title: "Copy | Paste", group: ["Edit"], source: .menu),
            BindingItem(chord: .combo([.command, .shift], KeyToken("s")), title: "Save As", group: ["File"], isEnabled: false, source: .menu)
        ]
        let markdown = MarkdownExporter.render(
            appName: "Demo",
            items: items,
            style: .symbols,
            language: .english,
            generatedAt: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(markdown.contains("# KagiPeek — Demo"))
        XCTAssertTrue(markdown.contains("## Edit"))
        XCTAssertTrue(markdown.contains("## File"))
        XCTAssertTrue(markdown.contains("| `⌘C` | Copy \\| Paste |"))
        XCTAssertTrue(markdown.contains("Save As _(unavailable)_"))
    }
}

final class ExternalConflictTests: XCTestCase {
    func testSystemHotkeyConflictsWithAppBinding() {
        let app = BindingItem(chord: .combo([.command], KeyToken("space")), title: "Custom", group: ["Edit"], source: .menu)
        let system = BindingItem(chord: .combo([.command], KeyToken("space")), title: "Spotlight", group: ["System hotkeys"], source: .system)
        let conflicts = ConflictDetector.conflicts(in: [app], external: [system])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].items.count, 2)
        XCTAssertTrue(conflicts[0].items.contains { $0.source == .system })
    }

    func testNoExternalMeansNoConflict() {
        let app = BindingItem(chord: .combo([.command], KeyToken("space")), title: "Custom", group: ["Edit"], source: .menu)
        XCTAssertTrue(ConflictDetector.conflicts(in: [app]).isEmpty)
    }
}

final class SettingsDefaultsTests: XCTestCase {
    func testSmartIsDefault() {
        let settings = AppSettingsSnapshot()
        XCTAssertEqual(settings.sortMode, .smart)
        XCTAssertEqual(settings.runRowKey, .runRowDefault)
        XCTAssertEqual(settings.copyRowKey, .copyRowDefault)
    }

    func testDecodingOlderPayloadKeepsDefaults() throws {
        let json = "{\"triggerMode\":\"holdModifiers\",\"holdDelay\":0.4}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(decoded.holdDelay, 0.4)
        XCTAssertEqual(decoded.sortMode, .smart)
        XCTAssertEqual(decoded.runRowKey, .runRowDefault)
    }

    /// v2.1 wrote `allowPanelExecute`; the field is gone, so the stored payload must still
    /// decode and the row keys must fall back to their defaults.
    func testLegacyPayloadWithAllowPanelExecuteStillDecodes() throws {
        let json = """
        {"triggerMode":"hotkey","allowPanelExecute":true,"allowSearchExecute":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(decoded.triggerMode, .hotkey)
        XCTAssertEqual(decoded.runRowKey, .runRowDefault)
        XCTAssertEqual(decoded.copyRowKey, .copyRowDefault)
    }
}

final class RowKeySpecTests: XCTestCase {
    func testReturnBindingAcceptsKeypadEnter() {
        let spec = HotkeySpec.runRowDefault // ↩, no modifiers
        XCTAssertTrue(spec.matches(keyCode: 36, modifiers: []))
        XCTAssertTrue(spec.matches(keyCode: 76, modifiers: []))
    }

    func testBindingDoesNotAcceptExtraModifiers() {
        XCTAssertFalse(HotkeySpec.runRowDefault.matches(keyCode: 36, modifiers: [.shift]))
        XCTAssertTrue(HotkeySpec.copyRowDefault.matches(keyCode: 36, modifiers: [.command]))
        XCTAssertFalse(HotkeySpec.copyRowDefault.matches(keyCode: 36, modifiers: []))
    }

    func testCapturedIdentifiersFollowTheReturnAlias() {
        let copy = HotkeySpec.copyRowDefault.capturedIdentifiers
        XCTAssertEqual(copy.count, 2)
        XCTAssertEqual(copy.map { $0.keyCode }, [36, 76])

        // A binding that is not Return has exactly one identity to swallow.
        XCTAssertEqual(HotkeySpec.panelDefault.capturedIdentifiers.count, 1)
    }
}

final class SearchCorpusTests: XCTestCase {
    private func item(_ modifiers: ModifierSet, _ key: String, _ title: String, group: [String] = ["Edit"]) -> BindingItem {
        BindingItem(chord: .combo(modifiers, KeyToken(key)), title: title, group: group, source: .menu)
    }

    func testModifierTokensInAnyOrder() {
        let items = [
            item([.command, .option], "x", "Special"),
            item([.command], "x", "Cut")
        ]
        XCTAssertEqual(SearchIndex.search("com op x", in: items, style: .symbols).first?.title, "Special")
        XCTAssertEqual(SearchIndex.search("op cm x", in: items, style: .symbols).first?.title, "Special")
        XCTAssertEqual(SearchIndex.search("x op cmd", in: items, style: .symbols).first?.title, "Special")
    }

    func testPinyinInitialsAndSyllables() {
        let items = [item([.command], "x", "剪切", group: ["编辑"])]
        XCTAssertEqual(SearchIndex.search("jq", in: items, style: .symbols).first?.title, "剪切")
        XCTAssertEqual(SearchIndex.search("jian qie", in: items, style: .symbols).first?.title, "剪切")
    }

    func testLatinInitials() {
        let items = [item([.command], "f", "Find Similar", group: ["Edit"])]
        XCTAssertEqual(SearchIndex.search("fs", in: items, style: .symbols).first?.title, "Find Similar")
    }

    func testMultipleTokensMustAllMatch() {
        let items = [item([.command], "x", "Cut")]
        XCTAssertTrue(SearchIndex.search("cmd zzz", in: items, style: .symbols).isEmpty)
    }

    func testPlusSeparator() {
        let items = [item([.command, .shift], "3", "Screenshot", group: ["System"])]
        XCTAssertEqual(SearchIndex.search("cmd+shift+3", in: items, style: .symbols).first?.title, "Screenshot")
    }
}

/// 菜单路径分层加权：越靠近命令本身的层级，权重越高（Menu-Bar-Search 的祖先逐层减半）。
final class MenuPathWeightTests: XCTestCase {
    private func item(_ title: String, group: [String]) -> BindingItem {
        BindingItem(chord: .combo([.command], KeyToken("a")), title: title, group: group, source: .menu)
    }

    /// "View" 是几十个命令的祖先，同名标题才是用户想找的那个。
    func testTitleMatchBeatsTopLevelMenuMatch() {
        let items = [
            item("Show Sidebar", group: ["View"]),
            item("View Source", group: ["Window"])
        ]
        XCTAssertEqual(SearchIndex.search("view", in: items, style: .symbols).first?.title, "View Source")
    }

    /// 同一个词出现在不同深度：近祖先（直接父菜单）压过远祖先（顶层菜单）。
    func testNearerLevelOutranksDeeperAncestor() {
        let items = [
            // View › Appearance › Sidebar —— "view" 是远祖先，权重减半
            item("Sidebar", group: ["View", "Appearance"]),
            // Format › View › Font —— "view" 是近祖先，权重不减
            item("Font", group: ["Format", "View"])
        ]
        XCTAssertEqual(SearchIndex.search("view", in: items, style: .symbols).first?.title, "Font")
    }

    /// 深层路径里，顶层菜单名永远压不过命令自己的标题（回归：旧实现把整条路径拼成
    /// 一个 haystack，顶层菜单的精确匹配与标题精确同分）。
    func testDeepAncestorCannotOutrankOwnTitle() {
        let items = [
            item("Zoom", group: ["View", "Appearance", "Text Size"]),
            item("View", group: ["Window"])
        ]
        // "view" 精确命中 "View" 的标题（2000+90），而对 "Zoom" 只是 level 2 的祖先
        // （2000/4）。标题必须赢。
        XCTAssertEqual(SearchIndex.search("view", in: items, style: .symbols).first?.title, "View")
    }

    /// 单层路径行为不变：按菜单名搜仍然能命中其下命令。
    func testSingleLevelPathStillMatches() {
        let items = [item("Close", group: ["File"])]
        XCTAssertEqual(SearchIndex.search("file", in: items, style: .symbols).first?.title, "Close")
    }

    /// 菜单名精确命中也压不过标题的前缀命中：叶子永远最高，最近的祖先也只有一半权重。
    func testExactMenuNameLosesToTitlePrefix() {
        let items = [
            item("Show Sidebar", group: ["View"]),   // "view" 精确命中菜单名：1000
            item("View Source", group: ["Window"])   // "view" 前缀命中标题：1590
        ]
        XCTAssertEqual(SearchIndex.search("view", in: items, style: .symbols).first?.title, "View Source")
    }

}

/// 菜单扫描磁盘缓存的纯规则：什么算"仍然可信"（Menu-Bar-Search 的控制文件 + 我们的年龄上限）。
final class MenuCachePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let fingerprint = MenuCachePolicy.fingerprint(showAppleMenu: false)

    func testFingerprintTracksScanShapingSettings() {
        XCTAssertNotEqual(
            MenuCachePolicy.fingerprint(showAppleMenu: false),
            MenuCachePolicy.fingerprint(showAppleMenu: true)
        )
    }

    func testControlIsOnlyCurrentForAMatchingFingerprint() {
        XCTAssertTrue(MenuCachePolicy.isControlCurrent(fingerprint, fingerprint: fingerprint))
        XCTAssertFalse(MenuCachePolicy.isControlCurrent(nil, fingerprint: fingerprint))
        XCTAssertFalse(MenuCachePolicy.isControlCurrent("schema=1;appleMenu=1", fingerprint: fingerprint))
    }

    func testFreshEntryIsUsable() {
        XCTAssertTrue(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(-60),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
    }

    func testEntryExpiresAtTheAgeCap() {
        // 窗口内可用，压线即失效：菜单会在 App 运行期间变化，缓存必须自我刷新。
        XCTAssertTrue(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(-(MenuCachePolicy.entryMaxAge - 1)),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
        XCTAssertFalse(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(-MenuCachePolicy.entryMaxAge),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
    }

    func testEntryFromOtherSettingsIsNotUsable() {
        XCTAssertFalse(MenuCachePolicy.isEntryUsable(
            scannedAt: now,
            entryFingerprint: MenuCachePolicy.fingerprint(showAppleMenu: true),
            fingerprint: fingerprint,
            now: now
        ))
    }

    /// 时钟回跳不能把一份过期扫描永久救活。
    func testFutureTimestampIsNotUsable() {
        XCTAssertFalse(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(600),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
    }
}

/// 面板窗口的高度：收窄列表不得改变窗口大小（否则视觉上就是"跳动"）。
final class PanelSizeStabilityTests: XCTestCase {
    private var settings: AppSettingsSnapshot {
        var value = AppSettingsSnapshot()
        value.columnCount = 1
        value.maxItemsPerPage = 24
        return value
    }

    private func state(rows: Int, budget: Int, headings: Int = 0, titled: Bool = false) -> PanelState {
        var value = PanelState()
        value.groups = [
            PanelGroup(
                id: "g",
                title: titled ? "System" : "",
                rows: (0..<rows).map { index in
                    PanelRow(
                        id: "r\(index)",
                        keySegments: [],
                        title: "Row \(index)",
                        note: "",
                        isGroup: false,
                        isEnabled: true,
                        hasConflict: false,
                        index: index,
                        isHighlighted: false,
                        isCompleted: false,
                        isFavorite: false
                    )
                }
            )
        ]
        value.rowBudget = budget
        value.headingBudget = headings
        return value
    }

    /// 核心：按下修饰键把 24 行收窄到 3 行，窗口高度必须一动不动。
    func testNarrowingDoesNotResizeThePanel() {
        let wide = state(rows: 24, budget: 24)
        let narrow = state(rows: 3, budget: 24)
        XCTAssertEqual(
            OverlayMetrics.size(for: narrow, settings: settings).height,
            OverlayMetrics.size(for: wide, settings: settings).height
        )
    }

    /// 收窄到极致也不缩：预算是会话内最宽的那份列表。
    func testSingleRowKeepsTheSessionHeight() {
        let one = state(rows: 1, budget: 24)
        let all = state(rows: 24, budget: 24)
        XCTAssertEqual(
            OverlayMetrics.size(for: one, settings: settings).height,
            OverlayMetrics.size(for: all, settings: settings).height
        )
    }

    /// 预算算小了也不能裁掉行：取两者较大值。
    func testFrameStillFitsMoreRowsThanTheBudget() {
        let crowded = state(rows: 30, budget: 4)
        let four = state(rows: 4, budget: 4)
        let size = OverlayMetrics.size(for: crowded, settings: settings)
        XCTAssertGreaterThan(size.height, OverlayMetrics.size(for: four, settings: settings).height)
    }

    /// 预算为 0（还没算出来，比如正在扫描）退回按屏上的行数。
    func testEmptyBudgetFallsBackToTheRowsOnScreen() {
        let withBudget = state(rows: 6, budget: 24)
        let noBudget = state(rows: 6, budget: 0)
        XCTAssertLessThan(
            OverlayMetrics.size(for: noBudget, settings: settings).height,
            OverlayMetrics.size(for: withBudget, settings: settings).height
        )
    }

    /// 标题行同样要预留：最宽列表里的"系统快捷键"标题消失后窗口不能缩。
    func testHeadingBudgetKeepsTheHeadingReserved() {
        let wideWithHeading = state(rows: 24, budget: 24, headings: 1, titled: true)
        var narrowNoHeading = state(rows: 3, budget: 24, headings: 1)
        narrowNoHeading.groups = [
            PanelGroup(id: "g", title: "", rows: narrowNoHeading.groups[0].rows)
        ]
        XCTAssertEqual(
            OverlayMetrics.size(for: narrowNoHeading, settings: settings).height,
            OverlayMetrics.size(for: wideWithHeading, settings: settings).height
        )
    }

    /// 高度始终夹在 [190, 720]。
    func testHeightIsClamped() {
        XCTAssertEqual(OverlayMetrics.size(for: state(rows: 1, budget: 0), settings: settings).height, 190)
        XCTAssertEqual(OverlayMetrics.size(for: state(rows: 24, budget: 24), settings: settings).height, 720)
    }
}

final class ModifierTapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let window: TimeInterval = 0.35

    /// Emacs 式的点一下就粘住：按下、很快松开、中间没按别的键。
    func testQuickReleaseTicks() {
        var tracker = ModifierTapTracker()
        XCTAssertNil(tracker.flagsChanged([.option], previous: [], now: start, window: window))
        let tapped = tracker.flagsChanged([], previous: [.option], now: start.addingTimeInterval(0.1), window: window)
        XCTAssertEqual(tapped, [.option])
    }

    /// 按住不放是"看一眼"，不是"点一下"：超时松开什么也不粘。
    func testHoldingIsNotATap() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.command], previous: [], now: start, window: window)
        let tapped = tracker.flagsChanged([], previous: [.command], now: start.addingTimeInterval(0.9), window: window)
        XCTAssertNil(tapped)
    }

    /// 修饰键期间按了别的键 ⇒ 它是某个快捷键的一半，不是点按。
    func testModifierUsedWithAKeyIsNotATap() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.command], previous: [], now: start, window: window)
        tracker.noteKeyPress()
        let tapped = tracker.flagsChanged([], previous: [.command], now: start.addingTimeInterval(0.1), window: window)
        XCTAssertNil(tapped)
    }

    /// 面板打开时手还按着修饰键（按住唤出）：那是触发器，不能算点按。
    func testPressAlreadyDownWhenThePanelOpenedIsNotATap() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.command], previous: [.command], now: start, window: window)
        let tapped = tracker.flagsChanged([], previous: [.command], now: start.addingTimeInterval(0.05), window: window)
        XCTAssertNil(tapped)
    }

    /// 两个修饰键一起点（滚动着按下）仍然是一次点按，带着两个键。
    func testRolledPressCarriesBothModifiers() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.option], previous: [], now: start, window: window)
        tracker.flagsChanged([.option, .command], previous: [.option], now: start.addingTimeInterval(0.05), window: window)
        let tapped = tracker.flagsChanged([], previous: [.option, .command], now: start.addingTimeInterval(0.12), window: window)
        XCTAssertEqual(tapped, [.option, .command])
    }

    /// 一次点按只兑现一次：松开之后再松开，不该又粘一遍。
    func testTapIsDeliveredOnce() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.option], previous: [], now: start, window: window)
        XCTAssertEqual(
            tracker.flagsChanged([], previous: [.option], now: start.addingTimeInterval(0.1), window: window),
            [.option]
        )
        XCTAssertNil(tracker.flagsChanged([], previous: [], now: start.addingTimeInterval(0.2), window: window))
    }
}

final class OutsideClickTests: XCTestCase {
    private let app = ScreenRect(x: 100, y: 100, width: 800, height: 600)
    private let panel = ScreenRect(x: 300, y: 200, width: 400, height: 300)

    /// 点在前台 App 窗口里、面板外 —— 那一次点击只该关面板，不该点中后面的 App。
    func testPressPastThePanelIsSwallowed() {
        XCTAssertTrue(OutsideClickPolicy.shouldSwallow(point: (700, 600), panel: panel, app: app))
    }

    /// 点在面板上是面板自己的事，不能吞。
    func testPressOnThePanelIsNotSwallowed() {
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (450, 350), panel: panel, app: app))
    }

    /// 点在前台 App 之外 —— 菜单栏、Dock、桌面、别的 App —— 是用户在拿别的东西，吞掉会像卡屏。
    func testPressOutsideTheAppIsNotSwallowed() {
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (50, 50), panel: panel, app: app))
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (950, 800), panel: panel, app: app))
    }

    /// 面板盖住整个窗口时（coverWindow），窗口里的点击都落在面板上，没有可吞的。
    func testPanelCoveringTheWindowLeavesNothingToSwallow() {
        let covering = app
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (500, 400), panel: covering, app: app))
    }

    func testRectContainsUsesHalfOpenEdges() {
        let rect = ScreenRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertTrue(rect.contains(x: 0, y: 0))
        XCTAssertFalse(rect.contains(x: 10, y: 10))
    }
}

final class LatchedTicksTests: XCTestCase {
    /// 撤销的是最后点的那个，不是 ⌃⌥⇧⌘ 顺序里的最后一个。
    func testPopRemovesTheMostRecentTick() {
        var state = (latched: ModifierSet(), order: [ModifierSet]())
        state = LatchedTicks.toggling([.command], latched: state.latched, order: state.order)
        state = LatchedTicks.toggling([.option], latched: state.latched, order: state.order)
        XCTAssertEqual(state.order, [.command, .option])
        let popped = LatchedTicks.popping(latched: state.latched, order: state.order)
        XCTAssertEqual(popped?.latched, [.command])
        XCTAssertEqual(popped?.order, [.command])
    }

    /// 再点一次同一个修饰键是取消，且不留顺序残渣。
    func testTickingTwiceUnticks() {
        let first = LatchedTicks.toggling([.option], latched: [], order: [])
        let second = LatchedTicks.toggling([.option], latched: first.latched, order: first.order)
        XCTAssertTrue(second.latched.isEmpty)
        XCTAssertTrue(second.order.isEmpty)
        XCTAssertNil(LatchedTicks.popping(latched: second.latched, order: second.order))
    }

    /// 没有 tick 时撤销返回 nil，让 ⌫ 落到"返回上一级"那层含义上。
    func testPoppingNothingReturnsNil() {
        XCTAssertNil(LatchedTicks.popping(latched: [], order: []))
    }
}

/// 磁盘缓存把整行 BindingItem（含 KeyChord 的 steps/alternates）编成 JSON 存盘。
/// Chord 的 Codable 合成若丢字段，恢复出来的行就会显示错误的快捷键——而缓存命中时
/// 没有任何扫描能纠正它。钉住往返保真。
final class MenuCacheRoundTripTests: XCTestCase {
    func testBindingItemSurvivesJSONRoundTrip() {
        let items = [
            BindingItem(
                chord: .combo([.command, .shift], "3"),
                title: "Screenshot",
                group: ["System"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "0,0,1"
            ),
            // 无快捷键行：缓存里数量最多的就是它们，空 chord 必须原样回来。
            BindingItem(
                chord: .empty,
                title: "Zoom",
                group: ["Window"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "7,0,2"
            ),
            // alternates 是同一按键的别名，丢了会让布局鲁棒性静默失效。
            BindingItem(
                chord: .combo([.option], "left", alternates: ["leftArrow"]),
                title: "Back",
                group: ["History"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "2,1,0"
            )
        ]
        let data = try! JSONEncoder().encode(items)
        let decoded = try! JSONDecoder().decode([BindingItem].self, from: data)
        XCTAssertEqual(decoded, items)
        // id 与 usageKey 是扫描时算出来的：往返后必须逐字节相同，
        // 否则点击、执行、收藏会在缓存命中后全部对不上行。
        XCTAssertEqual(decoded.map(\.id), items.map(\.id))
        XCTAssertEqual(decoded.map(\.usageKey), items.map(\.usageKey))
    }
}

final class HotkeyMatcherTests: XCTestCase {
    private let hyper = HotkeySpec(keyCode: 40, modifiers: [.control, .option, .shift, .command])

    func testExactModifiers() {
        XCTAssertTrue(HotkeyMatcher.matches(keyCode: 40, modifiers: [.control, .option, .shift, .command], key: KeyToken("k"), spec: hyper))
    }

    func testHyperKeyToleratesExtraModifier() {
        let withFunction = ModifierSet([.control, .option, .shift, .command])
        let spec = HotkeySpec(keyCode: 40, modifiers: [.control, .option, .command])
        XCTAssertTrue(HotkeyMatcher.matches(keyCode: 40, modifiers: withFunction, key: KeyToken("k"), spec: spec))
    }

    func testTwoModifierHotkeyIsStrict() {
        let spec = HotkeySpec(keyCode: 40, modifiers: [.command, .option])
        XCTAssertFalse(HotkeyMatcher.matches(keyCode: 40, modifiers: [.command, .option, .shift], key: KeyToken("k"), spec: spec))
    }

    func testWrongKeyCode() {
        XCTAssertFalse(HotkeyMatcher.matches(keyCode: 41, modifiers: [.command], key: KeyToken("k"), spec: HotkeySpec(keyCode: 40, modifiers: [.command])))
    }
}

final class PerAppUsageTests: XCTestCase {
    func testGroupsByBundleID() {
        var stats = UsageStatistics()
        let now = Date(timeIntervalSince1970: 1_000)
        stats.record(usageKey: "com.apple.Safari|8:c", at: now)
        stats.record(usageKey: "com.apple.Safari|8:c", at: now.addingTimeInterval(5))
        stats.record(usageKey: "*|8:v", at: now)
        stats.record(usageKey: "com.example.editor|8:s", at: now)

        let summaries = stats.summariesByApp()
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(summaries.first?.bundleID, "com.apple.Safari")
        XCTAssertEqual(summaries.first?.presses, 2)
        XCTAssertEqual(summaries.first?.shortcutCount, 1)
        XCTAssertTrue(summaries.contains { $0.bundleID == "*" && $0.isGlobal })
    }

    func testBundleIDParsing() {
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "com.foo|8:c"), "com.foo")
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "*|8:v"), "*")
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "no-separator"), "no-separator")
    }
}

final class V21SettingsDefaultsTests: XCTestCase {
    func testPanelDefaults() {
        let settings = AppSettingsSnapshot()
        XCTAssertEqual(settings.panelPlacement, .coverWindow)
        XCTAssertEqual(settings.switchHotkey, .switchDefault)
        XCTAssertEqual(settings.fixedPanelWidth, 720)
    }

    func testPlacementRoundTrip() throws {
        var settings = AppSettingsSnapshot()
        settings.panelPlacement = .fillScreen
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        XCTAssertEqual(decoded.panelPlacement, .fillScreen)
    }
}

final class PanelHighlighterTests: XCTestCase {
    private let items = [
        BindingItem(chord: .combo([.command], KeyToken("c")), title: "Copy", group: ["Edit"], source: .menu),
        BindingItem(chord: .combo([.command, .shift], KeyToken("s")), title: "Save As", group: ["File"], source: .menu),
        BindingItem(chord: .combo([.control], KeyToken("a")), title: "Line Start", group: ["Edit"], source: .builtIn),
        BindingItem(chord: KeyChord([.combo([.command], KeyToken("k")), .combo([.command], KeyToken("c"))]), title: "Chord", group: ["Edit"], source: .menu)
    ]

    func testHeldCommandHighlightsCommandRows() {
        let ids = PanelHighlighter.highlightedIDs(items: items, prefix: .empty, heldModifiers: [.command])
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains(items[0].id))
        XCTAssertTrue(ids.contains(items[1].id))
        XCTAssertTrue(ids.contains(items[3].id))
        XCTAssertFalse(ids.contains(items[2].id))
    }

    func testNoModifiersMeansNoHighlight() {
        XCTAssertTrue(PanelHighlighter.highlightedIDs(items: items, prefix: .empty, heldModifiers: []).isEmpty)
    }

    func testControlHighlightsOnlyControlRows() {
        let ids = PanelHighlighter.highlightedIDs(items: items, prefix: .empty, heldModifiers: [.control])
        XCTAssertEqual(ids, [items[2].id])
    }

    func testChordLevelHighlightsItsRows() {
        let prefix = KeyChord.combo([.command], KeyToken("k"))
        let ids = PanelHighlighter.highlightedIDs(items: items, prefix: prefix, heldModifiers: [.command])
        XCTAssertEqual(ids, [items[3].id])
    }
}
