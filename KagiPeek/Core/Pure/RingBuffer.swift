import Foundation

/// Fixed-capacity ring buffer, thread-safe for the mix of threads diagnostics sees
/// (MainActor engine, event-tap callback, background scan queue).
///
/// Capacity is small (30 user actions), so the storage is a plain array where the oldest
/// entry is dropped on overflow — obvious to read, and O(n) with n = 30 is not a cost.
final class RingBuffer<T> {
    let capacity: Int
    private var items: [T] = []
    private let lock = NSLock()

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return items.count == capacity
    }

    /// Appends an entry; when full, the oldest entry is silently dropped.
    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        if items.count >= capacity {
            items.removeFirst()
        }
        items.append(item)
    }

    /// All entries, oldest first.
    func snapshot() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }
}
