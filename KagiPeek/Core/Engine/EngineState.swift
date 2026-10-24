import AppKit
import Combine
import Foundation

/// Everything the engine knows, in one place.
///
/// This is the state half of the P0-2 split: `ShortcutEngine` coordinates collaborators and
/// executes side effects, and this object holds every published value the UI binds plus the
/// session state, caches and gesture machines the coordination reads and writes. It is
/// `@MainActor` because every mutation comes from the engine on the main thread, and it is
/// observable so the SwiftUI surfaces can bind straight to it (`state.panel`,
/// `$state.search.query`, …) instead of through the coordinator.
///
/// `panel` remains a wholesale-replaced immutable snapshot (`PanelState`); nothing here is
/// ever mutated in place across a rebuild.
@MainActor
final class EngineState: ObservableObject {
    // MARK: - Published state (UI binds and reads these)

    @Published var panel = PanelState.hidden
    @Published var settings: AppSettingsSnapshot
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var isListening = false
    @Published var hasAccessibility = false
    @Published var hasInputMonitoring = false
    @Published var isPaused = false
    @Published var conflicts: [BindingConflict] = []
    /// Conflicts across every running app, with ids scoped to their owner. Only the
    /// Conflicts page reads this; the panel keeps using `conflicts`.
    @Published var crossAppConflicts: [BindingConflict] = []
    /// When the list above was produced, or nil when it has never been scanned.
    @Published var crossAppScannedAt: Date?
    @Published var isScanningCrossApp = false
    @Published var catalogSize = 0
    @Published var scanDuration: TimeInterval = 0
    /// Why the last catalog read produced what it did. An empty panel and a read that
    /// never happened look the same, so the surfaces can say which one it was.
    @Published var scanState: ScanState = .ok
    @Published var usedBuiltInCatalog = false
    @Published var statusMessage: String?
    @Published var isFrontAppExcluded = false
    @Published var recordingTarget: HotkeyTarget?
    /// Bumped on every search open/close so the palette's text field can re-request focus.
    @Published var searchFocusToken = 0
    @Published var systemBindings: [BindingItem] = []
    @Published var configBindings: [BindingItem] = []
    @Published var configScan = ConfigScanResult()
    @Published var conflictCategory: ConflictCategory?
    @Published var conflictOwner: ConflictOwnerFilter = .all
    /// Which app the search palette looks at, or nil for the frontmost one.
    ///
    /// Looking at another app is the palette's job now: it is where
    /// people actually type, so the scope lives here now.
    /// The scope's identity and items live in `search` (pure state); the icon is AppKit
    /// and has to stay engine-side.
    @Published var searchScopeIcon: NSImage?
    @Published var liveTestState: ShortcutTester.State = .idle
    @Published var runningApps: [AppEntry] = []

    /// The palette's whole state as one snapshot (see `SearchSnapshot`). Only the query
    /// drives a re-search; the engine writes results/selection/visibility itself, and a
    /// re-search from those writes would loop. The re-search side effect is the engine's
    /// (it owns the catalog), so it is injected through `searchChangeHandler`.
    @Published var search = SearchSnapshot() {
        didSet {
            if oldValue.query != search.query { searchChangeHandler?(search) }
        }
    }
    @Published var showsFavoritesOnly = false

    // MARK: - Session state (coordination reads and writes these)

    /// The panel session phase, shared with `KeyEventRouter` through the pure `EnginePhase`.
    var phase: EnginePhase = .idle
    /// What the user has composed so far: modifier-only prefixes from a hold, then strokes.
    var prefix: KeyChord = .empty
    /// The physically held modifiers plus the ones ticked in the title bar. Derived from
    /// `panel`, never stored — a third copy would be one more thing to keep in step.
    var pending: PendingModifiers {
        PendingModifiers(held: panel.heldModifiers, latched: panel.latchedModifiers)
    }
    /// The modifier set that was down on the previous `flagsChanged`, for edge detection.
    var previousModifiers: ModifierSet = []
    /// The "press ⌘ twice to pin" gesture, as a pure state machine (see `CommandDoubleTap`).
    var doubleTapCommand = CommandDoubleTap()
    /// Karabiner-style hyper (⌃⌥⇧⌘) used as a single "Escape" key, as a pure state machine
    /// (see `HyperEscape`).
    var hyperEscape = HyperEscape()
    /// Press-and-release of a modifier, remembered so it can become a sticky tick: ⌥ ⌘ C
    /// instead of holding ⌥⌘ and pressing C. See `ModifierTapTracker`.
    var modifierTap = ModifierTapTracker()
    /// Throttle for the secure-input line: the check runs on every modifier press, and one
    /// line every few seconds is enough to explain a session in which nothing worked.
    var lastSecureInputLog: Date?

    // MARK: - Catalog and caches

