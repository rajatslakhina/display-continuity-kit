import XCTest
@testable import DisplayContinuity

/// `WindowedDemandModel` is the type that turns a budget into work keys. It was
/// previously only exercised transitively through `ContinuityPlanner`, which
/// means a bug in the window arithmetic could hide behind the planner's
/// clamping. These tests hit it directly.
final class WindowedDemandModelTests: XCTestCase {

    private func plan(window: Int, prefetch: Int, displayClass: DisplayClass = .compact) -> CapacityPlan {
        CapacityPlan(
            displayClass: displayClass,
            visibleWindow: window,
            prefetchDepth: prefetch,
            concurrentDecodes: 2,
            decodeByteBudget: 1_024
        )
    }

    private func rows(_ items: [DemandItem]) -> [Int] {
        items.compactMap { key in
            guard key.key.rawValue.hasPrefix("row:") else { return nil }
            return Int(key.key.rawValue.dropFirst("row:".count))
        }.sorted()
    }

    func testWindowIsCentredOnTheAnchor() {
        let model = WindowedDemandModel(itemCount: 1_000)
        let items = model.demand(for: plan(window: 8, prefetch: 4), anchor: 500, selection: nil)
        let indices = rows(items)

        // admissionWindow = 8 + 4*2 = 16, half = 8, so 492 ..< 508.
        XCTAssertEqual(indices.first, 492)
        XCTAssertEqual(indices.last, 507)
        XCTAssertEqual(indices.count, 16)
    }

    func testPriorityIsDistanceFromTheAnchor() {
        let model = WindowedDemandModel(itemCount: 1_000)
        let items = model.demand(for: plan(window: 8, prefetch: 4), anchor: 500, selection: nil)

        let anchorItem = items.first { $0.key == WorkKey("row:500") }
        let farItem = items.first { $0.key == WorkKey("row:492") }
        XCTAssertEqual(anchorItem?.priority, 0, "the anchor row is the most important row")
        XCTAssertEqual(farItem?.priority, 8)
    }

    func testWindowClampsAtTheStartOfTheFeedWithoutShrinking() {
        let model = WindowedDemandModel(itemCount: 1_000)
        let indices = rows(model.demand(for: plan(window: 8, prefetch: 4), anchor: 0, selection: nil))
        XCTAssertEqual(indices.first, 0, "must not walk off the front")
        XCTAssertEqual(indices.count, 16, "clamping must not silently shrink the window")
    }

    /// The mirror of the start-of-feed case, and for a long time the only one of
    /// the pair that did not assert a count.
    ///
    /// That asymmetry in the assertions hid an asymmetry in the code: the window
    /// slid correctly off the front of the feed and *truncated* against the
    /// back, so the bottom of a feed — where pagination pressure is highest —
    /// silently received a fraction of the planned prefetch.
    func testWindowSlidesBackAtTheEndOfTheFeedWithoutShrinking() {
        let model = WindowedDemandModel(itemCount: 20)
        let indices = rows(model.demand(for: plan(window: 8, prefetch: 4), anchor: 19, selection: nil))
        XCTAssertEqual(indices.last, 19, "must not walk off the end")
        XCTAssertEqual(indices.first, 4, "the window slides back rather than truncating")
        XCTAssertEqual(indices.count, 16, "clamping must not silently shrink the window")
        XCTAssertTrue(indices.allSatisfy { $0 >= 0 && $0 < 20 })
    }

    /// A stale or overshooting anchor must degrade to "the nearest full window",
    /// never to a single row.
    func testSaturatingAnchorsStayInsideTheFeedAndStillGetAFullWindow() {
        let model = WindowedDemandModel(itemCount: 40)
        for anchor in [Int.min, -10_000, -1, 0, 20, 35, 39, 40, 10_000, Int.max] {
            let indices = rows(model.demand(for: plan(window: 8, prefetch: 4), anchor: anchor, selection: nil))
            XCTAssertEqual(
                indices.count,
                16,
                "anchor \(anchor) got \(indices.count) rows instead of a full window"
            )
            XCTAssertTrue(
                indices.allSatisfy { $0 >= 0 && $0 < 40 },
                "anchor \(anchor) demanded out-of-range rows: \(indices)"
            )
        }
    }

