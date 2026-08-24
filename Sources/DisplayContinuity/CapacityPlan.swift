// CapacityPlan.swift
//
// The unfold is not a layout event. It is a *capacity* event.
//
// Viewport area roughly doubles, a detail pane demands content nobody
// requested, and the prefetch depth and decode budgets that were correct one
// frame ago are now wrong — while requests planned under the old budget are
// still in flight.
//
// A `CapacityPlan` is the derived budget for a display class: the single value
// feature modules read instead of asking what device they are on.

/// The resource budget a surface is entitled to at its current display class.
///
/// Every field is guaranteed non-negative, and `concurrentDecodes` is
/// guaranteed at least `1` — a budget of zero decoders is a deadlock, not a
/// conservative setting.
public struct CapacityPlan: Sendable, Hashable, Codable {
    public let displayClass: DisplayClass
    /// Rows expected to be on screen at once.
    public let visibleWindow: Int
    /// Rows beyond the visible window to fetch ahead of the user.
    public let prefetchDepth: Int
    /// Maximum image decodes permitted to run concurrently.
    public let concurrentDecodes: Int
    /// Soft ceiling on decoded-image bytes held resident, in bytes.
    public let decodeByteBudget: Int

    public init(
        displayClass: DisplayClass,
        visibleWindow: Int,
        prefetchDepth: Int,
        concurrentDecodes: Int,
        decodeByteBudget: Int
    ) {
        self.displayClass = displayClass
        self.visibleWindow = max(0, visibleWindow)
        self.prefetchDepth = max(0, prefetchDepth)
        self.concurrentDecodes = max(1, concurrentDecodes)
        self.decodeByteBudget = max(0, decodeByteBudget)
    }

    /// Total rows the planner is willing to have in flight, centred on the
    /// scroll anchor. Saturating: two large budgets must not overflow into a
    /// negative window.
    public var admissionWindow: Int {
        Saturating.add(visibleWindow, Saturating.multiply(prefetchDepth, 2))
    }

    /// A conservative plan used before the first real layout pass, and as the
    /// compiled-in fallback a host app can ship.
    public static let conservative = CapacityPlan(
        displayClass: .compact,
        visibleWindow: 4,
        prefetchDepth: 2,
        concurrentDecodes: 2,
        decodeByteBudget: 8 * 1024 * 1024
    )
}

/// Derives a `CapacityPlan` from geometry.
///
/// A protocol because the *policy* is the part a host app should be able to
/// tune (a video app and a text feed do not want the same decode budget),
/// while the re-planning machinery that consumes it stays fixed.
public protocol CapacityPolicy: Sendable {
    func plan(for displayClass: DisplayClass, viewport: Viewport) -> CapacityPlan
}

/// Scales budgets with viewport area, with hard floors and ceilings.
///
/// Design decisions worth defending in review:
///
/// 1. **Prefetch depth scales sub-linearly with area** (√area, not area). The
///    unfolded surface shows roughly twice the rows, but the user's *scroll
///    velocity* does not double — so doubling prefetch depth as well would
///    buy latency the user never perceives at twice the network cost. Rejected
///    alternative: linear scaling, which is simpler and measurably wasteful.
///
/// 2. **The decode budget is derived from admitted rows, not from area.**
///    Resident decoded bytes are bounded by the work the planner actually
///    admits — `(visibleWindow + prefetchDepth) × bytesPerRow` — so the budget
///    moves with the plan rather than with the glass. Rejected alternative:
///    scaling it by raw viewport area. The inner display is ~1.94× the area but
///    the planner only admits ~1.19× the rows, so an area-scaled budget would
///    authorise roughly 60% more resident bytes than the plan can ever produce.
///    A ceiling that never binds is not a budget.
///
/// 3. **`concurrentDecodes` is capped low** (`6`). Beyond a handful, decodes
///    stop being parallel and start being memory pressure — the unfold already
///    spikes resident bytes, and this is the wrong moment to add to it.
public struct AreaProportionalCapacityPolicy: CapacityPolicy {
    /// Approximate points of vertical extent one row occupies.
    public let rowHeight: Double
    /// Approximate decoded bytes attributable to one visible row.
    public let bytesPerRow: Int
    /// Hard ceiling on concurrent decodes regardless of surface size.
    public let maximumConcurrentDecodes: Int

    public init(
        rowHeight: Double = 96,
        bytesPerRow: Int = 512 * 1024,
        maximumConcurrentDecodes: Int = 6
    ) {
        // A non-positive or non-finite row height would make every derived
        // budget either zero or non-finite; fall back rather than propagate.
        self.rowHeight = rowHeight.isFinite && rowHeight > 0 ? rowHeight : 96
        self.bytesPerRow = max(1, bytesPerRow)
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
    }

    public func plan(for displayClass: DisplayClass, viewport: Viewport) -> CapacityPlan {
        // Rows down the primary column. `rowHeight` is guaranteed > 0 by init,
        // so this division cannot produce a non-finite value from a finite
        // numerator, and `Saturating.int` covers the rest.
        let rowsDown = Saturating.int((viewport.height / rowHeight).rounded(.down))

        // In `.expanded`, the primary list gets roughly the left third of a
        // near-square canvas; the detail pane takes the rest. So the *list*
        // does not get twice the rows — but the detail pane independently
        // demands content, which the planner accounts for via `detailDemand`.
        let listRows: Int
        switch displayClass {
        case .compact:
            listRows = rowsDown
        case .expanded:
            listRows = Saturating.scale(rowsDown, by: 1.15)
        }

        let visibleWindow = Saturating.clamp(listRows, lower: 1, upper: 200)

        // Sub-linear prefetch: √(area / referenceArea), clamped.
        let referenceArea = Viewport.coverDisplay.area
        let areaRatio = referenceArea > 0 ? viewport.area / referenceArea : 0
        // `areaRatio` is finite and >= 0 here, so `.squareRoot()` is finite.
        let prefetchScale = areaRatio.squareRoot()
        let prefetchDepth = Saturating.clamp(
            Saturating.scale(4, by: prefetchScale),
            lower: 1,
            upper: 32
        )

        let decodeByteBudget = Saturating.multiply(
            Saturating.add(visibleWindow, prefetchDepth),
            bytesPerRow
        )

        let concurrentDecodes = Saturating.clamp(
            Saturating.divide(visibleWindow, by: 3, fallback: 1),
            lower: 1,
            upper: maximumConcurrentDecodes
        )

        return CapacityPlan(
            displayClass: displayClass,
            visibleWindow: visibleWindow,
            prefetchDepth: prefetchDepth,
            concurrentDecodes: concurrentDecodes,
            decodeByteBudget: decodeByteBudget
        )
    }
}
