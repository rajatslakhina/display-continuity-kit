// ContinuitySnapshot.swift
//
// `@SceneStorage` restores what you handed it, one property at a time, with no
// notion of whether the set is mutually consistent. Across a display-class
// change that is not enough: restoring an anchor without its selection, or a
// selection whose schema predates the field the detail pane now needs, yields a
// surface that is half old and half new.
//
// So the restoration contract is an explicit, versioned, all-or-nothing value.

import Foundation

/// A restorable capture of one surface.
public struct ContinuitySnapshot: Sendable, Hashable, Codable {
    /// Bumped whenever the meaning of any field changes.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let surfaceID: SurfaceID
    public let selection: ItemID?
    public let anchor: Int
    public let displayClass: DisplayClass
    public let epoch: Epoch

    public init(
        surfaceID: SurfaceID,
        selection: ItemID?,
        anchor: Int,
        displayClass: DisplayClass,
        epoch: Epoch,
        schemaVersion: Int = ContinuitySnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.surfaceID = surfaceID
        self.selection = selection
        self.anchor = max(0, anchor)
        self.displayClass = displayClass
        self.epoch = epoch
    }
}

/// The result of attempting a restore.
public enum SnapshotRestoreOutcome: Sendable, Equatable {
    case restored(ContinuitySnapshot)
    /// The payload declared a schema this build does not understand.
    case rejectedUnsupportedSchema(found: Int, supported: Int)
    /// The payload was structurally unusable.
    case rejectedMalformed(reason: String)

    public var snapshot: ContinuitySnapshot? {
        if case .restored(let snapshot) = self { return snapshot }
        return nil
    }
}

/// Encodes and decodes `ContinuitySnapshot` under an explicit compatibility
/// contract.
///
/// ## The contract
///
/// 1. **Unknown extra fields are tolerated.** A newer build writing additional
///    keys must not brick an older build that reads them — otherwise a staged
///    rollout means every downgraded user loses their place.
///
/// 2. **A missing required field rejects the whole payload.** Not "default it
///    and carry on": a snapshot missing its anchor is a snapshot whose writer
///    disagreed with this reader about what a snapshot is, and guessing is how
///    the half-restored surface happens.
///
/// 3. **A schema version this build does not recognise rejects the whole
///    payload**, in *both* directions. Rejecting a *newer* payload is obvious.
///    Rejecting an *older* one is the part teams skip, and it is the one that
///    matters: v1 stored a screen-scoped selection, which under the surface-
///    scoped model of v2 restores the wrong pane.
///
/// Rejection is never a crash and never a partial apply — the caller gets a
/// clean surface, which is a worse experience for one launch and a correct one
/// forever after.
public enum ContinuitySnapshotCoder {

    /// Schema versions this build can read. Deliberately not a `>=` check.
    public static let supportedSchemaVersions: Set<Int> = [ContinuitySnapshot.currentSchemaVersion]

    public static func encode(_ snapshot: ContinuitySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        // Stable key order so a snapshot round-trips byte-identically, which is
        // what lets a test assert on the encoded form rather than only on the
        // decoded one.
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) -> SnapshotRestoreOutcome {
        guard !data.isEmpty else {
            return .rejectedMalformed(reason: "empty payload")
        }

        // Read the version first, from a minimal envelope, so that a payload
        // whose *body* this build cannot parse is still rejected with the
        // accurate reason rather than a generic decode failure.
        struct VersionEnvelope: Decodable { let schemaVersion: Int }
        let declaredVersion: Int
        do {
            declaredVersion = try JSONDecoder().decode(VersionEnvelope.self, from: data).schemaVersion
        } catch {
            return .rejectedMalformed(reason: "missing or non-numeric schemaVersion")
        }

        guard supportedSchemaVersions.contains(declaredVersion) else {
            return .rejectedUnsupportedSchema(
                found: declaredVersion,
                supported: ContinuitySnapshot.currentSchemaVersion
            )
        }

        do {
            let snapshot = try JSONDecoder().decode(ContinuitySnapshot.self, from: data)
            guard snapshot.anchor >= 0 else {
                return .rejectedMalformed(reason: "negative anchor")
            }
            guard !snapshot.surfaceID.rawValue.isEmpty else {
                return .rejectedMalformed(reason: "empty surfaceID")
            }
            return .restored(snapshot)
        } catch {
            return .rejectedMalformed(reason: "missing required field")
        }
    }
}
