// SurfaceStore.swift
//
// The micro-architecture half of the problem.
//
// The bug every fold migration ships: selection state owned by the *screen*.
// In `.compact` the list screen owns "which row is pushed". On unfold, a detail
// pane materialises and needs to know what to show — so it gets its own
// `@State`. Now there are two sources of truth for one fact, they are seeded
// from each other at exactly one moment, and every subsequent fold desynchronises
// them. The symptom is a detail pane showing the row the user selected two
// selections ago.
//
// The fix is an ownership boundary, not a synchronisation mechanism: state is
// scoped to the *surface*, which outlives any particular pane, and both panes
// are pure projections of it.

/// State owned at surface scope. Survives every display-class change, because
/// nothing about it is derived from the display class.
public struct SurfaceState: Sendable, Hashable, Codable {
    public var selection: ItemID?
    /// Index of the row the list is anchored on. Clamped to `>= 0`.
    public var anchor: Int

    public init(selection: ItemID? = nil, anchor: Int = 0) {
        self.selection = selection
        self.anchor = max(0, anchor)
    }
}

/// What a given display class should render, derived from one `SurfaceState`.
///
/// Note there is no setter here and no stored state — a projection is a value
/// computed on demand. That is what makes a second source of truth
/// unrepresentable rather than merely discouraged.
public struct PaneProjection: Sendable, Hashable {
    /// Row highlighted in the list. Present in both classes: in `.compact` it
    /// is the row the user pushed *from*, which is what makes the back-nav
    /// restore its scroll position.
    public let listSelection: ItemID?
    /// Content for the detail pane. `nil` in `.compact`, where detail is pushed
    /// rather than shown alongside.
    public let detail: ItemID?
    public let showsDetailPane: Bool
    /// True when the detail pane is visible but has nothing selected — the
    /// empty state a naive migration renders as a blank half-screen.
    public var needsDetailPlaceholder: Bool { showsDetailPane && detail == nil }

    public init(listSelection: ItemID?, detail: ItemID?, showsDetailPane: Bool) {
        self.listSelection = listSelection
        self.detail = detail
        self.showsDetailPane = showsDetailPane
    }
}

