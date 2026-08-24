# DisplayContinuityKit

**Every published iPhone Fold guide stops at "adopt `NavigationSplitView`." That solves the layout. It does not solve the part that breaks.**

The unfold is not a layout event. It is a **capacity event that lands mid-flight.**

Viewport area roughly doubles. A detail pane appears that nobody scrolled to and demands content immediately. Prefetch depth and decode budgets that were correct one frame ago are now wrong — while requests planned under the old budget are still in the air. The transition can land mid-request, mid-animation, mid-playback. And it can reverse two seconds later, because the user unfolded to glance at something.

`NavigationSplitView` reflows your views. It has nothing to say about any of that.

This package is the layer underneath: it turns a stream of surface observations into a stream of **diffs**, so a display-class change re-plans in-flight work instead of restarting it.

---

## Why this matters

The iPhone Fold ships in September running iOS 27 — not iPadOS, so iPad layouts do not transfer. Apple's `Parallel View` guarantees your app *runs* on the inner display. It guarantees nothing about what your app *does* to the network and to memory at the moment the hinge opens.

The default behaviour, if you write none of this, is:

- Every in-flight request is cancelled and immediately reissued, because the view hierarchy was rebuilt and the new one does not know the old one had already asked.
- The detail pane fires its own uncoordinated fetch that races the list's.
- A user who unfolds and folds back within two seconds pays for two full cancel-and-refetch cycles for content that never left memory.
- Selection state ends up owned by two different screens, seeded from each other exactly once, and desynchronised on every subsequent fold.

None of those are layout bugs. None are caught by a snapshot test. All four are the same missing abstraction.

---

## The two halves

This is deliberately a **system design** problem *and* an **architecture** problem, and the package addresses both rather than picking one.

### Macro — how work survives a capacity change

| Component | Responsibility |
|---|---|
| `CapacityPlan` | The derived budget for a display class: visible window, prefetch depth, concurrent decodes, decode byte budget. |
| `CapacityPolicy` | Derives the budget from geometry. Injectable — a video app and a text feed do not want the same decode budget. |
| `ContinuityPlanner` | An `actor`. Diffs desired work against in-flight work and emits `ReplanDirective { admit, cancel, retain }`. |
| `TransitionCoalescer` | Collapses a fold/unfold storm. Growth applies immediately; shrink defers its cancellations. |
| `WorkLedger` | The bounded in-flight set, with priority eviction. |
| `Epoch` | A monotonic plan generation stamped onto every unit of work, so a late response from a superseded plan is *identifiable* rather than indistinguishable. |
| `WorkExecutor` / `WorkRunning` | The reference consumer. Turns `admit` into real running `Task`s, `cancel` into real cancellation, and `retain` into **nothing at all**. Enforces `concurrentDecodes` as a hard limit, ordering the overflow by `ReplanDirective.admissionPriority`. |
| `FoldStormDriver` | Replays scripted transition sequences with time supplied by fiat and checks six continuity invariants. |

### Micro — who owns the state a disappearing pane was holding

| Component | Responsibility |
|---|---|
| `DisplayClass` | The only type that knows a foldable exists. Feature modules never branch on device or screen. |
| `SurfaceStore` | State scoped to the **surface**, which outlives any particular pane. Bounded, LRU-evicting. |
| `PaneProjection` | A computed value, not stored state. Both display classes project from one source of truth, which makes a second source of truth *unrepresentable* rather than merely discouraged. |
| `ContinuitySnapshot` | A versioned, all-or-nothing restoration contract. |

---

## The design decisions, and what was rejected

### 1. A re-plan is a diff, not a new state

`ReplanDirective` carries seven fields. Three of them are the instruction, and `retain` is the one that matters:

```swift
public struct ReplanDirective {
    public let admit: [WorkKey]    // start these
    public let cancel: [WorkKey]   // stop these
    public let retain: [WorkKey]   // already in flight and still wanted — do NOT restart
    public let admissionPriority: [WorkKey: Int]   // lower is more important
    // …plus `epoch`, `plan`, and `deferredCancellations` (informational:
    //    cancellations computed but held pending a possible reversal)
}
```

