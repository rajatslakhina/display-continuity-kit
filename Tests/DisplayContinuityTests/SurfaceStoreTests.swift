import XCTest
@testable import DisplayContinuity

final class SurfaceStoreTests: XCTestCase {

    private let surface = SurfaceID("feed")

    /// The bug this whole type exists to make unrepresentable.
    func testSelectionSurvivesAFoldAndUnfoldRoundTrip() async {
        let store = SurfaceStore()
        await store.select(ItemID("item-7"), in: surface)

        let expanded = await store.projection(for: surface, displayClass: .expanded)
        XCTAssertEqual(expanded.detail, ItemID("item-7"))
        XCTAssertTrue(expanded.showsDetailPane)

        // Fold. The detail pane goes away; the selection does not.
        let compact = await store.projection(for: surface, displayClass: .compact)
        XCTAssertNil(compact.detail, "no detail pane in compact")
        XCTAssertEqual(compact.listSelection, ItemID("item-7"), "but the selection is untouched")

        // Unfold again. The pane materialises already populated — no seeding step.
        let reExpanded = await store.projection(for: surface, displayClass: .expanded)
        XCTAssertEqual(reExpanded.detail, ItemID("item-7"))
    }

    func testSelectingWhileFoldedIsVisibleImmediatelyOnUnfold() async {
        let store = SurfaceStore()
        _ = await store.projection(for: surface, displayClass: .compact)
        await store.select(ItemID("item-3"), in: surface)
        let expanded = await store.projection(for: surface, displayClass: .expanded)
        XCTAssertEqual(
            expanded.detail,
            ItemID("item-3"),
            "there is no second source of truth to be stale"
        )
    }

    func testExpandedWithNoSelectionAsksForAPlaceholderRatherThanRenderingBlank() async {
        let store = SurfaceStore()
        let projection = await store.projection(for: surface, displayClass: .expanded)
        XCTAssertTrue(projection.needsDetailPlaceholder)
        XCTAssertNil(projection.detail)

        await store.select(ItemID("item-1"), in: surface)
        let filled = await store.projection(for: surface, displayClass: .expanded)
        XCTAssertFalse(filled.needsDetailPlaceholder)
    }

    func testCompactNeverAsksForADetailPlaceholder() async {
        let store = SurfaceStore()
        let projection = await store.projection(for: surface, displayClass: .compact)
        XCTAssertFalse(projection.needsDetailPlaceholder)
        XCTAssertFalse(projection.showsDetailPane)
    }

    func testAnchorIsClampedToNonNegative() async {
        let store = SurfaceStore()
        await store.setAnchor(-42, in: surface)
        let state = await store.state(for: surface)
        XCTAssertEqual(state.anchor, 0)
    }

    // MARK: - Bounded storage

    func testStoreEvictsLeastRecentlyTouchedSurfacesAndStaysBounded() async {
        let store = SurfaceStore(capacity: 3)
        for index in 0 ..< 3 {
            await store.select(ItemID("i\(index)"), in: SurfaceID("s\(index)"))
        }
        // Touch s0 so it is no longer the least-recently-used.
        _ = await store.state(for: SurfaceID("s0"))
        await store.select(ItemID("i3"), in: SurfaceID("s3"))

        let count = await store.count
        XCTAssertEqual(count, 3, "the bound held")

        let survivor = await store.state(for: SurfaceID("s0"))
        XCTAssertEqual(survivor.selection, ItemID("i0"), "the recently-touched surface survived")

        let evicted = await store.state(for: SurfaceID("s1"))
        XCTAssertNil(evicted.selection, "the least-recently-used surface was dropped")
    }

    func testDeepLinkingManySurfacesDoesNotLeak() async {
        let store = SurfaceStore(capacity: 8)
        for index in 0 ..< 2_000 {
            await store.select(ItemID("i\(index)"), in: SurfaceID("deeplink-\(index)"))
        }
        let count = await store.count
        XCTAssertEqual(count, 8, "2000 minted surfaces, 8 retained — this is the leak with a slow fuse")
    }

    func testCapacityIsClampedToAtLeastOne() async {
        let store = SurfaceStore(capacity: 0)
        XCTAssertEqual(store.capacity, 1)
        await store.select(ItemID("i0"), in: surface)
        let state = await store.state(for: surface)
        XCTAssertEqual(state.selection, ItemID("i0"), "a capacity-1 store still stores one thing")
    }

    /// Genuine concurrent writers against the actor, not a sequential loop.
    func testConcurrentWritersKeepTheStoreBounded() async {
        let store = SurfaceStore(capacity: 6)
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 128 {
                group.addTask {
                    let surface = SurfaceID("s\(index % 20)")
                    await store.select(ItemID("i\(index)"), in: surface)
                    await store.setAnchor(index, in: surface)
                }
            }
        }
        let count = await store.count
        XCTAssertLessThanOrEqual(count, 6, "128 racing writers across 20 surfaces stayed inside the bound")
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Snapshot integration

    func testSnapshotAndRestoreRoundTripThroughTheStore() async {
        let store = SurfaceStore()
        await store.select(ItemID("item-9"), in: surface)
        await store.setAnchor(31, in: surface)

        let snapshot = await store.snapshot(of: surface, displayClass: .expanded, epoch: Epoch(4))
        XCTAssertEqual(snapshot.selection, ItemID("item-9"))
        XCTAssertEqual(snapshot.anchor, 31)

        let fresh = SurfaceStore()
        await fresh.restore(snapshot)
        let restored = await fresh.projection(for: surface, displayClass: .expanded)
        XCTAssertEqual(restored.detail, ItemID("item-9"))
        let state = await fresh.state(for: surface)
        XCTAssertEqual(state.anchor, 31)
    }
}