/// Surface-scoped state, bounded.
///
/// The bound matters: a tab-per-surface app with deep linking can mint surface
/// IDs indefinitely, and a dictionary that only ever grows is a leak with a
/// slow fuse. Eviction is least-recently-touched.
public actor SurfaceStore {
    private var states: [SurfaceID: SurfaceState]
    /// Monotonic touch counter per surface, for LRU eviction.
    private var touchOrder: [SurfaceID: Int]
    private var tick: Int
    /// `nonisolated` because it is immutable: a caller asking how big the store
    /// is should not have to `await` a value that can never change.
    public nonisolated let capacity: Int

    public init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
        self.states = [:]
        self.touchOrder = [:]
        self.tick = 0
    }

    public var count: Int { states.count }

    /// Current state for a surface, creating a default one if absent.
    @discardableResult
    public func state(for surface: SurfaceID) -> SurfaceState {
        touch(surface)
        if let existing = states[surface] { return existing }
        let fresh = SurfaceState()
        insert(fresh, for: surface)
        return fresh
    }

    public func select(_ item: ItemID?, in surface: SurfaceID) {
        var state = state(for: surface)
        state.selection = item
        insert(state, for: surface)
    }

    public func setAnchor(_ anchor: Int, in surface: SurfaceID) {
        var state = state(for: surface)
        state.anchor = max(0, anchor)
        insert(state, for: surface)
    }

    /// The projection a pane should render.
    ///
    /// Both display classes read the *same* stored selection. On unfold the
    /// detail pane materialises already populated; on fold it disappears and
    /// the selection is untouched. No handoff, no seeding, nothing to
    /// desynchronise.
    /// - Note: this is a **pure read**. It does not create, touch or evict a
    ///   surface. Rendering a pane must never be able to evict someone else's
    ///   state — a read that writes is how a fold transition ends up dropping
    ///   the surface the user is about to return to.
    public func projection(for surface: SurfaceID, displayClass: DisplayClass) -> PaneProjection {
        let state = states[surface] ?? SurfaceState()
        return PaneProjection(
            listSelection: state.selection,
            detail: displayClass.showsDetailPane ? state.selection : nil,
            showsDetailPane: displayClass.showsDetailPane
        )
    }

    /// Captures a restorable snapshot of a surface. Also a pure read.
    public func snapshot(
        of surface: SurfaceID,
        displayClass: DisplayClass,
        epoch: Epoch
    ) -> ContinuitySnapshot {
        let state = states[surface] ?? SurfaceState()
        return ContinuitySnapshot(
            surfaceID: surface,
            selection: state.selection,
            anchor: state.anchor,
            displayClass: displayClass,
            epoch: epoch
        )
    }

    /// Restores a surface from a snapshot that has already been validated.
    public func restore(_ snapshot: ContinuitySnapshot) {
        insert(
            SurfaceState(selection: snapshot.selection, anchor: snapshot.anchor),
            for: snapshot.surfaceID
        )
    }

    // MARK: - Bounded storage

    private func touch(_ surface: SurfaceID) {
        tick = Saturating.add(tick, 1)
        touchOrder[surface] = tick
    }

    private func insert(_ state: SurfaceState, for surface: SurfaceID) {
        states[surface] = state
        touch(surface)
        evictIfNeeded(keeping: surface)
    }

    private func evictIfNeeded(keeping protected: SurfaceID) {
        while states.count > capacity {
            // Least-recently-touched, never the surface being written.
            let victim = states.keys
                .filter { $0 != protected }
                .min { lhs, rhs in
                    let l = touchOrder[lhs] ?? 0
                    let r = touchOrder[rhs] ?? 0
                    return l == r ? lhs.rawValue < rhs.rawValue : l < r
                }
            guard let victim else { break }
            states.removeValue(forKey: victim)
            touchOrder.removeValue(forKey: victim)
        }
    }
}
// SurfaceStore.swift
//
// The micro-architecture half of the problem.
//
// The bug every fold migration ships: selection state owned by the *screen*.
// In `.compact` the list screen owns "which row is pushed". On unfold, a detail
// pane materialises and needs to know what to show — so it gets its own
// `@State`. Now there are two sources of truth for one fact, they are seeded
// from each other at exactly one moment, and every subsequent fold desynchronises
// them. The symptom is a detail pane showing the row the user selected two
// selections ago.
//
// The fix is an ownership boundary, not a synchronisation mechanism: state is
// scoped to the *surface*, which outlives any particular pane, and both panes
// are pure projections of it.

/// State owned at surface scope. Survives every display-class change, because
/// nothing about it is derived from the display class.
public struct SurfaceState: Sendable, Hashable, Codable {
    public var selection: ItemID?
    /// Index of the row the list is anchored on. Clamped to `>= 0`.
    public var anchor: Int

    public init(selection: ItemID? = nil, anchor: Int = 0) {
        self.selection = selection
        self.anchor = max(0, anchor)
    }
}

/// What a given display class should render, derived from one `SurfaceState`.
///
/// Note there is no setter here and no stored state — a projection is a value
/// computed on demand. That is what makes a second source of truth
/// unrepresentable rather than merely discouraged.
public struct PaneProjection: Sendable, Hashable {
    /// Row highlighted in the list. Present in both classes: in `.compact` it
    /// is the row the user pushed *from*, which is what makes the back-nav
    /// restore its scroll position.
    public let listSelection: ItemID?
    /// Content for the detail pane. `nil` in `.compact`, where detail is pushed
    /// rather than shown alongside.
    public let detail: ItemID?
    public let showsDetailPane: Bool
    /// True when the detail pane is visible but has nothing selected — the
    /// empty state a naive migration renders as a blank half-screen.
    public var needsDetailPlaceholder: Bool { showsDetailPane && detail == nil }