**Rejected:** "here is the new desired set, go make it so." Simpler API, and the executor has no way to tell which of those requests are already in the air. That *is* the duplicated-fetch bug, expressed as an interface.

`admissionPriority` is there because `admit` is sorted **lexicographically**, and that ordering is for reproducible diffs, not for scheduling. An executor bounded by `concurrentDecodes` cannot start everything it is handed, so it has to choose — and reading `admit` in order starts `row:10` before `row:2`, because `"1" < "2"`. The planner's ranking has to cross the directive boundary or it is decoration. (It did not, for a while: a review found the executor advertising "a priority queue behind it" over a type that carried no priority at all.)

`WorkExecutor` is the reference consumer, and it exists so this is a measured claim rather than a rhetorical one. `WorkExecutorTests` drives the real planner through a fold storm, hands every directive to the real executor, and asserts that **no unit of work is ever started twice** — then does it again with a deliberately naive executor that folds `retain` into `admit`, and asserts that one *does* restart work. Without the negative control, the first test would only prove the planner never emitted a duplicate, not that honouring `retain` matters.

### 2. Growth and shrink are handled asymmetrically

- **Growth (`.compact` → `.expanded`) applies immediately.** The user is looking at a newly-revealed pane. Delay here is a visible empty half-screen — the one artefact of a fold transition anyone actually reports.
- **Shrink defers its cancellations for ~1.2 s.** Cancelling is a resource optimisation nobody perceives; nothing on the cover display is waiting on it. Deferring costs a bounded amount of wasted bandwidth and buys total immunity to the reverse-within-a-second case.

**Rejected:** a symmetric debounce on both edges. One fewer state, less code — and it makes the unfold feel slow, trading the invisible cost for the visible one, which is exactly backwards.

**Rejected:** cancel eagerly and let an HTTP cache make the refetch cheap. That assumes the work is a cacheable `GET`. Decodes, database reads and on-device inference are none of those things.

**The honest limit of "a reversal costs nothing":** `apply` takes one `SurfaceInput`, so a fold and a scroll that arrive together are a single observation. Reverse the fold *and* scroll a screenful in the same gesture and the held cancellations for rows you scrolled away from are issued, because those rows genuinely are not wanted any more. The guarantee is "reversing the fold does not itself cost anything", not "nothing is ever cancelled inside the window".

### 3. Prefetch depth scales *sub-linearly* with area; the decode budget tracks the plan, not the glass

Unfolding roughly doubles the viewport area but only widens the primary list by about 15% — the extra room goes to the detail pane, not to more rows. And scroll *velocity* does not change at all. So scaling prefetch with area would buy latency the user never perceives at a real network cost. Prefetch tracks `√area`: 4 rows on the cover display, 5 on the inner one.

The decode budget tracks the **plan**, not the glass: `(visibleWindow + prefetchDepth) × bytesPerRow`. Note that this is deliberately narrower than `admissionWindow` (`visibleWindow + 2 × prefetchDepth`) — they answer different questions. The admission window counts rows that may be *in flight*, prefetched in both directions. The decode budget counts rows that may be *decoded and resident at once*, which is the rows in front of the user; prefetch behind the anchor is fetched but not held as a bitmap, because scrolling backwards is the rarer motion and bitmaps are the expensive part. Bytes resident and requests outstanding are not one budget.

**Rejected:** scaling the decode budget by raw viewport area. The inner display is 1.94× the area (587,120 pt² against 302,064), but the rows that can be resident go from 12 to 14 — 1.17×. An area-scaled budget would authorise 12 × 1.94 ≈ 23 rows' worth of bytes against a plan that can never hold more than 14: **67% headroom that never binds.** A ceiling that never binds is not a budget.

