import XCTest
@testable import MacScope

final class LLDBLogicalBreakpointCallbackBatchDecoderTests: XCTestCase {
    func testDecoderProducesBoundedTypedRecordsForEveryCallbackOutcome() throws {
        let fixture = try makeFixture()
        let records: [Phase2ProductionJSONValue] = [
            callbackObject(fixture: fixture, sequence: 1, hitCount: 1, outcome: "ignored"),
            callbackObject(
                fixture: fixture,
                sequence: 2,
                hitCount: 2,
                outcome: "condition_false"
            ),
            callbackObject(
                fixture: fixture,
                sequence: 3,
                hitCount: 3,
                outcome: "stop",
                outputs: [
                    .object(["kind": .string("log"), "text": .string("value=7")]),
                    .object([
                        "kind": .string("evaluate_target_expression"),
                        "label": .string("counter"),
                        "value": .string("7"),
                    ]),
                ]
            ),
            callbackObject(
                fixture: fixture,
                sequence: 4,
                hitCount: 4,
                outcome: "continue_after_successful_actions",
                outputs: []
            ),
            callbackObject(
                fixture: fixture,
                sequence: 5,
                hitCount: 5,
                outcome: "fault_stop",
                faultCode: "condition-timeout",
                dropCount: 2
            ),
        ]

        let batch = try decoder(fixture).decode(
            canonicalRecords: Phase2ProductionJSONValue.array(records).canonicalJSONBytes(),
            afterSequence: 0,
            nextSequence: 5,
            isFinal: true
        )

        XCTAssertEqual(batch.records.map(\.outcome), [
            .ignored,
            .conditionFalse,
            .stopped,
            .continued,
            .fault(code: "condition-timeout"),
        ])
        XCTAssertEqual(batch.records[2].actionOutputs, [
            .log(text: "value=7"),
            .targetExpression(label: "counter", value: "7"),
        ])
        XCTAssertEqual(batch.records[4].reportedDropCount, 2)
        XCTAssertEqual(batch.nextSequence, 5)
        XCTAssertTrue(batch.isFinal)
    }

    func testOneMalformedMemberRejectsTheEntireCanonicalBatch() throws {
        let fixture = try makeFixture()
        let valid = callbackObject(
            fixture: fixture,
            sequence: 1,
            hitCount: 1,
            outcome: "stop",
            outputs: []
        )
        let malformed = callbackObject(
            fixture: fixture,
            sequence: 2,
            hitCount: 2,
            outcome: "stop",
            outputs: [.object(["kind": .string("log"), "text": .string("ok"), "extra": .bool(true)])]
        )

        XCTAssertThrowsError(try decoder(fixture).decode(
            canonicalRecords: Phase2ProductionJSONValue.array([valid, malformed]).canonicalJSONBytes(),
            afterSequence: 0,
            nextSequence: 2,
            isFinal: true
        )) { error in
            XCTAssertEqual(error as? LLDBLogicalBreakpointCallbackBatchDecoderError, .invalidSchema)
        }
    }

    func testDecoderRejectsNoncanonicalBytesGapsAndAuthorityDrift() throws {
        let fixture = try makeFixture()
        let valid = callbackObject(
            fixture: fixture,
            sequence: 1,
            hitCount: 1,
            outcome: "ignored"
        )
        let canonical = Phase2ProductionJSONValue.array([valid]).canonicalJSONBytes()
        let noncanonical = Data("[ \(String(decoding: canonical.dropFirst().dropLast(), as: UTF8.self)) ]".utf8)

        XCTAssertThrowsError(try decoder(fixture).decode(
            canonicalRecords: noncanonical,
            afterSequence: 0,
            nextSequence: 1,
            isFinal: true
        ))
        XCTAssertThrowsError(try decoder(fixture).decode(
            canonicalRecords: Phase2ProductionJSONValue.array([
                callbackObject(
                    fixture: fixture,
                    sequence: 2,
                    hitCount: 1,
                    outcome: "ignored"
                ),
            ]).canonicalJSONBytes(),
            afterSequence: 0,
            nextSequence: 2,
            isFinal: true
        ))

        let wrongGeneration = LLDBLogicalBreakpointCallbackBatchDecoder(
            expectedSessionEpoch: fixture.epoch,
            expectedAdapterGeneration: fixture.adapterGeneration + 1,
            expectedProcessID: fixture.processID,
            bindingIDsByWireID: [fixture.wireID: fixture.bindingID]
        )
        XCTAssertThrowsError(try wrongGeneration.decode(
            canonicalRecords: canonical,
            afterSequence: 0,
            nextSequence: 1,
            isFinal: true
        ))
    }