    public init(listSelection: ItemID?, detail: ItemID?, showsDetailPane: Bool) {
        self.listSelection = listSelection
        self.detail = detail
        self.showsDetailPane = showsDetailPane
    }
}

/// Surface-scoped state, bounded.
///
/// The bound matters: a tab-per-surface app with deep linking can mint surface
/// IDs indefinitely, and a dictionary that only ever grows is a leak with a
/// slow fuse. Eviction is least-recently-touched.
public actor SurfaceStore {
    private var states: [SurfaceID: SurfaceState]
    /// Monotonic touch counter per surface, for LRU eviction.
    private var touchOrder: [SurfaceID: Int]
    private var tick: Int
    /// `nonisolated` because it is immutable: a caller asking how big the store
    /// is should not have to `await` a value that can never change.
    public nonisolated let capacity: Int

    public init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
        self.states = [:]
        self.touchOrder = [:]
        self.tick = 0
    }

    public var count: Int { states.count }

    /// Current state for a surface, creating a default one if absent.
    @discardableResult
    public func state(for surface: SurfaceID) -> SurfaceState {
        touch(surface)
        if let existing = states[surface] { return existing }
        let fresh = SurfaceState()
        insert(fresh, for: surface)
        return fresh
    }

    public func select(_ item: ItemID?, in surface: SurfaceID) {
        var state = state(for: surface)
        state.selection = item
        insert(state, for: surface)
    }

    public func setAnchor(_ anchor: Int, in surface: SurfaceID) {
        var state = state(for: surface)
        state.anchor = max(0, anchor)
        insert(state, for: surface)
    }

    /// The projection a pane should render.
    ///
    /// Both display classes read the *same* stored selection. On unfold the
    /// detail pane materialises already populated; on fold it disappears and
    /// the selection is untouched. No handoff, no seeding, nothing to
    /// desynchronise.
    public func projection(for surface: SurfaceID, displayClass: DisplayClass) -> PaneProjection {
        let state = state(for: surface)
        return PaneProjection(
            listSelection: state.selection,
            detail: displayClass.showsDetailPane ? state.selection : nil,
            showsDetailPane: displayClass.showsDetailPane
        )
    }

    /// Captures a restorable snapshot of a surface.
    public func snapshot(
        of surface: SurfaceID,
        displayClass: DisplayClass,
        epoch: Epoch
    ) -> ContinuitySnapshot {
        let state = state(for: surface)
        return ContinuitySnapshot(
            surfaceID: surface,
            selection: state.selection,
            anchor: state.anchor,
            displayClass: displayClass,
            epoch: epoch
        )
    }

    /// Restores a surface from a snapshot that has already been validated.
    public func restore(_ snapshot: ContinuitySnapshot) {
        insert(
            SurfaceState(selection: snapshot.selection, anchor: snapshot.anchor),
            for: snapshot.surfaceID
        )
    }

    // MARK: - Bounded storage

    private func touch(_ surface: SurfaceID) {
        tick = Saturating.add(tick, 1)
        touchOrder[surface] = tick
    }

    private func insert(_ state: SurfaceState, for surface: SurfaceID) {
        states[surface] = state
        touch(surface)
        evictIfNeeded(keeping: surface)
    }

    private func evictIfNeeded(keeping protected: SurfaceID) {
        while states.count > capacity {
            // Least-recently-touched, never the surface being written.
            let victim = states.keys
                .filter { $0 != protected }
                .min { lhs, rhs in
                    let l = touchOrder[lhs] ?? 0
                    let r = touchOrder[rhs] ?? 0
                    return l == r ? lhs.rawValue < rhs.rawValue : l < r
                }
            guard let victim else { break }
            states.removeValue(forKey: victim)
            touchOrder.removeValue(forKey: victim)
        }
    }
}
