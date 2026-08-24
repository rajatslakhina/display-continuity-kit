// TransitionCoalescer.swift
//
// A fold transition can reverse two seconds later. Treating each edge as
// final means a user who unfolds, glances, and folds back pays for a full
// cancel-and-refetch cycle for content that never left memory.
//
// The load-bearing decision in this file is that the two directions are *not*
// symmetric.

/// Collapses a rapid display-class storm into the transitions that actually
/// matter.
///
/// ## The asymmetry, and why
///
/// - **Growth (`.compact` → `.expanded`) is applied immediately.** The user is
///   looking at a newly-revealed detail pane. Any delay here is a visible empty
///   pane, and an empty pane is the one artefact of a fold transition a user
///   will actually report.
///
/// - **Shrink (`.expanded` → `.compact`) defers its cancellations** for
///   `window` milliseconds. Cancelling is a resource optimisation, not
///   something the user perceives — nothing on the cover display is waiting on
///   it. Deferring costs a bounded amount of wasted bandwidth and buys total
///   immunity to the reverse-within-a-second case.
///
/// Rejected alternative: a symmetric debounce on both edges. It is less code
/// and one fewer state, and it makes the unfold feel slow — trading the
/// invisible cost for the visible one, which is exactly backwards.
///
/// Rejected alternative: cancel eagerly and rely on an HTTP cache to make the
/// refetch cheap. That assumes the work is a cacheable GET. Decodes, database
/// reads and model inferences are none of those things.
public struct TransitionCoalescer: Sendable, Equatable {

    /// What the planner should do about a display-class observation.
    public enum Decision: Sendable, Hashable {
        /// No change since the last observation, and nothing pending.
        case unchanged
        /// Capacity grew. Admit now; do not wait.
        case grew(from: DisplayClass, to: DisplayClass)
        /// Capacity shrank. Re-plan admissions now, but hold cancellations.
        case shrankDeferringCancellation(from: DisplayClass, to: DisplayClass)
        /// Capacity returned to the class we were deferring away from, inside
        /// the window. The deferred cancellations are dropped, not issued.
        case reverted(to: DisplayClass)
        /// The deferral window elapsed. Held cancellations may now be issued.
        case settled(at: DisplayClass)
    }

    /// Deferral window in milliseconds. Clamped to `>= 0`; a window of `0`
    /// degenerates to "cancel immediately", which is a legitimate configuration
    /// for a memory-constrained host.
    public let window: Int

    public private(set) var current: DisplayClass
    /// The class we were in when a shrink began, if one is pending.
    public private(set) var deferredFrom: DisplayClass?
    public private(set) var deferralStartedAt: MonotonicInstant?

    public init(initial: DisplayClass, window: Int = 1_200) {
        self.window = max(0, window)
        self.current = initial
        self.deferredFrom = nil
        self.deferralStartedAt = nil
    }

    /// Whether cancellations are currently being held back.
    public var hasDeferredCancellations: Bool { deferredFrom != nil }

    /// Records a display-class observation and returns the decision.
    ///
    /// This is a pure state machine over `(current, deferredFrom, now)` — it
    /// starts no timers and captures no clock, which is what makes the storm
    /// harness able to replay a transition sequence deterministically.
    public mutating func observe(
        _ observed: DisplayClass,
        at now: MonotonicInstant
    ) -> Decision {
        // Case 1: the class we are deferring *away from* came back. This is the
        // reversal the whole mechanism exists for.
        if let pendingSource = deferredFrom, observed == pendingSource {
            let elapsed = now.millisecondsSince(deferralStartedAt ?? now)
            if elapsed < window {
                current = observed
                deferredFrom = nil
                deferralStartedAt = nil
                return .reverted(to: observed)
            }
            // The window already elapsed, so those cancellations are the
            // caller's to issue; this is an ordinary growth back up.
            let previous = current
            current = observed
            deferredFrom = nil
            deferralStartedAt = nil
            return .grew(from: previous, to: observed)
        }

        // Case 2: no change in class.
        if observed == current {
            guard let start = deferralStartedAt else { return .unchanged }
            return now.millisecondsSince(start) >= window
                ? .settled(at: current)
                : .unchanged
        }

        // Case 3: a genuine transition.
        let previous = current
        current = observed
        if observed.capacityRank > previous.capacityRank {
            // Growth supersedes any pending shrink: whatever we were about to
            // cancel is wanted again by definition of having more room.
            deferredFrom = nil
            deferralStartedAt = nil
            return .grew(from: previous, to: observed)
        } else {
            // Only start the clock on the *first* shrink of a run; a
            // shrink-then-shrink sequence must not keep extending the window
            // indefinitely, or cancellations would never be issued at all.
            if deferredFrom == nil {
                deferredFrom = previous
                deferralStartedAt = now
            }
            return .shrankDeferringCancellation(from: previous, to: observed)
        }
    }

    /// Clears the pending deferral. Called once the planner has actually issued
    /// the held cancellations.
    public mutating func clearDeferral() {
        deferredFrom = nil
        deferralStartedAt = nil
    }
}