    /// The frontmost app's menu scan (or the preview snapshot), including system bindings.
    var catalog = CatalogSnapshot.empty
    /// Monotonic scan counter: only the newest request may publish its result.
    var catalogGeneration = 0
    /// Everything that feeds the row order. While it is unchanged, a rebuild can reuse the
    /// previous ordering, so a modifier press that does not move anything stays cheap.
    var orderedHitsCache: (key: OrderedHitsKey, hits: [PrefixHit])?
    /// The budget the panel window is sized for, cached on its own key.
    var rowBudgetCache: (key: RowBudgetKey, rows: Int, headings: Int)?
    /// Per-app usage breakdowns, invalidated by a usage-signature change.
    var usageBreakdownCache: [String: (signature: String, entries: [UsageEntry])] = [:]
    /// Which scanned items are ignored right now (deduplicated by id), so both the panel
    /// and the conflicts page agree about what to hide.
    var conflictIDs: Set<String> = []

    // MARK: - Search scope

    /// The scoped app's full catalog, so a scope switch is one read and the palette can
    /// answer while a rescan of the panel's own app is pending. Loaded the first time the
    /// scope is chosen, then reused. This is the engine's cache: the built-in catalog also
    /// comes through here, because the palette and the panel must agree on the same data
    /// source — the palette cannot answer questions the panel would answer differently.
    var searchScopeCatalog = CatalogSnapshot.empty
    /// The scoped app's process, so a click can bring it forward before the chord lands.
    var searchScopeProcessID: pid_t?
    /// What `searchCorpus` was built from. Rebuilt when the scope, the scan or the style
    /// changes; nil means "nothing built yet".
    var searchCorpusKey: String?
    /// The search index for the current scope, or nil while nothing has been searched yet.
    var searchCorpus: SearchCorpus?

    // MARK: - In-flight tasks

    var armedTask: Task<Void, Never>?
    /// Keeps the completed-row highlight visible for a beat after a shortcut runs; cancelled
    /// on dismissal so it cannot outlive the panel.
    var completionTask: Task<Void, Never>?
    var crossAppRefreshTask: Task<Void, Never>?
    var configScanTask: Task<Void, Never>?
    var liveTestPollingTask: Task<Void, Never>?
    var isTestingShortcut = false

    // MARK: - Derived state (computed for the UI)

    /// Title and icon the palette shows: the scoped app when one is chosen, otherwise the app
    /// that is in front. "Search Shortcuts" was a label where the answer belonged.
    /// `defaultTitle` is set by the engine (the localised app name) so this computed value
    /// stays free of collaborators.
    var defaultTitle = "KagiPeek"

    var searchPaletteTitle: String {
        if !search.scopeName.isEmpty { return search.scopeName }
        if !appName.isEmpty { return appName }
        return defaultTitle
    }

    var searchPaletteIcon: NSImage? {
        searchScopeIcon ?? appIcon
    }

    /// Conflicts the list currently shows, after both filters: kind and owner.
    ///
    /// The list is cross-app: `conflicts` is the frontmost app's own set and stays what the
    /// panel and the row badges use, while the Conflicts page answers "which app is this
    /// about" — a question you ask precisely when you are not in that app.
    var visibleConflicts: [BindingConflict] {
        let filter = ConflictFilter(category: conflictCategory, owner: conflictOwner)
        return crossAppConflicts.filter { filter.matches($0) }
    }

    /// Kinds that actually appear in the current findings, worst first, with counts.
    ///
    /// Built from the findings rather than from every possible kind: a menu listing all
    /// seven would be mostly empty answers.
    var conflictTypeOptions: [ConflictTypeOption] {
        var counts: [ConflictCategory: Int] = [:]
        for conflict in crossAppConflicts {
            counts[conflict.category, default: 0] += 1
        }
        return counts
            .map { ConflictTypeOption(category: $0.key, count: $0.value) }
            .sorted { $0.category > $1.category }
    }

    /// Installed by `ShortcutEngine` so a query change can re-run the search; nil in
    /// isolation, where the snapshot is a plain value.
    var searchChangeHandler: ((SearchSnapshot) -> Void)?

    init() {
        settings = AppSettingsSnapshot()
    }
}

/// Everything that feeds the row order. While it is unchanged, a rebuild can reuse the
/// previous ordering, so a modifier press that does not move anything stays cheap.
/// A signature, not a count: editing a rule without changing how many exist must
/// still invalidate the cached order.
struct OrderedHitsKey: Equatable {
    var prefix: KeyChord
    var heldModifiers: ModifierSet
    /// Also invalidates the cached order: a tick changes which rows are emphasised and
    /// which are reachable, so a cached order computed without it would be stale.
    var latchedModifiers: ModifierSet
    var scannedAt: Date
    /// The favorites rules as one value, so any of the three booleans changing (the
    /// star toggle or either settings) invalidates the cached order together.
    var favorites: FavoritesPolicy
    var includeDisabled: Bool
    var ignoredSignature: String
}

/// Everything that changes the session's row budget (the size the panel is sized for).
struct RowBudgetKey: Equatable {
    var scannedAt: Date
    var showsFavoritesOnly: Bool
    var includeDisabled: Bool
    var ignoredSignature: String
    var systemCount: Int
    var pageSize: Int
}
