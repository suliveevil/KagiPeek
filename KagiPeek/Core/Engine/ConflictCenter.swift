import Foundation

/// The cross-app conflict scan: what is stored, what a scan produces, and how often the page
/// may be redrawn while the scan fills it in.
///
/// It was a section of `ShortcutEngine` — 150 lines with its own lifecycle (a background AX
/// walk over every running app, throttled publishes, a disk cache, a resumable state machine)
/// that nothing in the panel's input path ever calls. The settings page touches three
/// entry points; the engine keeps those and delegates.
///
/// The findings themselves live in `EngineState` like every other published value: the page
/// binds to them, and this object's job is producing them, not holding them.
@MainActor
final class ConflictCenter {
    private let state: EngineState
    private let catalogLoader: CatalogLoader
    /// How an app is named in the owner picker. Weak on the caller's side: the engine owns
    /// this object, so a strong closure back into it would be a cycle.
    private let ownerName: (String) -> String?
    private var lastPublish = Date.distantPast

    init(
        state: EngineState,
        catalogLoader: CatalogLoader,
        ownerName: @escaping (String) -> String?
    ) {
        self.state = state
        self.catalogLoader = catalogLoader
        self.ownerName = ownerName
    }

    /// Everything that is not part of the frontmost app's own menus but can still claim a
    /// combo: the system's own hotkeys plus whatever the config scanners found.
    private var externalBindings: [BindingItem] {
        state.systemBindings + state.configBindings
    }

    // MARK: - Reading what is stored

    /// Restores the stored scan. One small file, read once at launch — cheap, and it is the
    /// difference between a Conflicts page that opens instantly and one that scans fifteen
    /// apps every time.
    func loadCached() {
        guard state.crossAppConflicts.isEmpty, let payload = ConflictCache.load() else { return }
        state.crossAppConflicts = payload.conflicts
            .map { BindingConflict(id: $0.chordKey, chordKey: $0.chordKey, items: $0.items) }
            .map { $0.scoped(to: $0.appBundleIDs.sorted().first) }
        state.crossAppScannedAt = payload.scannedAt
        state.crossAppScanState = .complete
        state.crossAppFailedAppCount = 0
        resetOwnerFilterIfGone()
    }

    /// The Conflicts page's entry point: show what is stored, and scan only if there is
    /// nothing to show yet.
    func prepare() {
        loadCached()
        guard state.crossAppConflicts.isEmpty, !state.isScanningCrossApp else { return }
        rescan()
    }

    // MARK: - Scanning

    /// Scans every running app's menus. User-initiated, or the first time the page is opened.
    ///
    /// Runs in the background and appends as it goes: the AX walk is already off the main
    /// thread, but grouping a 2 500-item catalog is not, and neither is redrawing a findings
    /// list of several hundred cards. The first is detached, the second is throttled to one
    /// publish a second — the page stays usable while it fills in.
    func rescan() {
        state.crossAppRefreshTask?.cancel()
        let ownBundleID = Bundle.main.bundleIdentifier
        let apps = state.runningApps.filter { $0.bundleID != ownBundleID }
        guard !apps.isEmpty else { return }
        state.isScanningCrossApp = true
        state.crossAppScanState = .scanning
        state.crossAppFailedAppCount = 0
        lastPublish = .distantPast
        state.crossAppRefreshTask = Task { [weak self] in
            guard let self else { return }
            let externals = self.externalBindings
            var builder = CrossAppConflictBuilder()
            var successes = 0
            var failures = 0
            builder.addGlobal(await Self.detectConflicts(in: [], externals: externals))
            for app in apps {
                if Task.isCancelled { return }
                let loaded = await self.catalogItems(for: app)
                if Task.isCancelled { return }
                if loaded.state == .permissionDenied {
                    failures += 1
                } else {
                    successes += 1
                }
                builder.add(await Self.detectConflicts(in: loaded.items, externals: externals), keepingAppsOnly: true)
                self.publishIfDue(builder.sorted())
            }
            let scannedAt = Date()
            let outcome = ConflictScanState.finished(successes: successes, failures: failures)
            self.state.crossAppScanState = outcome
            self.state.crossAppFailedAppCount = failures
            self.state.isScanningCrossApp = false
            switch outcome {
            case .failed:
                self.state.crossAppConflicts = []
                self.state.crossAppScannedAt = nil
            case .complete, .partial:
                self.state.crossAppConflicts = builder.sorted()
                self.state.crossAppScannedAt = scannedAt
                if outcome == .complete {
                    ConflictCache.save(self.state.crossAppConflicts, at: scannedAt)
                }
            case .idle, .scanning:
                break
            }
            self.resetOwnerFilterIfGone()
            let owners = Set(self.state.crossAppConflicts.flatMap(\.appBundleIDs)).count
            Diag.info(.scan, "cross-app scan: \(self.state.crossAppConflicts.count) findings across \(owners) app(s)")
        }
    }