`CapacityPolicyTests.testPrefetchScalesWithTheSquareRootOfAreaNotWithArea` fails if anyone "simplifies" this back. The obvious version of that test did **not** — it shipped vacuous, and a review caught it. Comparing only the cover and inner displays and asserting `prefetchRatio < areaRatio` passes against a *linear* implementation, because `4 × 1.9437 = 7.77` truncates to `7` and `7/4 = 1.75 < 1.94` holds anyway. Integer truncation manufactured the sub-linearity the test claimed to detect. The current version asserts the law across 4×, 9× and 16× areas, where truncation cannot hide it, and swapping `.squareRoot()` for `areaRatio` now turns 12 tests red.

### 4. Concurrency is served by having no suspension points, not by locks

Every mutating entry point on `ContinuityPlanner` is a **synchronous actor-isolated method**. None contains an `await`, so none has a suspension point, so there is no window in which a second caller observes half-applied state.

That constraint is why `CapacityPolicy`, `DemandModel` and `DisplayClassResolving` are all synchronous protocols. Making any of them `async` would reintroduce exactly the interleaving this type exists to remove.

For a while nothing enforced that. Making `replan` async and dropping a single `await Task.yield()` between freezing the admission list and consuming it left the whole suite green — while producing genuine duplicate admissions. `testConcurrentRePlansNeverAdmitTheSameWorkTwice` now closes it, and the interesting part is *how*, because there is no way to recover an actor's true serialisation order from outside it. It asserts two **order-independent** counting invariants over all 64 racing directives:

1. A key can only be started again after it has been stopped: `admits(key) ≤ cancels(key) + 1`.
2. Retaining a key asserts it is already in flight, so anything retained must appear in some `admit`.

Both hold for any serial sequence of atomic passes and both break under interleaving. Restoring the suspension point produces `row:13 was started 6 times against 2 stops`.

### 5. Restoration is versioned and all-or-nothing

`@SceneStorage` restores what you hand it, one property at a time, with no notion of whether the set is mutually consistent. `ContinuitySnapshotCoder` enforces three rules:

1. **Unknown extra fields are tolerated** — a newer build must not brick an older reader during a staged rollout.
2. **A missing required field rejects the whole payload** — not "default it and carry on." That is how the half-restored surface happens.
3. **An unrecognised schema version rejects, in *both* directions.** Rejecting a newer payload is obvious. Rejecting an *older* one is the part teams skip, and it is the one that matters: v1 stored a screen-scoped selection, which under v2's surface-scoped model restores the wrong pane.

Rejection is never a crash and never a partial apply. The user gets a clean surface — worse for one launch, correct forever after.

### 6. Everything that can trap, saturates

A layout pass mid-transition is exactly where a `NaN` viewport comes from (a division by a container that has not been measured yet). `Int(someDouble)` traps on `NaN`, on ±infinity, and out of range; `*` and `+` trap on overflow; `/` and `%` trap on zero; `Int.min / -1` traps; `abs(Int.min)` traps.

All of it funnels through one `Saturating` type, and every ceiling is derived from `Int.max` / `Int.min` rather than a 64-bit literal — so the behaviour is correct where `Int` is 32-bit.

Two of these are worth naming because the obvious version of each is wrong in a way that only shows up at a magnitude no test author would pick:

- **`dimension` and `product` deliberately disagree about infinity.** An infinite *input* is garbage — the signature of dividing by an unmeasured container — so it collapses to `0`. An infinite *product* of two finite dimensions is a genuinely enormous area, so it saturates. Collapsing the second makes every area-derived budget **non-monotone**: a 1e150-square viewport got the maximum prefetch depth while a strictly larger 1e200-square one got the minimum. The absurd-geometry test used 1e150 — the one value whose square is still finite.
- **A capacity is a policy bound, not an expected size.** `WorkLedger` used to `reserveCapacity` its own bound, so the type whose entire premise is "a hard capacity is the only bound that holds under adversarial input" died on `swift_slowAlloc` at 10⁸ and trapped inside the stdlib at `Int.max` — before admitting a single record, reachable straight from the public `ContinuityPlanner` initialiser.

---

## The test suite is designed to be able to fail

**132 tests across 10 suites.** The ones worth looking at are in `FoldStormDriverTests`.