    func testReducerAppliesCompleteBatchAtomicallyAndRetainsBoundedTypedHistory() throws {
        let fixture = try makeFixture()
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        XCTAssertTrue(reducer.beganNewStop(
            fixture.stop,
            adapterGeneration: fixture.adapterGeneration,
            observedPID: fixture.processID,
            observedStopID: 9
        ))
        XCTAssertTrue(reducer.observeOwnedInventory(try XCTUnwrap(
            DebuggerBreakpointOwnedInventoryObservation(
                sessionEpoch: fixture.epoch,
                adapterGeneration: fixture.adapterGeneration,
                stopCoordinate: fixture.stop,
                observedPID: fixture.processID,
                observedStopID: 9,
                isComplete: true,
                locations: [fixture.location]
            )
        )))

        let first = try callbackRecord(fixture: fixture, sequence: 1, hitCount: 1)
        let malformedSecond = try callbackRecord(
            fixture: fixture,
            sequence: 2,
            hitCount: 2,
            issuanceDigest: digest(99)
        )
        let rejected = try XCTUnwrap(DebuggerBreakpointCallbackBatch(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.adapterGeneration,
            processID: fixture.processID,
            afterSequence: 0,
            nextSequence: 2,
            isFinal: true,
            records: [first, malformedSecond]
        ))
        let before = reducer.snapshot
        XCTAssertFalse(reducer.recordCallbackBatch(rejected))
        XCTAssertEqual(reducer.snapshot, before)

        let second = try callbackRecord(
            fixture: fixture,
            sequence: 2,
            hitCount: 2,
            outputs: [.log(text: "two")]
        )
        let accepted = try XCTUnwrap(DebuggerBreakpointCallbackBatch(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.adapterGeneration,
            processID: fixture.processID,
            afterSequence: 0,
            nextSequence: 2,
            isFinal: true,
            records: [first, second]
        ))
        XCTAssertTrue(reducer.recordCallbackBatch(accepted))
        XCTAssertEqual(reducer.snapshot.lastCallbackSequence, 2)
        XCTAssertEqual(reducer.snapshot.observedHitCounts[fixture.logicalID], 2)
        XCTAssertEqual(reducer.snapshot.callbackRecords, [first, second])
    }

    func testFaultAfterEarlierHitMayReportTheLastAcceptedPreIncrementCount() throws {
        let fixture = try makeFixture()
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        XCTAssertTrue(reducer.beganNewStop(
            fixture.stop,
            adapterGeneration: fixture.adapterGeneration,
            observedPID: fixture.processID,
            observedStopID: 9
        ))
        XCTAssertTrue(reducer.observeOwnedInventory(try XCTUnwrap(
            DebuggerBreakpointOwnedInventoryObservation(
                sessionEpoch: fixture.epoch,
                adapterGeneration: fixture.adapterGeneration,
                stopCoordinate: fixture.stop,
                observedPID: fixture.processID,
                observedStopID: 9,
                isComplete: true,
                locations: [fixture.location]
            )
        )))

        let hit = try callbackRecord(fixture: fixture, sequence: 1, hitCount: 1)
        let preIncrementFault = try callbackRecord(
            fixture: fixture,
            sequence: 2,
            hitCount: 1,
            outcome: .fault(code: "ownership-drift")
        )
        let batch = try XCTUnwrap(DebuggerBreakpointCallbackBatch(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.adapterGeneration,
            processID: fixture.processID,
            afterSequence: 0,
            nextSequence: 2,
            isFinal: true,
            records: [hit, preIncrementFault]
        ))

        XCTAssertTrue(reducer.recordCallbackBatch(batch))
        XCTAssertTrue(reducer.snapshot.isInvalidated)
        XCTAssertEqual(reducer.snapshot.observedHitCounts[fixture.logicalID], 1)
        XCTAssertEqual(reducer.snapshot.callbackRecords, [hit, preIncrementFault])
    }

    private struct Fixture {
        let epoch: DebuggerSessionEpoch
        let stop: DebuggerStopCoordinate
        let adapterGeneration: UInt64
        let processID: Int32
        let logicalID: DebuggerLogicalBreakpointID
        let revision: DebuggerLogicalBreakpointRevision
        let bindingID: DebuggerTransientBreakpointBindingID
        let location: DebuggerOwnedBackendBreakpointLocation
        let wireID: String
    }

