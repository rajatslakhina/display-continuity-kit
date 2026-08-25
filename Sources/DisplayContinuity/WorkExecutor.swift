// WorkExecutor.swift
//
// A `ReplanDirective` is only worth emitting if something honours it. This is
// the reference consumer: it turns `admit` into real running `Task`s, `cancel`
// into real cancellation, and — the part that matters — turns `retain` into
// *nothing at all*.
//
// It exists because "no duplicated fetches" proven at the plan level is only
// half a proof. `WorkExecutorTests` drives this against the real planner and
// counts how many times each unit of work actually started.

/// One unit of work the executor can run. Deliberately opaque: this package has
/// no opinion about whether a `WorkKey` is a network fetch, an image decode, a
/// database read or an on-device inference.
public protocol WorkRunning: Sendable {
    /// Runs the work for `key`. Must observe `Task.isCancelled` and return
    /// early — cancellation is cooperative, and a body that ignores it makes
    /// the whole re-planning layer decorative.
    func run(_ key: WorkKey) async
}

/// Executes `ReplanDirective`s.
///
/// ## The concurrency limit is real, not advisory
///
/// `CapacityPlan.concurrentDecodes` bounds how many admitted units run at once.
/// Work beyond the limit is queued rather than started, so a re-plan that admits
/// 20 rows on a plan permitting 3 concurrent decodes starts 3 and holds 17 — and
/// if a later re-plan cancels those 17 before they ever start, they were never a
/// cost at all.
///
/// ## The queue is ordered by `ReplanDirective.admissionPriority`
///
/// The planner ranks admissions by distance from the scroll anchor. That
/// ranking has to survive the directive boundary or it is decoration: `admit`
/// is sorted lexicographically for reproducible diffs, so an executor that
/// consumed it directly would start `row:10` before `row:2`. This one consumes
/// `admissionOrder`, and re-sorts the pending queue on every `apply(_:)` —
/// work that has not started has cost nothing, so a newly admitted row beside
/// the anchor should not wait behind a stale row twenty positions away.
///
/// ## Why an actor with no `await` in the mutation path
///
/// Same reasoning as `ContinuityPlanner`: `apply(_:)` and the completion
/// bookkeeping are synchronous actor-isolated methods. The only suspension is
/// inside the spawned child task, which touches actor state exactly once, on
/// completion, through `finish(_:)`.
public actor WorkExecutor {

    /// Snapshot of what the executor is doing, for tests and debug UI.
    public struct State: Sendable, Hashable {
        public let running: [WorkKey]
        public let queued: [WorkKey]
        /// How many times each key has been *started*. The number that has to
        /// stay at 1 across a fold storm.
        public let startCounts: [WorkKey: Int]
        public let cancelCount: Int
        /// Completions that arrived from a run this executor had already
        /// replaced. See `finish(_:id:)` — a non-zero value here is normal
        /// under cancel-then-re-admit, and a *silent* one is the bug.
        public let staleCompletions: Int
        /// Completions whose work was admitted under an epoch older than the
        /// one currently in force. This is the number `Epoch` exists to make
        /// countable: a late response from a plan that no longer applies.
        public let supersededCompletions: Int
        /// The plan generation of the last directive applied.
        public let epoch: Epoch
    }

    /// A running unit of work, plus the two stamps that make it identifiable.
    private struct RunningWork {
        /// Unique per *start*, not per key. `Epoch` is not enough on its own:
        /// it only advances when the budget changes, so cancel-then-re-admit
        /// inside one epoch would produce two runs with identical stamps.
        let id: Int
        /// The plan generation this run was admitted under.
        let epoch: Epoch
        let task: Task<Void, Never>
    }

    private let runner: any WorkRunning
    private var limit: Int
    private var running: [WorkKey: RunningWork]
    /// Admitted-but-not-yet-started work, most important first.
    private var queue: [WorkKey]
    /// Membership shadow of `queue`. `Array.contains` inside the admit loop
    /// makes `apply(_:)` quadratic in the queue length, which is invisible at
    /// n = 64 and is exactly the kind of thing that stops being invisible on a
    /// feed. Three lines to make it O(1).
    private var queued: Set<WorkKey>
    /// Priorities carried over from the directives that admitted each key.
    ///
    /// Pruned whenever a key stops being owed — cancelled, completed, or torn
    /// down. An earlier revision pruned only on explicit cancellation, which
    /// left one entry per completed key forever: an unbounded dictionary in the
    /// package whose whole argument is that unbounded in-flight state is how a
    /// fold storm turns into an OOM.
    private var priorities: [WorkKey: Int]
    private var startCounts: [WorkKey: Int]
    private var cancelCount: Int
    private var staleCompletions: Int
    private var supersededCompletions: Int
    private var currentEpoch: Epoch
    private var nextRunID: Int

    public init(runner: any WorkRunning, concurrencyLimit: Int = 4) {
        self.runner = runner
        self.limit = max(1, concurrencyLimit)
        self.running = [:]
        self.queue = []
        self.queued = []
        self.priorities = [:]
        self.startCounts = [:]
        self.cancelCount = 0
        self.staleCompletions = 0
        self.supersededCompletions = 0
        self.currentEpoch = .initial
        self.nextRunID = 0
    }

    public func snapshot() -> State {
        State(
            running: running.keys.sorted { $0.rawValue < $1.rawValue },
            queued: queue,
            startCounts: startCounts,
            cancelCount: cancelCount,
            staleCompletions: staleCompletions,
            supersededCompletions: supersededCompletions,
            epoch: currentEpoch
        )
    }

    /// The epoch a currently-running unit of work was admitted under.
    public func epoch(of key: WorkKey) -> Epoch? { running[key]?.epoch }

    /// How many keys carry a remembered priority. Exposed so the bound can be
    /// asserted rather than assumed.
    public var trackedPriorityCount: Int { priorities.count }

    /// Honours a directive.
    ///
    /// Order is load-bearing: cancel first, then admit. Cancelling first frees
    /// concurrency slots, so an admission in the same directive can occupy a
    /// slot the cancellation just released rather than queueing behind work
    /// that is already on its way out.
    ///
    /// `directive.retain` is deliberately never read. That is the whole point:
    /// retained work is work this executor does not touch.
    public func apply(_ directive: ReplanDirective) {
        limit = max(1, directive.plan.concurrentDecodes)
        // Monotonic: a directive built by hand with a stale epoch must not walk
        // the executor's notion of "current" backwards.
        currentEpoch = max(currentEpoch, directive.epoch)

        // Cancellations are processed before admissions, so priorities are
        // recorded *after* the cancel loop — otherwise a key appearing in both
        // `cancel` and `admissionPriority` would have its priority stripped and
        // queue at `.max`. The planner keeps the two disjoint; a hand-built
        // directive need not.
        var cancelledFromQueue: Set<WorkKey> = []
        for key in directive.cancel {
            if let work = running.removeValue(forKey: key) {
                work.task.cancel()
                cancelCount += 1
            } else if queued.remove(key) != nil {
                // Never started, so nothing to cancel — it simply stops being
                // owed. Counting this as a cancellation would inflate the
                // metric with work that cost nothing.
                cancelledFromQueue.insert(key)
            }
            priorities.removeValue(forKey: key)
        }
        if !cancelledFromQueue.isEmpty {
            queue.removeAll { cancelledFromQueue.contains($0) }
        }

        for (key, priority) in directive.admissionPriority {
            priorities[key] = priority
        }

        // `admissionOrder`, not `admit`: the latter is sorted lexicographically
        // for reproducible diffs, which is not a schedule.
        for key in directive.admissionOrder where running[key] == nil && !queued.contains(key) {
            queue.append(key)
            queued.insert(key)
        }

        // Re-sort rather than append blindly. Work that has not started has cost
        // nothing, so there is no reason to make a newly admitted row next to
        // the anchor wait behind a stale row twenty positions away. Ties break
        // lexicographically so the schedule is reproducible.
        //
        // This *also* means insertion order above cannot be observed, so
        // consuming `admit` instead of `admissionOrder` here is invisible to a
        // test that only inspects the queue. `ReplanDirectiveTests` pins
        // `admissionOrder` directly for that reason.
        queue.sort { lhs, rhs in
            let left = priorities[lhs] ?? .max
            let right = priorities[rhs] ?? .max
            return left == right ? lhs.rawValue < rhs.rawValue : left < right
        }

        pump()
    }

    /// Cancels everything. Used on surface teardown.
    public func cancelAll() {
        for (_, work) in running {
            work.task.cancel()
            cancelCount += 1
        }
        running.removeAll()
        queue.removeAll()
        queued.removeAll()
        priorities.removeAll()
    }

    // MARK: - Private

    private func pump() {
        while running.count < limit, !queue.isEmpty {
            let key = queue.removeFirst()
            queued.remove(key)
            guard running[key] == nil else { continue }
            startCounts[key, default: 0] += 1
            nextRunID = Saturating.add(nextRunID, 1)
            let id = nextRunID
            let runner = self.runner
            let task = Task { [weak self] in
                await runner.run(key)
                // `weak self` so a torn-down executor does not keep itself
                // alive through an in-flight child task.
                await self?.finish(key, id: id)
            }
            running[key] = RunningWork(id: id, epoch: currentEpoch, task: task)
        }
    }

    /// Completion callback, keyed by *run* rather than by key.
    ///
    /// The `id` check is the whole point. Cancellation is cooperative, so a
    /// cancelled body keeps running until it next checks `Task.isCancelled` —
    /// and if the same key is re-admitted in the meantime, the old body's
    /// eventual return would otherwise evict the **new** run's entry. The
    /// executor would then believe the key is idle, `pump()` would start it a
    /// second time, and two bodies would be live for one key: the exact
    /// duplicated-fetch failure this package exists to prevent, reintroduced
    /// inside its own reference consumer. Cancel-then-re-admit is not an exotic
    /// path here — it is the fold storm.
    private func finish(_ key: WorkKey, id: Int) {
        guard let work = running[key], work.id == id else {
            // A run this executor has already replaced or torn down. Counted
            // rather than ignored: silence is what made this a bug.
            staleCompletions += 1
            return
        }
        if work.epoch < currentEpoch {
            // A response planned under a budget that no longer applies. The
            // work still finished, so it leaves `running` — but this is the
            // number `Epoch` exists to make countable, rather than a late
            // arrival being indistinguishable from a current one.
            supersededCompletions += 1
        }
        running.removeValue(forKey: key)
        if !queued.contains(key) {
            priorities.removeValue(forKey: key)
        }
        pump()
    }
}
