// FoldStormDriver.swift
//
// A fold transition is not a thing you can reliably reproduce by hand, and
// "we folded it a bunch of times and it looked fine" is not a regression test.
//
// This driver replays a scripted transition sequence against any
// `ContinuityPlanning` implementation with time supplied by fiat, and checks
// the invariants that distinguish a continuity layer from a reload.
//
// It is designed to be pointed at a *broken* planner and go red — see
// `FoldStormDriverTests`, which does exactly that. An invariant checker that
// has only ever been run against a correct implementation is decoration.

/// One step of a scripted storm.
public struct StormStep: Sendable, Hashable {
    public let input: SurfaceInput
    /// Milliseconds to advance the clock *before* applying this step.
    public let advanceMilliseconds: Int

    public init(input: SurfaceInput, advanceMilliseconds: Int = 0) {
        self.input = input
        self.advanceMilliseconds = max(0, advanceMilliseconds)
    }

    public static func fold(anchor: Int = 0, selection: ItemID? = nil, after milliseconds: Int = 0) -> StormStep {
        StormStep(
            input: SurfaceInput(viewport: .coverDisplay, anchor: anchor, selection: selection),
            advanceMilliseconds: milliseconds
        )
    }

    public static func unfold(anchor: Int = 0, selection: ItemID? = nil, after milliseconds: Int = 0) -> StormStep {
        StormStep(
            input: SurfaceInput(viewport: .innerDisplay, anchor: anchor, selection: selection),
            advanceMilliseconds: milliseconds
        )
    }
}

/// An invariant the planner broke.
public enum InvariantViolation: Sendable, Hashable, CustomStringConvertible {
    /// A key was started a second time without ever having been cancelled.
    /// This is the duplicated-fetch failure, stated precisely.
    case duplicateAdmission(WorkKey, admissions: Int, cancellations: Int)
    /// A key was cancelled that was not in flight.
    case cancelWithoutAdmission(WorkKey)
    /// A key was reported as *retained* while not in flight — a lie that reads
    /// as a continuity win on a dashboard while the content never arrives.
    /// Distinct from `duplicateAdmission` because the diagnosis differs: one is
    /// wasted work, the other is missing work reported as present.
    case retentionLie(WorkKey)
    /// One directive both starts and stops the same key.
    case admitAndCancelInSameDirective(WorkKey)
    /// The plan generation went backwards.
    case epochRegression(from: Epoch, to: Epoch)
    /// In-flight work exceeded the bound it claims to hold.
    case ledgerExceededBound(observed: Int, bound: Int)

    public var description: String {
        switch self {
        case .duplicateAdmission(let key, let admissions, let cancellations):
            return "duplicate admission of \(key): started \(admissions)x, cancelled \(cancellations)x"
        case .cancelWithoutAdmission(let key):
            return "cancelled \(key) which was not in flight"
        case .retentionLie(let key):
            return "reported \(key) as retained while it was not in flight"
        case .admitAndCancelInSameDirective(let key):
            return "\(key) both admitted and cancelled in one directive"
        case .epochRegression(let from, let to):
            return "epoch went backwards: \(from) -> \(to)"
        case .ledgerExceededBound(let observed, let bound):
            return "in-flight work \(observed) exceeded bound \(bound)"
        }
    }
}

/// The result of replaying a storm.
public struct StormReport: Sendable {
    public let directives: [ReplanDirective]
    public let admissionCounts: [WorkKey: Int]
    public let cancellationCounts: [WorkKey: Int]
    public let retentionCount: Int
    public let violations: [InvariantViolation]

    public var passed: Bool { violations.isEmpty }
    public var totalAdmissions: Int { admissionCounts.values.reduce(0, +) }
    public var totalCancellations: Int { cancellationCounts.values.reduce(0, +) }

    /// Work the planner kept rather than restarted, as a fraction of everything
    /// it could have restarted. `1.0` means a perfectly continuous storm.
    public var continuityRatio: Double {
        let denominator = retentionCount + totalAdmissions
        guard denominator > 0 else { return 1.0 }
        return Double(retentionCount) / Double(denominator)
    }
}

/// Replays scripted fold/unfold sequences and checks continuity invariants.
public struct FoldStormDriver: Sendable {
    /// Upper bound the in-flight set is expected to respect. Should match the
    /// planner's ledger capacity.
    public let inFlightBound: Int
    public let start: MonotonicInstant

    public init(inFlightBound: Int = 64, start: MonotonicInstant = .zero) {
        self.inFlightBound = max(0, inFlightBound)
        self.start = start
    }

