import XCTest
@testable import DisplayContinuity

final class ContinuityPlannerTests: XCTestCase {

    private func makePlanner(
        items: Int = 40,
        ledgerCapacity: Int = 64,
        window: Int = 1_200
    ) -> ContinuityPlanner {
        ContinuityPlanner(
            initialViewport: .coverDisplay,
            policy: AreaProportionalCapacityPolicy(),
            resolver: MinimumEdgeDisplayClassResolver(),
            demandModel: WindowedDemandModel(itemCount: items),
            ledgerCapacity: ledgerCapacity,
            coalesceWindowMilliseconds: window
        )
    }

    private func at(_ milliseconds: Int) -> MonotonicInstant {
        MonotonicInstant(milliseconds: milliseconds)
    }

    private let selection = ItemID("i0")

    // MARK: - The headline behaviour

    func testInitialPlanAdmitsTheCompactWindow() async {
        let planner = makePlanner()
        let directive = await planner.apply(
            SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection),
            at: at(0)
        )
        XCTAssertEqual(directive.epoch, .initial, "no resize yet, so no new plan generation")
        XCTAssertEqual(directive.admit.count, 16, "compact admission window")
        XCTAssertTrue(directive.cancel.isEmpty)
        XCTAssertTrue(directive.retain.isEmpty, "nothing was in flight to retain")
        XCTAssertFalse(
            directive.admit.contains(WorkKey("detail:i0")),
            "compact has no detail pane, so no detail fetch"
        )
    }

    /// The unfold: the detail pane demands content nobody scrolled to, and the
    /// list work already in flight is *kept*.
    func testUnfoldRetainsInFlightWorkAndAdmitsOnlyTheDelta() async {
        let planner = makePlanner()
        _ = await planner.apply(
            SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection),
            at: at(0)
        )
        let unfold = await planner.apply(
            SurfaceInput(viewport: .innerDisplay, anchor: 0, selection: selection),
            at: at(250)
        )

        XCTAssertEqual(unfold.epoch, Epoch(1), "the world resized, so the plan generation advanced")
        XCTAssertEqual(unfold.retain.count, 16, "every in-flight row was still wanted — none restarted")
        XCTAssertEqual(unfold.admit.count, 4, "3 newly visible rows plus the detail pane")
        XCTAssertTrue(unfold.cancel.isEmpty)
        XCTAssertTrue(
            unfold.admit.contains(WorkKey("detail:i0")),
            "the detail pane's own demand is admitted in the same directive, not as a racing second fetch"
        )
        XCTAssertEqual(unfold.plan.displayClass, .expanded)
    }

    /// The reversal case, which is the entire justification for the deferred
    /// cancellation policy: unfold, glance, fold back — nothing is refetched.
    func testFoldAndUnfoldInsideTheWindowRefetchesNothing() async {
        let planner = makePlanner(window: 1_200)
        _ = await planner.apply(SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection), at: at(0))
        _ = await planner.apply(SurfaceInput(viewport: .innerDisplay, anchor: 0, selection: selection), at: at(250))

        let fold = await planner.apply(
            SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection),
            at: at(450)
        )
        XCTAssertTrue(fold.cancel.isEmpty, "cancellation is held, not issued")
        XCTAssertEqual(fold.deferredCancellations.count, 4, "the detail fetch and 3 rows are held")
        XCTAssertTrue(fold.admit.isEmpty)

        let backUp = await planner.apply(
            SurfaceInput(viewport: .innerDisplay, anchor: 0, selection: selection),
            at: at(700)
        )
        XCTAssertTrue(backUp.admit.isEmpty, "nothing to restart — it was never cancelled")
        XCTAssertTrue(backUp.cancel.isEmpty)
        XCTAssertTrue(backUp.deferredCancellations.isEmpty)
        XCTAssertEqual(backUp.retain.count, 20, "all 20 units of work survived the round trip")
    }

    /// And the other half of the contract: if the user does *not* come back,
    /// the held cancellations must actually be issued.
    func testHeldCancellationsAreIssuedOnceTheWindowElapses() async {
        let planner = makePlanner(window: 1_200)
        _ = await planner.apply(SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection), at: at(0))
        _ = await planner.apply(SurfaceInput(viewport: .innerDisplay, anchor: 0, selection: selection), at: at(250))
        let fold = await planner.apply(
            SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection),
            at: at(450)
        )
        XCTAssertEqual(fold.deferredCancellations.count, 4)

        let settled = await planner.tick(at: at(450 + 1_200))
        XCTAssertEqual(settled.cancel.count, 4, "the window elapsed with no reversal, so they go")
        XCTAssertTrue(settled.deferredCancellations.isEmpty)

        let state = await planner.snapshotState()
        XCTAssertEqual(state.inFlight.count, 16)
        XCTAssertFalse(state.inFlight.contains(WorkKey("detail:i0")))
    }

    func testSelectionlessUnfoldDemandsNoDetailFetch() async {
        let planner = makePlanner()
        _ = await planner.apply(SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: nil), at: at(0))
        let unfold = await planner.apply(
            SurfaceInput(viewport: .innerDisplay, anchor: 0, selection: nil),
            at: at(250)
        )
        XCTAssertEqual(unfold.admit.count, 3, "rows only — an empty detail pane has nothing to fetch")
        XCTAssertFalse(unfold.admit.contains(where: { $0.rawValue.hasPrefix("detail:") }))
    }

    // MARK: - Epoch semantics

    func testScrollingReplansWithinTheSameEpoch() async {
        let planner = makePlanner()
        let first = await planner.apply(SurfaceInput(viewport: .coverDisplay, anchor: 0), at: at(0))
        let scrolled = await planner.apply(SurfaceInput(viewport: .coverDisplay, anchor: 20), at: at(40))
        XCTAssertEqual(
            scrolled.epoch,
            first.epoch,
            "a scroll changes what is wanted, not the budget — the plan generation is unchanged"
        )
        XCTAssertFalse(scrolled.admit.isEmpty, "but it does re-plan")
        XCTAssertFalse(scrolled.cancel.isEmpty, "rows that scrolled out are cancelled immediately")
    }

    func testEpochIsMonotonicAcrossAStorm() async {
        let planner = makePlanner()
        var epochs: [Epoch] = []
        for step in 0 ..< 12 {
            let viewport: Viewport = step.isMultiple(of: 2) ? .innerDisplay : .coverDisplay
            let directive = await planner.apply(
                SurfaceInput(viewport: viewport, anchor: 0, selection: selection),
                at: at(step * 300)
            )
            epochs.append(directive.epoch)
        }
        for (previous, next) in zip(epochs, epochs.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next, "epochs never go backwards")
        }
        XCTAssertGreaterThan(epochs.last ?? .initial, .initial)
    }

    // MARK: - Bounded under pressure

    func testLedgerCapacityIsRespectedAndTheNearestWorkSurvives() async {
        let planner = makePlanner(items: 200, ledgerCapacity: 10)
        let directive = await planner.apply(
            SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection),
            at: at(0)
        )
        XCTAssertEqual(directive.admit.count, 10, "capped at ledger capacity, not the 16-row demand")
        XCTAssertTrue(directive.cancel.isEmpty, "work that never started is not a cancellation")

        let state = await planner.snapshotState()
        XCTAssertEqual(state.inFlight.count, 10)
        XCTAssertTrue(state.inFlight.contains(WorkKey("row:0")), "the anchor row is never the eviction victim")
    }

    func testLongScrollNeverGrowsTheInFlightSetPastItsBound() async {
        let planner = makePlanner(items: 5_000, ledgerCapacity: 12)
        for index in stride(from: 0, to: 2_000, by: 7) {
            _ = await planner.apply(
                SurfaceInput(viewport: .coverDisplay, anchor: index, selection: selection),
                at: at(index)
            )
            let state = await planner.snapshotState()
            XCTAssertLessThanOrEqual(state.inFlight.count, 12)
        }
    }

    func testPathologicalAnchorsDoNotTrapOrProduceEmptyDemand() async {
        // Every key the demand model can legally emit for a 40-row feed.
        let legalRows = Set((0 ..< 40).map { WorkKey("row:\($0)") })

        for anchor in [Int.min, -1, 0, 39, 40, Int.max] {
            let planner = makePlanner(items: 40)
            _ = await planner.apply(
                SurfaceInput(viewport: .coverDisplay, anchor: anchor, selection: selection),
                at: at(0)
            )
            let state = await planner.snapshotState()

            XCTAssertFalse(state.inFlight.isEmpty, "anchor \(anchor) produced no work at all")
            // The real assertion: a saturating anchor must not walk the window
            // off the end of the feed. `Int.max` clamping to an empty or
            // out-of-range window is exactly the bug this guards.
            let outOfRange = Set(state.inFlight).subtracting(legalRows)
                .filter { !$0.rawValue.hasPrefix("detail:") }
            XCTAssertTrue(
                outOfRange.isEmpty,
                "anchor \(anchor) demanded rows outside 0..<40: \(outOfRange)"
            )
        }
    }

    // MARK: - Re-planning inside an open deferral window
    //
    // The path that is easy to get wrong: the user folds (opening the deferral
    // window) and then keeps scrolling on the cover display. Each scroll
    // re-plans while cancellations are still being held.

    func testScrollingInsideADeferralWindowStaysConsistent() async {
        let capacity = 24
        let planner = makePlanner(items: 5_000, ledgerCapacity: capacity, window: 1_200)

        _ = await planner.apply(SurfaceInput(viewport: .innerDisplay, anchor: 0, selection: selection), at: at(0))
        _ = await planner.apply(SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection), at: at(200))

        // Six scrolls, all inside the 1,200 ms window.
        for (step, anchor) in [40, 80, 120, 160, 200, 240].enumerated() {
            let directive = await planner.apply(
                SurfaceInput(viewport: .coverDisplay, anchor: anchor, selection: selection),
                at: at(260 + step * 60)
            )
            let state = await planner.snapshotState()

            // Held cancellations are a promise to stop work that is *still
            // running*. Anything held must therefore still be in the ledger.
            let heldButNotInFlight = Set(directive.deferredCancellations)
                .subtracting(state.inFlight)
            XCTAssertTrue(
                heldButNotInFlight.isEmpty,
                "held a cancellation for work that is not in flight: \(heldButNotInFlight)"
            )
            // …which also bounds the held set by the ledger's capacity. Without
            // this the held set is the one collection with no bound of its own.
            XCTAssertLessThanOrEqual(
                directive.deferredCancellations.count,
                capacity,
                "the held set grew past the ledger it is supposed to describe"
            )
            // And a key can never be both "stop this now" and "we are holding
            // this pending reversal" in the same directive.
            XCTAssertTrue(
                Set(directive.cancel).isDisjoint(with: Set(directive.deferredCancellations)),
                "a key was simultaneously cancelled and held"
            )
        }

        // Settling must not re-cancel anything that already left the ledger.
        let settled = await planner.tick(at: at(3_000))
        let state = await planner.snapshotState()
        XCTAssertTrue(
            Set(settled.cancel).isDisjoint(with: Set(state.inFlight)),
            "settle cancelled work that is still in flight"
        )
        XCTAssertTrue(settled.deferredCancellations.isEmpty, "settling must clear the held set")
    }

    func testEmptyFeedProducesAnEmptyButValidDirective() async {
        let planner = makePlanner(items: 0)
        let directive = await planner.apply(
            SurfaceInput(viewport: .innerDisplay, anchor: 0, selection: selection),
            at: at(0)
        )
        XCTAssertTrue(directive.admit.isEmpty)
        XCTAssertTrue(directive.cancel.isEmpty)
        XCTAssertTrue(directive.isNoOp)
    }

    // MARK: - Concurrency
    //
    // A real concurrent writer, not a sequential loop wearing an async hat:
    // 64 tasks race the same actor with interleaved fold and unfold
    // observations at out-of-order instants.

    /// A genuine concurrent-writer test: 64 tasks race the same actor with
    /// interleaved fold/unfold observations at out-of-order instants.
    ///
    /// The assertions are deliberately *per directive*, not on the final state.
    /// "The final epoch is the maximum epoch" and "the ledger is inside its own
    /// capacity" are true by construction and would pass for a planner that
    /// never bumps the epoch at all. What is not true by construction is that
    /// every directive a racing caller receives is internally coherent.
    ///
    /// Per-directive coherence is necessary and **not sufficient** — see
    /// `testConcurrentRePlansNeverAdmitTheSameWorkTwice`, which covers the
    /// property this one structurally cannot.
    func testConcurrentObserversAlwaysReceiveCoherentDirectives() async {
        let capacity = 24
        let planner = makePlanner(items: 500, ledgerCapacity: capacity)

        let directives: [ReplanDirective] = await withTaskGroup(of: ReplanDirective.self) { group in
            for index in 0 ..< 64 {
                group.addTask {
                    let viewport: Viewport = index.isMultiple(of: 3) ? .innerDisplay : .coverDisplay
                    // Out-of-order instants: a real clock read on a contended
                    // actor arrives in whatever order it arrives.
                    let instant = MonotonicInstant(milliseconds: (index * 977) % 5_000)
                    return await planner.apply(
                        SurfaceInput(viewport: viewport, anchor: index * 3, selection: ItemID("i\(index)")),
                        at: instant
                    )
                }
            }
            var results: [ReplanDirective] = []
            for await directive in group { results.append(directive) }
            return results
        }

        XCTAssertEqual(directives.count, 64)

        for (index, directive) in directives.enumerated() {
            let admit = Set(directive.admit)
            let cancel = Set(directive.cancel)
            let retain = Set(directive.retain)
            let held = Set(directive.deferredCancellations)

            XCTAssertTrue(admit.isDisjoint(with: cancel), "directive \(index): admit ∩ cancel")
            XCTAssertTrue(admit.isDisjoint(with: retain), "directive \(index): admit ∩ retain")
            XCTAssertTrue(cancel.isDisjoint(with: retain), "directive \(index): cancel ∩ retain")
            XCTAssertTrue(cancel.isDisjoint(with: held), "directive \(index): cancel ∩ held")
            XCTAssertLessThanOrEqual(
                admit.count + retain.count,
                capacity,
                "directive \(index) described more live work than the ledger can hold"
            )
            XCTAssertLessThanOrEqual(
                held.count,
                capacity,
                "directive \(index) held more cancellations than there is work to cancel"
            )
        }

        // At least one caller must have observed a real re-plan, or the test
        // proved nothing about contention.
        XCTAssertTrue(
            directives.contains { !$0.isNoOp },
            "no directive did any work — the race never exercised the planner"
        )
        XCTAssertTrue(
            directives.contains { $0.epoch > .initial },
            "the epoch never advanced, so no display-class change was observed"
        )
    }

    /// The property the per-directive test above structurally cannot reach.
    ///
    /// `replan` has no `await` in it, so the whole pass is atomic and no caller
    /// can observe it half-done. That is the load-bearing claim of this file —
    /// and until this test existed, **nothing enforced it**: injecting a single
    /// `await Task.yield()` between the cancellation pass and the admission pass
    /// left the suite 122/0 green while producing real duplicate admissions and
    /// real retention lies. The per-directive test cannot catch it because each
    /// individual directive stays disjoint and bounded under the mutation; the
    /// violation only exists *across* directives.
    ///
    /// The assertions here are deliberately **order-independent**, because there
    /// is no way to recover the actor's true serialisation order from the
    /// outside. Two counting invariants survive that:
    ///
    /// 1. A key can only be started again after it has been stopped, so across
    ///    the whole run `admits(key) <= cancels(key) + 1`.
    /// 2. Retaining a key asserts it is already in flight, so a key that appears
    ///    in any `retain` must appear in some `admit`.
    ///
    /// Both hold for any *serial* sequence of atomic passes, and both break
    /// under interleaving.
    func testConcurrentRePlansNeverAdmitTheSameWorkTwice() async {
        let planner = makePlanner(items: 500, ledgerCapacity: 24)

        let directives: [ReplanDirective] = await withTaskGroup(of: ReplanDirective.self) { group in
            for index in 0 ..< 64 {
                group.addTask {
                    // Fold, unfold and scroll all at once, so the run produces
                    // genuine cancellations rather than a stream of no-ops.
                    let viewport: Viewport = index.isMultiple(of: 2) ? .innerDisplay : .coverDisplay
                    return await planner.apply(
                        SurfaceInput(
                            viewport: viewport,
                            anchor: (index * 7) % 400,
                            selection: ItemID("i\(index % 5)")
                        ),
                        at: MonotonicInstant(milliseconds: index * 137)
                    )
                }
            }
            var results: [ReplanDirective] = []
            for await directive in group { results.append(directive) }
            return results
        }

        var admits: [WorkKey: Int] = [:]
        var cancels: [WorkKey: Int] = [:]
        var retains: [WorkKey: Int] = [:]
        for directive in directives {
            for key in directive.admit { admits[key, default: 0] += 1 }
            for key in directive.cancel { cancels[key, default: 0] += 1 }
            for key in directive.retain { retains[key, default: 0] += 1 }
        }

        XCTAssertFalse(admits.isEmpty, "the race never admitted anything")
        XCTAssertFalse(cancels.isEmpty, "the race never cancelled anything — it proved nothing")

        for (key, count) in admits {
            XCTAssertLessThanOrEqual(
                count,
                (cancels[key] ?? 0) + 1,
                "\(key) was started \(count) times against \(cancels[key] ?? 0) stops — "
                    + "a re-plan admitted work that was already in flight"
            )
        }

        for (key, count) in retains where count > 0 {
            XCTAssertGreaterThan(
                admits[key] ?? 0,
                0,
                "\(key) was retained \(count) times but never admitted — retention lie"
            )
        }
    }

    /// The frozen admission list, pinned directly rather than only via the storm.
    ///
    /// Computing `!ledger.contains(_:)` inside the admission loop looks
    /// equivalent to freezing the list first and is not: the loop runs
    /// best-priority-first, so a key already in flight whose priority got worse
    /// (the anchor moved) is evicted early in the pass — and by the time the
    /// loop reaches that key, a live check sees it as absent and re-admits it.
    /// The same key then appears in both `cancel` and `admit` in one directive,
    /// which is the duplicated-fetch bug in miniature.
    ///
    /// The parameters are not arbitrary. It reproduces only when the ledger is
    /// smaller than the demand window (so eviction actually happens) *and* the
    /// anchor moves by a few rows per step (so the overlap between consecutive
    /// windows is large enough for an in-flight key's rank to degrade). A
    /// ledger of 8 with a 3-row anchor step is the smallest configuration that
    /// reproduces it; the original discovery needed the full storm harness.
    func testAKeyEvictedDuringAdmissionIsNeverReAdmittedInTheSameDirective() async {
        let capacity = 8
        let planner = makePlanner(items: 500, ledgerCapacity: capacity)

        var sawEviction = false
        for step in 0 ..< 12 {
            let directive = await planner.apply(
                SurfaceInput(
                    viewport: step.isMultiple(of: 2) ? .innerDisplay : .coverDisplay,
                    anchor: step * 3,
                    selection: selection
                ),
                at: at(step * 300)
            )
            let admit = Set(directive.admit)
            let cancel = Set(directive.cancel)
            XCTAssertTrue(
                admit.isDisjoint(with: cancel),
                "step \(step): \(admit.intersection(cancel).map(\.rawValue).sorted()) "
                    + "was both admitted and cancelled in one directive"
            )
            XCTAssertLessThanOrEqual(
                admit.count + directive.retain.count,
                capacity,
                "step \(step) described more live work than the ledger can hold"
            )
            if !cancel.isEmpty { sawEviction = true }
        }
        XCTAssertTrue(sawEviction, "the ledger never came under pressure — the test proved nothing")
    }

    // MARK: - Directive shape

    /// `admissionOrder` pinned in isolation, because nothing downstream can.
    ///
    /// `WorkExecutor` re-sorts its pending queue by priority on every apply,
    /// which is correct — and which makes consuming `admit` instead of
    /// `admissionOrder` inside the executor **invisible from the outside**: the
    /// queue ends up sorted either way. That double defence is good engineering
    /// and bad coverage. It meant the executor-level ordering test could not
    /// fail for the property it was named after, and a mutation swapping the
    /// two left the whole suite green. The ordering is asserted here, at the
    /// only layer where nothing else compensates for it.
    func testAdmissionOrderRanksByPriorityWhileAdmitStaysLexicographic() {
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 4,
            prefetchDepth: 0,
            concurrentDecodes: 2,
            decodeByteBudget: 1_024
        )
        let keys = (0 ..< 12).map { WorkKey("row:\($0)") }
        let directive = ReplanDirective(
            epoch: .initial,
            plan: plan,
            admit: keys,
            cancel: [],
            retain: [],
            admissionPriority: Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        )

        // `admit` is lexicographic on purpose — reproducible diffs, not a schedule.
        XCTAssertEqual(
            Array(directive.admit.prefix(3)),
            [WorkKey("row:0"), WorkKey("row:1"), WorkKey("row:10")],
            "admit must stay lexicographic; that is why the priority field exists"
        )
        XCTAssertEqual(
            Array(directive.admissionOrder.prefix(4)),
            [WorkKey("row:0"), WorkKey("row:1"), WorkKey("row:2"), WorkKey("row:3")],
            "admissionOrder must rank by priority, not by string comparison"
        )
        XCTAssertEqual(
            Set(directive.admissionOrder),
            Set(directive.admit),
            "the two orderings must describe the same set"
        )

        // Keys with no recorded priority sort last, deterministically, so a
        // hand-built directive degrades rather than trapping.
        let partial = ReplanDirective(
            epoch: .initial,
            plan: plan,
            admit: [WorkKey("a"), WorkKey("b")],
            cancel: [],
            retain: [],
            admissionPriority: [WorkKey("b"): 0]
        )
        XCTAssertEqual(partial.admissionOrder, [WorkKey("b"), WorkKey("a")])
    }

    func testDirectiveSetsAreDisjointAndSorted() async {
        let planner = makePlanner(items: 200, ledgerCapacity: 20)
        _ = await planner.apply(SurfaceInput(viewport: .coverDisplay, anchor: 0, selection: selection), at: at(0))
        let directive = await planner.apply(
            SurfaceInput(viewport: .innerDisplay, anchor: 60, selection: selection),
            at: at(300)
        )
        let admit = Set(directive.admit)
        let cancel = Set(directive.cancel)
        let retain = Set(directive.retain)
        XCTAssertTrue(admit.isDisjoint(with: cancel))
        XCTAssertTrue(admit.isDisjoint(with: retain))
        XCTAssertTrue(cancel.isDisjoint(with: retain))
        XCTAssertEqual(directive.admit, directive.admit.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(directive.cancel, directive.cancel.sorted { $0.rawValue < $1.rawValue })
    }

    /// Determinism, asserted across two *independently constructed* planners
    /// rather than by calling the same one twice — the latter would pass for
    /// any implementation whose state happened not to change.
    func testTwoFreshPlannersProduceIdenticalDirectivesForTheSameScript() async {
        let script: [(Viewport, Int, Int)] = [
            (.coverDisplay, 0, 0),
            (.innerDisplay, 0, 250),
            (.coverDisplay, 5, 500),
            (.innerDisplay, 5, 700),
            (.innerDisplay, 40, 2_500)
        ]

        func run() async -> [ReplanDirective] {
            let planner = makePlanner(items: 120, ledgerCapacity: 18)
            var out: [ReplanDirective] = []
            for (viewport, anchor, time) in script {
                out.append(
                    await planner.apply(
                        SurfaceInput(viewport: viewport, anchor: anchor, selection: selection),
                        at: at(time)
                    )
                )
            }
            return out
        }

        let first = await run()
        let second = await run()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.allSatisfy(\.isNoOp), "the script does real work, so equality is meaningful")
    }
}
