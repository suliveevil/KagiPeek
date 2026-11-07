import AppKit
import ApplicationServices
import os

/// A live Accessibility element produced off the main actor and used there to press.
///
/// `AXUIElement` is not `Sendable`, but its handle is thread-safe (the same assumption
/// `CatalogSnapshot` already documents); the wrapper only makes the compiler state that.
nonisolated struct ResolvedAXElement: @unchecked Sendable {
    let element: AXUIElement
}

nonisolated struct CatalogSnapshot {
    var items: [BindingItem] = []
    var elements: [String: AXUIElement] = [:]
    var hasMenuBar = false
    /// When the data was produced (a scan) or restored (the disk cache).
    var scannedAt = Date.distantPast
    /// How long producing or restoring it took — what the diagnostics report as
    /// "scanDuration". A cache restore is milliseconds, not a walk of the menu bar.
    var readDuration: TimeInterval = 0
    var appIdentity = ""
    /// The process the rows belong to. A snapshot restored from the disk cache carries no
    /// elements, so pressing a row re-walks its menu path against this pid.
    var appPID: pid_t?
    /// Why the scan produced what it did — an empty list and a read that never happened
    /// look identical to the user.
    var state: ScanState = .noMenus
    var usedBuiltInCatalog = false

    static let empty = CatalogSnapshot()

    var isStale: Bool { Date().timeIntervalSince(scannedAt) > 20 }
}

/// The snapshot crosses an actor boundary: it is produced on the scan queue and read on the
/// main actor, and nothing mutates it after delivery. `AXUIElement` is a Core Foundation
/// handle — retain/release and attribute reads are thread-safe — so carrying the dictionary
/// across is safe, which is what the unchecked conformance states.
extension CatalogSnapshot: @unchecked Sendable {}