`FoldStormDriver` checks six invariants — no duplicated fetches, no cancel-without-admission, no admit-and-cancel in one directive, no retention lie, no epoch regression, no unbounded growth (of either the in-flight set or the held-cancellation set). An invariant checker that has only ever been run against a correct implementation has not been shown to catch anything, so the suite ships **five deliberately broken planners** and asserts the driver goes red for each:

| Mutant | Breaks |
|---|---|
| `NaiveRestartPlanner` | Emits the whole desired set as `admit` every time, never retains — the realistic bug |
| `ChurningPlanner` | Same key in `admit` and `cancel` in one directive |
| `RegressingEpochPlanner` | Walks the plan generation backwards |
| `UnboundedPlanner` | Admits without bound |
| `LyingRetainPlanner` | Reports cancelled work as retained — a lie that reads as a continuity win on a dashboard |

`testDriverDiscriminatesBetweenCorrectAndBrokenPlanners` asserts the real planner passes **and** all five mutants fail, in one test. Gutting the driver's checks turns that red.

This is not decoration. **The harness and two rounds of independent adversarial review have each caught real bugs,** and every fix is commented at the site:

1. A key evicted partway through an admission pass was re-admitted later in the same pass, landing in both `cancel` and `admit`. Only reproduces under ledger pressure. Fix: freeze the admission list before the loop. *(Found by `FoldStormDriver`.)*
2. The held-cancellation set was pruned only against the *desired* set, so a key evicted while held was cancelled twice — once as an eviction, again on settle — and the held set grew without bound. The reproducer is mundane: **fold the phone, then keep scrolling.** Fix: re-derive the held set from the ledger, which also bounds it by `ledgerCapacity`.
3. The demand window **slid** off the front of the feed and **truncated** against the back — so the bottom of a feed, where pagination pressure is highest, silently got 9 rows of a 16-row window, and any stale anchor collapsed it to 1. The start-of-feed test asserted a row count; its mirror did not. The asymmetry in the assertions was the asymmetry in the code.
4. `WorkLedger` reserved its own policy bound, crashing at construction for a large enough capacity (see §6).
5. `WorkExecutor` advertised a priority queue over a directive that carried no priorities, so it started rows in lexicographic order — `row:10` ahead of `row:2` (see §1).

### The mutation matrix

Every claim above is re-derived by breaking the implementation and confirming the suite notices. Baseline is 132 tests, 0 failures.

| Mutation | Result |
|---|---|
| Delete the `heldCancellations` ledger filter | **19 failures** — `the held set grew past the ledger it is supposed to describe` |
| Re-read `!ledger.contains` live inside the admission loop | **2 failures** — `row:… was both admitted and cancelled in one directive` |
| Suspend between freezing the admission list and consuming it | **36 failures** — `row:13 was started 6 times against 2 stops` |
| Scale prefetch linearly with area | **12 failures** |
| Truncate the demand window at the tail instead of sliding | **7 failures** |
| Collapse an overflowed area to `0` | **3 failures** |
| Make the executor consume `admit` rather than `admissionOrder` | **3 failures** |
| `reserveCapacity` the ledger's policy bound | **process crash** — `swift_slowAlloc` via `Dictionary.reserveCapacity` |
| Defer growth symmetrically with shrink | **13 failures** |
| Drop `.sortedKeys` from the snapshot encoder | **1 failure** |

Other things the suite deliberately does *not* do:

- **No test calls a pure function twice and asserts the results match.** The encoder test asserts the emitted JSON keys are in *ascending order* — a property that disappears if `.sortedKeys` is removed — rather than that a pure function is deterministic within one process, which holds either way.
- **No test asserts a value lies inside a range the implementation computed by clamping.** The pathological-anchor test asserts a *full window* of rows inside the feed, not merely that whatever came back was in range — the weaker version passed against a window that had collapsed to one row.
- **Concurrency is asserted twice, at two different scopes.** Per-directive coherence (disjoint sets, bounded counts) across 64 real `TaskGroup` writers, *and* the cross-directive counting invariants in §4. The first is necessary and provably insufficient: it stays green against an interleaving planner, because each individual directive remains internally coherent while the run as a whole double-starts work.
- Determinism is asserted across two **independently constructed** planners running the same script, not by calling one planner twice.

