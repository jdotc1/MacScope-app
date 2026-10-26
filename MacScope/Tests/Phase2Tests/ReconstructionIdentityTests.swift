import XCTest
@testable import MacScope

final class ReconstructionIdentityTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)

    func testDurableSourceOperationsRoundTripWithoutChangingExistingPriorities() throws {
        let operations: [ReconstructionOperationID] = [.sourceRevision, .sourceOracle, .sourceEvaluate]
        XCTAssertEqual(operations.map(\.rawValue), ["reconstruction.source.revision",
            "reconstruction.source.oracle", "reconstruction.source.evaluate"])
        XCTAssertEqual(operations.map(\.priority), [16, 17, 18])
        XCTAssertEqual(ReconstructionOperationID.allCases.prefix(17).map(\.priority), Array(0...16))
        for operation in operations {
            XCTAssertEqual(try JSONDecoder().decode(ReconstructionOperationID.self,
                from: JSONEncoder().encode(operation)), operation)
            XCTAssertTrue(operation.isDurableSourceOperation)
            XCTAssertFalse(ReconstructionAppToolCatalog.entries.contains { $0.operationID.rawValue == operation.rawValue })
        }
        XCTAssertFalse(ReconstructionOperationID.functionReview.isDurableSourceOperation)
        XCTAssertNil(ReconstructionOperationID(rawValue: "reconstruction.source.unknown"))
    }

    func testContentIdentityRejectsNonCanonicalDigestAndZeroBytes() {
        XCTAssertThrowsError(
            try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: "A" + String(repeating: "a", count: 63),
                byteCount: 1
            )
        )
        XCTAssertThrowsError(
            try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: digestA,
                byteCount: 0
            )
        )
    }

    func testDistinctOccurrencesMayShareContentWithoutBecomingEqualCoordinates() throws {
        let content = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digestA,
            byteCount: 12
        )
        let first = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            contentIdentity: content
        )
        let second = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            contentIdentity: content
        )

        XCTAssertEqual(first.contentIdentity, second.contentIdentity)
        XCTAssertNotEqual(first, second)
    }

    func testContentIdentityDependsOnlyOnCanonicalByteEvidence() throws {
        let first = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digestA,
            byteCount: 12
        )
        let second = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digestA,
            byteCount: 12
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            first,
            try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: digestB,
                byteCount: 12
            )
        )
    }

    func testFunctionCoordinateValidatesRangeAndStructuralIdentity() throws {
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            contentIdentity: try .init(algorithm: .sha256, digest: digestA, byteCount: 12)
        )
        let image = ReconstructionImageBinding(
            binaryID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )

        XCTAssertThrowsError(
            try ReconstructionFunctionCoordinate(
                artifact: artifact,
                image: image,
                analysisFingerprintSHA256: digestB,
                startAddress: 0x1000,
                endAddressExclusive: 0x1000,
                boundarySchemaVersion: 1,
                functionUUIDHint: nil,
                symbolHint: nil
            )
        )

        let first = try ReconstructionFunctionCoordinate(
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: digestB,
            startAddress: 0x1000,
            endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1,
            functionUUIDHint: UUID(),
            symbolHint: "_main"
        )
        let changedRange = try ReconstructionFunctionCoordinate(
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: digestB,
            startAddress: 0x1000,
            endAddressExclusive: 0x1020,
            boundarySchemaVersion: 1,
            functionUUIDHint: first.functionUUIDHint,
            symbolHint: first.symbolHint
        )
        let changedFingerprint = try ReconstructionFunctionCoordinate(
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: digestA,
            startAddress: 0x1000,
            endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1,
            functionUUIDHint: first.functionUUIDHint,
            symbolHint: first.symbolHint
        )

        XCTAssertNotEqual(first, changedRange)
        XCTAssertNotEqual(first, changedFingerprint)
    }

    func testFunctionHintsDoNotBecomeStructuralIdentity() throws {
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: digestA, byteCount: 12)
        )
        let image = ReconstructionImageBinding(
            binaryID: UUID(),
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let first = try ReconstructionFunctionCoordinate(
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: digestB,
            startAddress: 0x1000,
            endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1,
            functionUUIDHint: UUID(),
            symbolHint: "_main"
        )
        let second = try ReconstructionFunctionCoordinate(
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: digestB,
            startAddress: 0x1000,
            endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1,
            functionUUIDHint: UUID(),
            symbolHint: "renamed_main"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    func testCanonicalJSONIsIndependentOfDictionaryInsertionOrder() throws {
        struct Fixture: Codable, Equatable {
            let schemaVersion: Int
            let values: [String: Int]
        }
        var firstValues: [String: Int] = [:]
        firstValues["b"] = 2
        firstValues["a"] = 1
        var secondValues: [String: Int] = [:]
        secondValues["a"] = 1
        secondValues["b"] = 2

        let first = try ReconstructionCanonicalJSON.encode(
            Fixture(schemaVersion: 1, values: firstValues)
        )
        let second = try ReconstructionCanonicalJSON.encode(
            Fixture(schemaVersion: 1, values: secondValues)
        )

        XCTAssertEqual(first, Data(#"{"schemaVersion":1,"values":{"a":1,"b":2}}"#.utf8))
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try ReconstructionCanonicalJSON.sha256(
                of: Fixture(schemaVersion: 1, values: firstValues)
            ),
            "6e6fd1a0e7cb79481bac5f314a26196c5f89611c68eb80c64c1708ab4ae74c3f"
        )
    }

    func testDiagnosticSanitizationRemovesControlsAndRespectsUTF8Bound() {
        let diagnostic = ReconstructionDiagnostic.sanitizing(
            "failure\u{0}\n\t🙂🙂🙂tail",
            maxUTF8Bytes: 18
        )

        XCTAssertLessThanOrEqual(diagnostic.text.utf8.count, 18)
        XCTAssertFalse(diagnostic.text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f })
        XCTAssertTrue(String(data: Data(diagnostic.text.utf8), encoding: .utf8) != nil)
    }

    func testCanonicalJSONRejectsNonFiniteNumbers() {
        struct Fixture: Encodable { let value: Double }
        XCTAssertThrowsError(try ReconstructionCanonicalJSON.encode(Fixture(value: .nan)))
        XCTAssertThrowsError(try ReconstructionCanonicalJSON.encode(Fixture(value: .infinity)))
    }

    func testTaskIdentityCanonicalizesDependencyEnumerationOrder() throws {
        let taskA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let taskB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let commonID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let first = try ReconstructionTaskIdentity(
            taskID: commonID,
            jobID: UUID(),
            kind: .retrieveEvidence,
            subject: nil,
            dependencyTaskIDs: [taskB, taskA],
            operationContractIdentity: "reconstruction.v1/evidence.query",
            canonicalSHA256: digestA
        )
        let second = try ReconstructionTaskIdentity(
            taskID: commonID,
            jobID: first.jobID,
            kind: first.kind,
            subject: nil,
            dependencyTaskIDs: [taskA, taskB],
            operationContractIdentity: first.operationContractIdentity,
            canonicalSHA256: digestA
        )

        XCTAssertEqual(
            try ReconstructionCanonicalJSON.encode(first),
            try ReconstructionCanonicalJSON.encode(second)
        )
    }

    func testEvidenceAndCheckpointAggregatesCanonicalizeEnumerationOrder() throws {
        let evidenceA = try makeEvidence(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        )
        let evidenceB = try makeEvidence(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        )
        let taskA = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let taskB = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let firstCheckpoint = try makeCheckpoint(pendingTaskIDs: [taskB, taskA])
        let secondCheckpoint = try makeCheckpoint(pendingTaskIDs: [taskA, taskB])
        let first = try ReconstructionWorkspaceState(
            projects: [],
            corpusManifests: [],
            evidence: [evidenceB, evidenceA],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [firstCheckpoint],
            toolReceipts: [],
            modelReceipts: []
        )
        let second = try ReconstructionWorkspaceState(
            projects: [],
            corpusManifests: [],
            evidence: [evidenceA, evidenceB],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [secondCheckpoint],
            toolReceipts: [],
            modelReceipts: []
        )

        XCTAssertEqual(
            try ReconstructionCanonicalJSON.encode(first),
            try ReconstructionCanonicalJSON.encode(second)
        )
        XCTAssertEqual(
            try ReconstructionCanonicalJSON.sha256(of: first),
            try ReconstructionCanonicalJSON.sha256(of: second)
        )
    }

    func testCheckpointFactoryDerivesCanonicalByteCountAndDigestFromSemanticPreimage() throws {
        struct IndependentPreimage: Encodable {
            let checkpointID: UUID
            let schemaVersion: Int
            let jobID: UUID
            let revision: UInt64
            let parentCheckpointID: UUID?
            let parentCheckpointSHA256: String?
            let corpusManifestSHA256: String
            let evidenceFrontierSHA256: String
            let pendingTaskIDs: [UUID]
            let runningTaskIDs: [UUID]
            let completedTaskIDs: [UUID]
            let failedTaskIDs: [UUID]
            let blockedTaskIDs: [UUID]
            let unresolvedEvidenceGapSHA256: String
            let modelReceiptIDs: [UUID]
            let toolReceiptIDs: [UUID]
            let coordinatorState: ReconstructionJobState
            let terminalReason: ReconstructionDiagnostic?
        }

        let taskA = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let taskB = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
            jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: digestA,
            evidenceFrontierSHA256: digestB,
            pendingTaskIDs: [taskB, taskA],
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: digestA,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .created,
            terminalReason: nil
        )
        let preimage = IndependentPreimage(
            checkpointID: checkpoint.checkpointID,
            schemaVersion: checkpoint.schemaVersion,
            jobID: checkpoint.jobID,
            revision: checkpoint.revision,
            parentCheckpointID: checkpoint.parentCheckpointID,
            parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: [taskA, taskB],
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: checkpoint.coordinatorState,
            terminalReason: nil
        )
        let expectedBytes = try ReconstructionCanonicalJSON.encode(preimage)

        XCTAssertEqual(checkpoint.canonicalEncodedByteCount, UInt64(expectedBytes.count))
        XCTAssertEqual(
            checkpoint.canonicalSHA256,
            try ReconstructionCanonicalJSON.sha256(of: preimage)
        )
        XCTAssertNoThrow(try checkpoint.verifyCanonicalIdentity())
    }

    func testCheckpointVerificationRejectsForgedByteCountAndDigest() throws {
        let canonical = try makeCanonicalCheckpoint()
        let forgedCount = try checkpoint(
            copying: canonical,
            canonicalEncodedByteCount: canonical.canonicalEncodedByteCount + 1
        )
        let forgedDigest = try checkpoint(
            copying: canonical,
            canonicalSHA256: canonical.canonicalSHA256 == digestA ? digestB : digestA
        )

        XCTAssertThrowsError(try forgedCount.verifyCanonicalIdentity()) { error in
            guard case ReconstructionCheckpointIdentityError.encodedByteCountMismatch = error else {
                return XCTFail("Expected byte-count mismatch, got \(error)")
            }
        }
        XCTAssertThrowsError(try forgedDigest.verifyCanonicalIdentity()) { error in
            guard case ReconstructionCheckpointIdentityError.sha256Mismatch = error else {
                return XCTFail("Expected digest mismatch, got \(error)")
            }
        }
    }

    func testJobRecordLegacyWireShapeRoundTripsWithoutInventingAnOrdinal() throws {
        let legacy = try makeLegacyJobRecord()
        let encoded = try ReconstructionCanonicalJSON.encode(legacy)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNil(object["recordSchemaVersion"])
        XCTAssertNil(object["creationOrdinal"])

        let decoded = try JSONDecoder().decode(ReconstructionJobRecord.self, from: encoded)
        XCTAssertEqual(decoded.recordSchemaVersion, 1)
        XCTAssertNil(decoded.creationOrdinal)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(decoded), encoded)
    }

    func testJobRecordUpgradeEmitsCurrentSchemaAndRejectsZeroOrdinal() throws {
        let legacy = try makeLegacyJobRecord()
        let upgraded = try legacy.upgraded(creationOrdinal: 7)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(upgraded)
            ) as? [String: Any]
        )

        XCTAssertEqual(upgraded.recordSchemaVersion, ReconstructionJobRecord.schemaVersion)
        XCTAssertEqual(upgraded.creationOrdinal, 7)
        XCTAssertEqual(object["recordSchemaVersion"] as? Int, ReconstructionJobRecord.schemaVersion)
        XCTAssertEqual(object["creationOrdinal"] as? Int, 7)
        XCTAssertNil(object["pauseContext"])
        XCTAssertThrowsError(try legacy.upgraded(creationOrdinal: 0))

        var hostile = object
        hostile["creationOrdinal"] = 0
        let hostileData = try JSONSerialization.data(withJSONObject: hostile, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReconstructionJobRecord.self, from: hostileData)
        )

        hostile = object
        hostile.removeValue(forKey: "recordSchemaVersion")
        let incompleteData = try JSONSerialization.data(
            withJSONObject: hostile,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReconstructionJobRecord.self, from: incompleteData)
        )
    }

    func testJobRecordSchemaV2WireShapeRoundTripsBeforeExplicitNormalization() throws {
        let current = try makeCurrentJobRecord()
        var legacyV2Object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(current)
            ) as? [String: Any]
        )
        legacyV2Object["recordSchemaVersion"] = 2
        legacyV2Object.removeValue(forKey: "pauseContext")
        let legacyV2Bytes = try JSONSerialization.data(
            withJSONObject: legacyV2Object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder().decode(
            ReconstructionJobRecord.self,
            from: legacyV2Bytes
        )

        XCTAssertEqual(decoded.recordSchemaVersion, 2)
        XCTAssertEqual(decoded.creationOrdinal, 1)
        XCTAssertNil(decoded.pauseContext)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(decoded), legacyV2Bytes)
        XCTAssertEqual(try decoded.normalizedToCurrentSchema().recordSchemaVersion, ReconstructionJobRecord.schemaVersion)
    }

    func testPausedJobRequiresClosedDurablePauseContextAndPreservesItInCurrentSchema() throws {
        let context = try ReconstructionJobPauseContext(
            cause: .modelUnavailable,
            resumeTarget: .awaitingModel
        )
        let current = try makeCurrentJobRecord(
            state: .paused,
            pauseContext: context
        )
        let bytes = try ReconstructionCanonicalJSON.encode(current)
        let decoded = try JSONDecoder().decode(ReconstructionJobRecord.self, from: bytes)

        XCTAssertEqual(decoded.recordSchemaVersion, ReconstructionJobRecord.schemaVersion)
        XCTAssertEqual(decoded.pauseContext, context)
        XCTAssertEqual(decoded.pauseContext?.resumeTarget, .awaitingModel)
        XCTAssertEqual(decoded.pauseContext?.cause, .modelUnavailable)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(decoded), bytes)

        XCTAssertThrowsError(
            try makeCurrentJobRecord(state: .paused, pauseContext: nil)
        )
        XCTAssertThrowsError(
            try makeCurrentJobRecord(state: .retrieving, pauseContext: context)
        )
        XCTAssertThrowsError(
            try ReconstructionJobPauseContext(
                cause: .pausedByUser,
                resumeTarget: .completed
            )
        )
        XCTAssertThrowsError(
            try ReconstructionJobPauseContext(
                schemaVersion: 2,
                cause: .pausedByUser,
                resumeTarget: .created
            )
        )
    }

    func testJobRecordSchemasRejectExplicitNullAndForbiddenPauseContextShapes() throws {
        let active = try makeCurrentJobRecord()
        let activeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(active)
            ) as? [String: Any]
        )
        let contextObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(
                    try ReconstructionJobPauseContext(
                        cause: .pausedByUser,
                        resumeTarget: .created
                    )
                )
            ) as? [String: Any]
        )

        func data(
            schemaVersion: Int,
            pauseContext: Any
        ) throws -> Data {
            var object = activeObject
            switch schemaVersion {
            case 1:
                object.removeValue(forKey: "recordSchemaVersion")
                object.removeValue(forKey: "creationOrdinal")
            case 2:
                object["recordSchemaVersion"] = 2
            case 3:
                break
            default:
                preconditionFailure("unsupported test schema")
            }
            object["pauseContext"] = pauseContext
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        let forbiddenLegacyPauseContexts: [Any] = [NSNull(), contextObject]
        for schemaVersion in [1, 2] {
            for pauseContext in forbiddenLegacyPauseContexts {
                XCTAssertThrowsError(
                    try JSONDecoder().decode(
                        ReconstructionJobRecord.self,
                        from: data(
                            schemaVersion: schemaVersion,
                            pauseContext: pauseContext
                        )
                    ),
                    "schema-v\(schemaVersion) admitted a forbidden pauseContext key"
                ) { error in
                    guard let decodingError = error as? DecodingError,
                          case .dataCorrupted = decodingError else {
                        return XCTFail("Expected strict wire-shape rejection, got \(error)")
                    }
                }
            }
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReconstructionJobRecord.self,
                from: data(schemaVersion: 3, pauseContext: NSNull())
            )
        ) { error in
            guard let decodingError = error as? DecodingError,
                  case .dataCorrupted = decodingError else {
                return XCTFail("Expected explicit-null rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReconstructionJobRecord.self,
                from: data(schemaVersion: 3, pauseContext: contextObject)
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionValidationError,
                .invalidReference(field: "job pause context")
            )
        }

        var pausedWithoutContext = activeObject
        pausedWithoutContext["state"] = ReconstructionJobState.paused.rawValue
        pausedWithoutContext.removeValue(forKey: "pauseContext")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReconstructionJobRecord.self,
                from: JSONSerialization.data(
                    withJSONObject: pausedWithoutContext,
                    options: [.sortedKeys]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionValidationError,
                .invalidReference(field: "job pause context")
            )
        }
    }

    func testLegacyPausedJobFailsClosedInsteadOfInventingPauseSemantics() throws {
        let legacyV1 = try makeLegacyJobRecord(state: .paused)

        XCTAssertEqual(legacyV1.recordSchemaVersion, 1)
        XCTAssertNil(legacyV1.pauseContext)
        XCTAssertThrowsError(try legacyV1.upgraded(creationOrdinal: 1))

        var legacyV2Object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(
                    try makeCurrentJobRecord(
                        state: .paused,
                        pauseContext: try ReconstructionJobPauseContext(
                            cause: .pausedByUser,
                            resumeTarget: .created
                        )
                    )
                )
            ) as? [String: Any]
        )
        legacyV2Object["recordSchemaVersion"] = 2
        legacyV2Object.removeValue(forKey: "pauseContext")
        let legacyV2Bytes = try JSONSerialization.data(
            withJSONObject: legacyV2Object,
            options: [.sortedKeys]
        )
        let legacyV2 = try JSONDecoder().decode(
            ReconstructionJobRecord.self,
            from: legacyV2Bytes
        )

        XCTAssertEqual(legacyV2.recordSchemaVersion, 2)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(legacyV2), legacyV2Bytes)
        XCTAssertThrowsError(try legacyV2.normalizedToCurrentSchema())
    }

    func testJobFocusRoundTripsAndLegacySchemasRejectFocus() throws {
        let focus = try makeEvidence(id: UUID()).subject
        let job = try makeCurrentJobRecord(focus: focus)
        let data = try ReconstructionCanonicalJSON.encode(job)
        XCTAssertEqual(try JSONDecoder().decode(ReconstructionJobRecord.self, from: data), job)
        XCTAssertEqual(try job.upgraded(creationOrdinal: 2).focus, focus)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for version in [1, 2, 3] {
            object["recordSchemaVersion"] = version
            if version == 1 {
                object.removeValue(forKey: "recordSchemaVersion")
                object.removeValue(forKey: "creationOrdinal")
            } else { object["creationOrdinal"] = 1 }
            XCTAssertThrowsError(try JSONDecoder().decode(ReconstructionJobRecord.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
        let nilJobData = try ReconstructionCanonicalJSON.encode(makeCurrentJobRecord())
        let nilObject = try XCTUnwrap(JSONSerialization.jsonObject(with: nilJobData) as? [String: Any])
        XCTAssertNil(nilObject["focus"])
    }

    func testSchemaV3PausedJobNormalizesWithoutLosingPauseContext() throws {
        let context = try ReconstructionJobPauseContext(cause: .pausedByUser, resumeTarget: .created)
        let job = try makeCurrentJobRecord(state: .paused, pauseContext: context)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ReconstructionCanonicalJSON.encode(job)) as? [String: Any])
        object["recordSchemaVersion"] = 3
        let decoded = try JSONDecoder().decode(ReconstructionJobRecord.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.recordSchemaVersion, 3)
        XCTAssertNil(decoded.focus)
        XCTAssertEqual(try decoded.normalizedToCurrentSchema().pauseContext, context)
    }

    private func makeEvidence(id: UUID) throws -> ReconstructionEvidenceRecord {
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: .init(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            contentIdentity: try .init(algorithm: .sha256, digest: digestA, byteCount: 1)
        )
        let producer = try ReconstructionProducerIdentity(
            macScopeBuildIdentity: "build-1",
            macScopeSourceIdentity: "source-1",
            operationIdentity: "reconstruction.v1/evidence.query",
            registryIdentity: "reconstruction.v1",
            protocolIdentity: "reconstructionR1.v1",
            canonicalSHA256: digestA
        )
        return try ReconstructionEvidenceRecord(
            evidenceID: id,
            subject: .artifact(artifact),
            operationID: "reconstruction.v1/evidence.query",
            payloadKind: .text,
            payload: Data("x".utf8),
            payloadByteCount: 1,
            payloadSHA256: digestB,
            facetDependencies: [],
            producer: producer,
            citations: [],
            creatingJobID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            creatingTaskID: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
            creatingCheckpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
            modelReceiptID: nil,
            toolReceiptID: nil,
            classification: .acceptedCurrent,
            supersedesEvidenceID: nil,
            supersededByEvidenceID: nil,
            diagnostic: nil
        )
    }

    private func makeCheckpoint(pendingTaskIDs: [UUID]) throws -> ReconstructionCheckpoint {
        try ReconstructionCheckpoint(
            checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
            jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: digestA,
            evidenceFrontierSHA256: digestB,
            pendingTaskIDs: pendingTaskIDs,
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: digestA,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .created,
            terminalReason: nil,
            canonicalEncodedByteCount: 1,
            canonicalSHA256: digestB
        )
    }

    private func makeCanonicalCheckpoint() throws -> ReconstructionCheckpoint {
        try ReconstructionCheckpoint.make(
            checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
            jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: digestA,
            evidenceFrontierSHA256: digestB,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: digestA,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .created,
            terminalReason: nil
        )
    }

    private func checkpoint(
        copying checkpoint: ReconstructionCheckpoint,
        canonicalEncodedByteCount: UInt64? = nil,
        canonicalSHA256: String? = nil
    ) throws -> ReconstructionCheckpoint {
        try ReconstructionCheckpoint(
            checkpointID: checkpoint.checkpointID,
            schemaVersion: checkpoint.schemaVersion,
            jobID: checkpoint.jobID,
            revision: checkpoint.revision,
            parentCheckpointID: checkpoint.parentCheckpointID,
            parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: checkpoint.pendingTaskIDs,
            runningTaskIDs: checkpoint.runningTaskIDs,
            completedTaskIDs: checkpoint.completedTaskIDs,
            failedTaskIDs: checkpoint.failedTaskIDs,
            blockedTaskIDs: checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: checkpoint.modelReceiptIDs,
            toolReceiptIDs: checkpoint.toolReceiptIDs,
            coordinatorState: checkpoint.coordinatorState,
            terminalReason: checkpoint.terminalReason,
            canonicalEncodedByteCount: canonicalEncodedByteCount
                ?? checkpoint.canonicalEncodedByteCount,
            canonicalSHA256: canonicalSHA256 ?? checkpoint.canonicalSHA256
        )
    }

    private func makeCurrentJobRecord(
        state: ReconstructionJobState = .created,
        pauseContext: ReconstructionJobPauseContext? = nil,
        focus: ReconstructionSubjectCoordinate? = nil
    ) throws -> ReconstructionJobRecord {
        try ReconstructionJobRecord(
            jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
            reconstructionProjectID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000042"
            )!,
            objective: "Recover the reconstructed interface",
            objectiveSHA256: digestA,
            creationCorpusManifestSHA256: digestB,
            state: state,
            currentCheckpointID: nil,
            terminalReason: nil,
            budget: try ReconstructionJobBudget(
                maxRounds: 2,
                maxTasks: 4,
                maxEvidenceRecords: 8,
                maxEncodedBytes: 1_024
            ),
            creationOrdinal: 1,
            pauseContext: pauseContext,
            focus: focus
        )
    }

    private func makeLegacyJobRecord(
        state: ReconstructionJobState = .created
    ) throws -> ReconstructionJobRecord {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(
                    try makeCurrentJobRecord(
                        state: state,
                        pauseContext: state == .paused
                            ? try ReconstructionJobPauseContext(
                                cause: .pausedByUser,
                                resumeTarget: .created
                            )
                            : nil
                    )
                )
            ) as? [String: Any]
        )
        object.removeValue(forKey: "recordSchemaVersion")
        object.removeValue(forKey: "creationOrdinal")
        object.removeValue(forKey: "pauseContext")
        return try JSONDecoder().decode(
            ReconstructionJobRecord.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}
