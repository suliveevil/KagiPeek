import AppKit
import ApplicationServices
import os

struct CatalogSnapshot {
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

/// Scans the frontmost app off the main thread, merges the built-in fallback catalog when
/// the app exposes no usable menu bar, and caches the result per app: in memory for the
/// length of a sitting, on disk across launches.
final class CatalogLoader {
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
    private var cache: [CacheKey: CatalogSnapshot] = [:]
    private let timeToLive: TimeInterval = 20
    private let hasAccessibility: () -> Bool

    init(hasAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.hasAccessibility = hasAccessibility
    }

    /// Drops the in-memory snapshots. Called when apps launch or terminate: a conservative
    /// refresh of the app in front, without touching the disk cache — one app starting up
    /// says nothing about the menus of the app the user is working in.
    func invalidateMemory() {
        queue.async { self.cache.removeAll() }
    }

    /// Drops everything, memory and disk. For the cases where the fingerprints cannot be
    /// trusted to catch the change on their own — a settings reset, say.
    func invalidateAll() {
        queue.async {
            self.cache.removeAll()
            MenuScanCache.invalidateAll()
        }
    }

    func load(
        app: FrontmostApp,
        language: AppLanguage,
        includeBuiltIn: Bool,
        showAppleMenu: Bool,
        force: Bool,
        completion: @escaping @MainActor (CatalogSnapshot) -> Void
    ) {
        let identity = app.identity
        let pid = app.pid
        let bundleID = app.bundleID

        // Defensive: the context service never reports the app itself, and a scan of our own
        // process would only produce an empty menu bar.
        guard !app.isSelf else {
            AppLog.scan.error("refusing to scan KagiPeek's own process")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(.empty) }
            }
            return
        }

        queue.async {
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
            let mayUseCache = self.hasAccessibility()
            if !force, mayUseCache,
               let cached = self.cache[cacheKey],
               Date().timeIntervalSince(cached.scannedAt) < self.timeToLive {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(cached) }
                }
                return
            }

            // A scan is the expensive path — a hundred milliseconds and up for a big app.
            // Before paying it, ask the disk cache: the same rows, restored in
            // milliseconds, as long as the control file and the entry itself agree they
            // are still current (see MenuCachePolicy).
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
                    self.cache[cacheKey] = snapshot
                    AppLog.scan.debug("restored \(identity, privacy: .public) from the menu cache")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { completion(snapshot) }
                    }
                    return
                case .failure(let miss):
                    // A cache that always misses makes every panel slow for no visible
                    // reason; the reason is now in the log.
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
                // Only a real scan of a real menu bar is worth persisting: the built-in
                // fallback depends on the language and is cheap to rebuild.
                MenuScanCache.save(identity: identity, fingerprint: fingerprint, items: scanned.items)
            } else if includeBuiltIn {
                snapshot.items = BuiltInCatalog
                    .items(language: L10n.resolvedLanguage(language))
                    .filter { $0.appBundleID == nil || $0.appBundleID == bundleID }
                snapshot.usedBuiltInCatalog = true
            } else {
                snapshot.items = []
            }

            self.cache[cacheKey] = snapshot
            if self.cache.count > 24 {
                let oldest = self.cache.sorted { $0.value.scannedAt < $1.value.scannedAt }
                for entry in oldest.prefix(self.cache.count - 24) {
                    self.cache.removeValue(forKey: entry.key)
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(snapshot) }
            }
        }
    }
}
