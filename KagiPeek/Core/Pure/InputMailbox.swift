import Foundation

/// The bounded buffer between the tap thread and the engine.
///
/// The tap answers the system synchronously on its own thread — that is what keeps the
/// keyboard alive when the main thread wedges (`dbafe89`). The engine, however, still lives on
/// the main actor, so every event has to be handed over. Handing over with one
/// `DispatchQueue.main.async` per event made that hand-over an **unbounded** queue: a main
/// thread stuck for thirty seconds accumulated an unbounded backlog and then replayed all of
/// it at once, opening and closing the panel dozens of times for keystrokes the user typed
/// while nothing was on screen.
///
/// Two properties make the bound safe here, and both come from where this buffer sits:
///
/// - **It only carries the panel's copy.** The event itself was already returned to the
///   system on the tap thread, unchanged or swallowed, before anything was queued. Dropping
///   the copy cannot leave a key stuck in another app.
/// - **Order inside a batch is preserved.** The drain hands the engine a contiguous run of
///   events in the order they arrived, so chord composition still sees a sequence, not a set.
///
/// What a drop can leave behind is the *panel's* idea of the world: a modifier it thinks is
/// held, a selection mid-move. `owesReset` is that debt, paid with one `.interruption` at the
/// end of the next batch — the same event the engine already receives when the system
/// disables the tap, which releases whatever it was holding.
nonisolated struct InputMailbox {
    /// How many events may wait for the main thread. Sized in keystrokes, not seconds: 32 is
    /// several seconds of fast typing, and far more than the panel needs to stay coherent.
    static let capacity = 32

    private(set) var queue: [KeyEvent] = []
    /// Events discarded since the last drain, so the caller can say so in one line instead of
    /// one line per keystroke.
    private(set) var droppedSinceLastDrain = 0
    /// Whether the panel still owes a reset because something was dropped.
    private(set) var owesReset = false
    private(set) var totalDropped = 0

    var isFull: Bool { queue.count >= Self.capacity }

    /// Queues an event. Returns whether the caller should schedule a drain — which it should
    /// only do when nothing is draining yet, so a burst produces one hop, not one per event.
    ///
    /// A full buffer discards the incoming event rather than the oldest: the newest state is
    /// the one worth keeping, and the debt is paid by the reset instead of by replay.
    mutating func post(_ event: KeyEvent) -> Bool {
        guard !isFull else {
            droppedSinceLastDrain += 1
            totalDropped += 1
            owesReset = true
            return false
        }
        queue.append(event)
        return queue.count == 1
    }

    /// Takes everything queued, appending the reset if one is owed.
    ///
    /// The reset goes last on purpose: the engine should see the burst, then be told to
    /// forget it, not the other way round.
    mutating func drain() -> (events: [KeyEvent], dropped: Int) {
        var events = queue
        queue.removeAll(keepingCapacity: true)
        let dropped = droppedSinceLastDrain
        droppedSinceLastDrain = 0
        if owesReset {
            owesReset = false
            events.append(KeyEvent(
                kind: .interruption,
                modifiers: [],
                key: nil,
                keyCode: 0,
                isRepeat: false,
                happenedAt: Date()
            ))
        }
        return (events, dropped)
    }

    /// A fresh tap has nothing waiting and no debt.
    mutating func reset() {
        queue.removeAll(keepingCapacity: true)
        droppedSinceLastDrain = 0
        owesReset = false
    }
}