    /// At most one publish a second. Every publish redraws the findings list, and sixteen
    /// redraws of a few hundred cards is exactly the stall this is meant to avoid.
    private func publishIfDue(_ conflicts: [BindingConflict]) {
        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 1 else { return }
        lastPublish = now
        state.crossAppConflicts = conflicts
    }

    /// One path for "the catalog changed, recompute the findings": callers differ only in
    /// where the items came from, and the id set the panel and the conflicts page share must
    /// never drift from the list it was built from.
    func recompute(items: [BindingItem]) {
        state.conflicts = ConflictDetector.conflicts(in: items, external: externalBindings)
        state.conflictIDs = Set(state.conflicts.flatMap { $0.items.map(\.id) })
    }

    /// A filter pointing at an owner that no longer appears would show an empty page with no
    /// explanation; fall back to "all" instead.
    func resetOwnerFilterIfGone() {
        if state.conflictOwner != .all, !ownerOptions.contains(state.conflictOwner) {
            state.conflictOwner = .all
        }
        if let category = state.conflictCategory,
           !state.conflictTypeOptions.contains(where: { $0.category == category }) {
            state.conflictCategory = nil
        }
    }

    /// Owners that actually appear in the current conflicts, for the filter picker.
    ///
    /// Built from the findings rather than from the installed apps: a picker listing every
    /// app on the Mac would be mostly empty answers.
    var ownerOptions: [ConflictOwnerFilter] {
        var apps = Set<String>()
        var hasGlobal = false
        for conflict in state.crossAppConflicts {
            if conflict.isGlobalOnly { hasGlobal = true }
            apps.formUnion(conflict.appBundleIDs)
        }
        var options: [ConflictOwnerFilter] = [.all]
        if hasGlobal { options.append(.global) }
        let sorted = apps.sorted { lhs, rhs in
            let left = ownerName(lhs) ?? lhs
            let right = ownerName(rhs) ?? rhs
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        options.append(contentsOf: sorted.map { ConflictOwnerFilter.app($0) })
        return options
    }

    // MARK: - Off the main thread

    /// Conflict detection over one app's catalog, off the main thread.
    private nonisolated static func detectConflicts(
        in items: [BindingItem],
        externals: [BindingItem]
    ) async -> [BindingConflict] {
        await Task.detached(priority: .utility) {
            ConflictDetector.conflicts(in: items, external: externals)
        }.value
    }

    /// Catalog of one running app, cache first (`force: false`).
    private func catalogItems(for app: AppEntry) async -> (items: [BindingItem], state: ScanState) {
        let snapshot = await catalogLoader.load(
            app: FrontmostApp(pid: app.pid, bundleID: app.bundleID, name: app.name, icon: app.icon),
            language: state.settings.language,
            includeBuiltIn: false,
            showAppleMenu: state.settings.showAppleMenu,
            force: false
        )
        return (snapshot.items, snapshot.state)
    }
}

/// Collects conflicts from several apps, keeping the ids unique and the list ordered.
///
/// A value, not a class: a scan builds one, hands it to the page one publish at a time, and
/// throws it away — the state it must not corrupt is `EngineState.crossAppConflicts`.
private struct CrossAppConflictBuilder {
    private var conflicts: [BindingConflict] = []
    private var seen = Set<String>()

    /// Global findings (no app in them) belong here exactly once.
    mutating func addGlobal(_ items: [BindingConflict]) {
        for conflict in items where conflict.isGlobalOnly {
            insert(conflict.scoped(to: nil))
        }
    }

    /// Per-app findings: the ones where that app's menus take part. Global ones are already
    /// in the list and would otherwise repeat once per app.
    mutating func add(_ items: [BindingConflict], keepingAppsOnly: Bool) {
        for conflict in items {
            if keepingAppsOnly, conflict.isGlobalOnly { continue }
            insert(conflict.scoped(to: conflict.appBundleIDs.sorted().first))
        }
    }

    private mutating func insert(_ conflict: BindingConflict) {
        guard seen.insert(conflict.id).inserted else { return }
        conflicts.append(conflict)
    }

    func sorted() -> [BindingConflict] {
        conflicts.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category > rhs.category }
            if lhs.ownerCount != rhs.ownerCount { return lhs.ownerCount > rhs.ownerCount }
            return lhs.chordKey < rhs.chordKey
        }
    }
}
