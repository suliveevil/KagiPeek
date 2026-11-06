import AppKit

/// A bundle of `NSWorkspace` subscriptions that always tears itself down.
///
/// `AppDirectory` and `AppContextService` each kept their own `[NSObjectProtocol]` plus the
/// same three-part dance: register on the main queue, step back inside the main actor
/// because the block is `@Sendable` and the work is not, then remove every token on stop.
/// The only part that differs between the two is the handler. The bookkeeping is not
/// interesting enough to own twice — and a third copy is how a `removeAll()` gets lost.
@MainActor
final class WorkspaceObservation {
    private var observers: [NSObjectProtocol] = []

    /// True once at least one notification is registered. `start()` guards on it, so a
    /// service cannot subscribe twice by being started twice.
    var isRunning: Bool { !observers.isEmpty }

    func observe(_ names: [NSNotification.Name], handler: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in names {
            // The block must be `@Sendable`; the handler is main-actor isolated, which is
            // what makes the hop back sound — `queue: .main` already delivers it there.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
    }

    func observe(_ name: NSNotification.Name, handler: @escaping @MainActor () -> Void) {
        observe([name], handler: handler)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }
}
