import XCTest
@testable import DisplayContinuity

// MARK: - Deliberately broken planners
//
// The README claims `FoldStormDriver` catches duplicated fetches, torn state
// and unbounded growth. A checker that has only ever been pointed at a correct
// implementation has not been shown to catch anything at all — so each mutant
// below breaks exactly one invariant, and each has a test asserting the driver
// goes *red* for it. If someone gutted the driver's checks, this file fails.

/// Emits the whole desired set as `admit` on every observation and never
/// cancels — i.e. treats a re-plan as "here is the new state, go fetch it".
/// This is the realistic bug, and the one `ReplanDirective.retain` exists to
/// prevent.
private actor NaiveRestartPlanner: ContinuityPlanning {
    private let itemCount: Int
    private var epoch: Epoch = .initial
    private var plan: CapacityPlan = .conservative

    init(itemCount: Int) { self.itemCount = max(0, itemCount) }

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        epoch = epoch.next()
        let resolver = MinimumEdgeDisplayClassResolver()
        let displayClass = resolver.displayClass(for: input.viewport)
        plan = AreaProportionalCapacityPolicy().plan(for: displayClass, viewport: input.viewport)
        let demand = WindowedDemandModel(itemCount: itemCount)
            .demand(for: plan, anchor: input.anchor, selection: input.selection)
        // Everything, every time, with nothing retained and nothing cancelled.
        return ReplanDirective(epoch: epoch, plan: plan, admit: demand.map(\.key), cancel: [], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: epoch, plan: plan, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: epoch, plan: plan, inFlight: [], deferredCancellations: [])
    }
}

