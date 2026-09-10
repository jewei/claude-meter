import Foundation

/// Decides whether a background cycle must poll a source that does not own the
/// main meter.
///
/// The poll loop stays at 60 seconds. Only sources that no user-visible surface
/// depends on between popover visits can skip a cycle:
///
/// - The selected main provider is never gated. It owns the hero, the menu bar,
///   the header time, the widget, and every quota alert, so its cadence and its
///   notification timing stay exactly as specified.
/// - A secondary source appears only inside the popover. Opening the popover
///   always runs an interactive refresh, so a skipped background cycle is never
///   visible.
///
/// The saving is real work, not just network traffic: each Codex cycle starts a
/// `codex app-server` subprocess per configured home, and each Cursor cycle can
/// start `sqlite3`.
public enum SecondaryPollPolicy {
    /// The slow cadence's upper bound, before the stale threshold constrains it.
    static let maximumIdleInterval: TimeInterval = 150

    /// How long after a popover visit a secondary source keeps the fast cadence.
    /// A user who is switching between accounts sees fresh secondary cards.
    public static let recentInteractionWindow: TimeInterval = 300

    /// The slow cadence for a source that nobody is looking at.
    ///
    /// This must stay below the stale threshold, and by more than one poll cycle.
    /// Otherwise the policy alone would make a card report itself stale, which
    /// would turn an energy saving into a false staleness claim. A configured
    /// threshold at or below the cycle cadence disables the slow cadence, because
    /// no interval can then satisfy the rule.
    public static func idleInterval(
        staleAfterSeconds: TimeInterval,
        pollCadenceSeconds: TimeInterval = 60
    ) -> TimeInterval {
        guard staleAfterSeconds.isFinite, pollCadenceSeconds.isFinite else {
            return maximumIdleInterval
        }
        // One cycle of headroom: the source can be admitted a full cycle late.
        let ceiling = staleAfterSeconds - pollCadenceSeconds
        guard ceiling > pollCadenceSeconds else { return pollCadenceSeconds }
        return min(maximumIdleInterval, ceiling)
    }

    /// Whether this background cycle must poll one secondary source.
    ///
    /// - Parameters:
    ///   - now: The current cycle's time.
    ///   - lastAttemptAt: When this source last ran, successful or not. A failed
    ///     attempt still counts, so a broken source cannot busy-loop.
    ///   - lastPopoverOpenAt: When the popover last opened, or nil if never.
    ///   - isPopoverOpen: Whether the popover is on screen now. A popover that
    ///     stays open past the interaction window must keep receiving fresh data,
    ///     because its cards are visible and it runs a one-second clock.
    ///   - isInteractive: Whether a user action requested this refresh.
    ///   - idleInterval: The slow cadence, from `idleInterval(staleAfterSeconds:)`.
    public static func shouldPoll(
        now: Date,
        lastAttemptAt: Date?,
        lastPopoverOpenAt: Date?,
        isPopoverOpen: Bool,
        isInteractive: Bool,
        idleInterval: TimeInterval
    ) -> Bool {
        if isInteractive || isPopoverOpen { return true }
        // A source with no attempt yet must run: the popover can open at any time,
        // and an empty card is worse than one background cycle.
        guard let lastAttemptAt else { return true }
        // A clock change that puts the last attempt in the future must not park the
        // source until the clock catches up.
        let elapsed = now.timeIntervalSince(lastAttemptAt)
        guard elapsed.isFinite, elapsed >= 0 else { return true }
        if isRecentlyViewed(now: now, lastPopoverOpenAt: lastPopoverOpenAt) { return true }
        return elapsed >= idleInterval
    }

    /// Whether the popover was open recently enough to keep the fast cadence.
    public static func isRecentlyViewed(now: Date, lastPopoverOpenAt: Date?) -> Bool {
        guard let lastPopoverOpenAt else { return false }
        let sinceView = now.timeIntervalSince(lastPopoverOpenAt)
        guard sinceView.isFinite else { return false }
        // A future timestamp reads as "just viewed" rather than "never viewed".
        return sinceView < recentInteractionWindow
    }
}
