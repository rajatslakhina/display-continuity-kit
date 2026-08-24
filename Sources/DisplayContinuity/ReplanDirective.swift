// ReplanDirective.swift
//
// The output of a re-plan, expressed as a diff rather than a new state.
//
// A diff is the entire point. "Here is the new desired set, go make it so" is
// how a re-plan turns into a cancel-everything-and-refetch storm: the executor
// has no way to tell which of those requests are already in flight and
// perfectly fine. `retain` is the field that makes the difference between a
// continuity layer and a reload.

/// One unit of demand: what should be in flight, and how badly.
public struct DemandItem: Sendable, Hashable {
    public let key: WorkKey
    /// Lower is more important. Conventionally row distance from the anchor.
    public let priority: Int

    public init(key: WorkKey, priority: Int) {
        self.key = key
        self.priority = priority
    }
}

/// Computes what work a plan implies.
///
/// Separated from the planner so that "what content does this surface want"
/// (a product decision, per feature) is not entangled with "how do we get from
/// the old set to the new one without tearing" (a platform decision, once).
public protocol DemandModel: Sendable {
    func demand(for plan: CapacityPlan, anchor: Int, selection: ItemID?) -> [DemandItem]
}

/// The instruction a re-plan hands to whatever executes work.
///
/// `admit`, `cancel` and `retain` are disjoint by construction and each is
/// sorted, so two runs over the same input produce byte-identical directives.
public struct ReplanDirective: Sendable, Hashable {
    /// The plan generation this directive belongs to.
    public let epoch: Epoch
    /// The budget in force after this re-plan.
    public let plan: CapacityPlan
    /// Work to start. None of these are currently in flight.
    public let admit: [WorkKey]
    /// Work to stop. Includes both work that fell out of the plan and work
    /// evicted to keep the ledger inside its capacity.
    public let cancel: [WorkKey]
    /// Work that was already in flight and is still wanted.
    ///
    /// **These must not be restarted.** An executor that treats `retain` as
    /// `admit` produces exactly the duplicated-fetch behaviour
    /// `FoldStormDriver` fails a build for.
    public let retain: [WorkKey]
    /// Cancellations that were computed but deliberately held back pending a
    /// possible reversal. Informational — the executor takes no action on these.
    public let deferredCancellations: [WorkKey]
    /// Priority of each admitted key. Lower is more important.
    ///
    /// This exists because `admit` is sorted *lexicographically*, and that
    /// ordering is for reproducibility, not for scheduling. An executor bounded
    /// by `plan.concurrentDecodes` cannot start everything it is given, so it
    /// has to decide what to start **first** — and without this field the
    /// planner's carefully computed priority order dies at the directive
    /// boundary and the executor starts `row:10` ahead of `row:2` purely
    /// because `"1" < "2"`.
    ///
    /// Keys absent from this map sort last, so a directive built by hand
    /// without priorities degrades to the lexicographic order rather than
    /// trapping.
    public let admissionPriority: [WorkKey: Int]

    public init(
        epoch: Epoch,
        plan: CapacityPlan,
        admit: [WorkKey],
        cancel: [WorkKey],
        retain: [WorkKey],
        deferredCancellations: [WorkKey] = [],
        admissionPriority: [WorkKey: Int] = [:]
    ) {
        self.epoch = epoch
        self.plan = plan
        self.admit = admit.sorted { $0.rawValue < $1.rawValue }
        self.cancel = cancel.sorted { $0.rawValue < $1.rawValue }
        self.retain = retain.sorted { $0.rawValue < $1.rawValue }
        self.deferredCancellations = deferredCancellations.sorted { $0.rawValue < $1.rawValue }
        self.admissionPriority = admissionPriority
    }

    /// `admit`, in the order the executor should actually start work: most
    /// important first, with a lexicographic tiebreak so the order stays
    /// deterministic across runs.
    public var admissionOrder: [WorkKey] {
        admit.sorted { lhs, rhs in
            let left = admissionPriority[lhs] ?? .max
            let right = admissionPriority[rhs] ?? .max
            return left == right ? lhs.rawValue < rhs.rawValue : left < right
        }
    }

