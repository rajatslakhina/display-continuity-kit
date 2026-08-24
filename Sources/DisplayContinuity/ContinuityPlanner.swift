// ContinuityPlanner.swift
//
// The core of the package. Turns a stream of surface observations into a
// stream of diffs, such that a display-class change re-plans in-flight work
// instead of restarting it.

/// Everything the planner needs to know about a surface at one instant.
public struct SurfaceInput: Sendable, Hashable {
    public var viewport: Viewport
    /// Index of the row the user is anchored on.
    public var anchor: Int
    /// The currently selected item, if any. Survives fold transitions —
    /// see `SurfaceStore`.
    public var selection: ItemID?

    public init(viewport: Viewport, anchor: Int = 0, selection: ItemID? = nil) {
        self.viewport = viewport
        self.anchor = anchor
        self.selection = selection
    }
}

/// The planning interface the storm harness verifies against.
///
/// A protocol so that `FoldStormDriver` can be pointed at a *deliberately
/// broken* planner in tests. An invariant checker that has only ever been run
/// against a correct implementation has not been shown to detect anything.
public protocol ContinuityPlanning: Sendable {
    func apply(_ input: SurfaceInput, at now: MonotonicInstant) async -> ReplanDirective
    /// Re-evaluates without a new observation, so a deferral window can elapse.
    func tick(at now: MonotonicInstant) async -> ReplanDirective
    func snapshotState() async -> PlannerState
}

/// Observable planner state, for the harness and for debug UI.
public struct PlannerState: Sendable, Hashable {
    public let epoch: Epoch
    public let plan: CapacityPlan
    public let inFlight: [WorkKey]
    public let deferredCancellations: [WorkKey]

    public init(epoch: Epoch, plan: CapacityPlan, inFlight: [WorkKey], deferredCancellations: [WorkKey]) {
        self.epoch = epoch
        self.plan = plan
        self.inFlight = inFlight
        self.deferredCancellations = deferredCancellations
    }
}

