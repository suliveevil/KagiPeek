import Foundation

/// What one real keypress was seen to do.
///
/// Deliberately free of AppKit: the taps gather this and hand it over, so deciding what it
/// means is a value-in, value-out function that a test can exercise without a keyboard.
struct LiveTestObservation: Equatable, Sendable {
    /// The combo that was actually pressed, which is not always the one being tested.
    var chord: KeyChord
    /// Whether the press reached the far end of the event tap chain.
    var reachedTail: Bool
    /// An app that came to the front right after the press, if one did.
    var activatedAppName: String?
    var activatedBundleID: String?
    /// The app that was already frontmost when the press arrived.
    var frontmostAppName: String?
    var frontmostBundleID: String?
}

/// What a live shortcut test proved, in plain language.
///
/// `LayerVerdict` reasons from config files and guesses. This reasons from a real keypress,
/// so where the two disagree, this is the more trustworthy of the pair. It still has blind
/// spots and names them: once a key gets past the event tap layer, a macOS system shortcut
/// can swallow it without leaving anything an outside observer could ever see. Saying so is
/// the whole point — a confident wrong answer here would be worse than the guess it was
/// meant to replace.
nonisolated enum LiveTestVerdict: Equatable, Sendable {

    /// How much the observation is worth. Drives the tint and the icon.
    enum Tone: Equatable, Sendable {
        /// We watched it happen.
        case confirmed
        /// We learned something real but short of proof.
        case informative
        /// The key vanished somewhere no observer can follow.
        case inconclusive
    }

    /// An event tap consumed the key. Candidates are the tools from the last scan that hook
    /// that layer with this combo, which may be one, several, or none.
    case swallowedByTap(candidates: [String])
    /// An app that claims this combo appears to have received it.
    case reachedApp(itemID: String, ownerName: String, cameToFront: Bool)
    /// An app clearly reacted, but the scan has no record of it claiming this combo.
    case unregisteredApp(name: String)
    /// The key survived every event tap and nothing visible happened afterwards.
    case survivedUnclaimed(ruledOut: [String])
    /// What reached macOS was not the combo under test, so something rewrote it below the OS.
    case rewritten(expected: String, observed: String)
    /// The listen window closed without a single keypress arriving.
    case nothingSeen

    // MARK: - Evaluation

    /// Turns one observation into a verdict, read against what the scan already knew.
    static func evaluate(
        observation: LiveTestObservation?,
        expectedChord: KeyChord,
        items: [BindingItem],
        ownerNameForBundleID: (String) -> String? = { _ in nil }
    ) -> LiveTestVerdict {
        guard let observation else { return .nothingSeen }

        guard observation.chord.cacheKey == expectedChord.cacheKey else {
            return .rewritten(
                expected: KeyFormatter.render(expectedChord, style: .symbols),
                observed: KeyFormatter.render(observation.chord, style: .symbols)
            )
        }

        // The tools that hook the event tap layer with this combo are the only candidates
        // for "who swallowed it", and they are also the ones this result rules out when the
        // key survives.
        let tapTools = uniqueNames(
            items.filter { ShortcutLayer.classify($0) == .eventTap }
                .compactMap { $0.configTool?.displayName }
        )

        if !observation.reachedTail {
            return .swallowedByTap(candidates: tapTools)
        }

        if let activated = observation.activatedBundleID ?? observation.activatedAppName {
            if let match = item(in: items, matchingBundleID: observation.activatedBundleID, name: observation.activatedAppName) {
                return .reachedApp(
                    itemID: match.id,
                    ownerName: ownerName(for: match, ownerNameForBundleID: ownerNameForBundleID),
                    cameToFront: true
                )
            }
            let name = observation.activatedAppName ?? activated
            return .unregisteredApp(name: name)
        }

        // Nothing came to the front. A menu shortcut would not make anything appear, so the
        // app that was already there is the next best candidate.
        if let match = items.first(where: {
            $0.source == .menu && matches($0, bundleID: observation.frontmostBundleID, name: observation.frontmostAppName)
        }) {
            return .reachedApp(
                itemID: match.id,
                ownerName: ownerName(for: match, ownerNameForBundleID: ownerNameForBundleID),
                cameToFront: false
            )
        }
        return .survivedUnclaimed(ruledOut: tapTools)
    }

    // MARK: - Presentation

    var tone: Tone {
        switch self {
        case .swallowedByTap(let candidates):
            return candidates.count == 1 ? .confirmed : .informative
        case .reachedApp(_, _, let cameToFront):
            return cameToFront ? .confirmed : .informative
        case .unregisteredApp, .rewritten:
            return .informative
        case .survivedUnclaimed, .nothingSeen:
            return .inconclusive
        }
    }

    var headlineKey: L10nKey {
        switch self {
        case .swallowedByTap(let candidates):
            return candidates.count == 1 ? .testVerdictSwallowedByTapOne : .testVerdictSwallowedByTap
        case .reachedApp(_, _, let cameToFront):
            return cameToFront ? .testVerdictReachedApp : .testVerdictAlreadyFrontmost
        case .unregisteredApp:
            return .testVerdictUnregisteredApp
        case .survivedUnclaimed:
            return .testVerdictSurvivedUnclaimed
        case .rewritten:
            return .testVerdictRewritten
        case .nothingSeen:
            return .testVerdictNothingSeen
        }
    }

    /// The `%@` argument for `headlineKey`, when it takes one.
    var headlineArgument: String? {
        switch self {
        case .swallowedByTap(let candidates):
            return candidates.count == 1 ? candidates[0] : nil
        case .reachedApp(_, let ownerName, _):
            return ownerName
        case .unregisteredApp(let name):
            return name
        default:
            return nil
        }
    }

    var summaryKey: L10nKey {
        switch self {
        case .swallowedByTap(let candidates):
            switch candidates.count {
            case 0: return .testSummarySwallowedNone
            case 1: return .testSummarySwallowedOne
            default: return .testSummarySwallowedMany
            }
        case .reachedApp(_, _, let cameToFront):
            return cameToFront ? .testSummaryReachedApp : .testSummaryAlreadyFrontmost
        case .unregisteredApp:
            return .testSummaryUnregisteredApp
        case .survivedUnclaimed(let ruledOut):
            return ruledOut.isEmpty ? .testSummarySurvived : .testSummarySurvivedRuledOut
        case .rewritten:
            return .testSummaryRewritten
        case .nothingSeen:
            return .testSummaryNothingSeen
        }
    }

    /// The `%@` argument for `summaryKey`, when it takes one.
    ///
    /// Several names are joined into one string here rather than passed as separate
    /// arguments, so the format string stays the same whether there are two candidates or
    /// six.
    var summaryArgument: String? {
        switch self {
        case .swallowedByTap(let candidates):
            return candidates.isEmpty ? nil : Self.joined(candidates)
        case .reachedApp(_, let ownerName, _):
            return ownerName
        case .unregisteredApp(let name):
            return name
        case .survivedUnclaimed(let ruledOut):
            return ruledOut.isEmpty ? nil : Self.joined(ruledOut)
        case .rewritten(_, let observed):
            return observed
        default:
            return nil
        }
    }

    /// The second argument, used only by the rewritten verdict: `%1$@ observed, %2$@ expected`.
    var summarySecondArgument: String? {
        if case .rewritten(let expected, _) = self { return expected }
        return nil
    }

    /// The binding the observation points at, when it points at exactly one. Stays nil for
    /// every hedged verdict, so a row is only marked when the evidence really is about it.
    var confirmedItemID: String? {
        if case .reachedApp(let itemID, _, _) = self { return itemID }
        return nil
    }

    var toneKey: L10nKey {
        switch tone {
        case .confirmed: return .testToneConfirmed
        case .informative: return .testToneInformative
        case .inconclusive: return .testToneInconclusive
        }
    }

    // MARK: - Helpers

    private static func item(
        in items: [BindingItem],
        matchingBundleID bundleID: String?,
        name: String?
    ) -> BindingItem? {
        // Prefer whichever candidate hooks the keyboard earliest: if an app both registers
        // a global hotkey and has a menu item on the same combo, the global one is what made
        // it appear.
        items
            .filter { matches($0, bundleID: bundleID, name: name) }
            .min { ShortcutLayer.classify($0) < ShortcutLayer.classify($1) }
    }

    /// Bundle ID where both sides have one, name otherwise. Config-file bindings have no
    /// bundle ID, so the name fallback earns its keep.
    private static func matches(_ item: BindingItem, bundleID: String?, name: String?) -> Bool {
        if let bundleID, let itemBundleID = item.appBundleID {
            return bundleID == itemBundleID
        }
        guard let name else { return false }
        if let tool = item.configTool { return tool.displayName == name }
        return false
    }

    private static func ownerName(
        for item: BindingItem,
        ownerNameForBundleID: (String) -> String?
    ) -> String {
        if let tool = item.configTool { return tool.displayName }
        if item.source == .system { return "macOS" }
        if let bundleID = item.appBundleID, let name = ownerNameForBundleID(bundleID) { return name }
        return item.appBundleID ?? item.title
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }
}
