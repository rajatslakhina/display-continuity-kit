import XCTest
@testable import DisplayContinuity

final class WorkLedgerTests: XCTestCase {

    private func record(_ name: String, priority: Int, epoch: Int = 0) -> WorkRecord {
        WorkRecord(key: WorkKey(name), admittedAtEpoch: Epoch(epoch), priority: priority)
    }

    func testAdmitsUpToCapacityWithoutEviction() {
        var ledger = WorkLedger(capacity: 3)
        XCTAssertTrue(ledger.admit(record("a", priority: 0)).isEmpty)
        XCTAssertTrue(ledger.admit(record("b", priority: 1)).isEmpty)
        XCTAssertTrue(ledger.admit(record("c", priority: 2)).isEmpty)
        XCTAssertEqual(ledger.count, 3)
    }

    func testEvictsTheWorstPriorityNotTheOldest() {
        var ledger = WorkLedger(capacity: 3)
        ledger.admit(record("far", priority: 90))
        ledger.admit(record("near", priority: 1))
        ledger.admit(record("mid", priority: 40))

        let evicted = ledger.admit(record("nearest", priority: 0))
        XCTAssertEqual(evicted, [WorkKey("far")], "the row furthest from the anchor loses")
        XCTAssertEqual(ledger.count, 3)
        XCTAssertTrue(ledger.contains(WorkKey("nearest")))
        XCTAssertTrue(ledger.contains(WorkKey("near")))
        XCTAssertFalse(ledger.contains(WorkKey("far")))
    }

    func testAdmittingSomethingWorseThanEverythingEvictsItself() {
        var ledger = WorkLedger(capacity: 2)
        ledger.admit(record("a", priority: 0))
        ledger.admit(record("b", priority: 1))

        let evicted = ledger.admit(record("worst", priority: 999))
        XCTAssertEqual(evicted, [WorkKey("worst")])
        XCTAssertFalse(ledger.contains(WorkKey("worst")), "it must never have entered the ledger")
        XCTAssertEqual(ledger.count, 2)
    }

    func testZeroCapacityLedgerAdmitsNothingAndDoesNotTrap() {
        var ledger = WorkLedger(capacity: 0)
        let evicted = ledger.admit(record("a", priority: 0))
        XCTAssertEqual(evicted, [WorkKey("a")])
        XCTAssertEqual(ledger.count, 0)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testNegativeCapacityIsClampedToZero() {
        let ledger = WorkLedger(capacity: -10)
        XCTAssertEqual(ledger.capacity, 0)
    }

    /// The property that makes `retain` meaningful: re-admitting a key already
    /// in flight must not restamp its epoch, or a retained item becomes
    /// indistinguishable from a freshly-requested one.
    func testReAdmittingPreservesTheOriginalEpoch() {
        var ledger = WorkLedger(capacity: 4)
        ledger.admit(record("a", priority: 5, epoch: 1))
        let evicted = ledger.admit(record("a", priority: 0, epoch: 9))

        XCTAssertTrue(evicted.isEmpty)
        XCTAssertEqual(ledger.record(for: WorkKey("a"))?.admittedAtEpoch, Epoch(1))
        XCTAssertEqual(ledger.record(for: WorkKey("a"))?.priority, 5)
        XCTAssertEqual(ledger.count, 1)
    }

    /// The bound has to hold under adversarial input, not just typical input.
    func testLedgerNeverExceedsCapacityUnderSustainedPressure() {
        var ledger = WorkLedger(capacity: 8)
        for index in 0 ..< 5_000 {
            ledger.admit(record("k\(index)", priority: index % 97))
            XCTAssertLessThanOrEqual(ledger.count, 8)
        }
        XCTAssertEqual(ledger.count, 8)
    }

    func testKeysByPriorityIsDeterministicAcrossIdenticalLedgers() {
        // Dictionary iteration order is seeded per process, so this asserts
        // ordering is imposed rather than incidental — built in two different
        // insertion orders to make the claim non-trivial.
        var forwards = WorkLedger(capacity: 16)
        var backwards = WorkLedger(capacity: 16)
        let items = [("d", 3), ("a", 1), ("c", 3), ("b", 2)]
        for (name, priority) in items { forwards.admit(record(name, priority: priority)) }
        for (name, priority) in items.reversed() { backwards.admit(record(name, priority: priority)) }

        XCTAssertEqual(forwards.keysByPriority, backwards.keysByPriority)
        XCTAssertEqual(
            forwards.keysByPriority,
            [WorkKey("a"), WorkKey("b"), WorkKey("c"), WorkKey("d")],
            "priority first, then key as a stable tiebreak"
        )
    }

    func testKeysNotInDesiredIsSortedAndComplete() {
        var ledger = WorkLedger(capacity: 8)
        for name in ["a", "b", "c", "d"] { ledger.admit(record(name, priority: 0)) }
        let stale = ledger.keys(notIn: [WorkKey("b"), WorkKey("d")])
        XCTAssertEqual(stale, [WorkKey("a"), WorkKey("c")])
    }

    func testRemoveAndRemoveAll() {
        var ledger = WorkLedger(capacity: 4)
        ledger.admit(record("a", priority: 0))
        XCTAssertNotNil(ledger.remove(WorkKey("a")))
        XCTAssertNil(ledger.remove(WorkKey("a")), "removing twice is a no-op, not a trap")
        ledger.admit(record("b", priority: 0))
        ledger.removeAll()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testEpochSaturatesRatherThanWrapping() {
        // A wrapped epoch would make stale work look current — the exact
        // failure the epoch stamp exists to prevent.
        XCTAssertEqual(Epoch(Int.max).next(), Epoch(Int.max))
        XCTAssertEqual(Epoch(0).next(), Epoch(1))
        XCTAssertEqual(Epoch(-5), Epoch(0), "negative epochs are not representable")
        XCTAssertLessThan(Epoch(1), Epoch(2))
    }

    func testMonotonicInstantClampsBackwardsTime() {
        let later = MonotonicInstant(milliseconds: 100)
        let earlier = MonotonicInstant(milliseconds: 400)
        XCTAssertEqual(later.millisecondsSince(earlier), 0, "never a negative interval")
        XCTAssertEqual(earlier.millisecondsSince(later), 300)
        XCTAssertEqual(
            MonotonicInstant(milliseconds: .max).advanced(byMilliseconds: 10).milliseconds,
            .max
        )
    }
}