### What the suite does not cover

`DisplayContinuityUI` has **no unit tests**. SwiftUI does not exist on the Linux runner where the suite executes, so the module compiles to zero symbols there; the macOS CI job builds it for an iOS Simulator destination but runs nothing. Everything asserted above is about `DisplayContinuity`, which is where all the logic deliberately lives — but "132 tests" is not a number about the view layer, and the two `ContinuityDemoModel` races fixed in review were found by reading, not by a failing test.

---

## Usage

```swift
.package(url: "https://github.com/rajatslakhina/display-continuity-kit.git", from: "1.0.0")
```

```swift
import DisplayContinuity

let planner = ContinuityPlanner(
    initialViewport: .coverDisplay,
    demandModel: WindowedDemandModel(itemCount: feed.count)
)

// On every geometry change, scroll, or selection change:
let directive = await planner.apply(
    SurfaceInput(viewport: viewport, anchor: firstVisibleRow, selection: selectedItem),
    at: MonotonicInstant(milliseconds: elapsedMilliseconds)
)

for key in directive.cancel { executor.cancel(key) }
for key in directive.admit  { executor.start(key, epoch: directive.epoch) }
// directive.retain is the work you did NOT have to touch.
```

Or hand it to the reference executor, which does exactly that and enforces `concurrentDecodes`:

```swift
let executor = WorkExecutor(runner: myFetcher)   // myFetcher: some WorkRunning
await executor.apply(directive)
```

Verify your own integration under a storm:

```swift
let report = await FoldStormDriver(inFlightBound: 64).run(
    [.unfold(after: 200), .fold(after: 180), .unfold(after: 150)],
    against: planner
)
XCTAssertTrue(report.passed, "\(report.violations)")
```

---

## Verification — what was actually checked

Stated precisely, because "it builds" and "it runs" are different claims and only one of them was earned here.

| Check | Status |
|---|---|
| `swift build -Xswiftc -warnings-as-errors`, from a deleted `.build` | **Passed**, 0 warnings |
| `swift test -Xswiftc -warnings-as-errors` | **Passed** — 132 tests, 0 failures, 10 suites |
| Suite shown able to fail | **Yes** — 10 mutations, each one verified red; see the mutation matrix above |
| Toolchain used locally | Swift 6.0.3, `aarch64-unknown-linux-gnu` |
| Linux CI (`swift:6.0` container) | **Green** — see [Actions](../../actions). Builds and tests the core with warnings as errors |
| iOS CI (`macos-15`) | **Green** — see [Actions](../../actions). Compiles `DisplayContinuityUI` for `generic/platform=iOS Simulator` |
| SwiftUI layer **executed** on a Simulator | **No.** See below — this is a separate claim from "it compiles for a Simulator destination", and only the compile claim was earned. |

The core is platform-agnostic Swift by design, precisely so it can be fully tested headlessly rather than only eyeballed. The SwiftUI layer is compiled by CI for an iOS Simulator destination, but **nothing here was ever launched and interacted with on a running Simulator.** The automated run that produced this repo requested Simulator access three times and was refused each time with:

> Computer-use access to "Simulator", "Xcode 26.3" can't be approved during a scheduled run. To grant it, send a message in this conversation (the approval card will appear), or add the app to the scheduled task's settings.

Consequently there are **no screenshots** anywhere in either repo, and no mockup stands in for one.

**Demo app:** [rajatslakhina/display-continuity-demo-app](https://github.com/rajatslakhina/display-continuity-demo-app) — a SwiftUI app that consumes this package as a **version-pinned remote** dependency (`upToNextMajorVersion` from `1.0.0`), not a local path. Its CI job resolves this package from GitHub on a clean `macos-15` runner with nothing cached and compiles the app against it; that repo's Actions tab is the record of whether it did. That is the cheapest honest proof that the published package works as a dependency — and it is a *compile* proof, not a run proof.

---

## Requirements

Swift 6.0+ · iOS 17+ · macOS 14+ · Swift 6 language mode

## Licence

MIT