    /// True when this re-plan asks the executor to do nothing at all.
    public var isNoOp: Bool { admit.isEmpty && cancel.isEmpty }

    /// Work saved by retaining rather than restarting — the metric that makes
    /// the continuity layer's value legible in a log line.
    public var retainedCount: Int { retain.count }
}

/// Demand for a contiguous window of rows centred on the scroll anchor, plus
/// the detail pane's own demand when one is visible.
///
/// The detail-pane demand is the part a layout-only migration misses: on
/// unfold, a pane appears that *nobody scrolled to*, and it needs content
/// immediately. Deriving it here means the planner admits it in the same
/// directive as everything else, rather than as a second uncoordinated fetch
/// that races the first.
public struct WindowedDemandModel: DemandModel {
    /// Total number of rows available. Clamped to `>= 0`.
    public let itemCount: Int
    /// Prefix applied to row work keys.
    public let rowPrefix: String
    /// Prefix applied to the detail pane's work key.
    public let detailPrefix: String

    public init(itemCount: Int, rowPrefix: String = "row", detailPrefix: String = "detail") {
        self.itemCount = max(0, itemCount)
        self.rowPrefix = rowPrefix
        self.detailPrefix = detailPrefix
    }

    /// Hard ceiling on how many rows a single re-plan will ever demand.
    ///
    /// `CapacityPlan` only floors its fields, so a plan built through the public
    /// initialiser with `visibleWindow: .max` carries a saturated
    /// `admissionWindow`. Emitting one `DemandItem` per row for that window
    /// against a large feed allocates until the process dies — which is the same
    /// class of failure `WorkLedger` exists to prevent, reintroduced one layer
    /// up. "The caller will pass a sane plan" is not a bound.
    public static let maximumWindow = 4_096

    public func demand(for plan: CapacityPlan, anchor: Int, selection: ItemID?) -> [DemandItem] {
        guard itemCount > 0 else { return [] }

        let window = min(plan.admissionWindow, Self.maximumWindow)
        guard window > 0 else { return [] }

        // Centre the window on the anchor, saturating so a pathological anchor
        // (`Int.min`, `Int.max`) cannot wrap the bounds into an inverted range.
        let half = Saturating.divide(window, by: 2, fallback: 0)
        let rawLower = Saturating.subtract(anchor, half)

        // Slide the window back off the end of the feed rather than truncating
        // it against the last row.
        //
        // Clamping `lower` to `itemCount - 1` looks equivalent and is not: it
        // shrinks the window as the anchor approaches the tail — a 40-row feed
        // with a 16-row window served only 9 rows at the last row and *1* row
        // for any overshooting anchor — so the bottom of a feed, which is
        // exactly where pagination pressure is highest, got the least prefetch.
        // The head of the feed slid correctly, which is why it went unnoticed.
        let maxLower = Saturating.subtract(itemCount, window)
        let lower = Saturating.clamp(rawLower, lower: 0, upper: max(0, maxLower))
        let rawUpper = Saturating.add(lower, window)
        let upper = Saturating.clamp(rawUpper, lower: lower, upper: itemCount)

        var items: [DemandItem] = []
        // Saturating rather than `upper - lower + 1`: both bounds are clamped,
        // but a negative or overflowing reservation would trap.
        items.reserveCapacity(Saturating.add(Saturating.subtract(upper, lower), 1))

        // `lower ..< upper` is well-formed: `upper` is clamped to be >= `lower`.
        for index in lower ..< upper {
            // `Saturating.distance`, not `abs(a - b)`: `abs(Int.min)` traps, and
            // an `anchor` of `Int.max` puts the difference within one of it.
            let distance = Saturating.distance(index, anchor)
            items.append(
                DemandItem(key: WorkKey("\(rowPrefix):\(index)"), priority: distance)
            )
        }

        // A detail pane only exists in `.expanded`, and only has something to
        // fetch when a selection survived the transition.
        if plan.displayClass.showsDetailPane, let selection {
            items.append(
                DemandItem(key: WorkKey("\(detailPrefix):\(selection.rawValue)"), priority: -1)
            )
        }

        return items
    }
}