    public func run(
        _ steps: [StormStep],
        against planner: some ContinuityPlanning
    ) async -> StormReport {
        var now = start
        var directives: [ReplanDirective] = []
        var admissionCounts: [WorkKey: Int] = [:]
        var cancellationCounts: [WorkKey: Int] = [:]
        var inFlight: Set<WorkKey> = []
        var retentionCount = 0
        var violations: [InvariantViolation] = []
        var lastEpoch: Epoch?

        for step in steps {
            now = now.advanced(byMilliseconds: step.advanceMilliseconds)
            let directive = await planner.apply(step.input, at: now)
            directives.append(directive)

            if let previous = lastEpoch, directive.epoch < previous {
                violations.append(.epochRegression(from: previous, to: directive.epoch))
            }
            lastEpoch = directive.epoch

            let admitSet = Set(directive.admit)
            let cancelSet = Set(directive.cancel)
            for key in admitSet.intersection(cancelSet) {
                violations.append(.admitAndCancelInSameDirective(key))
            }

            // Cancellations are applied first: within one directive, a key that
            // is cancelled and re-admitted is legal (it genuinely restarted),
            // whereas re-admitting one that is still in flight is not.
            for key in directive.cancel {
                if inFlight.remove(key) == nil {
                    violations.append(.cancelWithoutAdmission(key))
                }
                cancellationCounts[key, default: 0] += 1
            }

            for key in directive.admit {
                if inFlight.contains(key) {
                    violations.append(
                        .duplicateAdmission(
                            key,
                            admissions: (admissionCounts[key] ?? 0) + 1,
                            cancellations: cancellationCounts[key] ?? 0
                        )
                    )
                }
                inFlight.insert(key)
                admissionCounts[key, default: 0] += 1
            }

            // Retained work must actually still be in flight — a planner that
            // reports a key as retained after cancelling it is lying in the
            // most expensive possible way.
            for key in directive.retain where !inFlight.contains(key) {
                violations.append(.retentionLie(key))
            }
            retentionCount += directive.retain.count

            if inFlight.count > inFlightBound {
                violations.append(
                    .ledgerExceededBound(observed: inFlight.count, bound: inFlightBound)
                )
            }

            // A deferred cancellation is a promise to stop something that is
            // still running. Anything reported as held but not in flight is the
            // same class of lie as a false retention — and, left unchecked, the
            // held set is the one collection in the planner with no capacity of
            // its own, so this is also the bound check for it.
            for key in directive.deferredCancellations where !inFlight.contains(key) {
                violations.append(.cancelWithoutAdmission(key))
            }
            if directive.deferredCancellations.count > inFlightBound {
                violations.append(
                    .ledgerExceededBound(
                        observed: directive.deferredCancellations.count,
                        bound: inFlightBound
                    )
                )
            }
        }

        return StormReport(
            directives: directives,
            admissionCounts: admissionCounts,
            cancellationCounts: cancellationCounts,
            retentionCount: retentionCount,
            violations: violations
        )
    }
}
// FoldStormDriver.swift
//
// A fold transition is not a thing you can reliably reproduce by hand, and
// "we folded it a bunch of times and it looked fine" is not a regression test.
//
// This driver replays a scripted transition sequence against any
// `ContinuityPlanning` implementation with time supplied by fiat, and checks
// the invariants that distinguish a continuity layer from a reload.
//
// It is designed to be pointed at a *broken* planner and go red — see
// `FoldStormDriverTests`, which does exactly that. An invariant checker that
// has only ever been run against a correct implementation is decoration.

/// One step of a scripted storm.
public struct StormStep: Sendable, Hashable {
    public let input: SurfaceInput
    /// Milliseconds to advance the clock *before* applying this step.
    public let advanceMilliseconds: Int

    public init(input: SurfaceInput, advanceMilliseconds: Int = 0) {
        self.input = input
        self.advanceMilliseconds = max(0, advanceMilliseconds)
    }

    public static func fold(anchor: Int = 0, selection: ItemID? = nil, after milliseconds: Int = 0) -> StormStep {
        StormStep(
            input: SurfaceInput(viewport: .coverDisplay, anchor: anchor, selection: selection),
            advanceMilliseconds: milliseconds
        )
    }

    public static func unfold(anchor: Int = 0, selection: ItemID? = nil, after milliseconds: Int = 0) -> StormStep {
        StormStep(
            input: SurfaceInput(viewport: .innerDisplay, anchor: anchor, selection: selection),
            advanceMilliseconds: milliseconds
        )
    }
}

/// An invariant the planner broke.
public enum InvariantViolation: Sendable, Hashable, CustomStringConvertible {
    /// A key was started a second time without ever having been cancelled.
    /// This is the duplicated-fetch failure, stated precisely.
    case duplicateAdmission(WorkKey, admissions: Int, cancellations: Int)
    /// A key was cancelled that was not in flight.
    case cancelWithoutAdmission(WorkKey)
    /// One directive both starts and stops the same key.
    case admitAndCancelInSameDirective(WorkKey)
    /// The plan generation went backwards.
    case epochRegression(from: Epoch, to: Epoch)
    /// In-flight work exceeded the bound it claims to hold.
    case ledgerExceededBound(observed: Int, bound: Int)

