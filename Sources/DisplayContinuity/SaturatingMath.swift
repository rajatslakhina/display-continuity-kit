// SaturatingMath.swift
//
// Every number in this package is ultimately derived from a viewport the
// system hands us. Viewport values arrive as `Double`s from a layout pass, and
// a layout pass mid-fold-transition is exactly where a NaN or an infinity comes
// from (a division by a zero-height container that has not been measured yet).
//
// `Int(someDouble)` traps on NaN, on ±infinity, and on anything outside
// `Int`'s range. `*` and `+` trap on overflow. `/` and `%` trap on zero. A
// display-class change is a hot path that runs during an animation, so a trap
// here is a crash the user sees at the worst possible moment.
//
// Rather than scatter `guard`s across every derivation, all arithmetic that can
// trap is funnelled through this one type, which clamps instead.

/// Arithmetic that saturates at the representable bounds instead of trapping.
///
/// Every ceiling is derived from `Int.max` / `Int.min` rather than a 64-bit
/// literal, so the behaviour is correct on 32-bit `Int` platforms too.
public enum Saturating {

    /// Converts a `Double` to an `Int`, clamping instead of trapping.
    ///
    /// - NaN maps to `0` (there is no defensible clamp direction for NaN, and
    ///   `0` is the safe identity for every budget in this package).
    /// - `+.infinity` and anything at or above `Int.max` maps to `Int.max`.
    /// - `-.infinity` and anything at or below `Int.min` maps to `Int.min`.
    public static func int(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        // `Double(Int.max)` is not exactly `Int.max`: it rounds *up* to the next
        // power of two (2^63 on a 64-bit `Int`, 2^31 on a 32-bit one). Comparing
        // with `>=` against that rounded-up bound is therefore correct and
        // lossless — every `Double` strictly below it is safely convertible.
        let upperBound = Double(Int.max)
        // `Double(Int.min)` *is* exact (it is already a power of two), so `<=`
        // is likewise correct here.
        let lowerBound = Double(Int.min)
        if value >= upperBound { return .max }
        if value <= lowerBound { return .min }
        return Int(value)
    }

    /// `a + b`, clamped to `Int.min ... Int.max`.
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        // Overflow direction is determined by the sign of the addend: two
        // positives can only overflow upward, two negatives only downward.
        return b > 0 ? .max : .min
    }

    /// `a - b`, clamped to `Int.min ... Int.max`.
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        return b < 0 ? .max : .min
    }

    /// `a * b`, clamped to `Int.min ... Int.max`.
    ///
    /// This also covers the `Int.min * -1` case, which traps under `*`.
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        // The mathematical product's sign is the XOR of the operands' signs.
        let negative = (a < 0) != (b < 0)
        return negative ? .min : .max
    }

    /// `a / b`, returning `fallback` when `b == 0`.
    ///
    /// Also guards `Int.min / -1`, which traps because its true result is not
    /// representable.
    public static func divide(_ a: Int, by b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        let (result, overflow) = a.dividedReportingOverflow(by: b)
        return overflow ? .max : result
    }

    /// Scales `base` by a `Double` factor without trapping on a non-finite
    /// factor or on an out-of-range product.
    public static func scale(_ base: Int, by factor: Double) -> Int {
        guard factor.isFinite else { return factor.isNaN ? 0 : (factor > 0 ? .max : .min) }
        return int(Double(base) * factor)
    }

    /// Clamps `value` into `range`.
    ///
    /// - Precondition: none. If `range` is inverted (`lower > upper`) the lower
    ///   bound wins, which keeps this total rather than trapping the way
    ///   `ClosedRange` construction would.
    public static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        if lower >= upper { return lower }
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }

    /// Sanitises a `Double` that is about to be used as a geometric dimension.
    ///
    /// NaN, infinities and negatives all collapse to `0`, which the capacity
    /// policy then treats as "no usable area" and floors accordingly.
    public static func dimension(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}