    /// Demand is bounded by a hard ceiling, not only by the feed.
    ///
    /// `CapacityPlan` floors its fields but does not cap them, and a feed can be
    /// millions of rows. One `DemandItem` per row for a saturated window is an
    /// allocation that ends the process — the same failure `WorkLedger` exists
    /// to prevent, reintroduced one layer up. "The caller will pass a sane plan"
    /// is not a bound.
    func testDemandIsBoundedWhenBothTheFeedAndThePlanAreEnormous() {
        let model = WindowedDemandModel(itemCount: 50_000_000)
        let saturated = CapacityPlan(
            displayClass: .compact,
            visibleWindow: .max,
            prefetchDepth: .max,
            concurrentDecodes: 4,
            decodeByteBudget: .max
        )
        let items = model.demand(for: saturated, anchor: 25_000_000, selection: nil)
        XCTAssertEqual(items.count, WindowedDemandModel.maximumWindow)
        XCTAssertEqual(Set(items.map(\.key)).count, items.count, "no duplicate keys")
    }

    func testWindowLargerThanTheFeedDemandsTheWholeFeedExactlyOnce() {
        let model = WindowedDemandModel(itemCount: 5)
        let items = model.demand(for: plan(window: 200, prefetch: 32), anchor: 2, selection: nil)
        let indices = rows(items)
        XCTAssertEqual(indices, [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(items.map(\.key)).count, items.count, "no duplicate keys")
    }

    func testSaturatedPlanDoesNotTrap() {
        // `CapacityPlan` floors its fields but does not cap them, so this plan
        // is constructible through the public initialiser and its
        // `admissionWindow` saturates at `Int.max`.
        let model = WindowedDemandModel(itemCount: 64)
        let saturated = CapacityPlan(
            displayClass: .expanded,
            visibleWindow: .max,
            prefetchDepth: .max,
            concurrentDecodes: 4,
            decodeByteBudget: .max
        )
        XCTAssertEqual(saturated.admissionWindow, .max)
        let indices = rows(model.demand(for: saturated, anchor: 0, selection: ItemID("x")))
        XCTAssertEqual(indices.count, 64, "the whole feed, and nothing outside it")
    }

    // MARK: - The detail pane's own demand

    func testDetailDemandExistsOnlyInExpandedAndOnlyWithASelection() {
        let model = WindowedDemandModel(itemCount: 40)
        let detail = WorkKey("detail:i7")

        let compactWithSelection = model.demand(
            for: plan(window: 8, prefetch: 4, displayClass: .compact),
            anchor: 0,
            selection: ItemID("i7")
        )
        XCTAssertFalse(
            compactWithSelection.contains { $0.key == detail },
            "compact has no detail pane, so it has nothing to fetch for one"
        )

        let expandedWithoutSelection = model.demand(
            for: plan(window: 8, prefetch: 4, displayClass: .expanded),
            anchor: 0,
            selection: nil
        )
        XCTAssertFalse(
            expandedWithoutSelection.contains { $0.key == detail },
            "an empty detail pane has nothing to fetch"
        )

        let expandedWithSelection = model.demand(
            for: plan(window: 8, prefetch: 4, displayClass: .expanded),
            anchor: 0,
            selection: ItemID("i7")
        )
        let detailItem = expandedWithSelection.first { $0.key == detail }
        XCTAssertNotNil(detailItem, "the detail pane must demand its own content")
        XCTAssertEqual(
            detailItem?.priority,
            -1,
            "the pane the user is looking at outranks every row"
        )
    }

    func testEmptyFeedDemandsNothingEvenInExpanded() {
        let model = WindowedDemandModel(itemCount: 0)
        let items = model.demand(
            for: plan(window: 8, prefetch: 4, displayClass: .expanded),
            anchor: 0,
            selection: ItemID("i0")
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testNegativeItemCountIsClampedToEmpty() {
        XCTAssertEqual(WindowedDemandModel(itemCount: -5).itemCount, 0)
    }

    func testCustomPrefixesAreHonoured() {
        let model = WindowedDemandModel(itemCount: 10, rowPrefix: "tile", detailPrefix: "sheet")
        let items = model.demand(
            for: plan(window: 2, prefetch: 1, displayClass: .expanded),
            anchor: 0,
            selection: ItemID("z")
        )
        XCTAssertTrue(items.contains { $0.key == WorkKey("tile:0") })
        XCTAssertTrue(items.contains { $0.key == WorkKey("sheet:z") })
    }
}
