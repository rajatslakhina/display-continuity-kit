import XCTest
@testable import DisplayContinuity

final class CapacityPolicyTests: XCTestCase {

    private let policy = AreaProportionalCapacityPolicy()

    // MARK: - Exact derivations
    //
    // Asserting the actual numbers, not "the number is inside the range the
    // implementation clamped it to". A range assertion over a clamped value is
    // satisfied by any implementation at all, including one that returns the
    // clamp bound unconditionally.

    func testCompactPlanForCoverDisplayHasExactBudgets() {
        let plan = policy.plan(for: .compact, viewport: .coverDisplay)
        XCTAssertEqual(plan.displayClass, .compact)
        XCTAssertEqual(plan.visibleWindow, 8)
        XCTAssertEqual(plan.prefetchDepth, 4)
        XCTAssertEqual(plan.concurrentDecodes, 2)
        XCTAssertEqual(plan.decodeByteBudget, 12 * 524_288)
        XCTAssertEqual(plan.admissionWindow, 16)
    }

    func testExpandedPlanForInnerDisplayHasExactBudgets() {
        let plan = policy.plan(for: .expanded, viewport: .innerDisplay)
        XCTAssertEqual(plan.displayClass, .expanded)
        XCTAssertEqual(plan.visibleWindow, 9)
        XCTAssertEqual(plan.prefetchDepth, 5)
        XCTAssertEqual(plan.concurrentDecodes, 3)
        XCTAssertEqual(plan.decodeByteBudget, 14 * 524_288)
        XCTAssertEqual(plan.admissionWindow, 19)
    }

    /// The documented design decision, stated as an executable claim: prefetch
    /// depth grows like **√area**, not like area.
    ///
    /// The obvious spelling of this test is vacuous, and shipped that way for a
    /// while: comparing only the cover and inner displays and asserting
    /// `prefetchRatio < areaRatio` passes against a *linear* implementation,
    /// because the inner display is 1.94× the area and `4 × 1.94 = 7.77`
    /// truncates to 7, so `7/4 = 1.75 < 1.94` holds anyway. Integer truncation
    /// silently manufactured the sub-linearity the test claimed to detect.
    ///
    /// This version picks areas far enough apart that truncation cannot hide
    /// the difference and asserts the law itself. Replacing `.squareRoot()`
    /// with plain `areaRatio` fails every row below.
    func testPrefetchScalesWithTheSquareRootOfAreaNotWithArea() {
        let base = Viewport.coverDisplay
        XCTAssertEqual(
            policy.plan(for: .compact, viewport: base).prefetchDepth,
            4,
            "the reference viewport is what every ratio below is relative to"
        )

        // Linear scaling would give 16, 36 and 64 (clamped to 16, 32, 32).
        for (linearScale, expected) in [(2.0, 8), (3.0, 12), (4.0, 16)] {
            let viewport = Viewport(width: base.width * linearScale, height: base.height * linearScale)
            let areaRatio = viewport.area / base.area
            XCTAssertEqual(areaRatio, linearScale * linearScale, accuracy: 1e-9)
            XCTAssertEqual(
                policy.plan(for: .compact, viewport: viewport).prefetchDepth,
                expected,
                "\(Int(areaRatio))× the area must give \(Int(linearScale))× the prefetch, not \(Int(areaRatio))×"
            )
        }
    }

    /// A strictly larger viewport must never receive a strictly smaller budget.
    ///
    /// This is the property that a "sanitise non-finite values to zero" rule
    /// quietly breaks: once `width * height` overflows `Double`, collapsing the
    /// product to `0` makes an enormous viewport look like a degenerate one, and
    /// the budget falls off a cliff at a magnitude no test author would think to
    /// pick. `testAbsurdViewportSaturatesRatherThanTraps` used 1e150 — the one
    /// absurd value whose square is still finite.
    func testBudgetsAreMonotoneInAreaEvenPastDoubleOverflow() {
        let magnitudes = [1e3, 1e75, 1e150, 1e200, 1e300, Double.greatestFiniteMagnitude]
        var previous = 0
        for magnitude in magnitudes {
            let plan = policy.plan(for: .expanded, viewport: Viewport(width: magnitude, height: magnitude))
            XCTAssertGreaterThanOrEqual(
                plan.prefetchDepth,
                previous,
                "a \(magnitude)-square viewport got less prefetch than a smaller one"
            )
            previous = plan.prefetchDepth
        }
        XCTAssertEqual(previous, 32, "and the largest representable viewport lands on the ceiling")
    }

    /// The decode budget is derived from *admitted rows*, not from area. This
    /// asserts the exact identity rather than "it went up", which any monotone
    /// function would satisfy — including the area-scaled version this design
    /// deliberately rejects.
    func testDecodeBudgetTracksAdmittedRowsAndNotArea() {
        let bytesPerRow = 512 * 1024
        for (displayClass, viewport) in [
            (DisplayClass.compact, Viewport.coverDisplay),
            (DisplayClass.expanded, Viewport.innerDisplay)
        ] {
            let plan = policy.plan(for: displayClass, viewport: viewport)
            XCTAssertEqual(
                plan.decodeByteBudget,
                (plan.visibleWindow + plan.prefetchDepth) * bytesPerRow,
                "the budget must be exactly what the plan can hold resident, for \(displayClass)"
            )
        }

        // And the rejected alternative is measurably rejected: an area-scaled
        // budget would authorise far more than the plan can ever produce.
        let compact = policy.plan(for: .compact, viewport: .coverDisplay)
        let expanded = policy.plan(for: .expanded, viewport: .innerDisplay)
        let areaRatio = Viewport.innerDisplay.area / Viewport.coverDisplay.area
        let budgetRatio = Double(expanded.decodeByteBudget) / Double(compact.decodeByteBudget)

        XCTAssertGreaterThan(budgetRatio, 1.0, "it still grows")
        XCTAssertLessThan(
            budgetRatio,
            areaRatio,
            "a ceiling that never binds is not a budget — this must not track area"
        )
    }

