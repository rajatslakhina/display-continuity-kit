// ContinuityDemoModel.swift
//
// The SwiftUI half is deliberately thin. Every decision it displays was already
// made — and unit-tested — in `DisplayContinuity`. The view's only job is to
// make the re-plan legible.
//
// The whole file is behind `#if canImport(SwiftUI)` so the package still
// compiles and tests cleanly on Linux CI, where the core is fully exercised.

#if canImport(SwiftUI)
import Foundation
import Observation
import DisplayContinuity

/// Drives a real `ContinuityPlanner` from UI events.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
@Observable
public final class ContinuityDemoModel {

    /// A row rendered by the demo list.
    public struct Row: Identifiable, Sendable, Hashable {
        public let id: ItemID
        public let index: Int
        public var title: String { "Item \(index)" }
    }

    public private(set) var displayClass: DisplayClass
    public private(set) var plan: CapacityPlan
    public private(set) var lastDirective: ReplanDirective?
    public private(set) var stormSummary: String?
    public private(set) var stormPassed: Bool?
    public private(set) var selection: ItemID?
    /// What the current display class renders, projected from the one
    /// surface-scoped source of truth. Recomputed on every re-plan.
    public private(set) var projection: PaneProjection = PaneProjection(
        listSelection: nil,
        detail: nil,
        showsDetailPane: false
    )
    public private(set) var rows: [Row]
    /// Cumulative count of work retained rather than restarted.
    public private(set) var totalRetained: Int = 0
    /// Cumulative count of work actually started.
    public private(set) var totalAdmitted: Int = 0

    private let planner: ContinuityPlanner
    private let store: SurfaceStore
    private let surface = SurfaceID("demo.feed")
    private let resolver = MinimumEdgeDisplayClassResolver()
    private let policy = AreaProportionalCapacityPolicy()
    private let ledgerCapacity: Int
    private var clock: MonotonicInstant = .zero
    private var anchor: Int = 0

    /// - Parameters:
    ///   - fallbackPlan: the compiled-in budget shown before the first re-plan.
    ///     The host app owns this value — it is the one piece of policy that
    ///     ships in the binary rather than being derived at runtime.
    ///   - itemCount: how many rows the demo feed contains.
    public init(fallbackPlan: CapacityPlan = .conservative, itemCount: Int = 40, ledgerCapacity: Int = 48) {
        let count = max(0, itemCount)
        self.plan = fallbackPlan
        self.displayClass = fallbackPlan.displayClass
        self.ledgerCapacity = max(1, ledgerCapacity)
        self.rows = (0 ..< count).map { Row(id: ItemID("item-\($0)"), index: $0) }
        self.store = SurfaceStore(capacity: 8)
        self.planner = ContinuityPlanner(
            initialViewport: .coverDisplay,
            policy: AreaProportionalCapacityPolicy(),
            resolver: MinimumEdgeDisplayClassResolver(),
            demandModel: WindowedDemandModel(itemCount: count),
            ledgerCapacity: max(1, ledgerCapacity),
            coalesceWindowMilliseconds: 1_200
        )
    }

    private var currentViewport: Viewport {
        displayClass == .expanded ? .innerDisplay : .coverDisplay
    }

    /// Runs an initial plan so the screen is never empty on first appearance.
    public func start() async {
        // Seed a selection so the detail pane has something to show the moment
        // the surface expands — which is the behaviour the demo is about.
        if selection == nil, let first = rows.first {
            selection = first.id
            await store.select(first.id, in: surface)
        }
        await replan(viewport: .coverDisplay, advancing: 0)
    }

    public func select(_ item: ItemID) async {
        selection = item
        await store.select(item, in: surface)
        await replan(viewport: currentViewport, advancing: 16)
    }

    /// Moves the scroll anchor. Re-plans *within* the current epoch: scrolling
    /// changes what is wanted without changing the budget.
    public func scroll(to index: Int) async {
        anchor = Saturating.clamp(index, lower: 0, upper: max(0, rows.count - 1))
        await store.setAnchor(anchor, in: surface)
        await replan(viewport: currentViewport, advancing: 16)
    }

    /// The headline interaction: change the display class and watch the diff.
    ///
    /// `displayClass` is updated **synchronously, before the first `await`**.
    /// Every button in the view spawns an unstructured `Task`, so two quick
    /// taps run concurrently; updating after the suspension would let the
    /// second tap read a stale class and resolve to the same target as the
    /// first, which looks like a dead button.
    public func setDisplayClass(_ newValue: DisplayClass) async {
        guard newValue != displayClass else { return }
        displayClass = newValue
        let viewport: Viewport = newValue == .expanded ? .innerDisplay : .coverDisplay
        await replan(viewport: viewport, advancing: 250)
    }

    public func toggleFold() async {
        await setDisplayClass(displayClass == .expanded ? .compact : .expanded)
    }