    private func makeFixture() throws -> Fixture {
        let epoch = DebuggerSessionEpoch(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let stop = DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .init(rawValue: 2)
            ),
            stopRevision: .init(rawValue: 3)
        )
        let logicalID = DebuggerLogicalBreakpointID(
            rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let revision = try DebuggerLogicalBreakpointRevision(validating: 1)
        let siteID = DebuggerLogicalBreakpointSiteID(
            logicalID: logicalID,
            specificationRevision: revision,
            imageAddress: .primary(0x1000),
            staticOrdinal: 0
        )
        let moduleID = DebuggerRuntimeModuleInstanceID(
            processID: 77,
            stop: stop,
            inventoryRevision: .init(rawValue: 1),
            ordinal: 0
        )
        let bindingID = try XCTUnwrap(DebuggerTransientBreakpointBindingID(
            logicalID: logicalID,
            siteID: siteID,
            moduleInstanceID: moduleID
        ))
        let location = try XCTUnwrap(DebuggerOwnedBackendBreakpointLocation(
            bindingID: bindingID,
            backendBreakpointID: 41,
            backendLocationID: 7,
            runtimeAddress: 0x9000,
            ownershipTagDigest: digest(1),
            policyActionDigest: digest(2),
            issuanceDigest: digest(3)
        ))
        return Fixture(
            epoch: epoch,
            stop: stop,
            adapterGeneration: 4,
            processID: 77,
            logicalID: logicalID,
            revision: revision,
            bindingID: bindingID,
            location: location,
            wireID: "b1." + String(repeating: "a", count: 64)
        )
    }

    private func decoder(_ fixture: Fixture) -> LLDBLogicalBreakpointCallbackBatchDecoder {
        LLDBLogicalBreakpointCallbackBatchDecoder(
            expectedSessionEpoch: fixture.epoch,
            expectedAdapterGeneration: fixture.adapterGeneration,
            expectedProcessID: fixture.processID,
            bindingIDsByWireID: [fixture.wireID: fixture.bindingID]
        )
    }

    private func callbackObject(
        fixture: Fixture,
        sequence: UInt64,
        hitCount: UInt64,
        outcome: String,
        outputs: [Phase2ProductionJSONValue]? = nil,
        faultCode: String? = nil,
        dropCount: UInt64? = nil
    ) -> Phase2ProductionJSONValue {
        var object: [String: Phase2ProductionJSONValue] = [
            "adapter_generation": .number(String(fixture.adapterGeneration)),
            "backend_breakpoint_id": .number(String(fixture.location.backendBreakpointID)),
            "backend_location_id": .number(String(fixture.location.backendLocationID)),
            "binding_id": .string(fixture.wireID),
            "hit_count": .number(String(hitCount)),
            "issuance_digest": .string(hex(fixture.location.issuanceDigest.bytes)),
            "logical_id": .string(fixture.logicalID.rawValue.uuidString.lowercased()),
            "outcome": .string(outcome),
            "process_id": .number(String(fixture.processID)),
            "sequence": .number(String(sequence)),
            "session_epoch": .string(fixture.epoch.rawValue.uuidString.lowercased()),
            "specification_revision": .number(String(fixture.revision.rawValue)),
        ]
        if let outputs { object["outputs"] = .array(outputs) }
        if let faultCode { object["code"] = .string(faultCode) }
        if let dropCount { object["drop_count"] = .number(String(dropCount)) }
        return .object(object)
    }

    private func callbackRecord(
        fixture: Fixture,
        sequence: UInt64,
        hitCount: UInt64,
        issuanceDigest: DebuggerBreakpointDigest? = nil,
        outputs: [DebuggerBreakpointCallbackActionOutput] = [],
        outcome: DebuggerBreakpointCallbackOutcome = .stopped
    ) throws -> DebuggerBreakpointCallbackRecord {
        try XCTUnwrap(DebuggerBreakpointCallbackRecord(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.adapterGeneration,
            processID: fixture.processID,
            sequence: sequence,
            logicalID: fixture.logicalID,
            specificationRevision: fixture.revision,
            bindingID: fixture.bindingID,
            backendBreakpointID: fixture.location.backendBreakpointID,
            backendLocationID: fixture.location.backendLocationID,
            issuanceDigest: issuanceDigest ?? fixture.location.issuanceDigest,
            observedLogicalHitCount: hitCount,
            outcome: outcome,
            actionOutputs: outputs,
            reportedDropCount: nil
        ))
    }

    private func digest(_ byte: UInt8) -> DebuggerBreakpointDigest {
        DebuggerBreakpointDigest(Data(repeating: byte, count: 32))!
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
