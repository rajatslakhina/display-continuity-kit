import Foundation
import XCTest
@testable import DisplayContinuity

final class ContinuitySnapshotTests: XCTestCase {

    private func makeSnapshot(
        surfaceID: SurfaceID = SurfaceID("feed"),
        selection: ItemID? = ItemID("item-4"),
        anchor: Int = 12
    ) -> ContinuitySnapshot {
        ContinuitySnapshot(
            surfaceID: surfaceID,
            selection: selection,
            anchor: anchor,
            displayClass: .expanded,
            epoch: Epoch(3)
        )
    }

    /// A payload in whatever shape this build actually writes, as a mutable
    /// dictionary.
    ///
    /// Deriving the fixture from a real encode rather than hand-rolling JSON
    /// keeps these tests honest: a hand-written fixture that happens not to
    /// match the encoder tests the fixture, not the contract.
    private func basePayloadObject() throws -> [String: Any] {
        let data = try ContinuitySnapshotCoder.encode(makeSnapshot())
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Round trip

    func testRoundTripPreservesEveryField() throws {
        let original = makeSnapshot()
        let encoded = try ContinuitySnapshotCoder.encode(original)
        guard case .restored(let decoded) = ContinuitySnapshotCoder.decode(encoded) else {
            return XCTFail("a snapshot this build wrote must be readable by this build")
        }
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, ContinuitySnapshot.currentSchemaVersion)
        XCTAssertEqual(decoded.anchor, 12)
        XCTAssertEqual(decoded.selection, ItemID("item-4"))
        XCTAssertEqual(decoded.displayClass, .expanded)
        XCTAssertEqual(decoded.epoch, Epoch(3))
    }

    func testNilSelectionRoundTrips() throws {
        let snapshot = makeSnapshot(selection: nil, anchor: 0)
        let encoded = try ContinuitySnapshotCoder.encode(snapshot)
        guard case .restored(let decoded) = ContinuitySnapshotCoder.decode(encoded) else {
            return XCTFail("a nil selection is a legitimate state, not a malformed one")
        }
        XCTAssertNil(decoded.selection)
    }

    /// Asserts the *property* `.sortedKeys` provides, not that a pure function
    /// is deterministic within one process.
    ///
    /// Encoding the same value twice in one run matches regardless of
    /// `outputFormatting`, so that assertion would pass with the option
    /// deleted. Checking that the emitted keys are in ascending order does not:
    /// remove `encoder.outputFormatting = [.sortedKeys]` and this goes red.
    func testEncodedKeysAreSortedSoTheFormIsCanonicalAcrossBuilds() throws {
        let data = try ContinuitySnapshotCoder.encode(makeSnapshot())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Top-level keys, in the order the encoder emitted them.
        var emitted: [String] = []
        var depth = 0
        var index = json.startIndex
        while index < json.endIndex {
            let character = json[index]
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" { depth -= 1 }
            if character == "\"", depth == 1 {
                let after = json.index(after: index)
                if let close = json[after...].firstIndex(of: "\"") {
                    let candidate = String(json[after ..< close])
                    let next = json.index(after: close)
                    if next < json.endIndex, json[next] == ":" {
                        emitted.append(candidate)
                    }
                    index = close
                }
            }
            index = json.index(after: index)
        }

        XCTAssertGreaterThan(emitted.count, 1, "there must be keys to compare")
        XCTAssertEqual(
            emitted,
            emitted.sorted(),
            "keys must be emitted in ascending order; got \(emitted)"
        )
    }

    // MARK: - Rule 1 — unknown fields are tolerated

    func testUnknownExtraFieldsAreTolerated() throws {
        var object = try basePayloadObject()
        // Written by a future build this one has never heard of.
        object["hingeAngleDegrees"] = 137.5
        object["paneSplitRatio"] = 0.38
        object["triFoldSegment"] = "middle"

        guard case .restored(let decoded) = ContinuitySnapshotCoder.decode(try data(from: object)) else {
            return XCTFail("extra fields must not brick an older reader during a staged rollout")
        }
        XCTAssertEqual(decoded.anchor, 12)
        XCTAssertEqual(decoded.selection, ItemID("item-4"))
    }

    // MARK: - Rule 2 — a missing required field rejects the whole payload

    func testMissingRequiredFieldRejectsTheWholePayload() throws {
        var object = try basePayloadObject()
        object.removeValue(forKey: "anchor")
        guard case .rejectedMalformed = ContinuitySnapshotCoder.decode(try data(from: object)) else {
            return XCTFail("a snapshot missing its anchor must not be partially applied")
        }
    }