/// Scans the frontmost app off the main thread, merges the built-in fallback catalog when
/// the app exposes no usable menu bar, and caches the result per app: in memory for the
/// length of a sitting, on disk across launches.
///
/// `nonisolated` because the state this type owns is only touched on its own queues: `cache`
/// behind `cacheLock`, scans on `scanQueue`, invalidation as a barrier on the same queue.
/// Under the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` it would otherwise
/// become main-actor state mutated from a background queue — which is what the
/// strict-concurrency warnings were saying, and they were right.
nonisolated final class CatalogLoader: @unchecked Sendable {
    // Nonisolated so the off-main scan path can build and look up keys; the key is plain
    // value data and its Hashable conformance must not inherit the enclosing isolation.
    private nonisolated struct CacheKey: Hashable {
        let identity: String
        /// A relaunched app keeps its bundle id but gets new AX elements and a new pid.
        let pid: pid_t
        let includeBuiltIn: Bool
        let language: String
        let showAppleMenu: Bool
    }

    /// One scan request, carried as a value so the cancelled and timed-out paths can answer
    /// from the cache without re-deriving the keys or the language.
    private nonisolated struct Request: Sendable {
        let identity: String
        let pid: pid_t
        let bundleID: String?
        let language: AppLanguage
        let includeBuiltIn: Bool
        let showAppleMenu: Bool
        let force: Bool
        let cacheKey: CacheKey
    }

    /// Scans are concurrent, capped at two in flight: a slow scan for the previous app may
    /// still be running when the next app is asked for, and serialising them would make the
    /// second request wait for the first. More than two would let a burst of frontmost
    /// changes start a scan per app.
    private let scanQueue = DispatchQueue(
        label: "com.suliveevil.kaname.catalog.scan",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let scanSlots = DispatchSemaphore(value: 2)
    /// Element lookups are short but can block on a busy app's AX server, so they get their
    /// own queue: waiting behind a menu scan here would put the wait back on the click path.
    private let elementQueue = DispatchQueue(
        label: "com.suliveevil.kaname.catalog.element",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let cacheLock = NSLock()
    private var cache: [CacheKey: CatalogSnapshot] = [:]
    private let timeToLive: TimeInterval = 20
    /// The newest request owns the result; anything older is answered from the cache instead
    /// of paying for a scan nobody is waiting for.
    private let requestGate = ScanRequestGate()
    /// A single scan gets this long before the caller is answered from the cache or the
    /// built-in catalog. The scan keeps running and drops its result.
    private let scanDeadline: TimeInterval = 1.5
    private let hasAccessibility: @Sendable () -> Bool

    init(hasAccessibility: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.hasAccessibility = hasAccessibility
    }

    /// Drops the in-memory snapshots. Called when apps launch or terminate: a conservative
    /// refresh of the app in front, without touching the disk cache — one app starting up
    /// says nothing about the menus of the app the user is working in.
    func invalidateMemory() {
        // A barrier waits for the scans already running, then runs alone: clearing the cache
        // in the middle of a scan would let that scan write its result back right after.
        scanQueue.async(flags: .barrier) { [self] in
            cacheLock.lock()
            cache.removeAll()
            cacheLock.unlock()
        }
    }

    /// Drops everything, memory and disk. For the cases where the fingerprints cannot be
    /// trusted to catch the change on their own — a settings reset, say.
    func invalidateAll() {
        scanQueue.async(flags: .barrier) { [self] in
            cacheLock.lock()
            cache.removeAll()
            cacheLock.unlock()
            MenuScanCache.invalidateAll()
        }
    }

    /// Reads the app's menus, cache first, and returns the snapshot.
    ///
    /// `@concurrent` keeps the body on the global executor: with
    /// `NonisolatedNonsendingByDefault` (the target's `SWIFT_APPROACHABLE_CONCURRENCY`) a
    /// plain `nonisolated async` function inherits the caller's actor, so this would run on
    /// the main thread up to the point where it hands the work to `scanQueue`. Scans run there
    /// at most two at a time, and a scan that has not answered within `scanDeadline` is
    /// answered from the cache or the built-in catalog instead — the UI never waits on a busy
    /// app's Accessibility server. The attribute is what stops a future change to the body
    /// from quietly doing main-thread work.
    ///
    /// This was a `@MainActor` completion closure hopping back through
    /// `DispatchQueue.main.async` + `assumeIsolated`. Async returning a `Sendable` snapshot is
    /// the same guarantee with neither the closure nor the assertion.
    @concurrent
    func load(
        app: FrontmostApp,
        language: AppLanguage,
        includeBuiltIn: Bool,
        showAppleMenu: Bool,
        force: Bool
    ) async -> CatalogSnapshot {
        let identity = app.identity
        let pid = app.pid
        let bundleID = app.bundleID

        // Defensive: the context service never reports the app itself, and a scan of our own
        // process would only produce an empty menu bar.
        guard !app.isSelf else {
            Diag.error(.scan, "refusing to scan Kaname's own process")
            return .empty
        }

        let cacheKey = CacheKey(
            identity: identity,
            pid: pid,
            includeBuiltIn: includeBuiltIn,
            language: L10n.resolvedLanguage(language).rawValue,
            showAppleMenu: showAppleMenu
        )
        let request = Request(
            identity: identity,
            pid: pid,
            bundleID: bundleID,
            language: language,
            includeBuiltIn: includeBuiltIn,
            showAppleMenu: showAppleMenu,
            force: force,
            cacheKey: cacheKey
        )
        // Claim the newest token before anything else: an older scan still in flight is now
        // known to be obsolete, and will drop its result rather than publish it.
        let token = requestGate.begin()

        let deadlineAt = Date().addingTimeInterval(scanDeadline)
        return await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            scanQueue.async { [self] in
                // Ask whether this request is still wanted before occupying one of the two
                // slots: a superseded or late request must not make the relevant one wait.
                guard ScanAdmission.decide(
                    isCurrent: requestGate.isCurrent(token),
                    now: Date(),
                    deadline: deadlineAt
                ) == .scan else {
                    Diag.debug(.scan, "dropping superseded scan for \(identity) before it took a slot")
                    reply.resume(fallbackSnapshot(for: request))
                    return
                }
                // Bounded wait: without it, two stuck scans would leave this block parked on
                // the semaphore while the caller's 1.5 s deadline answers the UI. The scan
                // keeps no slot and the continuation is always resumed exactly once.
                guard scanSlots.wait(timeout: .now() + ScanAdmission.slotWaitTimeout) == .success else {
                    Diag.warning(.scan, "scan slot unavailable after \(ScanAdmission.slotWaitTimeout)s for \(identity)")
                    reply.resume(fallbackSnapshot(for: request))
                    return
                }
                defer { scanSlots.signal() }
                guard ScanAdmission.decide(
                    isCurrent: requestGate.isCurrent(token),
                    now: Date(),
                    deadline: deadlineAt
                ) == .scan else {
                    Diag.debug(.scan, "dropping superseded scan for \(identity) after taking a slot")
                    reply.resume(fallbackSnapshot(for: request))
                    return
                }
                let snapshot = scan(request)
                guard requestGate.isCurrent(token) else {
                    Diag.debug(.scan, "dropping superseded scan result for \(identity)")
                    reply.resume(fallbackSnapshot(for: request))
                    return
                }
                reply.resume(snapshot)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + scanDeadline) { [self] in
                // Whoever gets here second is ignored: a scan that finished first has already
                // been delivered, and one that finishes later must not overwrite the answer.
                reply.resume(fallbackSnapshot(for: request))
            }
        }
    }

    /// Convenience for callers that already hold a `CatalogQuery`: expand it into the
    /// original argument list. The scan itself — the two queues, the slot semaphore, the
    /// request gate and the cache — is deliberately left untouched.
    @concurrent
    func load(app: FrontmostApp, query: CatalogQuery) async -> CatalogSnapshot {
        await load(
            app: app,
            language: query.language,
            includeBuiltIn: query.includeBuiltIn,
            showAppleMenu: query.showAppleMenu,
            force: query.force
        )
    }

    /// Re-walks a restored row's menu path and verifies its title on the element queue.
    ///
    /// The caller resumes on the main actor only to press; resolution itself never touches
    /// it. The element crosses back as `ResolvedAXElement` because `AXUIElement` is a
    /// Core Foundation handle without a `Sendable` conformance; see the note on
    /// `CatalogSnapshot`.
    @concurrent
    func resolveElement(atAxPath axPath: String, pid: pid_t, expectingTitle title: String) async -> ResolvedAXElement? {
        await withCheckedContinuation { continuation in
            elementQueue.async {
                let element = MenuScanner.element(atAxPath: axPath, pid: pid, expectingTitle: title)
                continuation.resume(returning: element.map(ResolvedAXElement.init))
            }
        }
    }

    /// The body of `load`, on the queue. Split out so the cache reads and writes are all in
    /// one function with one isolation.
    private func scan(_ request: Request) -> CatalogSnapshot {
        let fingerprint = MenuCachePolicy.fingerprint(showAppleMenu: request.showAppleMenu)
        let cacheKey = request.cacheKey
        // A cached menu is only a shortcut around reading menus. Without Accessibility
        // there is no grant to read under, so the cache must not bypass the degraded path.
        let mayUseCache = hasAccessibility()
        if !request.force, mayUseCache,
           let cached = cachedSnapshot(for: cacheKey),
           Date().timeIntervalSince(cached.scannedAt) < timeToLive {
            return cached
        }

        // A scan is the expensive path — a hundred milliseconds and up for a big app. Before
        // paying it, ask the disk cache: the same rows, restored in milliseconds, as long as
        // the control file and the entry itself agree they are still current (see
        // MenuCachePolicy).
        if !request.force, mayUseCache {
            let restoreStarted = Date()
            switch MenuScanCache.load(identity: request.identity, fingerprint: fingerprint) {
            case .success(let entry):
                var snapshot = CatalogSnapshot()
                snapshot.items = entry.items
                snapshot.hasMenuBar = true
                snapshot.scannedAt = entry.scannedAt
                snapshot.readDuration = Date().timeIntervalSince(restoreStarted)
                snapshot.appIdentity = request.identity
                snapshot.appPID = request.pid
                snapshot.state = .ok
                store(snapshot, for: cacheKey)
                Diag.debug(.scan, "restored \(request.identity) from the menu cache")
                return snapshot
            case .failure(let miss):
                // A cache that always misses makes every panel slow for no visible reason;
                // the reason is now in the log.
                Diag.debug(.scan, "cache-miss identity=\(request.identity) reason=\(miss.rawValue)")
            }
        }

        let started = Date()
        let scanned = MenuScanner.scan(
            pid: request.pid,
            bundleID: request.bundleID,
            showAppleMenu: request.showAppleMenu
        )
        var snapshot = CatalogSnapshot()
        snapshot.elements = scanned.elements
        snapshot.hasMenuBar = scanned.hasMenuBar
        snapshot.scannedAt = Date()
        snapshot.readDuration = Date().timeIntervalSince(started)
        snapshot.appIdentity = request.identity
        snapshot.appPID = request.pid
        snapshot.state = scanned.state

        let menuUsable = scanned.hasMenuBar && !scanned.items.isEmpty
        if menuUsable {
            snapshot.items = scanned.items
            // Only a real scan of a real menu bar is worth persisting: the built-in fallback
            // depends on the language and is cheap to rebuild.
            MenuScanCache.save(identity: request.identity, fingerprint: fingerprint, items: scanned.items)
        } else if scanned.state == .menuBarUnavailable,
                  let standIn = MenuScanCache.loadStandIn(
                      identity: request.identity,
                      fingerprint: fingerprint
                  ) {
            // The bar is hidden (a full-screen app, the auto-hide setting, Mission Control) or
            // the app did not answer. Its commands still exist; the last scan stands in for a
            // tree that cannot be read, so the panel keeps the app's own rows instead of
            // dropping to the built-in catalog for the whole session. These rows carry no
            // elements — a press walks its path, fails while the bar is hidden, and the chord
            // replay is what runs the command.
            snapshot.items = standIn.items
            snapshot.usedBuiltInCatalog = false
            Diag.warning(.scan, """
                menu bar unreadable: standing in a scan from \
                \(Int(Date().timeIntervalSince(standIn.scannedAt)))s ago for \(request.identity) \
                (\(standIn.items.count) rows)
                """)
        } else if request.includeBuiltIn {
            snapshot.items = builtInItems(for: request)
            snapshot.usedBuiltInCatalog = true
        } else {
            snapshot.items = []
        }

        store(snapshot, for: cacheKey)
        return snapshot
    }

    // MARK: - Cache

    /// What the caller gets when the scan is superseded or runs past `scanDeadline`: the
    /// same rows the cache would have served, or the built-in catalog when there is none.
    ///
    /// Running this off the main actor matters: a timeout on the click path must not turn
    /// into a disk read on the thread that draws the panel.
    private func fallbackSnapshot(for request: Request) -> CatalogSnapshot {
        if let cached = cachedSnapshot(for: request.cacheKey) {
            return cached
        }
        switch MenuScanCache.load(
            identity: request.identity,
            fingerprint: MenuCachePolicy.fingerprint(showAppleMenu: request.showAppleMenu)
        ) {
        case .success(let entry):
            var snapshot = CatalogSnapshot()
            snapshot.items = entry.items
            snapshot.hasMenuBar = true
            snapshot.scannedAt = entry.scannedAt
            snapshot.appIdentity = request.identity
            snapshot.appPID = request.pid
            snapshot.state = .ok
            return snapshot
        case .failure:
            break
        }
        var snapshot = CatalogSnapshot()
        snapshot.appIdentity = request.identity
        snapshot.appPID = request.pid
        snapshot.scannedAt = Date()
        if request.includeBuiltIn {
            snapshot.items = builtInItems(for: request)
            snapshot.usedBuiltInCatalog = true
        }
        return snapshot
    }

    private func builtInItems(for request: Request) -> [BindingItem] {
        BuiltInCatalog
            .items(language: L10n.resolvedLanguage(request.language))
            .filter { $0.appBundleID == nil || $0.appBundleID == request.bundleID }
    }

    /// Resumes the continuation at most once. A scan that finishes after the deadline must not
    /// publish its result, and a deadline that fires after a real answer must not overwrite it.
    private nonisolated final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CatalogSnapshot, Never>?

        init(_ continuation: CheckedContinuation<CatalogSnapshot, Never>) {
            self.continuation = continuation
        }

        func resume(_ snapshot: CatalogSnapshot) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: snapshot)
        }
    }

    private func cachedSnapshot(for key: CacheKey) -> CatalogSnapshot? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func store(_ snapshot: CatalogSnapshot, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = snapshot
        guard cache.count > 24 else { return }
        let oldest = cache.sorted { $0.value.scannedAt < $1.value.scannedAt }
        for entry in oldest.prefix(cache.count - 24) {
            cache.removeValue(forKey: entry.key)
        }
    }
}