/// Re-plans in-flight work across display-class changes.
///
/// ## Concurrency
///
/// Every mutating entry point below is a *synchronous* actor-isolated method.
/// None of them contains an `await`, so none of them has a suspension point,
/// so there is no window in which a second caller can observe half-applied
/// state. That is deliberate and load-bearing: this type's whole job is to be
/// the serialisation point for a race between a layout pass, a scroll, and a
/// network completion. Introducing an `await` inside `apply(_:at:)` would
/// reintroduce exactly the interleaving it exists to remove — so injected
/// collaborators (`CapacityPolicy`, `DemandModel`, `DisplayClassResolving`) are
/// all deliberately synchronous protocols.
public actor ContinuityPlanner: ContinuityPlanning {

    private let policy: any CapacityPolicy
    private let resolver: any DisplayClassResolving
    private let demandModel: any DemandModel

    private var epoch: Epoch
    private var plan: CapacityPlan
    private var ledger: WorkLedger
    private var coalescer: TransitionCoalescer
    private var lastInput: SurfaceInput
    /// Cancellations computed but held back pending a possible reversal.
    private var heldCancellations: Set<WorkKey>

    public init(
        initialViewport: Viewport = .coverDisplay,
        policy: any CapacityPolicy = AreaProportionalCapacityPolicy(),
        resolver: any DisplayClassResolving = MinimumEdgeDisplayClassResolver(),
        demandModel: any DemandModel,
        ledgerCapacity: Int = 64,
        coalesceWindowMilliseconds: Int = 1_200
    ) {
        let initialClass = resolver.displayClass(for: initialViewport)
        self.policy = policy
        self.resolver = resolver
        self.demandModel = demandModel
        self.epoch = .initial
        self.plan = policy.plan(for: initialClass, viewport: initialViewport)
        self.ledger = WorkLedger(capacity: ledgerCapacity)
        self.coalescer = TransitionCoalescer(initial: initialClass, window: coalesceWindowMilliseconds)
        self.lastInput = SurfaceInput(viewport: initialViewport)
        self.heldCancellations = []
    }

    public func snapshotState() -> PlannerState {
        PlannerState(
            epoch: epoch,
            plan: plan,
            inFlight: ledger.keysByPriority,
            deferredCancellations: heldCancellations.sorted { $0.rawValue < $1.rawValue }
        )
    }

    public func apply(_ input: SurfaceInput, at now: MonotonicInstant) -> ReplanDirective {
        lastInput = input
        return replan(at: now)
    }

    public func tick(at now: MonotonicInstant) -> ReplanDirective {
        replan(at: now)
    }

    // MARK: - The re-plan

    private func replan(at now: MonotonicInstant) -> ReplanDirective {
        let observedClass = resolver.displayClass(for: lastInput.viewport)
        let decision = coalescer.observe(observedClass, at: now)

        // The coalescer, not the raw observation, decides which class is in
        // force. They differ during a deferral window.
        let effectiveClass = coalescer.current
        let newPlan = policy.plan(for: effectiveClass, viewport: lastInput.viewport)

        // Epoch advances exactly when the budget changes. A pure scroll re-plans
        // *within* an epoch, because nothing about the plan generation changed —
        // which keeps epoch bumps meaningful as "the world resized".
        if newPlan != plan {
            epoch = epoch.next()
            plan = newPlan
        }

        let demand = demandModel.demand(
            for: plan,
            anchor: lastInput.anchor,
            selection: lastInput.selection
        )
        let desiredKeys = Set(demand.map(\.key))

        // Work already in flight and still wanted. Recomputed after eviction
        // below, because an admission can evict a would-be-retained key.
        let cancelCandidates = Set(ledger.keys(notIn: desiredKeys))

        // Anything we were holding that is wanted again stops being a
        // cancellation candidate at all — this is the reversal payoff.
        heldCancellations.subtract(desiredKeys)

        var issuedCancellations: Set<WorkKey> = []
        switch decision {
        case .shrankDeferringCancellation:
            // Hold: the user may fold back inside the window.
            heldCancellations.formUnion(cancelCandidates)

        case .unchanged:
            if coalescer.hasDeferredCancellations {
                // Mid-deferral. While a reversal is plausible, cancel nothing —
                // including work that merely scrolled out of the window.
                heldCancellations.formUnion(cancelCandidates)
            } else {
                issuedCancellations = cancelCandidates
            }

        case .settled:
            issuedCancellations = cancelCandidates.union(heldCancellations)
            heldCancellations.removeAll()
            coalescer.clearDeferral()

        case .grew, .reverted:
            // The coalescer has already dropped any pending deferral: more room
            // means nothing that was about to be cancelled still needs to be.
            issuedCancellations = cancelCandidates.union(heldCancellations)
            heldCancellations.removeAll()
        }

        // Never "cancel" something that is currently wanted.
        issuedCancellations.subtract(desiredKeys)

        for key in issuedCancellations {
            ledger.remove(key)
        }

        // Admit in priority order so that, under eviction pressure, the items
        // nearest the anchor are the ones that survive.
        let ordered = demand.sorted { lhs, rhs in
            lhs.priority == rhs.priority
                ? lhs.key.rawValue < rhs.key.rawValue
                : lhs.priority < rhs.priority
        }

        var admitted: Set<WorkKey> = []
        var evictionCancellations: Set<WorkKey> = []

        // The admission list is frozen *before* the loop runs, deliberately.
        //
        // Computing `!ledger.contains(_:)` inside the loop looks equivalent and
        // is not: a key that was in flight at the top of the pass can be
        // evicted by a higher-priority admission partway through, at which
        // point a live check would see it as absent and re-admit it — putting
        // the same key in both `cancel` and `admit` in one directive. That is
        // the duplicated-fetch bug in miniature, and `FoldStormDriver` caught
        // exactly this during development, under ledger pressure only.
        let toAdmit = ordered.filter { !ledger.contains($0.key) }

        for item in toAdmit {
            let evicted = ledger.admit(
                WorkRecord(key: item.key, admittedAtEpoch: epoch, priority: item.priority)
            )
            for victim in evicted {
                if admitted.contains(victim) {
                    // Admitted earlier in this same pass and immediately
                    // displaced: it never started, so it is not a cancellation.
                    admitted.remove(victim)
                } else if victim != item.key {
                    // Displaced work from an earlier epoch — a real cancellation.
                    evictionCancellations.insert(victim)
                }
                // `victim == item.key` and not previously admitted: this item
                // was itself the worst candidate and never entered the ledger.
                // Nothing to admit and nothing to cancel.
            }
            if ledger.contains(item.key) {
                admitted.insert(item.key)
            }
        }

        // Retained = wanted, in flight, and not started by this pass. Derived
        // from the ledger *after* eviction so an evicted key is never reported
        // as retained.
        let retained = desiredKeys
            .filter { ledger.contains($0) && !admitted.contains($0) }

        let allCancellations = issuedCancellations.union(evictionCancellations)

        return ReplanDirective(
            epoch: epoch,
            plan: plan,
            admit: Array(admitted),
            cancel: Array(allCancellations),
            retain: Array(retained),
            deferredCancellations: Array(heldCancellations)
        )
    }
}
