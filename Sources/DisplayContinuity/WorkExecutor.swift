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
/// Work beyond the limit is queued in priority order rather than started, so a
/// re-plan that admits 20 rows on a plan permitting 3 concurrent decodes starts
/// 3 and holds 17 — and if a later re-plan cancels those 17 before they ever
/// start, they were never a cost at all.
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
    }

    private let runner: any WorkRunning
    private var limit: Int
    private var running: [WorkKey: Task<Void, Never>]
    /// Admitted-but-not-yet-started work, in priority order.
    private var queue: [WorkKey]
    private var startCounts: [WorkKey: Int]
    private var cancelCount: Int

    public init(runner: any WorkRunning, concurrencyLimit: Int = 4) {
        self.runner = runner
        self.limit = max(1, concurrencyLimit)
        self.running = [:]
        self.queue = []
        self.startCounts = [:]
        self.cancelCount = 0
    }

    public func snapshot() -> State {
        State(
            running: running.keys.sorted { $0.rawValue < $1.rawValue },
            queued: queue,
            startCounts: startCounts,
            cancelCount: cancelCount
        )
    }

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

        for key in directive.cancel {
            if let task = running.removeValue(forKey: key) {
                task.cancel()
                cancelCount += 1
            } else if let index = queue.firstIndex(of: key) {
                // Never started, so nothing to cancel — it simply stops being
                // owed. Counting this as a cancellation would inflate the
                // metric with work that cost nothing.
                queue.remove(at: index)
            }
        }

        for key in directive.admit where running[key] == nil && !queue.contains(key) {
            queue.append(key)
        }

        pump()
    }

    /// Cancels everything. Used on surface teardown.
    public func cancelAll() {
        for (_, task) in running {
            task.cancel()
            cancelCount += 1
        }
        running.removeAll()
        queue.removeAll()
    }

    // MARK: - Private

    private func pump() {
        while running.count < limit, !queue.isEmpty {
            let key = queue.removeFirst()
            guard running[key] == nil else { continue }
            startCounts[key, default: 0] += 1
            let runner = self.runner
            running[key] = Task { [weak self] in
                await runner.run(key)
                // `weak self` so a torn-down executor does not keep itself
                // alive through an in-flight child task.
                await self?.finish(key)
            }
        }
    }

    private func finish(_ key: WorkKey) {
        running.removeValue(forKey: key)
        pump()
    }
}