/// Emits the same key in both `admit` and `cancel` in one directive.
private actor ChurningPlanner: ContinuityPlanning {
    private var epoch: Epoch = .initial

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        epoch = epoch.next()
        let key = WorkKey("row:0")
        return ReplanDirective(epoch: epoch, plan: .conservative, admit: [key], cancel: [key], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: epoch, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: epoch, plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

/// Walks the epoch backwards, which would make stale work look current.
private actor RegressingEpochPlanner: ContinuityPlanning {
    private var step = 0

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        step += 1
        let epoch = step == 1 ? Epoch(5) : Epoch(1)
        return ReplanDirective(epoch: epoch, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: Epoch(1), plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: Epoch(1), plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

/// Admits without bound — the fold-storm OOM.
private actor UnboundedPlanner: ContinuityPlanning {
    private var counter = 0

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        var admitted: [WorkKey] = []
        for _ in 0 ..< 10 {
            admitted.append(WorkKey("row:\(counter)"))
            counter += 1
        }
        return ReplanDirective(epoch: .initial, plan: .conservative, admit: admitted, cancel: [], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: .initial, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: .initial, plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

/// Reports work as retained that it already cancelled — a lie that reads as a
/// continuity win in a metrics dashboard while the content never arrives.
private actor LyingRetainPlanner: ContinuityPlanning {
    private var step = 0

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        step += 1
        let key = WorkKey("row:0")
        if step == 1 {
            return ReplanDirective(epoch: .initial, plan: .conservative, admit: [key], cancel: [], retain: [])
        }
        // Cancel it and simultaneously claim it is still in flight.
        return ReplanDirective(epoch: .initial, plan: .conservative, admit: [], cancel: [key], retain: [key])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: .initial, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: .initial, plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

// MARK: - Tests

final class FoldStormDriverTests: XCTestCase {

    private let selection = ItemID("i0")

    private var storm: [StormStep] {
        [
            .unfold(anchor: 0, selection: selection, after: 200),
            .fold(anchor: 0, selection: selection, after: 180),
            .unfold(anchor: 0, selection: selection, after: 150),
            .fold(anchor: 4, selection: selection, after: 120),
            .unfold(anchor: 4, selection: selection, after: 90),
            .unfold(anchor: 8, selection: selection, after: 2_000),
            .fold(anchor: 8, selection: selection, after: 2_000),
            .fold(anchor: 8, selection: selection, after: 2_000)
        ]
    }

    private func realPlanner(items: Int = 40, capacity: Int = 64) -> ContinuityPlanner {
        ContinuityPlanner(
            initialViewport: .coverDisplay,
            policy: AreaProportionalCapacityPolicy(),
            resolver: MinimumEdgeDisplayClassResolver(),
            demandModel: WindowedDemandModel(itemCount: items),
            ledgerCapacity: capacity,
            coalesceWindowMilliseconds: 1_200
        )
    }

    // MARK: - The real planner passes

    func testRealPlannerSurvivesAFoldStorm() async {
        let report = await FoldStormDriver(inFlightBound: 64).run(storm, against: realPlanner())
        XCTAssertTrue(
            report.passed,
            "violations: \(report.violations.map(\.description).joined(separator: "; "))"
        )
        XCTAssertEqual(report.directives.count, storm.count)
        XCTAssertGreaterThan(report.retentionCount, 0, "the storm must actually exercise retention")
    }

    func testRealPlannerRetainsFarMoreWorkThanItRestarts() async {
        let report = await FoldStormDriver(inFlightBound: 64).run(storm, against: realPlanner())
        XCTAssertGreaterThan(
            report.continuityRatio,
            0.75,
            "an 8-transition storm should keep most work; got \(report.continuityRatio)"
        )
        XCTAssertLessThan(
            report.totalAdmissions,
            report.retentionCount,
            "more work retained than started — that is the point of the layer"
        )
    }

    func testRealPlannerStaysInsideItsBoundUnderAStorm() async {
        let report = await FoldStormDriver(inFlightBound: 12).run(
            storm,
            against: realPlanner(items: 500, capacity: 12)
        )
        XCTAssertTrue(report.passed, "violations: \(report.violations.map(\.description))")
    }

    func testEmptyStormIsAVacuousPassNotACrash() async {
        let report = await FoldStormDriver().run([], against: realPlanner())
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.directives.isEmpty)
        XCTAssertEqual(report.continuityRatio, 1.0)
    }

    // MARK: - Mutation tests: each mutant must make the driver go red

    func testDriverCatchesDuplicatedFetches() async {
        let report = await FoldStormDriver(inFlightBound: 1_000).run(
            storm,
            against: NaiveRestartPlanner(itemCount: 40)
        )
        XCTAssertFalse(report.passed, "a planner that re-issues in-flight work must not pass")
        let duplicates = report.violations.filter {
            if case .duplicateAdmission = $0 { return true }
            return false
        }
        XCTAssertFalse(duplicates.isEmpty, "the duplicate-admission check did not fire")
    }

    func testDriverCatchesAdmitAndCancelInTheSameDirective() async {
        let report = await FoldStormDriver().run(storm, against: ChurningPlanner())
        XCTAssertFalse(report.passed)
        XCTAssertTrue(
            report.violations.contains(.admitAndCancelInSameDirective(WorkKey("row:0"))),
            "got: \(report.violations.map(\.description))"
        )
    }

    func testDriverCatchesCancellingWorkThatWasNeverStarted() async {
        let report = await FoldStormDriver().run(storm, against: ChurningPlanner())
        XCTAssertTrue(
            report.violations.contains(.cancelWithoutAdmission(WorkKey("row:0"))),
            "got: \(report.violations.map(\.description))"
        )
    }

    func testDriverCatchesEpochRegression() async {
        let report = await FoldStormDriver().run(storm, against: RegressingEpochPlanner())
        XCTAssertFalse(report.passed)
        XCTAssertTrue(
            report.violations.contains(.epochRegression(from: Epoch(5), to: Epoch(1))),
            "got: \(report.violations.map(\.description))"
        )
    }

    func testDriverCatchesUnboundedInFlightGrowth() async {
        let report = await FoldStormDriver(inFlightBound: 20).run(storm, against: UnboundedPlanner())
        XCTAssertFalse(report.passed)
        let boundViolations = report.violations.filter {
            if case .ledgerExceededBound = $0 { return true }
            return false
        }
        XCTAssertFalse(boundViolations.isEmpty, "the bound check did not fire")
    }

    func testDriverCatchesAPlannerThatLiesAboutRetention() async {
        let report = await FoldStormDriver().run(storm, against: LyingRetainPlanner())
        XCTAssertFalse(report.passed, "claiming cancelled work is retained must not pass")
        XCTAssertTrue(
            report.violations.contains(.retentionLie(WorkKey("row:0"))),
            "a retention lie must be diagnosed as one, not as a duplicate admission; got: "
                + report.violations.map(\.description).joined(separator: "; ")
        )
    }

    /// The scenario an earlier revision of `ContinuityPlanner` failed: the user
    /// folds, opening the deferral window, and then keeps scrolling.
    ///
    /// Cancellations are held across every one of those re-plans, so any key
    /// that leaves the ledger while held used to be cancelled twice — once as
    /// an eviction, once again on settle — and the held set grew without bound.
    func testRealPlannerSurvivesAScrollDuringDeferral() async {
        let capacity = 24
        let planner = ContinuityPlanner(
            initialViewport: .coverDisplay,
            demandModel: WindowedDemandModel(itemCount: 5_000),
            ledgerCapacity: capacity,
            coalesceWindowMilliseconds: 1_200
        )
        let steps: [StormStep] = [
            .unfold(anchor: 0, selection: selection, after: 200),
            .fold(anchor: 0, selection: selection, after: 100),
            .fold(anchor: 40, selection: selection, after: 60),
            .fold(anchor: 80, selection: selection, after: 60),
            .fold(anchor: 120, selection: selection, after: 60),
            .fold(anchor: 160, selection: selection, after: 60),
            .fold(anchor: 200, selection: selection, after: 60),
            .fold(anchor: 200, selection: selection, after: 1_500)
        ]
        let report = await FoldStormDriver(inFlightBound: capacity).run(steps, against: planner)
        XCTAssertTrue(
            report.passed,
            "violations: " + report.violations.map(\.description).joined(separator: "; ")
        )
    }

    /// Guards the guard: if every mutant somehow passed, the checks above would
    /// still be green individually but the suite would be meaningless. This
    /// asserts the driver discriminates — real passes, all five mutants fail.
    func testDriverDiscriminatesBetweenCorrectAndBrokenPlanners() async {
        // Bound matches the real planner's own `ledgerCapacity` default (64).
        // An earlier version used 20, which happened to equal the real
        // planner's exact peak for this storm — one tweak to `rowHeight` or the
        // reference viewports away from a false red for reasons that have
        // nothing to do with discrimination.
        let driver = FoldStormDriver(inFlightBound: 64)
        let realReport = await driver.run(storm, against: realPlanner())
        XCTAssertTrue(realReport.passed)

        var mutantResults: [Bool] = []
        mutantResults.append(await driver.run(storm, against: NaiveRestartPlanner(itemCount: 40)).passed)
        mutantResults.append(await driver.run(storm, against: ChurningPlanner()).passed)
        mutantResults.append(await driver.run(storm, against: RegressingEpochPlanner()).passed)
        mutantResults.append(await driver.run(storm, against: UnboundedPlanner()).passed)
        mutantResults.append(await driver.run(storm, against: LyingRetainPlanner()).passed)

        XCTAssertEqual(
            mutantResults,
            [false, false, false, false, false],
            "every deliberately broken planner must fail the harness"
        )
    }

    // MARK: - Report arithmetic

    func testContinuityRatioIsWellDefinedForAStormThatStartsNothing() async {
        let report = await FoldStormDriver().run(
            [.fold(after: 0)],
            against: realPlanner(items: 0)
        )
        XCTAssertEqual(report.continuityRatio, 1.0, "0/0 must not be a NaN or a trap")
        XCTAssertEqual(report.totalAdmissions, 0)
    }

    func testStormStepClampsNegativeTimeAdvances() {
        let step = StormStep(input: SurfaceInput(viewport: .coverDisplay), advanceMilliseconds: -500)
        XCTAssertEqual(step.advanceMilliseconds, 0)
    }
}
import XCTest
@testable import DisplayContinuity

// MARK: - Deliberately broken planners
//
// The README claims `FoldStormDriver` catches duplicated fetches, torn state
// and unbounded growth. A checker that has only ever been pointed at a correct
// implementation has not been shown to catch anything at all — so each mutant
// below breaks exactly one invariant, and each has a test asserting the driver
// goes *red* for it. If someone gutted the driver's checks, this file fails.

/// Emits the whole desired set as `admit` on every observation and never
/// cancels — i.e. treats a re-plan as "here is the new state, go fetch it".
/// This is the realistic bug, and the one `ReplanDirective.retain` exists to
/// prevent.
private actor NaiveRestartPlanner: ContinuityPlanning {
    private let itemCount: Int
    private var epoch: Epoch = .initial
    private var plan: CapacityPlan = .conservative

    init(itemCount: Int) { self.itemCount = max(0, itemCount) }

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        epoch = epoch.next()
        let resolver = MinimumEdgeDisplayClassResolver()
        let displayClass = resolver.displayClass(for: input.viewport)
        plan = AreaProportionalCapacityPolicy().plan(for: displayClass, viewport: input.viewport)
        let demand = WindowedDemandModel(itemCount: itemCount)
            .demand(for: plan, anchor: input.anchor, selection: input.selection)
        // Everything, every time, with nothing retained and nothing cancelled.
        return ReplanDirective(epoch: epoch, plan: plan, admit: demand.map(\.key), cancel: [], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: epoch, plan: plan, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: epoch, plan: plan, inFlight: [], deferredCancellations: [])
    }
}

/// Emits the same key in both `admit` and `cancel` in one directive.
private actor ChurningPlanner: ContinuityPlanning {
    private var epoch: Epoch = .initial

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        epoch = epoch.next()
        let key = WorkKey("row:0")
        return ReplanDirective(epoch: epoch, plan: .conservative, admit: [key], cancel: [key], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: epoch, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: epoch, plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

/// Walks the epoch backwards, which would make stale work look current.
private actor RegressingEpochPlanner: ContinuityPlanning {
    private var step = 0

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        step += 1
        let epoch = step == 1 ? Epoch(5) : Epoch(1)
        return ReplanDirective(epoch: epoch, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: Epoch(1), plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: Epoch(1), plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

/// Admits without bound — the fold-storm OOM.
private actor UnboundedPlanner: ContinuityPlanning {
    private var counter = 0

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        var admitted: [WorkKey] = []
        for _ in 0 ..< 10 {
            admitted.append(WorkKey("row:\(counter)"))
            counter += 1
        }
        return ReplanDirective(epoch: .initial, plan: .conservative, admit: admitted, cancel: [], retain: [])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: .initial, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: .initial, plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

/// Reports work as retained that it already cancelled — a lie that reads as a
/// continuity win in a metrics dashboard while the content never arrives.
private actor LyingRetainPlanner: ContinuityPlanning {
    private var step = 0

    func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        step += 1
        let key = WorkKey("row:0")
        if step == 1 {
            return ReplanDirective(epoch: .initial, plan: .conservative, admit: [key], cancel: [], retain: [])
        }
        // Cancel it and simultaneously claim it is still in flight.
        return ReplanDirective(epoch: .initial, plan: .conservative, admit: [], cancel: [key], retain: [key])
    }

    func tick(at now: MonotonicInstant) -> ReplanDirective {
        ReplanDirective(epoch: .initial, plan: .conservative, admit: [], cancel: [], retain: [])
    }

    func snapshotState() -> PlannerState {
        PlannerState(epoch: .initial, plan: .conservative, inFlight: [], deferredCancellations: [])
    }
}

// MARK: - Tests

final class FoldStormDriverTests: XCTestCase {

    private let selection = ItemID("i0")

    private var storm: [StormStep] {
        [
            .unfold(anchor: 0, selection: selection, after: 200),
            .fold(anchor: 0, selection: selection, after: 180),
            .unfold(anchor: 0, selection: selection, after: 150),
            .fold(anchor: 4, selection: selection, after: 120),
            .unfold(anchor: 4, selection: selection, after: 90),
            .unfold(anchor: 8, selection: selection, after: 2_000),
            .fold(anchor: 8, selection: selection, after: 2_000),
            .fold(anchor: 8, selection: selection, after: 2_000)
        ]
    }

    private func realPlanner(items: Int = 40, capacity: Int = 64) -> ContinuityPlanner {
        ContinuityPlanner(
            initialViewport: .coverDisplay,
            policy: AreaProportionalCapacityPolicy(),
            resolver: MinimumEdgeDisplayClassResolver(),
            demandModel: WindowedDemandModel(itemCount: items),
            ledgerCapacity: capacity,
            coalesceWindowMilliseconds: 1_200
        )
    }

    // MARK: - The real planner passes

    func testRealPlannerSurvivesAFoldStorm() async {
        let report = await FoldStormDriver(inFlightBound: 64).run(storm, against: realPlanner())
        XCTAssertTrue(
            report.passed,
            "violations: \(report.violations.map(\.description).joined(separator: "; "))"
        )
        XCTAssertEqual(report.directives.count, storm.count)
        XCTAssertGreaterThan(report.retentionCount, 0, "the storm must actually exercise retention")
    }

    func testRealPlannerRetainsFarMoreWorkThanItRestarts() async {
        let report = await FoldStormDriver(inFlightBound: 64).run(storm, against: realPlanner())
        XCTAssertGreaterThan(
            report.continuityRatio,
            0.75,
            "an 8-transition storm should keep most work; got \(report.continuityRatio)"
        )
        XCTAssertLessThan(
            report.totalAdmissions,
            report.retentionCount,
            "more work retained than started — that is the point of the layer"
        )
    }

    func testRealPlannerStaysInsideItsBoundUnderAStorm() async {
        let report = await FoldStormDriver(inFlightBound: 12).run(
            storm,
            against: realPlanner(items: 500, capacity: 12)
        )
        XCTAssertTrue(report.passed, "violations: \(report.violations.map(\.description))")
    }

    func testEmptyStormIsAVacuousPassNotACrash() async {
        let report = await FoldStormDriver().run([], against: realPlanner())
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.directives.isEmpty)
        XCTAssertEqual(report.continuityRatio, 1.0)
    }

    // MARK: - Mutation tests: each mutant must make the driver go red

    func testDriverCatchesDuplicatedFetches() async {
        let report = await FoldStormDriver(inFlightBound: 1_000).run(
            storm,
            against: NaiveRestartPlanner(itemCount: 40)
        )
        XCTAssertFalse(report.passed, "a planner that re-issues in-flight work must not pass")
        let duplicates = report.violations.filter {
            if case .duplicateAdmission = $0 { return true }
            return false
        }
        XCTAssertFalse(duplicates.isEmpty, "the duplicate-admission check did not fire")
    }

    func testDriverCatchesAdmitAndCancelInTheSameDirective() async {
        let report = await FoldStormDriver().run(storm, against: ChurningPlanner())
        XCTAssertFalse(report.passed)
        XCTAssertTrue(
            report.violations.contains(.admitAndCancelInSameDirective(WorkKey("row:0"))),
            "got: \(report.violations.map(\.description))"
        )
    }

    func testDriverCatchesCancellingWorkThatWasNeverStarted() async {
        let report = await FoldStormDriver().run(storm, against: ChurningPlanner())
        XCTAssertTrue(
            report.violations.contains(.cancelWithoutAdmission(WorkKey("row:0"))),
            "got: \(report.violations.map(\.description))"
        )
    }

    func testDriverCatchesEpochRegression() async {
        let report = await FoldStormDriver().run(storm, against: RegressingEpochPlanner())
        XCTAssertFalse(report.passed)
        XCTAssertTrue(
            report.violations.contains(.epochRegression(from: Epoch(5), to: Epoch(1))),
            "got: \(report.violations.map(\.description))"
        )
    }

    func testDriverCatchesUnboundedInFlightGrowth() async {
        let report = await FoldStormDriver(inFlightBound: 20).run(storm, against: UnboundedPlanner())
        XCTAssertFalse(report.passed)
        let boundViolations = report.violations.filter {
            if case .ledgerExceededBound = $0 { return true }
            return false
        }
        XCTAssertFalse(boundViolations.isEmpty, "the bound check did not fire")
    }

    func testDriverCatchesAPlannerThatLiesAboutRetention() async {
        let report = await FoldStormDriver().run(storm, against: LyingRetainPlanner())
        XCTAssertFalse(report.passed, "claiming cancelled work is retained must not pass")
    }

    /// Guards the guard: if every mutant somehow passed, the checks above would
    /// still be green individually but the suite would be meaningless. This
    /// asserts the driver discriminates — real passes, all five mutants fail.
    func testDriverDiscriminatesBetweenCorrectAndBrokenPlanners() async {
        let driver = FoldStormDriver(inFlightBound: 20)
        let realReport = await driver.run(storm, against: realPlanner())
        XCTAssertTrue(realReport.passed)

        var mutantResults: [Bool] = []
        mutantResults.append(await driver.run(storm, against: NaiveRestartPlanner(itemCount: 40)).passed)
        mutantResults.append(await driver.run(storm, against: ChurningPlanner()).passed)
        mutantResults.append(await driver.run(storm, against: RegressingEpochPlanner()).passed)
        mutantResults.append(await driver.run(storm, against: UnboundedPlanner()).passed)
        mutantResults.append(await driver.run(storm, against: LyingRetainPlanner()).passed)

        XCTAssertEqual(
            mutantResults,
            [false, false, false, false, false],
            "every deliberately broken planner must fail the harness"
        )
    }

    // MARK: - Report arithmetic

    func testContinuityRatioIsWellDefinedForAStormThatStartsNothing() async {
        let report = await FoldStormDriver().run(
            [.fold(after: 0)],
            against: realPlanner(items: 0)
        )
        XCTAssertEqual(report.continuityRatio, 1.0, "0/0 must not be a NaN or a trap")
        XCTAssertEqual(report.totalAdmissions, 0)
    }

    func testStormStepClampsNegativeTimeAdvances() {
        let step = StormStep(input: SurfaceInput(viewport: .coverDisplay), advanceMilliseconds: -500)
        XCTAssertEqual(step.advanceMilliseconds, 0)
    }
}
