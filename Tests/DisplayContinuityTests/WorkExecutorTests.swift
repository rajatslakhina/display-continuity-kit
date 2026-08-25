import XCTest
@testable import DisplayContinuity

/// Counts how many times each unit of work actually *started*, and how many
/// times a started unit observed cancellation.
private actor RecordingRunner: WorkRunning {
    private(set) var starts: [WorkKey: Int] = [:]
    private(set) var completions: [WorkKey: Int] = [:]
    private(set) var cancellations: [WorkKey: Int] = [:]
    /// Number of iterations each unit of work spends before finishing.
    private let ticks: Int

    init(ticks: Int = 3) { self.ticks = ticks }

    func run(_ key: WorkKey) async {
        starts[key, default: 0] += 1
        for _ in 0 ..< ticks {
            if Task.isCancelled {
                cancellations[key, default: 0] += 1
                return
            }
            await Task.yield()
        }
        if Task.isCancelled {
            cancellations[key, default: 0] += 1
            return
        }
        completions[key, default: 0] += 1
    }

    func startCount(_ key: WorkKey) -> Int { starts[key] ?? 0 }
    func totalStarts() -> Int { starts.values.reduce(0, +) }
    func distinctStarted() -> Int { starts.keys.count }
    func maxStartsForAnyKey() -> Int { starts.values.max() ?? 0 }
    /// How many times a *body* observed cancellation. Distinct from the
    /// executor's own `cancelCount`, which it increments synchronously whether
    /// or not `Task.cancel()` was ever called.
    func cancellationCount(_ key: WorkKey) -> Int { cancellations[key] ?? 0 }
}

/// Parks each body on a continuation until the test explicitly releases it,
/// and never checks `Task.isCancelled`.
///
/// Cooperative cancellation means a real body can outlive its `cancel()` call
/// by an arbitrary amount — a decode mid-frame, a request parked on a socket.
/// Modelling that with "linger for N yields" makes the overlap a *race*: the
/// window the test is named after only sometimes exists, which is how a test
/// ends up passing for a reason other than the one it claims. A gate makes the
/// overlap a fact.
private actor GatedRunner: WorkRunning {
    private(set) var starts: [WorkKey: Int] = [:]
    private(set) var live = 0
    private(set) var peakLive = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    func run(_ key: WorkKey) async {
        starts[key, default: 0] += 1
        live += 1
        peakLive = max(peakLive, live)
        await withCheckedContinuation { parked.append($0) }
        live -= 1
    }

    /// Lets `count` parked bodies return, oldest first.
    func release(_ count: Int = 1) {
        for _ in 0 ..< min(count, parked.count) {
            parked.removeFirst().resume()
        }
    }

    func releaseAll() { release(parked.count) }
    func parkedCount() -> Int { parked.count }
    func startCount(_ key: WorkKey) -> Int { starts[key] ?? 0 }
    func peak() -> Int { peakLive }
}

/// Runs forever until cancelled. Used to prove the concurrency limit binds.
private actor BlockingRunner: WorkRunning {
    private(set) var started: Set<WorkKey> = []

    func run(_ key: WorkKey) async {
        started.insert(key)
        while !Task.isCancelled {
            await Task.yield()
        }
    }

    func startedKeys() -> Set<WorkKey> { started }
}

/// The point of `ReplanDirective.retain` is that *something downstream does
/// nothing with it*. These tests prove that end to end: they drive the real
/// planner, hand every directive to the real executor, and count starts.
final class WorkExecutorTests: XCTestCase {

    private let selection = ItemID("i0")

    private func makePlanner(items: Int = 40, capacity: Int = 64) -> ContinuityPlanner {
        ContinuityPlanner(
            initialViewport: .coverDisplay,
            demandModel: WindowedDemandModel(itemCount: items),
            ledgerCapacity: capacity,
            coalesceWindowMilliseconds: 1_200
        )
    }

    private func at(_ ms: Int) -> MonotonicInstant { MonotonicInstant(milliseconds: ms) }