    /// Advances past the coalescing window so held cancellations are issued.
    public func settle() async {
        clock = clock.advanced(byMilliseconds: 1_500)
        let directive = await planner.tick(at: clock)
        absorb(directive)
    }

    /// Replays a deterministic fold storm and reports whether the invariants held.
    public func runStorm() async {
        let selected = selection
        let steps: [StormStep] = [
            .unfold(anchor: 0, selection: selected, after: 200),
            .fold(anchor: 0, selection: selected, after: 180),
            .unfold(anchor: 0, selection: selected, after: 150),
            .fold(anchor: 4, selection: selected, after: 120),
            .unfold(anchor: 4, selection: selected, after: 90),
            .unfold(anchor: 8, selection: selected, after: 2_000),
            .fold(anchor: 8, selection: selected, after: 2_000),
            .fold(anchor: 8, selection: selected, after: 2_000)
        ]
        let stormPlanner = ContinuityPlanner(
            initialViewport: .coverDisplay,
            policy: policy,
            resolver: resolver,
            demandModel: WindowedDemandModel(itemCount: rows.count),
            ledgerCapacity: ledgerCapacity,
            coalesceWindowMilliseconds: 1_200
        )
        let driver = FoldStormDriver(inFlightBound: ledgerCapacity)
        let report = await driver.run(steps, against: stormPlanner)
        stormPassed = report.passed
        let ratio = Int((report.continuityRatio * 100).rounded())
        if report.passed {
            stormSummary = "\(steps.count) transitions · \(report.totalAdmissions) started · "
                + "\(report.retentionCount) retained (\(ratio)% continuity) · 0 violations"
        } else {
            let first = report.violations.first.map(String.init(describing:)) ?? "unknown"
            stormSummary = "\(report.violations.count) violation(s) — first: \(first)"
        }
    }

    public func row(for item: ItemID) -> Row? {
        rows.first { $0.id == item }
    }

    // MARK: - Private

    private func replan(viewport: Viewport, advancing milliseconds: Int) async {
        // Advance and capture in one main-actor step, with no `await` between
        // them. Concurrent callers therefore each get a distinct, increasing
        // instant; reading `clock` again after the suspension would let two
        // in-flight re-plans hand the planner out-of-order timestamps.
        clock = clock.advanced(byMilliseconds: milliseconds)
        let instant = clock
        let resolved = resolver.displayClass(for: viewport)
        let input = SurfaceInput(viewport: viewport, anchor: anchor, selection: selection)

        let directive = await planner.apply(input, at: instant)
        let projection = await store.projection(for: surface, displayClass: resolved)

        displayClass = resolved
        self.projection = projection
        absorb(directive)
    }

    private func absorb(_ directive: ReplanDirective) {
        lastDirective = directive
        plan = directive.plan
        totalRetained += directive.retain.count
        totalAdmitted += directive.admit.count
    }
}
#endif
// ContinuityDemoModel.swift
//
// The SwiftUI half is deliberately thin. Every decision it displays was already
// made — and unit-tested — in `DisplayContinuity`. The view's only job is to
// make the re-plan legible.
//
// The whole file is behind `#if canImport(SwiftUI)` so the package still
// compiles and tests cleanly on Linux CI, where the core is fully exercised.

#if canImport(SwiftUI)
import Foundation
import Observation
import DisplayContinuity

/// Drives a real `ContinuityPlanner` from UI events.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
@Observable
public final class ContinuityDemoModel {

    /// A row rendered by the demo list.
    public struct Row: Identifiable, Sendable, Hashable {
        public let id: ItemID
        public let index: Int
        public var title: String { "Item \(index)" }
    }

    public private(set) var displayClass: DisplayClass
    public private(set) var plan: CapacityPlan
    public private(set) var lastDirective: ReplanDirective?
    public private(set) var stormSummary: String?
    public private(set) var stormPassed: Bool?
    public private(set) var selection: ItemID?
    /// What the current display class renders, projected from the one
    /// surface-scoped source of truth. Recomputed on every re-plan.
    public private(set) var projection: PaneProjection = PaneProjection(
        listSelection: nil,
        detail: nil,
        showsDetailPane: false
    )
    public private(set) var rows: [Row]
    /// Cumulative count of work retained rather than restarted.
    public private(set) var totalRetained: Int = 0
    /// Cumulative count of work actually started.
    public private(set) var totalAdmitted: Int = 0

    private let planner: ContinuityPlanner
    private let store: SurfaceStore
    private let surface = SurfaceID("demo.feed")
    private let resolver = MinimumEdgeDisplayClassResolver()
    private let policy = AreaProportionalCapacityPolicy()
    private let ledgerCapacity: Int
    private var clock: MonotonicInstant = .zero
    private var anchor: Int = 0

