// WorkLedger.swift
//
// The ledger of work currently in flight. Bounded by construction: an
// unbounded in-flight set is how a fold/unfold storm turns into an OOM, and
// "the user will not fold it that many times" is not a bound.

/// Identifies a unit of in-flight work — a fetch, a decode, a prefetch.
public struct WorkKey: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A unit of work together with the plan generation that admitted it.
public struct WorkRecord: Sendable, Hashable {
    public let key: WorkKey
    /// The epoch under which this work was admitted. Retained work keeps its
    /// *original* epoch across a re-plan — that is what distinguishes "still
    /// wanted" from "re-requested".
    public let admittedAtEpoch: Epoch
    /// Lower is more important. Conventionally the absolute row distance from
    /// the scroll anchor.
    public let priority: Int

    public init(key: WorkKey, admittedAtEpoch: Epoch, priority: Int) {
        self.key = key
        self.admittedAtEpoch = admittedAtEpoch
        self.priority = priority
    }
}

/// A bounded, priority-evicting set of in-flight work.
///
/// Rejected alternative: an unbounded dictionary plus a periodic sweep. It is
/// simpler, and it makes the bound a function of how often the sweep runs —
/// which under a fold storm is "not often enough". A hard capacity enforced at
/// admission time is the only bound that holds under adversarial input.
public struct WorkLedger: Sendable, Equatable {
    /// Maximum number of records held. Clamped to `>= 0` at construction.
    public let capacity: Int
    private var records: [WorkKey: WorkRecord]

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.records = [:]
        self.records.reserveCapacity(self.capacity)
    }

    public var count: Int { records.count }
    public var isEmpty: Bool { records.isEmpty }

    public func contains(_ key: WorkKey) -> Bool { records[key] != nil }
    public func record(for key: WorkKey) -> WorkRecord? { records[key] }

    /// All keys, in a deterministic order (priority, then key).
    ///
    /// Deterministic ordering matters: `Dictionary` iteration order is seeded
    /// per-process, so a directive built from raw iteration would differ
    /// between runs and make every diff-based test flaky-by-construction.
    public var keysByPriority: [WorkKey] {
        records.values
            .sorted { lhs, rhs in
                lhs.priority == rhs.priority
                    ? lhs.key.rawValue < rhs.key.rawValue
                    : lhs.priority < rhs.priority
            }
            .map(\.key)
    }

    /// Admits a record, evicting the lowest-priority entries if that would
    /// exceed `capacity`.
    ///
    /// - Returns: the keys evicted to make room, in deterministic order. A
    ///   returned key may be the one just admitted, if it was itself the worst
    ///   candidate (or if `capacity == 0`).
    @discardableResult
    public mutating func admit(_ record: WorkRecord) -> [WorkKey] {
        guard capacity > 0 else { return [record.key] }

        // Re-admitting a key already present preserves the *existing* record —
        // in particular its original epoch — so that a retained item is never
        // silently restamped as newly requested.
        if records[record.key] != nil { return [] }

        records[record.key] = record
        guard records.count > capacity else { return [] }

        var evicted: [WorkKey] = []
        // Worst-first: highest priority number, then highest key for a stable
        // tiebreak. Loop rather than a single removal so that a capacity
        // reduction elsewhere cannot leave the ledger permanently over budget.
        while records.count > capacity {
            guard let victim = records.values.max(by: { lhs, rhs in
                lhs.priority == rhs.priority
                    ? lhs.key.rawValue < rhs.key.rawValue
                    : lhs.priority < rhs.priority
            }) else { break }
            records.removeValue(forKey: victim.key)
            evicted.append(victim.key)
        }
        return evicted.sorted { $0.rawValue < $1.rawValue }
    }

    @discardableResult
    public mutating func remove(_ key: WorkKey) -> WorkRecord? {
        records.removeValue(forKey: key)
    }

    public mutating func removeAll() { records.removeAll(keepingCapacity: true) }

    /// Keys present in the ledger but absent from `desired`.
    public func keys(notIn desired: Set<WorkKey>) -> [WorkKey] {
        records.keys.filter { !desired.contains($0) }.sorted { $0.rawValue < $1.rawValue }
    }
}