    /// Yields until `condition` holds, or until the bound is exhausted.
    ///
    /// A fixed number of `Task.yield()` calls is not a synchronisation
    /// primitive. How many yields it takes for a spawned child task to reach
    /// its first line depends on the executor's queue depth, which depends on
    /// the machine — so `for _ in 0 ..< 8 { await Task.yield() }` passes on a
    /// quiet laptop and fails on a loaded CI runner. That is not a flaky test,
    /// it is a test asserting something it never established.
    ///
    /// Waiting on the *observable condition* instead makes these tests
    /// deterministic without making them slow: they return as soon as the work
    /// has actually happened, and the bound only exists so a genuine regression
    /// fails rather than hangs.
    /// Waits until `condition` holds, bounded by **wall clock**, and fails if
    /// it never does.
    ///
    /// Two things here were learned the hard way. First, a fixed number of
    /// `Task.yield()` calls is not a synchronisation primitive: on a loaded
    /// machine 10,000 yields can elapse before a spawned body is scheduled at
    /// all, so a yield-counted bound turns machine load into a test failure.
    /// After a short spin this sleeps instead, which actually cedes the core.
    ///
    /// Second, exhausting the bound is a **failure**, not a silent give-up. A
    /// `settle` that returns quietly on timeout downgrades a regression into a
    /// weaker test rather than a red one — the fold-storm test would silently
    /// degenerate into a queue and collapse to "the planner never emitted a
    /// duplicate", which is exactly what its negative control exists to rule out.
    private func settle(
        timeout: Duration = .seconds(20),
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var spins = 0
        while clock.now < deadline {
            if await condition() { return }
            if spins < 200 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(1))
            }
            spins += 1
        }
        XCTFail("settle timed out after \(timeout)", file: file, line: line)
    }

    /// The headline claim, measured rather than asserted: across a fold storm,
    /// no unit of work is ever *started* twice.
    func testNoUnitOfWorkIsEverStartedTwiceAcrossAFoldStorm() async {
        let runner = RecordingRunner(ticks: 2)
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 8)
        let planner = makePlanner()

        let script: [(Viewport, Int)] = [
            (.coverDisplay, 0), (.innerDisplay, 250), (.coverDisplay, 430),
            (.innerDisplay, 580), (.coverDisplay, 700), (.innerDisplay, 790)
        ]
        for (viewport, time) in script {
            let directive = await planner.apply(
                SurfaceInput(viewport: viewport, anchor: 0, selection: selection),
                at: at(time)
            )
            await executor.apply(directive)
            // Wait for this transition's admissions to actually begin before
            // driving the next one, so the storm is a storm and not a queue.
            await settle { await executor.snapshot().queued.isEmpty }
        }

        let worst = await runner.maxStartsForAnyKey()
        XCTAssertEqual(worst, 1, "some unit of work was started more than once across the storm")

        let distinct = await runner.distinctStarted()
        XCTAssertGreaterThanOrEqual(distinct, 16, "the storm must actually have done work")

        await executor.cancelAll()
    }

    /// The negative control. An executor that treats `retain` as `admit` — the
    /// exact mistake `ReplanDirective` documents — restarts work, and this test
    /// asserts that it does. Without this, the test above proves only that the
    /// planner never emitted a duplicate, not that honouring `retain` matters.
    func testTreatingRetainAsAdmitDemonstrablyRestartsWork() async {
        let runner = RecordingRunner(ticks: 2)
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 8)
        let planner = makePlanner()

        let script: [(Viewport, Int)] = [
            (.coverDisplay, 0), (.innerDisplay, 250), (.coverDisplay, 430), (.innerDisplay, 580)
        ]
        for (viewport, time) in script {
            let directive = await planner.apply(
                SurfaceInput(viewport: viewport, anchor: 0, selection: selection),
                at: at(time)
            )
            // The bug, expressed as a directive: fold `retain` into `admit`.
            let naive = ReplanDirective(
                epoch: directive.epoch,
                plan: directive.plan,
                admit: directive.admit + directive.retain,
                cancel: directive.cancel,
                retain: []
            )
            await executor.apply(naive)
            // Wait on the executor's own queue draining, not on a start count.
            // Counting distinct starts is wrong here in both directions: the
            // naive executor re-admits keys it has already started, so the
            // distinct count saturates and the wait becomes a no-op that looks
            // like a wait.
            await settle { await executor.snapshot().queued.isEmpty }
        }

        // The restart is the point of this test, so wait for it rather than
        // assuming it has happened.
        await settle { await runner.maxStartsForAnyKey() > 1 }
        let worst = await runner.maxStartsForAnyKey()
        XCTAssertGreaterThan(
            worst,
            1,
            "the naive executor must visibly restart work, or the correct one proves nothing"
        )
        await executor.cancelAll()
    }

    /// `concurrentDecodes` is a real limit, not advisory.
    func testConcurrencyLimitBindsAndQueuesTheRest() async {
        let runner = BlockingRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 3)

        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 10,
            prefetchDepth: 0,
            concurrentDecodes: 3,
            decodeByteBudget: 1_024
        )
        let keys = (0 ..< 10).map { WorkKey("row:\($0)") }
        await executor.apply(
            ReplanDirective(epoch: .initial, plan: plan, admit: keys, cancel: [], retain: [])
        )
        await settle { await runner.startedKeys().count >= 3 }

        let state = await executor.snapshot()
        XCTAssertEqual(state.running.count, 3, "the limit must bind")
        XCTAssertEqual(state.queued.count, 7, "the rest must queue, not start")

        let started = await runner.startedKeys()
        XCTAssertEqual(started.count, 3, "queued work must not have run")

        await executor.cancelAll()
    }

    /// Work cancelled before it ever started costs nothing and must not be
    /// counted as a cancellation — otherwise the metric measures the queue
    /// rather than wasted effort.
    func testCancellingQueuedWorkIsFreeAndNotCountedAsACancellation() async {
        let runner = BlockingRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 1)

        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 4,
            prefetchDepth: 0,
            concurrentDecodes: 1,
            decodeByteBudget: 1_024
        )
        let keys = (0 ..< 4).map { WorkKey("row:\($0)") }
        await executor.apply(
            ReplanDirective(epoch: .initial, plan: plan, admit: keys, cancel: [], retain: [])
        )
        await settle { await runner.startedKeys().count >= 1 }

        // Cancel the three that never started.
        await executor.apply(
            ReplanDirective(
                epoch: Epoch(1),
                plan: plan,
                admit: [],
                cancel: Array(keys.dropFirst()),
                retain: [keys[0]]
            )
        )
        await settle { await executor.snapshot().queued.isEmpty }

        let state = await executor.snapshot()
        XCTAssertEqual(state.cancelCount, 0, "queued-but-unstarted work costs nothing to drop")
        XCTAssertEqual(state.queued.count, 0)
        XCTAssertEqual(state.running.count, 1, "the one that started keeps running")

        await executor.cancelAll()
    }

    func testCancellationIsObservedByRunningWork() async {
        let runner = RecordingRunner(ticks: 10_000)
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 2)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 2,
            prefetchDepth: 0,
            concurrentDecodes: 2,
            decodeByteBudget: 1_024
        )
        let key = WorkKey("row:0")
        await executor.apply(
            ReplanDirective(epoch: .initial, plan: plan, admit: [key], cancel: [], retain: [])
        )
        await settle { await runner.startCount(key) == 1 }
        let firstStarts = await runner.startCount(key)
        XCTAssertEqual(firstStarts, 1)

        await executor.apply(
            ReplanDirective(epoch: Epoch(1), plan: plan, admit: [], cancel: [key], retain: [])
        )
        await settle { await executor.snapshot().cancelCount == 1 }
        // The executor's own counter increments synchronously in `apply`,
        // whether or not `Task.cancel()` was ever called — so asserting it
        // alone proves nothing about cancellation. Deleting the `cancel()`
        // call used to leave this suite entirely green. What has to be observed
        // is the *body* noticing.
        await settle { await runner.cancellationCount(key) == 1 }

        let state = await executor.snapshot()
        XCTAssertEqual(state.cancelCount, 1, "cancelling running work is a real cancellation")
        XCTAssertFalse(state.running.contains(key))
        let observed = await runner.cancellationCount(key)
        XCTAssertEqual(observed, 1, "the running body never observed its cancellation")
    }

    /// A cancelled body that outlives its cancellation must not evict its
    /// replacement.
    ///
    /// Cancellation is cooperative, so `task.cancel()` returns long before the
    /// body does. If the completion callback is keyed only by `WorkKey`, the
    /// old body's eventual return removes the **new** run's entry — the
    /// executor then believes the key is idle, and the very next re-admission
    /// starts a second live body for one key. That is the duplicated-fetch bug
    /// this package exists to prevent, reintroduced inside its own reference
    /// consumer, and cancel-then-re-admit is not an exotic path here: it is
    /// what a fold storm *is*.
    func testACancelledBodyThatOutlivesItsCancellationCannotEvictItsReplacement() async {
        let runner = GatedRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 1)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 2,
            prefetchDepth: 0,
            concurrentDecodes: 1,
            decodeByteBudget: 1_024
        )
        let key = WorkKey("row:0")

        await executor.apply(
            ReplanDirective(epoch: .initial, plan: plan, admit: [key], cancel: [], retain: [])
        )
        await settle { await runner.parkedCount() == 1 }

        // Cancel and immediately re-admit. The first body ignores cancellation,
        // so it is *still parked* — genuinely alive — while the second starts.
        await executor.apply(
            ReplanDirective(epoch: Epoch(1), plan: plan, admit: [], cancel: [key], retain: [])
        )
        await executor.apply(
            ReplanDirective(epoch: Epoch(2), plan: plan, admit: [key], cancel: [], retain: [])
        )
        await settle { await runner.parkedCount() == 2 }

        // Let only the *original* body return. Its completion belongs to a run
        // this executor has already replaced.
        await runner.release(1)
        await settle { await executor.snapshot().staleCompletions >= 1 }

        // The defensive re-admit the package documents as a no-op. With a
        // key-only completion callback the executor now believes nothing is
        // running for this key, and this starts a third body alongside the
        // second — which is still parked, so the overlap is a fact rather than
        // a race.
        await executor.apply(
            ReplanDirective(epoch: Epoch(2), plan: plan, admit: [key], cancel: [], retain: [])
        )
        await settle { await runner.parkedCount() >= 1 }

        let starts = await runner.startCount(key)
        XCTAssertEqual(starts, 2, "one cancellation produced \(starts) starts — the executor lost track of its own run")
        let peak = await runner.peak()
        XCTAssertLessThanOrEqual(peak, 2, "more than two bodies were live at once for a single key")

        await runner.releaseAll()
        await executor.cancelAll()
    }

    /// A completion planned under a superseded budget is *countable*, not
    /// indistinguishable — which is the entire reason `Epoch` exists.
    func testACompletionFromASupersededEpochIsCounted() async {
        let runner = GatedRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 2)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 2,
            prefetchDepth: 0,
            concurrentDecodes: 2,
            decodeByteBudget: 1_024
        )
        let key = WorkKey("row:0")

        await executor.apply(
            ReplanDirective(epoch: .initial, plan: plan, admit: [key], cancel: [], retain: [])
        )
        await settle { await runner.parkedCount() == 1 }
        let stamped = await executor.epoch(of: key)
        XCTAssertEqual(stamped, .initial, "work must carry the epoch it was admitted under")

        // A new plan generation lands while the work is still in flight, and
        // retains it — so it is not cancelled, merely outdated.
        await executor.apply(
            ReplanDirective(epoch: Epoch(3), plan: plan, admit: [], cancel: [], retain: [key])
        )
        await runner.releaseAll()
        await settle { await executor.snapshot().supersededCompletions >= 1 }

        let state = await executor.snapshot()
        XCTAssertEqual(state.supersededCompletions, 1)
        XCTAssertEqual(state.staleCompletions, 0, "it was superseded, not replaced")
        XCTAssertEqual(state.epoch, Epoch(3))
    }

    /// The bound on remembered priorities, asserted rather than assumed.
    ///
    /// `WorkLedger` argues that an unbounded in-flight set is how a fold storm
    /// turns into an OOM. That argument does not survive a sibling dictionary
    /// that keeps one entry per key the executor has *ever* been told about.
    func testRememberedPrioritiesDoNotOutliveTheWorkTheyDescribe() async {
        let runner = RecordingRunner(ticks: 1)
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 4)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 4,
            prefetchDepth: 0,
            concurrentDecodes: 4,
            decodeByteBudget: 1_024
        )

        for index in 0 ..< 200 {
            let key = WorkKey("row:\(index)")
            await executor.apply(
                ReplanDirective(
                    epoch: .initial,
                    plan: plan,
                    admit: [key],
                    cancel: [],
                    retain: [],
                    admissionPriority: [key: index]
                )
            )
            await settle { await runner.startCount(key) >= 1 }
        }
        await settle { await executor.snapshot().running.isEmpty }

        let tracked = await executor.trackedPriorityCount
        XCTAssertEqual(tracked, 0, "200 completed keys left \(tracked) priorities behind")
    }

    func testReAdmittingSomethingAlreadyRunningIsANoOp() async {
        let runner = BlockingRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 4)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 2,
            prefetchDepth: 0,
            concurrentDecodes: 4,
            decodeByteBudget: 1_024
        )
        let key = WorkKey("row:0")
        for epoch in 0 ..< 5 {
            await executor.apply(
                ReplanDirective(epoch: Epoch(epoch), plan: plan, admit: [key], cancel: [], retain: [])
            )
            await settle { await runner.startedKeys().contains(key) }
        }
        let state = await executor.snapshot()
        XCTAssertEqual(state.startCounts[key], 1, "a defensive re-admit must not restart running work")
        await executor.cancelAll()
    }

    /// Teardown must actually cancel, not merely forget.
    ///
    /// Asserting only on `state.running.isEmpty` and `state.cancelCount` is
    /// vacuous: both are bookkeeping `cancelAll` updates synchronously whether
    /// or not `Task.cancel()` was ever called. Deleting the `cancel()` from
    /// `cancelAll` used to leave this suite entirely green while every torn-down
    /// body kept running forever. The bodies have to be observed noticing.
    func testCancelAllIsObservedByEveryRunningBody() async {
        let runner = RecordingRunner(ticks: 100_000)
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 3)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 3,
            prefetchDepth: 0,
            concurrentDecodes: 3,
            decodeByteBudget: 1_024
        )
        let keys = (0 ..< 3).map { WorkKey("row:\($0)") }
        await executor.apply(
            ReplanDirective(epoch: .initial, plan: plan, admit: keys, cancel: [], retain: [])
        )
        await settle { await runner.distinctStarted() == 3 }

        await executor.cancelAll()
        await settle {
            var seen = 0
            for key in keys where await runner.cancellationCount(key) == 1 { seen += 1 }
            return seen == 3
        }

        for key in keys {
            let observed = await runner.cancellationCount(key)
            XCTAssertEqual(observed, 1, "\(key) was dropped from the executor but never actually cancelled")
        }
    }

    func testCancelAllStopsEverything() async {
        let runner = BlockingRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 4)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 8,
            prefetchDepth: 0,
            concurrentDecodes: 4,
            decodeByteBudget: 1_024
        )
        await executor.apply(
            ReplanDirective(
                epoch: .initial,
                plan: plan,
                admit: (0 ..< 8).map { WorkKey("row:\($0)") },
                cancel: [],
                retain: []
            )
        )
        await settle { await runner.startedKeys().count >= 4 }
        await executor.cancelAll()

        let state = await executor.snapshot()
        XCTAssertTrue(state.running.isEmpty)
        XCTAssertTrue(state.queued.isEmpty)
        XCTAssertEqual(state.cancelCount, 4, "the four that were running were cancelled")
    }

    /// Under a binding concurrency limit, *which* work starts is the whole
    /// question — and the answer must be the planner's answer.
    ///
    /// `ReplanDirective.admit` is sorted lexicographically so that two runs over
    /// the same input produce byte-identical directives. That is reproducibility,
    /// not scheduling: consuming it directly starts `row:10` before `row:2`,
    /// because `"1" < "2"`. This is the test that catches it.
    func testTheConcurrencyLimitStartsTheRowsNearestTheAnchorFirst() async {
        let runner = BlockingRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 3)

        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 12,
            prefetchDepth: 0,
            concurrentDecodes: 3,
            decodeByteBudget: 1_024
        )
        // Anchor at row 0: priority is distance, so 0, 1, 2 are the three that
        // must run and 3, 4, 5 the head of the queue. Lexicographic order would
        // pick 0, 1, 10.
        let keys = (0 ..< 12).map { WorkKey("row:\($0)") }
        var priorities: [WorkKey: Int] = [:]
        for (index, key) in keys.enumerated() { priorities[key] = index }

        await executor.apply(
            ReplanDirective(
                epoch: .initial,
                plan: plan,
                admit: keys,
                cancel: [],
                retain: [],
                admissionPriority: priorities
            )
        )
        await settle { await runner.startedKeys().count >= 3 }

        let state = await executor.snapshot()
        XCTAssertEqual(
            state.running,
            [WorkKey("row:0"), WorkKey("row:1"), WorkKey("row:2")],
            "the executor started the wrong rows — priority died at the directive boundary"
        )
        XCTAssertEqual(
            Array(state.queued.prefix(3)),
            [WorkKey("row:3"), WorkKey("row:4"), WorkKey("row:5")],
            "the queue must be in priority order too, not lexicographic"
        )

        await executor.cancelAll()
    }

    /// Work that has not started has cost nothing, so a newly admitted row
    /// beside the anchor must not wait behind a stale row far from it.
    func testNewlyAdmittedHigherPriorityWorkJumpsThePendingQueue() async {
        let runner = BlockingRunner()
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 1)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 8,
            prefetchDepth: 0,
            concurrentDecodes: 1,
            decodeByteBudget: 1_024
        )

        let far = (5 ..< 9).map { WorkKey("row:\($0)") }
        await executor.apply(
            ReplanDirective(
                epoch: .initial,
                plan: plan,
                admit: far,
                cancel: [],
                retain: [],
                admissionPriority: Dictionary(uniqueKeysWithValues: far.enumerated().map { ($1, 50 + $0) })
            )
        )
        await settle { await runner.startedKeys().count >= 1 }

        let near = WorkKey("row:1")
        await executor.apply(
            ReplanDirective(
                epoch: Epoch(1),
                plan: plan,
                admit: [near],
                cancel: [],
                retain: [],
                admissionPriority: [near: 0]
            )
        )
        await settle { await executor.snapshot().queued.first == near }

        let state = await executor.snapshot()
        XCTAssertEqual(state.queued.first, near, "the nearer row must be next to start")
        XCTAssertEqual(state.running.count, 1, "and nothing already running was disturbed")

        await executor.cancelAll()
    }

    func testZeroOrNegativeConcurrencyLimitIsClampedRatherThanDeadlocking() async {
        let runner = RecordingRunner(ticks: 1)
        let executor = WorkExecutor(runner: runner, concurrencyLimit: 0)
        let plan = CapacityPlan(
            displayClass: .compact,
            visibleWindow: 1,
            prefetchDepth: 0,
            concurrentDecodes: 0,
            decodeByteBudget: 1_024
        )
        XCTAssertEqual(plan.concurrentDecodes, 1, "a zero-decoder plan is a deadlock, not a setting")
        await executor.apply(
            ReplanDirective(
                epoch: .initial,
                plan: plan,
                admit: [WorkKey("row:0")],
                cancel: [],
                retain: []
            )
        )
        await settle { await runner.totalStarts() == 1 }
        let totalStarts = await runner.totalStarts()
        XCTAssertEqual(totalStarts, 1, "work must still make progress")
    }
}