    public var description: String {
        switch self {
        case .duplicateAdmission(let key, let admissions, let cancellations):
            return "duplicate admission of \(key): started \(admissions)x, cancelled \(cancellations)x"
        case .cancelWithoutAdmission(let key):
            return "cancelled \(key) which was not in flight"
        case .admitAndCancelInSameDirective(let key):
            return "\(key) both admitted and cancelled in one directive"
        case .epochRegression(let from, let to):
            return "epoch went backwards: \(from) -> \(to)"
        case .ledgerExceededBound(let observed, let bound):
            return "in-flight work \(observed) exceeded bound \(bound)"
        }
    }
}

/// The result of replaying a storm.
public struct StormReport: Sendable {
    public let directives: [ReplanDirective]
    public let admissionCounts: [WorkKey: Int]
    public let cancellationCounts: [WorkKey: Int]
    public let retentionCount: Int
    public let violations: [InvariantViolation]

    public var passed: Bool { violations.isEmpty }
    public var totalAdmissions: Int { admissionCounts.values.reduce(0, +) }
    public var totalCancellations: Int { cancellationCounts.values.reduce(0, +) }

    /// Work the planner kept rather than restarted, as a fraction of everything
    /// it could have restarted. `1.0` means a perfectly continuous storm.
    public var continuityRatio: Double {
        let denominator = retentionCount + totalAdmissions
        guard denominator > 0 else { return 1.0 }
        return Double(retentionCount) / Double(denominator)
    }
}

/// Replays scripted fold/unfold sequences and checks continuity invariants.
public struct FoldStormDriver: Sendable {
    /// Upper bound the in-flight set is expected to respect. Should match the
    /// planner's ledger capacity.
    public let inFlightBound: Int
    public let start: MonotonicInstant

    public init(inFlightBound: Int = 64, start: MonotonicInstant = .zero) {
        self.inFlightBound = max(0, inFlightBound)
        self.start = start
    }

    public func run(
        _ steps: [StormStep],
        against planner: some ContinuityPlanning
    ) async -> StormReport {
        var now = start
        var directives: [ReplanDirective] = []
        var admissionCounts: [WorkKey: Int] = [:]
        var cancellationCounts: [WorkKey: Int] = [:]
        var inFlight: Set<WorkKey> = []
        var retentionCount = 0
        var violations: [InvariantViolation] = []
        var lastEpoch: Epoch?

        for step in steps {
            now = now.advanced(byMilliseconds: step.advanceMilliseconds)
            let directive = await planner.apply(step.input, at: now)
            directives.append(directive)

            if let previous = lastEpoch, directive.epoch < previous {
                violations.append(.epochRegression(from: previous, to: directive.epoch))
            }
            lastEpoch = directive.epoch

            let admitSet = Set(directive.admit)
            let cancelSet = Set(directive.cancel)
            for key in admitSet.intersection(cancelSet) {
                violations.append(.admitAndCancelInSameDirective(key))
            }

            // Cancellations are applied first: within one directive, a key that
            // is cancelled and re-admitted is legal (it genuinely restarted),
            // whereas re-admitting one that is still in flight is not.
            for key in directive.cancel {
                if inFlight.remove(key) == nil {
                    violations.append(.cancelWithoutAdmission(key))
                }
                cancellationCounts[key, default: 0] += 1
            }

            for key in directive.admit {
                if inFlight.contains(key) {
                    violations.append(
                        .duplicateAdmission(
                            key,
                            admissions: (admissionCounts[key] ?? 0) + 1,
                            cancellations: cancellationCounts[key] ?? 0
                        )
                    )
                }
                inFlight.insert(key)
                admissionCounts[key, default: 0] += 1
            }

            // Retained work must actually still be in flight — a planner that
            // reports a key as retained after cancelling it is lying in the
            // most expensive possible way.
            for key in directive.retain where !inFlight.contains(key) {
                violations.append(
                    .duplicateAdmission(
                        key,
                        admissions: admissionCounts[key] ?? 0,
                        cancellations: cancellationCounts[key] ?? 0
                    )
                )
            }
            retentionCount += directive.retain.count

            if inFlight.count > inFlightBound {
                violations.append(
                    .ledgerExceededBound(observed: inFlight.count, bound: inFlightBound)
                )
            }
        }

        return StormReport(
            directives: directives,
            admissionCounts: admissionCounts,
            cancellationCounts: cancellationCounts,
            retentionCount: retentionCount,
            violations: violations
        )
    }
}
