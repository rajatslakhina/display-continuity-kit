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
| `FoldStormDriver` | Replays scripted transition sequences with time supplied by fiat and checks five continuity invariants. |

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

`ReplanDirective` has three fields, and `retain` is the one that matters:

```swift
public struct ReplanDirective {
    public let admit: [WorkKey]    // start these
    public let cancel: [WorkKey]   // stop these
    public let retain: [WorkKey]   // already in flight and still wanted — do NOT restart
}
```

**Rejected:** "here is the new desired set, go make it so." Simpler API, and the executor has no way to tell which of those requests are already in the air. That *is* the duplicated-fetch bug, expressed as an interface.

### 2. Growth and shrink are handled asymmetrically

- **Growth (`.compact` → `.expanded`) applies immediately.** The user is looking at a newly-revealed pane. Delay here is a visible empty half-screen — the one artefact of a fold transition anyone actually reports.
- **Shrink defers its cancellations for ~1.2 s.** Cancelling is a resource optimisation nobody perceives; nothing on the cover display is waiting on it. Deferring costs a bounded amount of wasted bandwidth and buys total immunity to the reverse-within-a-second case.

**Rejected:** a symmetric debounce on both edges. One fewer state, less code — and it makes the unfold feel slow, trading the invisible cost for the visible one, which is exactly backwards.

**Rejected:** cancel eagerly and let an HTTP cache make the refetch cheap. That assumes the work is a cacheable `GET`. Decodes, database reads and on-device inference are none of those things.

### 3. Prefetch depth scales *sub-linearly* with area; decode budget scales linearly

The unfolded surface shows roughly twice the rows, but scroll *velocity* does not double — so doubling prefetch buys latency the user never perceives at twice the network cost. Prefetch tracks `√area`; the decode budget tracks `area`, because what is resident genuinely does double.

**Rejected:** linear scaling for both. Simpler, and measurably wasteful. `CapacityPolicyTests.testPrefetchScalesSubLinearlyWithArea` fails if anyone "simplifies" it back.

### 4. Concurrency is served by having no suspension points, not by locks

Every mutating entry point on `ContinuityPlanner` is a **synchronous actor-isolated method**. None contains an `await`, so none has a suspension point, so there is no window in which a second caller observes half-applied state.

That constraint is why `CapacityPolicy`, `DemandModel` and `DisplayClassResolving` are all synchronous protocols. Making any of them `async` would reintroduce exactly the interleaving this type exists to remove.

### 5. Restoration is versioned and all-or-nothing

`@SceneStorage` restores what you hand it, one property at a time, with no notion of whether the set is mutually consistent. `ContinuitySnapshotCoder` enforces three rules:

1. **Unknown extra fields are tolerated** — a newer build must not brick an older reader during a staged rollout.
2. **A missing required field rejects the whole payload** — not "default it and carry on." That is how the half-restored surface happens.
3. **An unrecognised schema version rejects, in *both* directions.** Rejecting a newer payload is obvious. Rejecting an *older* one is the part teams skip, and it is the one that matters: v1 stored a screen-scoped selection, which under v2's surface-scoped model restores the wrong pane.

Rejection is never a crash and never a partial apply. The user gets a clean surface — worse for one launch, correct forever after.

### 6. Everything that can trap, saturates

A layout pass mid-transition is exactly where a `NaN` viewport comes from (a division by a container that has not been measured yet). `Int(someDouble)` traps on `NaN`, on ±infinity, and out of range; `*` and `+` trap on overflow; `/` and `%` trap on zero; `Int.min / -1` traps.

All of it funnels through one `Saturating` type, and every ceiling is derived from `Int.max` / `Int.min` rather than a 64-bit literal — so the behaviour is correct where `Int` is 32-bit.

---

## The test suite is designed to be able to fail

**100 tests across 8 suites.** The ones worth looking at are in `FoldStormDriverTests`.

`FoldStormDriver` checks five invariants — no duplicated fetches, no cancel-without-admission, no admit-and-cancel in one directive, no epoch regression, no unbounded growth. An invariant checker that has only ever been run against a correct implementation has not been shown to catch anything, so the suite ships **five deliberately broken planners** and asserts the driver goes red for each:

| Mutant | Breaks |
|---|---|
| `NaiveRestartPlanner` | Emits the whole desired set as `admit` every time, never retains — the realistic bug |
| `ChurningPlanner` | Same key in `admit` and `cancel` in one directive |
| `RegressingEpochPlanner` | Walks the plan generation backwards |
| `UnboundedPlanner` | Admits without bound |
| `LyingRetainPlanner` | Reports cancelled work as retained — a lie that reads as a continuity win on a dashboard |

`testDriverDiscriminatesBetweenCorrectAndBrokenPlanners` asserts the real planner passes **and** all five mutants fail, in one test. Gutting the driver's checks turns that red.

This is not decoration. The harness caught a genuine bug in `ContinuityPlanner` during development that only appeared under ledger pressure: a key evicted partway through an admission pass was re-admitted later in the same pass, landing in both `cancel` and `admit`. The fix — freezing the admission list before the loop — is commented at the site.

Other things the suite deliberately does *not* do: no test calls a pure function twice and asserts the results match; no test asserts a value lies inside a range the implementation computed by clamping. Determinism is asserted across two **independently constructed** planners running the same script. Concurrency tests use real `TaskGroup` writers racing the actor — 64 tasks with out-of-order clock reads — not a sequential loop wearing an `async` hat.

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
| `swift test -Xswiftc -warnings-as-errors` | **Passed** — 100 tests, 0 failures, 8 suites |
| Toolchain used locally | Swift 6.0.3, `aarch64-unknown-linux-gnu` |
| Linux CI (`swift:6.0` container) | See [Actions](../../actions) — builds and tests the core with warnings as errors |
| iOS CI (`macos-15`) | See [Actions](../../actions) — compiles `DisplayContinuityUI` for `generic/platform=iOS Simulator` |
| SwiftUI layer executed on a Simulator | **Not in this repo.** See the demo app below. |

The core is platform-agnostic Swift by design, precisely so it can be fully tested headlessly rather than only eyeballed.

**Demo app:** (added after the companion repo is pushed — see below)

---

## Requirements

Swift 6.0+ · iOS 17+ · macOS 14+ · Swift 6 language mode

## Licence

MIT
