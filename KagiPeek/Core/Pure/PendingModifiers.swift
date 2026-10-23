import Foundation

/// The modifiers that belong to the stroke the user is composing, from two sources.
///
/// Emacs reaches `C-x C-s` by holding Control and typing `x s`; which-key reaches it by
/// pressing `C-x` and *then* `C-s`. KagiPeek now answers both, which means a stroke can be
/// assembled from two places at once:
///
/// - **held** — physically down right now, transient, updated by every `flagsChanged`. This
///   is the narrowing the panel has always done.
/// - **latched** — ticked by tapping a modifier or clicking a title-bar chip, sticky until
///   the sequence finishes or is cancelled. This is what lets ⌥⌘C be typed as "tap ⌥, tap ⌘,
///   press C" without ever holding two keys at once. Ticking and unticking — including which
///   one ⌫ undoes — is owned by `LatchedTicks`, because "the last one" needs an order and a
///   set does not have one.
///
/// The two are kept apart on purpose. Everything that *narrows* or *lights up* reads
/// `effective`; everything that *builds a chord* reads the physical modifiers of the event
/// plus the latched set. Merging them into one set is what would make a latched ⌥
/// indistinguishable from a held one — and then "does this key need swallowing?" has no
/// answer.
struct PendingModifiers: Equatable, Sendable {
    /// Physically held; transient.
    var held: ModifierSet = []
    /// Ticked in the title bar; sticky until the sequence completes or is cancelled.
    var latched: ModifierSet = []

    var union: ModifierSet { held.union(latched) }

    /// What narrows the panel and lights up the rows.
    ///
    /// A lone ⇧ is dropped from *held* only: capital letters arrive with ⇧ down, so a held
    /// ⇧ is not a decision to narrow. A ⇧ the user clicked in the title bar is explicit and
    /// counts.
    var effective: ModifierSet {
        let held = self.held == [.shift] ? ModifierSet() : self.held
        return held.union(latched)
    }

    var isEmpty: Bool { effective.isEmpty }
}
