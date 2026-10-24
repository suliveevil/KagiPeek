import Foundation

/// Where the panel session is.
///
/// `idle` — no panel, keys pass through; `armed` — the trigger was held long enough to arm,
/// waiting for the panel to open; `active` — the panel (or the search palette) owns the
/// keyboard.
///
/// Pure so the key handlers can be routed without the AppKit engine: whether a key means
/// "dismiss", "navigate" or "compose" is a function of the phase, and the side effects
/// belong to whoever holds the state.
enum EnginePhase: Equatable {
    case idle
    case armed
    case active
}