    // MARK: - Degenerate geometry

    func testZeroViewportStillProducesAUsablePlan() {
        let plan = policy.plan(for: .compact, viewport: .zero)
        XCTAssertEqual(plan.visibleWindow, 1)
        XCTAssertEqual(plan.prefetchDepth, 1)
        XCTAssertEqual(plan.concurrentDecodes, 1)
        XCTAssertEqual(plan.admissionWindow, 3)
    }

    func testAbsurdViewportSaturatesRatherThanTraps() {
        let huge = Viewport(width: 1e150, height: 1e150)
        let plan = policy.plan(for: .expanded, viewport: huge)
        XCTAssertEqual(plan.visibleWindow, 200, "clamped at the documented ceiling")
        XCTAssertEqual(plan.prefetchDepth, 32, "clamped at the documented ceiling")
        XCTAssertEqual(plan.concurrentDecodes, 6, "capped: more decoders is memory pressure, not speed")
        XCTAssertGreaterThan(plan.decodeByteBudget, 0)
    }

    func testNonFiniteViewportIsSanitisedBeforeItReachesThePolicy() {
        let broken = Viewport(width: .nan, height: .infinity)
        let plan = policy.plan(for: .compact, viewport: broken)
        XCTAssertEqual(plan.visibleWindow, 1)
        XCTAssertEqual(plan.concurrentDecodes, 1)
    }

    // MARK: - Policy configuration

    func testInvalidRowHeightFallsBackInsteadOfProducingInfiniteBudgets() {
        let zeroRowHeight = AreaProportionalCapacityPolicy(rowHeight: 0)
        let nanRowHeight = AreaProportionalCapacityPolicy(rowHeight: .nan)
        let reference = AreaProportionalCapacityPolicy(rowHeight: 96)
        XCTAssertEqual(
            zeroRowHeight.plan(for: .compact, viewport: .coverDisplay),
            reference.plan(for: .compact, viewport: .coverDisplay)
        )
        XCTAssertEqual(
            nanRowHeight.plan(for: .compact, viewport: .coverDisplay),
            reference.plan(for: .compact, viewport: .coverDisplay)
        )
    }

    func testConcurrentDecodesRespectsAConfiguredCap() {
        let capped = AreaProportionalCapacityPolicy(maximumConcurrentDecodes: 2)
        let tall = Viewport(width: 716, height: 4_000)
        XCTAssertEqual(capped.plan(for: .expanded, viewport: tall).concurrentDecodes, 2)
    }

    // MARK: - CapacityPlan invariants

    func testPlanInitialiserRejectsNonsenseBudgets() {
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: -5,
            prefetchDepth: -5,
            concurrentDecodes: 0,
            decodeByteBudget: -1
        )
        XCTAssertEqual(plan.visibleWindow, 0)
        XCTAssertEqual(plan.prefetchDepth, 0)
        XCTAssertEqual(plan.concurrentDecodes, 1)
        XCTAssertEqual(plan.decodeByteBudget, 0)
    }

    func testAdmissionWindowSaturatesInsteadOfOverflowingNegative() {
        let plan = CapacityPlan(
            displayClass: .expanded,
            visibleWindow: .max,
            prefetchDepth: .max,
            concurrentDecodes: 4,
            decodeByteBudget: .max
        )
        XCTAssertEqual(plan.admissionWindow, .max, "must not wrap to a negative window")
        XCTAssertGreaterThan(plan.admissionWindow, 0)
    }

    // MARK: - Display-class resolution

    func testResolverUsesTheShorterEdgeNotTheArea() {
        let resolver = MinimumEdgeDisplayClassResolver()
        XCTAssertEqual(resolver.displayClass(for: .coverDisplay), .compact)
        XCTAssertEqual(resolver.displayClass(for: .innerDisplay), .expanded)

        // A short, very wide landscape phone has a large *area* but no room for
        // a second pane. Area-based classification gets this wrong.
        let landscapePhone = Viewport(width: 2_000, height: 390)
        XCTAssertGreaterThan(landscapePhone.area, Viewport.innerDisplay.area)
        XCTAssertEqual(resolver.displayClass(for: landscapePhone), .compact)
    }

    func testResolverRejectsAnInvalidThreshold() {
        let broken = MinimumEdgeDisplayClassResolver(expandedThreshold: .nan)
        XCTAssertEqual(broken.expandedThreshold, 600)
        XCTAssertEqual(broken.displayClass(for: .coverDisplay), .compact)

        let negative = MinimumEdgeDisplayClassResolver(expandedThreshold: -1)
        XCTAssertEqual(negative.expandedThreshold, 600)
        XCTAssertEqual(
            negative.displayClass(for: .coverDisplay),
            .compact,
            "a negative threshold would otherwise classify everything as expanded"
        )
    }

    func testResolverHonoursACustomThreshold() {
        let eager = MinimumEdgeDisplayClassResolver(expandedThreshold: 300)
        XCTAssertEqual(eager.displayClass(for: .coverDisplay), .expanded)
    }
}
