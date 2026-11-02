import AppKit
import ApplicationServices
import os

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
/// `nonisolated` because this type *is* a serial queue: every read and write of `cache`
/// happens inside `queue.async`, and that is its isolation. Under the app target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` it would otherwise become main-actor state
/// mutated from a background queue — which is what the strict-concurrency warnings were
/// saying, and they were right.
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

    private let queue = DispatchQueue(label: "com.voltline.kagipeek.catalog", qos: .userInitiated)
    private let cacheLock = NSLock()
    private var cache: [CacheKey: CatalogSnapshot] = [:]
    private let timeToLive: TimeInterval = 20
    private let hasAccessibility: @Sendable () -> Bool

    init(hasAccessibility: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.hasAccessibility = hasAccessibility
    }

    /// Drops the in-memory snapshots. Called when apps launch or terminate: a conservative
    /// refresh of the app in front, without touching the disk cache — one app starting up
    /// says nothing about the menus of the app the user is working in.
    func invalidateMemory() {
        queue.async { [self] in
            cacheLock.lock()
            cache.removeAll()
            cacheLock.unlock()
        }
    }

    /// Drops everything, memory and disk. For the cases where the fingerprints cannot be
    /// trusted to catch the change on their own — a settings reset, say.
    func invalidateAll() {
        queue.async { [self] in
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
    /// the main thread up to the point where it hands the work to `queue`. The scan itself is
    /// serialised on `queue`; the attribute is what stops a future change to the body from
    /// quietly doing main-thread work.
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
            Diag.error(.scan, "refusing to scan KagiPeek's own process")
            return .empty
        }

        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: scan(
                    identity: identity,
                    pid: pid,
                    bundleID: bundleID,
                    language: language,
                    includeBuiltIn: includeBuiltIn,
                    showAppleMenu: showAppleMenu,
                    force: force
                ))
            }
        }
    }

    /// The body of `load`, on the queue. Split out so the cache reads and writes are all in
    /// one function with one isolation.
    private func scan(
        identity: String,
        pid: pid_t,
        bundleID: String?,
        language: AppLanguage,
        includeBuiltIn: Bool,
        showAppleMenu: Bool,
        force: Bool
    ) -> CatalogSnapshot {
        let fingerprint = MenuCachePolicy.fingerprint(showAppleMenu: showAppleMenu)
        let cacheKey = CacheKey(
            identity: identity,
            pid: pid,
            includeBuiltIn: includeBuiltIn,
            language: L10n.resolvedLanguage(language).rawValue,
            showAppleMenu: showAppleMenu
        )
        // A cached menu is only a shortcut around reading menus. Without Accessibility
        // there is no grant to read under, so the cache must not bypass the degraded path.
        let mayUseCache = hasAccessibility()
        if !force, mayUseCache,
           let cached = cachedSnapshot(for: cacheKey),
           Date().timeIntervalSince(cached.scannedAt) < timeToLive {
            return cached
        }

        // A scan is the expensive path — a hundred milliseconds and up for a big app. Before
        // paying it, ask the disk cache: the same rows, restored in milliseconds, as long as
        // the control file and the entry itself agree they are still current (see
        // MenuCachePolicy).
        if !force, mayUseCache {
            let restoreStarted = Date()
            switch MenuScanCache.load(identity: identity, fingerprint: fingerprint) {
            case .success(let entry):
                var snapshot = CatalogSnapshot()
                snapshot.items = entry.items
                snapshot.hasMenuBar = true
                snapshot.scannedAt = entry.scannedAt
                snapshot.readDuration = Date().timeIntervalSince(restoreStarted)
                snapshot.appIdentity = identity
                snapshot.appPID = pid
                snapshot.state = .ok
                store(snapshot, for: cacheKey)
                Diag.debug(.scan, "restored \(identity) from the menu cache")
                return snapshot
            case .failure(let miss):
                // A cache that always misses makes every panel slow for no visible reason;
                // the reason is now in the log.
                Diag.debug(.scan, "cache-miss identity=\(identity) reason=\(miss.rawValue)")
            }
        }

        let started = Date()
        let scanned = MenuScanner.scan(pid: pid, bundleID: bundleID, showAppleMenu: showAppleMenu)
        var snapshot = CatalogSnapshot()
        snapshot.elements = scanned.elements
        snapshot.hasMenuBar = scanned.hasMenuBar
        snapshot.scannedAt = Date()
        snapshot.readDuration = Date().timeIntervalSince(started)
        snapshot.appIdentity = identity
        snapshot.appPID = pid
        snapshot.state = scanned.state

        let menuUsable = scanned.hasMenuBar && !scanned.items.isEmpty
        if menuUsable {
            snapshot.items = scanned.items
            // Only a real scan of a real menu bar is worth persisting: the built-in fallback
            // depends on the language and is cheap to rebuild.
            MenuScanCache.save(identity: identity, fingerprint: fingerprint, items: scanned.items)
        } else if includeBuiltIn {
            snapshot.items = BuiltInCatalog
                .items(language: L10n.resolvedLanguage(language))
                .filter { $0.appBundleID == nil || $0.appBundleID == bundleID }
            snapshot.usedBuiltInCatalog = true
        } else {
            snapshot.items = []
        }

        store(snapshot, for: cacheKey)
        return snapshot
    }

    // MARK: - Cache

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