    func testMissingDisplayClassRejectsTheWholePayload() throws {
        var object = try basePayloadObject()
        object.removeValue(forKey: "displayClass")
        guard case .rejectedMalformed = ContinuitySnapshotCoder.decode(try data(from: object)) else {
            return XCTFail("restoring without knowing which class wrote it is guessing")
        }
    }

    // MARK: - Rule 3 — unrecognised schema versions reject, in both directions

    /// The direction teams skip. v1 stored a *screen*-scoped selection, which
    /// under v2's surface-scoped model restores the wrong pane — so "read it
    /// anyway" is the bug, not the compatibility win.
    func testOlderSchemaIsRejectedRatherThanReinterpreted() throws {
        var object = try basePayloadObject()
        object["schemaVersion"] = 1
        XCTAssertEqual(
            ContinuitySnapshotCoder.decode(try data(from: object)),
            .rejectedUnsupportedSchema(found: 1, supported: ContinuitySnapshot.currentSchemaVersion)
        )
    }

    func testNewerSchemaIsRejected() throws {
        var object = try basePayloadObject()
        let future = ContinuitySnapshot.currentSchemaVersion + 1
        object["schemaVersion"] = future
        XCTAssertEqual(
            ContinuitySnapshotCoder.decode(try data(from: object)),
            .rejectedUnsupportedSchema(found: future, supported: ContinuitySnapshot.currentSchemaVersion)
        )
    }

    func testMissingSchemaVersionIsReportedAsSuchNotAsAGenericFailure() throws {
        var object = try basePayloadObject()
        object.removeValue(forKey: "schemaVersion")
        XCTAssertEqual(
            ContinuitySnapshotCoder.decode(try data(from: object)),
            .rejectedMalformed(reason: "missing or non-numeric schemaVersion")
        )
    }

    func testNonNumericSchemaVersionIsRejected() throws {
        var object = try basePayloadObject()
        object["schemaVersion"] = "two"
        XCTAssertEqual(
            ContinuitySnapshotCoder.decode(try data(from: object)),
            .rejectedMalformed(reason: "missing or non-numeric schemaVersion")
        )
    }

    // MARK: - Semantic validation

    func testEmptySurfaceIDIsRejected() throws {
        // Encoded from a real (if degenerate) snapshot, so the payload shape is
        // whatever this build writes.
        let encoded = try ContinuitySnapshotCoder.encode(makeSnapshot(surfaceID: SurfaceID("")))
        XCTAssertEqual(
            ContinuitySnapshotCoder.decode(encoded),
            .rejectedMalformed(reason: "empty surfaceID")
        )
    }

    func testNegativeAnchorIsSanitisedInProcessAndRejectedOnTheWire() throws {
        // In-process construction clamps — there is no way to build one.
        XCTAssertEqual(makeSnapshot(anchor: -9).anchor, 0)

        // A payload carrying a negative anchor is one this build did not write,
        // so it is rejected rather than silently corrected.
        var object = try basePayloadObject()
        object["anchor"] = -9
        XCTAssertEqual(
            ContinuitySnapshotCoder.decode(try data(from: object)),
            .rejectedMalformed(reason: "negative anchor")
        )
    }

    func testUnknownDisplayClassIsRejected() throws {
        var object = try basePayloadObject()
        object["displayClass"] = "tri-fold-inner"
        guard case .rejectedMalformed = ContinuitySnapshotCoder.decode(try data(from: object)) else {
            return XCTFail("a display class this build cannot render must not restore")
        }
    }

    // MARK: - Hostile input

    func testEmptyAndGarbagePayloadsAreRejectedWithoutTrapping() {
        XCTAssertEqual(
            ContinuitySnapshotCoder.decode(Data()),
            .rejectedMalformed(reason: "empty payload")
        )
        let garbage = Data([0xFF, 0x00, 0xFE, 0x42, 0x7B, 0x7B, 0x7B])
        guard case .rejectedMalformed = ContinuitySnapshotCoder.decode(garbage) else {
            return XCTFail("non-JSON bytes must be rejected cleanly, not trapped on")
        }
    }

    func testTruncatedPayloadIsRejectedWithoutTrapping() throws {
        let encoded = try ContinuitySnapshotCoder.encode(makeSnapshot())
        // Every proper prefix of a valid payload must be rejected rather than
        // partially applied — a half-written file on disk is a real case.
        for length in stride(from: 1, to: encoded.count, by: 3) {
            let truncated = encoded.prefix(length)
            guard case .rejectedMalformed = ContinuitySnapshotCoder.decode(Data(truncated)) else {
                return XCTFail("prefix of length \(length) decoded when it should not have")
            }
        }
    }
}
