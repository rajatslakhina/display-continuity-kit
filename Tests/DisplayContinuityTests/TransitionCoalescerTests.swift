import XCTest
@testable import DisplayContinuity

/// The asymmetry between growth and shrink is the load-bearing decision in the
/// package. These tests assert it directly, so a "simplification" to a
/// symmetric debounce fails the build rather than quietly making the unfold
/// feel slow.
final class TransitionCoalescerTests: XCTestCase {

    private func at(_ milliseconds: Int) -> MonotonicInstant {
        MonotonicInstant(milliseconds: milliseconds)
    }

    func testGrowthIsAppliedImmediately() {
        var coalescer = TransitionCoalescer(initial: .compact, window: 1_000)
        let decision = coalescer.observe(.expanded, at: at(0))
        XCTAssertEqual(decision, .grew(from: .compact, to: .expanded))
        XCTAssertFalse(coalescer.hasDeferredCancellations, "growth never defers")
        XCTAssertEqual(coalescer.current, .expanded)
    }

    func testShrinkDefersCancellation() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 1_000)
        let decision = coalescer.observe(.compact, at: at(0))
        XCTAssertEqual(decision, .shrankDeferringCancellation(from: .expanded, to: .compact))
        XCTAssertTrue(coalescer.hasDeferredCancellations)
        XCTAssertEqual(coalescer.current, .compact, "the plan shrinks now; only cancellation waits")
    }

    /// The whole reason the mechanism exists: a user unfolds, glances, folds
    /// back. Nothing should have been thrown away.
    func testReversalInsideTheWindowDropsTheDeferredCancellations() {
        var coalescer = TransitionCoalescer(initial: .compact, window: 1_200)
        XCTAssertEqual(coalescer.observe(.expanded, at: at(0)), .grew(from: .compact, to: .expanded))
        XCTAssertEqual(
            coalescer.observe(.compact, at: at(200)),
            .shrankDeferringCancellation(from: .expanded, to: .compact)
        )
        XCTAssertEqual(coalescer.observe(.expanded, at: at(700)), .reverted(to: .expanded))
        XCTAssertFalse(coalescer.hasDeferredCancellations)
    }

    func testReversalAfterTheWindowIsAnOrdinaryGrowth() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 500)
        XCTAssertEqual(
            coalescer.observe(.compact, at: at(0)),
            .shrankDeferringCancellation(from: .expanded, to: .compact)
        )
        // 900ms later the window has long elapsed; this is not a reversal.
        XCTAssertEqual(coalescer.observe(.expanded, at: at(900)), .grew(from: .compact, to: .expanded))
        XCTAssertFalse(coalescer.hasDeferredCancellations)
    }

    func testWindowElapsingSettles() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 500)
        _ = coalescer.observe(.compact, at: at(0))
        XCTAssertEqual(coalescer.observe(.compact, at: at(499)), .unchanged, "still inside the window")
        XCTAssertEqual(coalescer.observe(.compact, at: at(500)), .settled(at: .compact), "boundary is inclusive")
    }

    func testNoChangeWithNoPendingDeferralIsUnchanged() {
        var coalescer = TransitionCoalescer(initial: .compact, window: 500)
        XCTAssertEqual(coalescer.observe(.compact, at: at(0)), .unchanged)
        XCTAssertEqual(coalescer.observe(.compact, at: at(9_999)), .unchanged)
    }

    /// A repeated shrink must not keep extending the window, or cancellations
    /// would be deferred forever and the ledger would only ever grow.
    func testRepeatedShrinksDoNotExtendTheWindowIndefinitely() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 400)
        _ = coalescer.observe(.compact, at: at(0))
        // Re-observing the same shrunk class at t=300 must not restart the clock.
        _ = coalescer.observe(.compact, at: at(300))
        XCTAssertEqual(
            coalescer.observe(.compact, at: at(400)),
            .settled(at: .compact),
            "the clock started at the first shrink, not the most recent observation"
        )
    }

    func testZeroWindowDegeneratesToImmediateCancellation() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 0)
        XCTAssertEqual(
            coalescer.observe(.compact, at: at(0)),
            .shrankDeferringCancellation(from: .expanded, to: .compact)
        )
        XCTAssertEqual(
            coalescer.observe(.compact, at: at(0)),
            .settled(at: .compact),
            "with a zero window the very next observation settles"
        )
    }

    func testNegativeWindowIsClampedRatherThanInverted() {
        let coalescer = TransitionCoalescer(initial: .compact, window: -500)
        XCTAssertEqual(coalescer.window, 0)
    }

    /// Backwards clock readings must not make a window appear to have elapsed.
    func testBackwardsClockDoesNotPrematurelySettle() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 1_000)
        _ = coalescer.observe(.compact, at: at(5_000))
        XCTAssertEqual(
            coalescer.observe(.compact, at: at(10)),
            .unchanged,
            "a clock that went backwards reads as zero elapsed, not as a huge interval"
        )
    }

    func testClearDeferralIsIdempotent() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 1_000)
        _ = coalescer.observe(.compact, at: at(0))
        coalescer.clearDeferral()
        XCTAssertFalse(coalescer.hasDeferredCancellations)
        coalescer.clearDeferral()
        XCTAssertFalse(coalescer.hasDeferredCancellations)
    }

    /// `.settled` means "issue the held cancellations", and that instruction is
    /// only correct once.
    ///
    /// `ContinuityPlanner` calls `clearDeferral()` on settle, so this was
    /// invisible in-tree — but `TransitionCoalescer` is a public type with no
    /// documented obligation to do so, and a second consumer that took the
    /// decision at face value would have cancelled everything twice.
    func testSettlingIsReportedOnceAndNotOnEverySubsequentObservation() {
        var coalescer = TransitionCoalescer(initial: .expanded, window: 500)

        let shrink = coalescer.observe(.compact, at: MonotonicInstant(milliseconds: 0))
        guard case .shrankDeferringCancellation = shrink else {
            return XCTFail("expected a deferred shrink, got \(shrink)")
        }
        XCTAssertTrue(coalescer.hasDeferredCancellations)

        let settled = coalescer.observe(.compact, at: MonotonicInstant(milliseconds: 500))
        guard case .settled = settled else { return XCTFail("expected settle, got \(settled)") }
        XCTAssertFalse(coalescer.hasDeferredCancellations, "settling must clear the deferral itself")

        for time in [600, 700, 5_000] {
            let again = coalescer.observe(.compact, at: MonotonicInstant(milliseconds: time))
            XCTAssertEqual(
                again,
                .unchanged,
                "settled twice at \(time)ms — a second consumer would double-cancel"
            )
        }
    }

    func testCapacityRankOrdersTheClasses() {
        XCTAssertLessThan(DisplayClass.compact.capacityRank, DisplayClass.expanded.capacityRank)
        XCTAssertTrue(DisplayClass.expanded.showsDetailPane)
        XCTAssertFalse(DisplayClass.compact.showsDetailPane)
    }
}