    /// - Parameters:
    ///   - fallbackPlan: the compiled-in budget shown before the first re-plan.
    ///     The host app owns this value — it is the one piece of policy that
    ///     ships in the binary rather than being derived at runtime.
    ///   - itemCount: how many rows the demo feed contains.
    public init(fallbackPlan: CapacityPlan = .conservative, itemCount: Int = 40, ledgerCapacity: Int = 48) {
        let count = max(0, itemCount)
        self.plan = fallbackPlan
        self.displayClass = fallbackPlan.displayClass
        self.ledgerCapacity = max(1, ledgerCapacity)
        self.rows = (0 ..< count).map { Row(id: ItemID("item-\($0)"), index: $0) }
        self.store = SurfaceStore(capacity: 8)
        self.planner = ContinuityPlanner(
            initialViewport: .coverDisplay,
            policy: AreaProportionalCapacityPolicy(),
            resolver: MinimumEdgeDisplayClassResolver(),
            demandModel: WindowedDemandModel(itemCount: count),
            ledgerCapacity: max(1, ledgerCapacity),
            coalesceWindowMilliseconds: 1_200
        )
    }

    private var currentViewport: Viewport {
        displayClass == .expanded ? .innerDisplay : .coverDisplay
    }

    /// Runs an initial plan so the screen is never empty on first appearance.
    public func start() async {
        // Seed a selection so the detail pane has something to show the moment
        // the surface expands — which is the behaviour the demo is about.
        if selection == nil, let first = rows.first {
            selection = first.id
            await store.select(first.id, in: surface)
        }
        await replan(viewport: .coverDisplay, advancing: 0)
    }

    public func select(_ item: ItemID) async {
        selection = item
        await store.select(item, in: surface)
        await replan(viewport: currentViewport, advancing: 16)
    }

    /// Moves the scroll anchor. Re-plans *within* the current epoch: scrolling
    /// changes what is wanted without changing the budget.
    public func scroll(to index: Int) async {
        anchor = Saturating.clamp(index, lower: 0, upper: max(0, rows.count - 1))
        await store.setAnchor(anchor, in: surface)
        await replan(viewport: currentViewport, advancing: 16)
    }

    /// The headline interaction: change the display class and watch the diff.
    public func setDisplayClass(_ newValue: DisplayClass) async {
        let viewport: Viewport = newValue == .expanded ? .innerDisplay : .coverDisplay
        await replan(viewport: viewport, advancing: 250)
    }

    public func toggleFold() async {
        await setDisplayClass(displayClass == .expanded ? .compact : .expanded)
    }

    /// Advances past the coalescing window so held cancellations are issued.
    public func settle() async {
        clock = clock.advanced(byMilliseconds: 1_500)
        let directive = await planner.tick(at: clock)
        absorb(directive)
    }

    /// Replays a deterministic fold storm and reports whether the invariants held.
    public func runStorm() async {
        let selected = selection
        let steps: [StormStep] = [
            .unfold(anchor: 0, selection: selected, after: 200),
            .fold(anchor: 0, selection: selected, after: 180),
            .unfold(anchor: 0, selection: selected, after: 150),
            .fold(anchor: 4, selection: selected, after: 120),
            .unfold(anchor: 4, selection: selected, after: 90),
            .unfold(anchor: 8, selection: selected, after: 2_000),
            .fold(anchor: 8, selection: selected, after: 2_000),
            .fold(anchor: 8, selection: selected, after: 2_000)
        ]
        let stormPlanner = ContinuityPlanner(
            initialViewport: .coverDisplay,
            policy: policy,
            resolver: resolver,
            demandModel: WindowedDemandModel(itemCount: rows.count),
            ledgerCapacity: ledgerCapacity,
            coalesceWindowMilliseconds: 1_200
        )
        let driver = FoldStormDriver(inFlightBound: ledgerCapacity)
        let report = await driver.run(steps, against: stormPlanner)
        stormPassed = report.passed
        let ratio = Int((report.continuityRatio * 100).rounded())
        if report.passed {
            stormSummary = "\(steps.count) transitions · \(report.totalAdmissions) started · "
                + "\(report.retentionCount) retained (\(ratio)% continuity) · 0 violations"
        } else {
            let first = report.violations.first.map(String.init(describing:)) ?? "unknown"
            stormSummary = "\(report.violations.count) violation(s) — first: \(first)"
        }
    }

    public func row(for item: ItemID) -> Row? {
        rows.first { $0.id == item }
    }

    // MARK: - Private

    private func replan(viewport: Viewport, advancing milliseconds: Int) async {
        clock = clock.advanced(byMilliseconds: milliseconds)
        let input = SurfaceInput(viewport: viewport, anchor: anchor, selection: selection)
        let directive = await planner.apply(input, at: clock)
        displayClass = resolver.displayClass(for: viewport)
        projection = await store.projection(for: surface, displayClass: displayClass)
        absorb(directive)
    }

    private func absorb(_ directive: ReplanDirective) {
        lastDirective = directive
        plan = directive.plan
        totalRetained += directive.retain.count
        totalAdmitted += directive.admit.count
    }
}
#endif
