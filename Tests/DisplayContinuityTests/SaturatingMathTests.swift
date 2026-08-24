import XCTest
@testable import DisplayContinuity

/// These are the tests that keep a fold transition from being a crash.
///
/// Every value here is one that `Int(_:)`, `*`, `+` or `/` would trap on. If
/// `Saturating` regressed to plain arithmetic, this file would not fail —
/// it would abort the test process, which is itself the signal.
final class SaturatingMathTests: XCTestCase {

    func testIntConversionHandlesEveryTrappingDouble() {
        XCTAssertEqual(Saturating.int(.nan), 0)
        XCTAssertEqual(Saturating.int(.signalingNaN), 0)
        XCTAssertEqual(Saturating.int(.infinity), .max)
        XCTAssertEqual(Saturating.int(-.infinity), .min)
        XCTAssertEqual(Saturating.int(1e300), .max)
        XCTAssertEqual(Saturating.int(-1e300), .min)
        XCTAssertEqual(Saturating.int(Double(Int.max)), .max)
        XCTAssertEqual(Saturating.int(Double(Int.min)), .min)
    }

    func testIntConversionTruncatesTowardZeroInsideRange() {
        XCTAssertEqual(Saturating.int(3.9), 3)
        XCTAssertEqual(Saturating.int(-3.9), -3)
        XCTAssertEqual(Saturating.int(0.0), 0)
        XCTAssertEqual(Saturating.int(-0.0), 0)
    }

    func testAdditionSaturatesInBothDirections() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.max, .max), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.add(.min, .min), .min)
        XCTAssertEqual(Saturating.add(7, 5), 12)
        XCTAssertEqual(Saturating.add(.max, -1), Int.max - 1)
    }

    func testSubtractionSaturatesInBothDirections() {
        XCTAssertEqual(Saturating.subtract(.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(.max, -1), .max)
        XCTAssertEqual(Saturating.subtract(10, 3), 7)
        // `Int.min` negated is not representable; this must not trap.
        XCTAssertEqual(Saturating.subtract(0, .min), .max)
    }

    func testMultiplicationSaturatesAndHandlesIntMinTimesNegativeOne() {
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.min, 2), .min)
        // The classic trap: |Int.min| is one larger than Int.max.
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(-1, .min), .max)
        XCTAssertEqual(Saturating.multiply(.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(6, 7), 42)
        XCTAssertEqual(Saturating.multiply(0, .min), 0)
    }

    func testDivisionGuardsZeroAndIntMinOverNegativeOne() {
        XCTAssertEqual(Saturating.divide(10, by: 0), 0)
        XCTAssertEqual(Saturating.divide(10, by: 0, fallback: 99), 99)
        XCTAssertEqual(Saturating.divide(.min, by: -1), .max)
        XCTAssertEqual(Saturating.divide(9, by: 3), 3)
        XCTAssertEqual(Saturating.divide(-9, by: 2), -4)
    }

    func testScaleRejectsNonFiniteFactors() {
        XCTAssertEqual(Saturating.scale(10, by: .nan), 0)
        XCTAssertEqual(Saturating.scale(10, by: .infinity), .max)
        XCTAssertEqual(Saturating.scale(10, by: -.infinity), .min)
        XCTAssertEqual(Saturating.scale(10, by: 2.5), 25)
        XCTAssertEqual(Saturating.scale(.max, by: 2.0), .max)
    }

    func testClampIsTotalEvenForInvertedRanges() {
        XCTAssertEqual(Saturating.clamp(5, lower: 0, upper: 10), 5)
        XCTAssertEqual(Saturating.clamp(-5, lower: 0, upper: 10), 0)
        XCTAssertEqual(Saturating.clamp(50, lower: 0, upper: 10), 10)
        // A `ClosedRange` would trap here; this must not.
        XCTAssertEqual(Saturating.clamp(5, lower: 10, upper: 0), 10)
    }

    func testDimensionSanitisesGeometryFromAnUnmeasuredLayoutPass() {
        XCTAssertEqual(Saturating.dimension(.nan), 0)
        XCTAssertEqual(Saturating.dimension(.infinity), 0)
        XCTAssertEqual(Saturating.dimension(-10), 0)
        XCTAssertEqual(Saturating.dimension(0), 0)
        XCTAssertEqual(Saturating.dimension(42.5), 42.5)
    }

    /// A viewport built from a division by an unmeasured (zero) container is
    /// the realistic source of a NaN here, so it gets its own test rather than
    /// only appearing as a raw `.nan` literal.
    func testViewportFromDivisionByUnmeasuredContainerIsUsable() {
        let unmeasuredHeight = 0.0
        let derived = Viewport(width: 100.0 / unmeasuredHeight, height: unmeasuredHeight / unmeasuredHeight)
        XCTAssertEqual(derived.width, 0)
        XCTAssertEqual(derived.height, 0)
        XCTAssertEqual(derived.area, 0)
        // And the policy that consumes it must still produce a usable budget.
        let plan = AreaProportionalCapacityPolicy().plan(for: .compact, viewport: derived)
        XCTAssertEqual(plan.visibleWindow, 1, "floors at one row rather than zero")
        XCTAssertGreaterThanOrEqual(plan.concurrentDecodes, 1, "zero decoders is a deadlock")
    }
}
