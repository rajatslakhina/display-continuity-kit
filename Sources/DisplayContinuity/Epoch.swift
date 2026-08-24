// Epoch.swift
//
// Every unit of work is stamped with the epoch it was planned under. That
// stamp is what makes a late-arriving response from a superseded plan
// identifiable instead of indistinguishable — the difference between "ignore
// this, it was planned for a screen that no longer exists" and a torn UI.

/// A monotonically increasing plan generation.
///
/// Bumped once per accepted display-class transition. Saturates at `Int.max`
/// rather than wrapping: a wrapped epoch would silently make stale work look
/// current, which is precisely the failure this type exists to prevent.
public struct Epoch: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: Int

    public init(_ value: Int) { self.value = max(0, value) }

    public static let initial = Epoch(0)

    /// The next epoch. At `Int.max` this returns `Int.max` — the counter stops
    /// rather than wraps. Reaching it requires ~9.2 × 10^18 fold transitions,
    /// so saturation is unreachable in practice; it is here so the type has no
    /// undefined edge at all rather than because anyone expects to hit it.
    public func next() -> Epoch { Epoch(Saturating.add(value, 1)) }

    public static func < (lhs: Epoch, rhs: Epoch) -> Bool { lhs.value < rhs.value }
    public var description: String { "e\(value)" }
}

/// A monotonic instant in whole milliseconds.
///
/// Deliberately a plain value rather than `ContinuousClock`: the coalescing
/// window is timing-sensitive behaviour, and timing-sensitive behaviour that
/// cannot be driven deterministically from a test is behaviour nobody has
/// actually verified. Every time-dependent entry point in this package takes an
/// instant as a parameter, so the storm harness can advance time by fiat.
public struct MonotonicInstant: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let milliseconds: Int

    public init(milliseconds: Int) { self.milliseconds = milliseconds }

    public static let zero = MonotonicInstant(milliseconds: 0)

    /// Elapsed milliseconds since `earlier`, clamped at `0`.
    ///
    /// Clamping at zero means a caller that passes instants out of order gets
    /// "no time has passed" rather than a negative interval that would make a
    /// coalescing window appear to have elapsed.
    public func millisecondsSince(_ earlier: MonotonicInstant) -> Int {
        max(0, Saturating.subtract(milliseconds, earlier.milliseconds))
    }

    public func advanced(byMilliseconds delta: Int) -> MonotonicInstant {
        MonotonicInstant(milliseconds: Saturating.add(milliseconds, delta))
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    public var description: String { "\(milliseconds)ms" }
}
