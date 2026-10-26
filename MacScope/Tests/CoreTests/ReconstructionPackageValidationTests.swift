import XCTest
@testable import MacScope

final class ReconstructionPackageValidationTests: XCTestCase {
    func testPackageRejectsFocusWithoutSelectedIngestRootOrCommittedFunctionEvidence() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let original = try XCTUnwrap(fixture.state.jobs.first)
        let occurrence = try XCTUnwrap(fixture.state.corpusManifests.first?.artifacts.first)
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: occurrence.occurrenceID,
            contentIdentity: occurrence.contentIdentity)
        func job(focus: ReconstructionSubjectCoordinate) throws -> ReconstructionJobRecord {
            try ReconstructionJobRecord(jobID: original.jobID,
                reconstructionProjectID: original.reconstructionProjectID,
                objective: original.objective, objectiveSHA256: original.objectiveSHA256,
                creationCorpusManifestSHA256: original.creationCorpusManifestSHA256,
                state: original.state, currentCheckpointID: original.currentCheckpointID,
                terminalReason: original.terminalReason, budget: original.budget,
                creationOrdinal: try XCTUnwrap(original.creationOrdinal),
                pauseContext: original.pauseContext, focus: focus)
        }
        let unselected = try replacing(fixture.state, jobs: [job(focus: .artifact(artifact))])
        XCTAssertThrowsError(try ReconstructionPackageCodec.encode(unselected)) { error in
            XCTAssertEqual(error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("job focus selected corpus ownership"))
        }
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: ReconstructionImageBinding(binaryID: fixture.binaryID, imageSlot: .primary,
                selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: String(repeating: "a", count: 64), startAddress: 0x1000,
            endAddressExclusive: 0x1010, boundarySchemaVersion: 1, functionUUIDHint: nil,
            symbolHint: nil)
        let unsupported = try replacing(fixture.state, jobs: [job(focus: .function(function))])
        XCTAssertThrowsError(try ReconstructionPackageCodec.encode(unsupported)) { error in
            XCTAssertEqual(error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("job function focus evidence"))
        }
    }

    func testPackageBoundaryNormalizesSchemaV2JobsAndRejectsLegacyPausedSemantics() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let encoded = try ReconstructionPackageCodec.encode(fixture.state)
        var checkpointObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded.checkpointData) as? [String: Any]
        )
        var jobs = try XCTUnwrap(checkpointObject["jobs"] as? [[String: Any]])
        var legacyV2Job = try XCTUnwrap(jobs.first)
        legacyV2Job["recordSchemaVersion"] = 2
        legacyV2Job.removeValue(forKey: "pauseContext")
        jobs[0] = legacyV2Job
        checkpointObject["jobs"] = jobs
        let legacyV2Data = try JSONSerialization.data(
            withJSONObject: checkpointObject,
            options: [.sortedKeys]
        )
        func descriptor(checkpointData: Data) throws -> ReconstructionPackageDescriptor {
            try ReconstructionPackageDescriptor(
                corpusManifestPath: encoded.descriptor.corpusManifestPath,
                evidenceManifestPath: encoded.descriptor.evidenceManifestPath,
                checkpointManifestPath: encoded.descriptor.checkpointManifestPath,
                corpusManifestSHA256: encoded.descriptor.corpusManifestSHA256,
                evidenceManifestSHA256: encoded.descriptor.evidenceManifestSHA256,
                checkpointManifestSHA256: ReconstructionPackageFixture.digest(checkpointData)
            )
        }

        let normalized = try ReconstructionPackageCodec.decode(
            descriptor: descriptor(checkpointData: legacyV2Data),
            corpusData: encoded.corpusData,
            evidenceData: encoded.evidenceData,
            checkpointData: legacyV2Data
        )

        XCTAssertEqual(normalized.jobs.first?.recordSchemaVersion, ReconstructionJobRecord.schemaVersion)
        XCTAssertNil(normalized.jobs.first?.pauseContext)

        let originalJob = try XCTUnwrap(fixture.state.jobs.first)
        let originalCheckpoint = try XCTUnwrap(fixture.state.checkpoints.first)
        let resumableCheckpoint = try ReconstructionCheckpoint.make(
            checkpointID: originalCheckpoint.checkpointID,
            schemaVersion: originalCheckpoint.schemaVersion,
            jobID: originalCheckpoint.jobID,
            revision: originalCheckpoint.revision,
            parentCheckpointID: originalCheckpoint.parentCheckpointID,
            parentCheckpointSHA256: originalCheckpoint.parentCheckpointSHA256,
            corpusManifestSHA256: originalCheckpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: originalCheckpoint.evidenceFrontierSHA256,
            pendingTaskIDs: originalCheckpoint.pendingTaskIDs,
            runningTaskIDs: originalCheckpoint.runningTaskIDs,
            completedTaskIDs: originalCheckpoint.completedTaskIDs,
            failedTaskIDs: originalCheckpoint.failedTaskIDs,
            blockedTaskIDs: originalCheckpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: originalCheckpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: originalCheckpoint.modelReceiptIDs,
            toolReceiptIDs: originalCheckpoint.toolReceiptIDs,
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        let pausedCheckpoint = try ReconstructionCheckpoint.make(
            checkpointID: UUID(uuidString: "53000000-0000-0000-0000-000000000099")!,
            schemaVersion: originalCheckpoint.schemaVersion,
            jobID: originalCheckpoint.jobID,
            revision: 1,
            parentCheckpointID: resumableCheckpoint.checkpointID,
            parentCheckpointSHA256: resumableCheckpoint.canonicalSHA256,
            corpusManifestSHA256: resumableCheckpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: resumableCheckpoint.evidenceFrontierSHA256,
            pendingTaskIDs: resumableCheckpoint.pendingTaskIDs,
            runningTaskIDs: resumableCheckpoint.runningTaskIDs,
            completedTaskIDs: resumableCheckpoint.completedTaskIDs,
            failedTaskIDs: resumableCheckpoint.failedTaskIDs,
            blockedTaskIDs: resumableCheckpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: resumableCheckpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: resumableCheckpoint.modelReceiptIDs,
            toolReceiptIDs: resumableCheckpoint.toolReceiptIDs,
            coordinatorState: .paused,
            terminalReason: nil
        )
        let pauseContext = try ReconstructionJobPauseContext(
            cause: .pausedByUser,
            resumeTarget: .retrieving
        )
        let pausedJob = try ReconstructionJobRecord(
            jobID: originalJob.jobID,
            reconstructionProjectID: originalJob.reconstructionProjectID,
            objective: originalJob.objective,
            objectiveSHA256: originalJob.objectiveSHA256,
            creationCorpusManifestSHA256: originalJob.creationCorpusManifestSHA256,
            state: .paused,
            currentCheckpointID: pausedCheckpoint.checkpointID,
            terminalReason: nil,
            budget: originalJob.budget,
            creationOrdinal: try XCTUnwrap(originalJob.creationOrdinal),
            pauseContext: pauseContext
        )
        let validPausedState = try replacing(
            fixture.state,
            jobs: [pausedJob],
            checkpoints: [resumableCheckpoint, pausedCheckpoint]
        )
        let validPausedEncoding = try ReconstructionPackageCodec.encode(validPausedState)
        var pausedCheckpointObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: validPausedEncoding.checkpointData
            ) as? [String: Any]
        )
        var pausedJobs = try XCTUnwrap(
            pausedCheckpointObject["jobs"] as? [[String: Any]]
        )
        var ambiguousLegacyPausedJob = try XCTUnwrap(pausedJobs.first)
        ambiguousLegacyPausedJob["recordSchemaVersion"] = 2
        ambiguousLegacyPausedJob.removeValue(forKey: "pauseContext")
        pausedJobs[0] = ambiguousLegacyPausedJob
        pausedCheckpointObject["jobs"] = pausedJobs
        let ambiguousPausedData = try JSONSerialization.data(
            withJSONObject: pausedCheckpointObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try ReconstructionPackageCodec.decode(
                descriptor: try ReconstructionPackageDescriptor(
                    corpusManifestPath: validPausedEncoding.descriptor.corpusManifestPath,
                    evidenceManifestPath: validPausedEncoding.descriptor.evidenceManifestPath,
                    checkpointManifestPath: validPausedEncoding.descriptor.checkpointManifestPath,
                    corpusManifestSHA256: validPausedEncoding.descriptor.corpusManifestSHA256,
                    evidenceManifestSHA256: validPausedEncoding.descriptor.evidenceManifestSHA256,
                    checkpointManifestSHA256: ReconstructionPackageFixture.digest(
                        ambiguousPausedData
                    )
                ),
                corpusData: validPausedEncoding.corpusData,
                evidenceData: validPausedEncoding.evidenceData,
                checkpointData: ambiguousPausedData
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionValidationError,
                .invalidReference(field: "legacy paused job pause context")
            )
        }
    }

    func testPackageBoundaryRejectsTaskCanonicalIdentityDrift() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let original = try XCTUnwrap(fixture.state.tasks.first)
        let forgedDigest = original.identity.canonicalSHA256 == String(repeating: "a", count: 64)
            ? String(repeating: "b", count: 64)
            : String(repeating: "a", count: 64)
        let forgedIdentity = try ReconstructionTaskIdentity(
            taskID: original.identity.taskID,
            schemaVersion: original.identity.schemaVersion,
            jobID: original.identity.jobID,
            kind: original.identity.kind,
            subject: original.identity.subject,
            dependencyTaskIDs: original.identity.dependencyTaskIDs,
            operationContractIdentity: original.identity.operationContractIdentity,
            canonicalSHA256: forgedDigest
        )
        let forgedTask = ReconstructionTaskRecord(
            identity: forgedIdentity,
            state: original.state,
            diagnostic: original.diagnostic
        )

        XCTAssertThrowsError(
            try ReconstructionPackageCodec.encode(
                replacing(fixture.state, tasks: [forgedTask])
            )
        )
    }

    func testPackageBoundaryRejectsCheckpointIdentityCountAndDigestDrift() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let checkpoint = try XCTUnwrap(fixture.state.checkpoints.first)
        let forgedCount = try ReconstructionCheckpoint(
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
            canonicalEncodedByteCount: checkpoint.canonicalEncodedByteCount + 1,
            canonicalSHA256: checkpoint.canonicalSHA256
        )
        let forgedDigest = try ReconstructionCheckpoint(
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
            canonicalEncodedByteCount: checkpoint.canonicalEncodedByteCount,
            canonicalSHA256: checkpoint.canonicalSHA256 == String(repeating: "a", count: 64)
                ? String(repeating: "b", count: 64)
                : String(repeating: "a", count: 64)
        )

        for hostile in [forgedCount, forgedDigest] {
            let hostileState = try replacing(fixture.state, checkpoints: [hostile])
            XCTAssertThrowsError(
                try ReconstructionPackageCodec.encode(hostileState)
            )
            XCTAssertThrowsError(
                try ReconstructionPackageCodec.validateGraph(
                    hostileState,
                    declaredContents: ReconstructionPackageCodec.contentRecords(
                        in: hostileState
                    )
                )
            )
        }
    }

    func testVersion3WorkspaceManifestRejectsDuplicateMembersAtEveryObjectDepth() throws {
        let mutations: [(String, (String) throws -> String)] = [
            ("root", { manifest in
                guard manifest.first == "{" else {
                    throw ReconstructionPackageValidationError.noncanonicalManifest("test fixture")
                }
                return "{\"formatVersion\":3," + manifest.dropFirst()
            }),
            ("descriptor", { manifest in
                guard let field = manifest.range(of: "\"reconstruction\""),
                      let brace = manifest[field.upperBound...].firstIndex(of: "{") else {
                    throw ReconstructionPackageValidationError.noncanonicalManifest("test fixture")
                }
                var mutated = manifest
                mutated.insert(
                    contentsOf: "\"schemaVersion\":1,",
                    at: mutated.index(after: brace)
                )
                return mutated
            }),
            ("escaped descriptor", { manifest in
                guard let field = manifest.range(of: "\"reconstruction\""),
                      let brace = manifest[field.upperBound...].firstIndex(of: "{") else {
                    throw ReconstructionPackageValidationError.noncanonicalManifest("test fixture")
                }
                var mutated = manifest
                mutated.insert(
                    contentsOf: "\"schema\\u0056ersion\":1,",
                    at: mutated.index(after: brace)
                )
                return mutated
            }),
        ]

        for (label, mutation) in mutations {
            let fixture = try ReconstructionPackageFixture.make()
            defer { fixture.remove() }
            try fixture.write()
            let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
            let original = try XCTUnwrap(
                String(data: Data(contentsOf: manifestURL), encoding: .utf8)
            )
            try Data(mutation(original).utf8).write(to: manifestURL)

            XCTAssertThrowsError(
                try MacScopeDocumentPackage.openPackage(from: fixture.packageURL),
                label
            )
        }
    }

    func testVersion3WorkspaceManifestRejectsUnknownTopLevelAndDescriptorKeys() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        let canonical = try Data(contentsOf: manifestURL)
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )

        var hostileTopLevel = original
        hostileTopLevel["unexpectedV3Metadata"] = "must reject"
        try JSONSerialization.data(
            withJSONObject: hostileTopLevel,
            options: [.sortedKeys]
        ).write(to: manifestURL)
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))

        var hostileDescriptor = original
        var descriptor = try XCTUnwrap(hostileDescriptor["reconstruction"] as? [String: Any])
        descriptor["unexpectedDescriptorField"] = true
        hostileDescriptor["reconstruction"] = descriptor
        try JSONSerialization.data(
            withJSONObject: hostileDescriptor,
            options: [.sortedKeys]
        ).write(to: manifestURL)
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
    }

    func testCorpusObjectValidationRejectsMissingMutatedOversizedAndAliasedLeaves() throws {
        let mutations: [(ReconstructionPackageFixture) throws -> Void] = [
            { try FileManager.default.removeItem(at: $0.corpusAttachmentURL) },
            { fixture in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: fixture.corpusAttachmentURL.path
                )
                try Data("mutated corpus object".utf8).write(to: fixture.corpusAttachmentURL)
            },
            { fixture in
                try FileManager.default.removeItem(at: fixture.corpusAttachmentURL)
                FileManager.default.createFile(atPath: try fixture.corpusAttachmentURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: fixture.corpusAttachmentURL)
                try handle.truncate(atOffset: ReconstructionPackageLayout.maximumCorpusAttachmentBytes + 1)
                try handle.close()
            },
            { fixture in
                try FileManager.default.removeItem(at: fixture.corpusAttachmentURL)
                try FileManager.default.createDirectory(
                    at: fixture.corpusAttachmentURL,
                    withIntermediateDirectories: false
                )
            },
            { fixture in
                try FileManager.default.removeItem(at: fixture.corpusAttachmentURL)
                try FileManager.default.createSymbolicLink(
                    at: fixture.corpusAttachmentURL,
                    withDestinationURL: fixture.sourceURL
                )
            },
            { fixture in
                let alias = fixture.root.appendingPathComponent("hard-link-alias")
                try FileManager.default.linkItem(at: fixture.corpusAttachmentURL, to: alias)
            },
        ]
        for mutation in mutations {
            let fixture = try ReconstructionPackageFixture.make()
            defer { fixture.remove() }
            try fixture.write()
            try mutation(fixture)
            XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
        }
    }

    func testDescriptorRelativeTraversalRejectsRootIntermediateCaseShardAndEscapeAttacks() throws {
        let mutations: [(ReconstructionPackageFixture) throws -> Void] = [
            { fixture in
                let root = fixture.packageURL.appendingPathComponent("Reconstruction")
                let target = fixture.packageURL.appendingPathComponent("RealReconstruction")
                try FileManager.default.moveItem(at: root, to: target)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
            },
            { fixture in
                let shard = try fixture.corpusAttachmentURL.deletingLastPathComponent()
                let target = fixture.root.appendingPathComponent("RealShard")
                try FileManager.default.moveItem(at: shard, to: target)
                try FileManager.default.createSymbolicLink(at: shard, withDestinationURL: target)
            },
            { fixture in
                let root = fixture.packageURL.appendingPathComponent("Reconstruction")
                let temporary = fixture.packageURL.appendingPathComponent("case-temporary")
                try FileManager.default.moveItem(at: root, to: temporary)
                try FileManager.default.moveItem(
                    at: temporary,
                    to: fixture.packageURL.appendingPathComponent("reconstruction")
                )
            },
            { fixture in
                let object = try fixture.corpusAttachmentURL
                let temporary = fixture.root.appendingPathComponent("case-object")
                try FileManager.default.moveItem(at: object, to: temporary)
                try FileManager.default.moveItem(
                    at: temporary,
                    to: object.deletingLastPathComponent()
                        .appendingPathComponent(fixture.contentIdentity.digest.uppercased())
                )
            },
            { fixture in
                let object = try fixture.corpusAttachmentURL
                let wrongShard = object.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("ff", isDirectory: true)
                try FileManager.default.createDirectory(at: wrongShard, withIntermediateDirectories: false)
                try FileManager.default.moveItem(
                    at: object,
                    to: wrongShard.appendingPathComponent(fixture.contentIdentity.digest)
                )
            },
            { fixture in
                let extra = fixture.packageURL.appendingPathComponent(
                    "Reconstruction/Corpus/sha256/00/" + String(repeating: "0", count: 64)
                )
                try FileManager.default.createDirectory(
                    at: extra.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("undeclared".utf8).write(to: extra)
            },
            { fixture in
                try Self.mutateWorkspaceDescriptor(in: fixture) { descriptor in
                    descriptor["corpusManifestPath"] = "../corpus-manifest.json"
                }
            },
        ]
        for mutation in mutations {
            let fixture = try ReconstructionPackageFixture.make()
            defer { fixture.remove() }
            try fixture.write()
            try mutation(fixture)
            XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
        }
    }

    func testDetachedManifestValidationRejectsDigestCanonicalityDisagreementAndCycles() throws {
        try assertRejectedDetachedMutation(path: ReconstructionPackageLayout.corpusManifestPath) { data in
            (data + Data([0x20]), false)
        }
        try assertRejectedDetachedMutation(path: ReconstructionPackageLayout.corpusManifestPath) { data in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["unknown"] = true
            return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), true)
        }
        try assertRejectedDetachedMutation(path: ReconstructionPackageLayout.evidenceManifestPath) {
            (Data([0x20]) + $0, true)
        }
        try assertRejectedDetachedMutation(path: ReconstructionPackageLayout.corpusManifestPath) { data in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["contents"] = []
            return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), true)
        }
        try assertRejectedDetachedMutation(
            path: ReconstructionPackageLayout.checkpointManifestPath,
            includesEvidenceGraph: true
        ) { data in
            let manifest = try JSONDecoder().decode(
                ReconstructionPackageCheckpointManifest.self,
                from: data
            )
            let original = try XCTUnwrap(manifest.checkpoints.first)
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: original.checkpointID,
                schemaVersion: original.schemaVersion,
                jobID: original.jobID,
                revision: 1,
                parentCheckpointID: original.checkpointID,
                parentCheckpointSHA256: original.canonicalSHA256,
                corpusManifestSHA256: original.corpusManifestSHA256,
                evidenceFrontierSHA256: original.evidenceFrontierSHA256,
                pendingTaskIDs: original.pendingTaskIDs,
                runningTaskIDs: original.runningTaskIDs,
                completedTaskIDs: original.completedTaskIDs,
                failedTaskIDs: original.failedTaskIDs,
                blockedTaskIDs: original.blockedTaskIDs,
                unresolvedEvidenceGapSHA256: original.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: original.modelReceiptIDs,
                toolReceiptIDs: original.toolReceiptIDs,
                coordinatorState: original.coordinatorState,
                terminalReason: original.terminalReason
            )
            return (
                try ReconstructionCanonicalJSON.encode(
                    ReconstructionPackageCheckpointManifest(
                        jobs: manifest.jobs,
                        tasks: manifest.tasks,
                        checkpoints: [checkpoint]
                    )
                ),
                true
            )
        }
    }

    func testNestedTask2SemanticsAndEvidencePayloadDigestAreRevalidated() throws {
        try assertRejectedDetachedMutation(path: ReconstructionPackageLayout.corpusManifestPath) { data in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var manifests = try XCTUnwrap(object["corpusManifests"] as? [[String: Any]])
            var manifest = try XCTUnwrap(manifests.first)
            var artifacts = try XCTUnwrap(manifest["artifacts"] as? [[String: Any]])
            artifacts[0]["roles"] = []
            manifest["artifacts"] = artifacts
            manifests[0] = manifest
            object["corpusManifests"] = manifests
            return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), true)
        }
        try assertRejectedDetachedMutation(
            path: ReconstructionPackageLayout.evidenceManifestPath,
            includesEvidenceGraph: true
        ) { data in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var evidence = try XCTUnwrap(object["evidence"] as? [[String: Any]])
            let original = try XCTUnwrap(Data(base64Encoded: evidence[0]["payload"] as? String ?? ""))
            evidence[0]["payload"] = Data(repeating: 0x58, count: original.count).base64EncodedString()
            object["evidence"] = evidence
            return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), true)
        }
        try assertRejectedDetachedMutation(
            path: ReconstructionPackageLayout.checkpointManifestPath,
            includesEvidenceGraph: true
        ) { data in
            let manifest = try JSONDecoder().decode(
                ReconstructionPackageCheckpointManifest.self,
                from: data
            )
            let original = try XCTUnwrap(manifest.checkpoints.first)
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: original.checkpointID,
                schemaVersion: original.schemaVersion,
                jobID: original.jobID,
                revision: original.revision,
                parentCheckpointID: original.parentCheckpointID,
                parentCheckpointSHA256: original.parentCheckpointSHA256,
                corpusManifestSHA256: original.corpusManifestSHA256,
                evidenceFrontierSHA256: original.evidenceFrontierSHA256,
                pendingTaskIDs: original.completedTaskIDs,
                runningTaskIDs: original.runningTaskIDs,
                completedTaskIDs: [],
                failedTaskIDs: original.failedTaskIDs,
                blockedTaskIDs: original.blockedTaskIDs,
                unresolvedEvidenceGapSHA256: original.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: original.modelReceiptIDs,
                toolReceiptIDs: original.toolReceiptIDs,
                coordinatorState: original.coordinatorState,
                terminalReason: original.terminalReason
            )
            return (
                try ReconstructionCanonicalJSON.encode(
                    ReconstructionPackageCheckpointManifest(
                        jobs: manifest.jobs,
                        tasks: manifest.tasks,
                        checkpoints: [checkpoint]
                    )
                ),
                true
            )
        }
    }

    func testGraphRejectsOrphanAndStaleAuthoritativeCheckpoints() throws {
        for mutation in ["orphan", "stale"] {
            try assertRejectedDetachedMutation(
                path: ReconstructionPackageLayout.checkpointManifestPath,
                includesEvidenceGraph: true
            ) { data in
                if mutation == "orphan" {
                    let manifest = try JSONDecoder().decode(
                        ReconstructionPackageCheckpointManifest.self,
                        from: data
                    )
                    let original = try XCTUnwrap(manifest.checkpoints.first)
                    let checkpoint = try ReconstructionCheckpoint.make(
                        checkpointID: original.checkpointID,
                        schemaVersion: original.schemaVersion,
                        jobID: UUID(),
                        revision: original.revision,
                        parentCheckpointID: original.parentCheckpointID,
                        parentCheckpointSHA256: original.parentCheckpointSHA256,
                        corpusManifestSHA256: original.corpusManifestSHA256,
                        evidenceFrontierSHA256: original.evidenceFrontierSHA256,
                        pendingTaskIDs: original.pendingTaskIDs,
                        runningTaskIDs: original.runningTaskIDs,
                        completedTaskIDs: original.completedTaskIDs,
                        failedTaskIDs: original.failedTaskIDs,
                        blockedTaskIDs: original.blockedTaskIDs,
                        unresolvedEvidenceGapSHA256: original.unresolvedEvidenceGapSHA256,
                        modelReceiptIDs: original.modelReceiptIDs,
                        toolReceiptIDs: original.toolReceiptIDs,
                        coordinatorState: original.coordinatorState,
                        terminalReason: original.terminalReason
                    )
                    return (
                        try ReconstructionCanonicalJSON.encode(
                            ReconstructionPackageCheckpointManifest(
                                jobs: manifest.jobs,
                                tasks: manifest.tasks,
                                checkpoints: [checkpoint]
                            )
                        ),
                        true
                    )
                } else {
                    var object = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: data) as? [String: Any]
                    )
                    var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
                    jobs[0]["currentCheckpointID"] = NSNull()
                    object["jobs"] = jobs
                    return (
                        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                        true
                    )
                }
            }
        }
    }

    func testGraphRejectsCrossProjectCheckpointAndTaskDependencyCycle() throws {
        do {
            let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
            defer { fixture.remove() }
            try fixture.write()
            let corpusURL = fixture.packageURL.appendingPathComponent(
                ReconstructionPackageLayout.corpusManifestPath
            )
            var corpus = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as? [String: Any]
            )
            let otherProjectID = UUID().uuidString
            let otherDigest = ReconstructionPackageFixture.digest(Data("other-project-corpus".utf8))
            var projects = try XCTUnwrap(corpus["projects"] as? [[String: Any]])
            projects.append([
                "projectID": otherProjectID,
                "schemaVersion": 1,
                "name": "Other project",
                "currentCorpusManifestSHA256": otherDigest,
            ])
            projects.sort { ($0["projectID"] as? String ?? "") < ($1["projectID"] as? String ?? "") }
            var manifests = try XCTUnwrap(corpus["corpusManifests"] as? [[String: Any]])
            manifests.append([
                "schemaVersion": 1,
                "reconstructionProjectID": otherProjectID,
                "artifacts": [],
                "relations": [],
                "canonicalSHA256": otherDigest,
            ])
            manifests.sort {
                ($0["reconstructionProjectID"] as? String ?? "")
                    < ($1["reconstructionProjectID"] as? String ?? "")
            }
            corpus["projects"] = projects
            corpus["corpusManifests"] = manifests
            let corpusData = try JSONSerialization.data(withJSONObject: corpus, options: [.sortedKeys])
            try corpusData.write(to: corpusURL)
            try updateDescriptor(
                in: fixture,
                path: ReconstructionPackageLayout.corpusManifestPath,
                data: corpusData
            )

            let checkpointURL = fixture.packageURL.appendingPathComponent(
                ReconstructionPackageLayout.checkpointManifestPath
            )
            let checkpointManifest = try JSONDecoder().decode(
                ReconstructionPackageCheckpointManifest.self,
                from: Data(contentsOf: checkpointURL)
            )
            let originalCheckpoint = try XCTUnwrap(checkpointManifest.checkpoints.first)
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: originalCheckpoint.checkpointID,
                schemaVersion: originalCheckpoint.schemaVersion,
                jobID: originalCheckpoint.jobID,
                revision: originalCheckpoint.revision,
                parentCheckpointID: originalCheckpoint.parentCheckpointID,
                parentCheckpointSHA256: originalCheckpoint.parentCheckpointSHA256,
                corpusManifestSHA256: otherDigest,
                evidenceFrontierSHA256: originalCheckpoint.evidenceFrontierSHA256,
                pendingTaskIDs: originalCheckpoint.pendingTaskIDs,
                runningTaskIDs: originalCheckpoint.runningTaskIDs,
                completedTaskIDs: originalCheckpoint.completedTaskIDs,
                failedTaskIDs: originalCheckpoint.failedTaskIDs,
                blockedTaskIDs: originalCheckpoint.blockedTaskIDs,
                unresolvedEvidenceGapSHA256: originalCheckpoint.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: originalCheckpoint.modelReceiptIDs,
                toolReceiptIDs: originalCheckpoint.toolReceiptIDs,
                coordinatorState: originalCheckpoint.coordinatorState,
                terminalReason: originalCheckpoint.terminalReason
            )
            let checkpointData = try ReconstructionCanonicalJSON.encode(
                ReconstructionPackageCheckpointManifest(
                    jobs: checkpointManifest.jobs,
                    tasks: checkpointManifest.tasks,
                    checkpoints: [checkpoint]
                )
            )
            try checkpointData.write(to: checkpointURL)
            try updateDescriptor(
                in: fixture,
                path: ReconstructionPackageLayout.checkpointManifestPath,
                data: checkpointData
            )
            XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
        }

        do {
            let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
            defer { fixture.remove() }
            try fixture.write()
            let checkpointURL = fixture.packageURL.appendingPathComponent(
                ReconstructionPackageLayout.checkpointManifestPath
            )
            let manifest = try JSONDecoder().decode(
                ReconstructionPackageCheckpointManifest.self,
                from: Data(contentsOf: checkpointURL)
            )
            let template = try XCTUnwrap(manifest.tasks.first)
            let firstID = template.identity.taskID
            let secondID = UUID()
            let first = ReconstructionTaskRecord(
                identity: try ReconstructionTaskIdentity.make(
                    taskID: firstID,
                    jobID: template.identity.jobID,
                    kind: template.identity.kind,
                    subject: template.identity.subject,
                    dependencyTaskIDs: [secondID],
                    operationContractIdentity: template.identity.operationContractIdentity
                ),
                state: template.state,
                diagnostic: template.diagnostic
            )
            let second = ReconstructionTaskRecord(
                identity: try ReconstructionTaskIdentity.make(
                    taskID: secondID,
                    jobID: template.identity.jobID,
                    kind: template.identity.kind,
                    subject: template.identity.subject,
                    dependencyTaskIDs: [firstID],
                    operationContractIdentity: template.identity.operationContractIdentity
                ),
                state: template.state,
                diagnostic: template.diagnostic
            )
            let originalCheckpoint = try XCTUnwrap(manifest.checkpoints.first)
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: originalCheckpoint.checkpointID,
                schemaVersion: originalCheckpoint.schemaVersion,
                jobID: originalCheckpoint.jobID,
                revision: originalCheckpoint.revision,
                parentCheckpointID: originalCheckpoint.parentCheckpointID,
                parentCheckpointSHA256: originalCheckpoint.parentCheckpointSHA256,
                corpusManifestSHA256: originalCheckpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: originalCheckpoint.evidenceFrontierSHA256,
                pendingTaskIDs: originalCheckpoint.pendingTaskIDs,
                runningTaskIDs: originalCheckpoint.runningTaskIDs,
                completedTaskIDs: [firstID, secondID],
                failedTaskIDs: originalCheckpoint.failedTaskIDs,
                blockedTaskIDs: originalCheckpoint.blockedTaskIDs,
                unresolvedEvidenceGapSHA256: originalCheckpoint.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: originalCheckpoint.modelReceiptIDs,
                toolReceiptIDs: originalCheckpoint.toolReceiptIDs,
                coordinatorState: originalCheckpoint.coordinatorState,
                terminalReason: originalCheckpoint.terminalReason
            )
            let data = try ReconstructionCanonicalJSON.encode(
                ReconstructionPackageCheckpointManifest(
                    jobs: manifest.jobs,
                    tasks: [first, second],
                    checkpoints: [checkpoint]
                )
            )
            try data.write(to: checkpointURL)
            try updateDescriptor(
                in: fixture,
                path: ReconstructionPackageLayout.checkpointManifestPath,
                data: data
            )
            XCTAssertThrowsError(
                try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
            ) { error in
                guard case ReconstructionPackageValidationError.stateGraphInvalid(
                    "task dependency cycle"
                ) = error else {
                    return XCTFail("Expected task dependency cycle, got \(error)")
                }
            }
        }
    }

    func testLongAcyclicTaskDependencyChainOpensWithoutStackGrowthAndCycleStillRejects() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        try fixture.write()
        let checkpointURL = fixture.packageURL.appendingPathComponent(
            ReconstructionPackageLayout.checkpointManifestPath
        )
        let originalManifest = try JSONDecoder().decode(
            ReconstructionPackageCheckpointManifest.self,
            from: Data(contentsOf: checkpointURL)
        )
        var tasks = originalManifest.tasks
        let template = try XCTUnwrap(tasks.first)
        let rootID = template.identity.taskID
        var priorID = rootID
        var chainIDs: [UUID] = []
        chainIDs.reserveCapacity(20_000)
        for index in 0..<20_000 {
            let taskID = try XCTUnwrap(UUID(
                uuidString: String(
                    format: "39000000-0000-0000-0000-%012llx",
                    UInt64(index + 1)
                )
            ))
            let identity = try ReconstructionTaskIdentity.make(
                taskID: taskID,
                jobID: template.identity.jobID,
                kind: template.identity.kind,
                subject: template.identity.subject,
                dependencyTaskIDs: [priorID],
                operationContractIdentity: template.identity.operationContractIdentity
            )
            tasks.append(ReconstructionTaskRecord(
                identity: identity,
                state: template.state,
                diagnostic: template.diagnostic
            ))
            chainIDs.append(taskID)
            priorID = taskID
        }
        let mutatedCheckpoint = try XCTUnwrap(originalManifest.checkpoints.first)
        let canonicalCheckpoint = try ReconstructionCheckpoint.make(
            checkpointID: mutatedCheckpoint.checkpointID,
            schemaVersion: mutatedCheckpoint.schemaVersion,
            jobID: mutatedCheckpoint.jobID,
            revision: mutatedCheckpoint.revision,
            parentCheckpointID: mutatedCheckpoint.parentCheckpointID,
            parentCheckpointSHA256: mutatedCheckpoint.parentCheckpointSHA256,
            corpusManifestSHA256: mutatedCheckpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: mutatedCheckpoint.evidenceFrontierSHA256,
            pendingTaskIDs: mutatedCheckpoint.pendingTaskIDs,
            runningTaskIDs: mutatedCheckpoint.runningTaskIDs,
            completedTaskIDs: [rootID] + chainIDs,
            failedTaskIDs: mutatedCheckpoint.failedTaskIDs,
            blockedTaskIDs: mutatedCheckpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: mutatedCheckpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: mutatedCheckpoint.modelReceiptIDs,
            toolReceiptIDs: mutatedCheckpoint.toolReceiptIDs,
            coordinatorState: mutatedCheckpoint.coordinatorState,
            terminalReason: mutatedCheckpoint.terminalReason
        )
        var data = try ReconstructionCanonicalJSON.encode(
            ReconstructionPackageCheckpointManifest(
                jobs: originalManifest.jobs,
                tasks: tasks,
                checkpoints: [canonicalCheckpoint]
            )
        )
        try data.write(to: checkpointURL)
        try updateDescriptor(
            in: fixture,
            path: ReconstructionPackageLayout.checkpointManifestPath,
            data: data
        )

        XCTAssertNoThrow(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))

        let rootIndex = try XCTUnwrap(tasks.firstIndex {
            $0.identity.taskID == rootID
        })
        let rootTask = tasks[rootIndex]
        tasks[rootIndex] = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: rootTask.identity.taskID,
                jobID: rootTask.identity.jobID,
                kind: rootTask.identity.kind,
                subject: rootTask.identity.subject,
                dependencyTaskIDs: [try XCTUnwrap(chainIDs.last)],
                operationContractIdentity: rootTask.identity.operationContractIdentity
            ),
            state: rootTask.state,
            diagnostic: rootTask.diagnostic
        )
        data = try ReconstructionCanonicalJSON.encode(
            ReconstructionPackageCheckpointManifest(
                jobs: originalManifest.jobs,
                tasks: tasks,
                checkpoints: [canonicalCheckpoint]
            )
        )
        try data.write(to: checkpointURL)
        try updateDescriptor(
            in: fixture,
            path: ReconstructionPackageLayout.checkpointManifestPath,
            data: data
        )

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        ) { error in
            guard case ReconstructionPackageValidationError.stateGraphInvalid(
                "task dependency cycle"
            ) = error else {
                return XCTFail("Expected task dependency cycle, got \(error)")
            }
        }
    }

    func testReceiptFrontierRequiresRecordedFirstIntroductionAndCumulativeCarryForward() throws {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let rich = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        let toolReceipt = try XCTUnwrap(rich.toolReceipts.first)
        let modelReceipt = try XCTUnwrap(rich.modelReceipts.first)
        let replay = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: rich,
            receipt: toolReceipt
        )
        let cumulativeCheckpoints = rich.checkpoints + [replay.successorCheckpoint]
        let toolReceipts = [toolReceipt.receiptID: toolReceipt]
        let modelReceipts = [modelReceipt.receiptID: modelReceipt]

        XCTAssertNoThrow(
            try ReconstructionPackageCodec.validateCumulativeReceiptFrontiers(
                checkpoints: cumulativeCheckpoints,
                toolReceipts: toolReceipts,
                modelReceipts: modelReceipts
            )
        )

        let introductionOmitted = try checkpoint(
            copying: rich.checkpoints[1],
            toolReceiptIDs: [],
            modelReceiptIDs: rich.checkpoints[1].modelReceiptIDs
        )
        let carryForwardOmitted = try checkpoint(
            copying: replay.successorCheckpoint,
            toolReceiptIDs: [],
            modelReceiptIDs: replay.successorCheckpoint.modelReceiptIDs
        )
        let introducedEarly = try checkpoint(
            copying: rich.checkpoints[0],
            toolReceiptIDs: [toolReceipt.receiptID],
            modelReceiptIDs: []
        )
        let duplicateIntroduction = try checkpoint(
            copying: rich.checkpoints[1],
            checkpointID: UUID(),
            revision: rich.checkpoints[1].revision,
            parentCheckpointID: rich.checkpoints[1].parentCheckpointID,
            parentCheckpointSHA256: rich.checkpoints[1].parentCheckpointSHA256,
            toolReceiptIDs: rich.checkpoints[1].toolReceiptIDs,
            modelReceiptIDs: rich.checkpoints[1].modelReceiptIDs
        )
        let foreignToolReceipt = try ReconstructionToolReceipt(
            receiptID: toolReceipt.receiptID,
            jobID: UUID(),
            taskID: toolReceipt.taskID,
            checkpointRevision: toolReceipt.checkpointRevision,
            requestIdentitySHA256: toolReceipt.requestIdentitySHA256,
            producer: toolReceipt.producer,
            terminalState: toolReceipt.terminalState,
            outputEvidenceIDs: toolReceipt.outputEvidenceIDs,
            diagnostic: toolReceipt.diagnostic,
            canonicalSHA256: toolReceipt.canonicalSHA256
        )
        let hostileFrontiers: [(
            String,
            [ReconstructionCheckpoint],
            [UUID: ReconstructionToolReceipt]
        )] = [
            (
                "omitted recorded introduction",
                [rich.checkpoints[0], introductionOmitted, replay.successorCheckpoint],
                toolReceipts
            ),
            (
                "omitted cumulative carry-forward",
                rich.checkpoints + [carryForwardOmitted],
                toolReceipts
            ),
            (
                "early introduction",
                [introducedEarly, rich.checkpoints[1], replay.successorCheckpoint],
                toolReceipts
            ),
            (
                "foreign receipt",
                cumulativeCheckpoints,
                [foreignToolReceipt.receiptID: foreignToolReceipt]
            ),
            (
                "duplicate first introduction",
                rich.checkpoints + [duplicateIntroduction],
                toolReceipts
            ),
        ]
        for (label, checkpoints, receipts) in hostileFrontiers {
            XCTAssertThrowsError(
                try ReconstructionPackageCodec.validateCumulativeReceiptFrontiers(
                    checkpoints: checkpoints,
                    toolReceipts: receipts,
                    modelReceipts: modelReceipts
                ),
                label
            )
        }
    }

    func testToolReceiptsRejectTwoCanonicalTerminalOutcomesForOneTask() throws {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let rich = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        let original = try XCTUnwrap(rich.toolReceipts.first)
        let duplicate = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: UUID(uuidString: "53000000-0000-4000-8000-000000000201")!,
            jobID: original.jobID,
            taskID: original.taskID,
            checkpointRevision: original.checkpointRevision,
            requestIdentitySHA256: ReconstructionDatabaseTestFixtures.digest("9"),
            producer: original.producer,
            terminalState: .failed,
            outputEvidenceIDs: [],
            diagnostic: .sanitizing(
                "A second terminal outcome must not bind the same task."
            )
        )
        let hostile = try replacing(
            rich,
            toolReceipts: rich.toolReceipts + [duplicate]
        )

        XCTAssertThrowsError(try ReconstructionPackageCodec.validateGraph(hostile)) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("duplicate tool receipt task binding")
            )
        }

        // Mandatory mutation RED: remove the
        // `validateUniqueToolReceiptTaskBindings(state.toolReceipts)` call from validateGraph.
        // This exact hostile graph is then accepted because both receipt IDs and digests are
        // individually canonical, proving the package admission guard is load-bearing.
    }

    func testArtifactRelationIDsAreUniqueAcrossWorkspaceManifests() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let originalManifest = try XCTUnwrap(fixture.state.corpusManifests.first)
        let originalOccurrence = try XCTUnwrap(originalManifest.artifacts.first)
        let secondOccurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
            contentIdentity: fixture.contentIdentity,
            kind: .source,
            roles: [.referenceSource],
            executableMode: false,
            originalName: "second.bin",
            diagnostic: nil
        )
        let relationID = UUID()
        let relation1 = try ReconstructionArtifactRelationRecord(
            relationID: relationID,
            kind: .unresolvedDependency,
            sourceOccurrenceID: originalOccurrence.occurrenceID,
            targetOccurrenceID: nil,
            unresolvedLocator: "one",
            evidenceSource: .userSelection,
            canonicalSHA256: String(repeating: "a", count: 64)
        )
        let relation2 = try ReconstructionArtifactRelationRecord(
            relationID: relationID,
            kind: .unresolvedDependency,
            sourceOccurrenceID: secondOccurrence.occurrenceID,
            targetOccurrenceID: nil,
            unresolvedLocator: "two",
            evidenceSource: .userSelection,
            canonicalSHA256: String(repeating: "b", count: 64)
        )
        let firstManifest = try canonicalManifest(
            projectID: originalManifest.reconstructionProjectID,
            artifacts: [originalOccurrence],
            relations: [relation1]
        )
        let firstProject = try ReconstructionProjectRecord(
            projectID: originalManifest.reconstructionProjectID,
            name: try XCTUnwrap(fixture.state.projects.first?.name),
            currentCorpusManifestSHA256: firstManifest.canonicalSHA256
        )
        let secondProjectID = UUID()
        let secondManifest = try canonicalManifest(
            projectID: secondProjectID,
            artifacts: [secondOccurrence],
            relations: [relation2]
        )
        let encoded = try ReconstructionPackageCodec.encode(fixture.state)
        let originalPackage: ReconstructionPackageCorpusManifest = try JSONDecoder().decode(
            ReconstructionPackageCorpusManifest.self,
            from: encoded.corpusData
        )
        let hostile = try ReconstructionCanonicalJSON.encode(
            ReconstructionPackageCorpusManifest(
                contents: originalPackage.contents,
                projects: [firstProject] + [
                    try ReconstructionProjectRecord(
                        projectID: secondProjectID,
                        name: "Second",
                        currentCorpusManifestSHA256: secondManifest.canonicalSHA256
                    ),
                ],
                corpusManifests: [firstManifest, secondManifest]
            )
        )
        let url = fixture.packageURL.appendingPathComponent(
            ReconstructionPackageLayout.corpusManifestPath
        )
        try hostile.write(to: url)
        try updateDescriptor(
            in: fixture,
            path: ReconstructionPackageLayout.corpusManifestPath,
            data: hostile
        )
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
    }

    func testReceiptMembershipMustBeReciprocalWithEvidenceProvenance() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        try fixture.write()
        let job = try XCTUnwrap(fixture.state.jobs.first)
        let task = try XCTUnwrap(fixture.state.tasks.first)
        let evidence = try XCTUnwrap(fixture.state.evidence.first)
        let sourceCheckpoint = try XCTUnwrap(fixture.state.checkpoints.first)
        let receipt = try ReconstructionToolReceipt(
            receiptID: UUID(),
            jobID: job.jobID,
            taskID: task.identity.taskID,
            checkpointRevision: sourceCheckpoint.revision,
            requestIdentitySHA256: String(repeating: "d", count: 64),
            producer: evidence.producer,
            terminalState: .completed,
            outputEvidenceIDs: [evidence.evidenceID],
            diagnostic: nil,
            canonicalSHA256: String(repeating: "e", count: 64)
        )

        let evidenceURL = fixture.packageURL.appendingPathComponent(
            ReconstructionPackageLayout.evidenceManifestPath
        )
        let evidencePackage: ReconstructionPackageEvidenceManifest = try JSONDecoder().decode(
            ReconstructionPackageEvidenceManifest.self,
            from: Data(contentsOf: evidenceURL)
        )
        let hostileEvidence = try ReconstructionCanonicalJSON.encode(
            ReconstructionPackageEvidenceManifest(
                evidence: evidencePackage.evidence,
                evidenceRelations: evidencePackage.evidenceRelations,
                evidenceGaps: evidencePackage.evidenceGaps,
                toolReceipts: [receipt],
                modelReceipts: evidencePackage.modelReceipts
            )
        )
        try hostileEvidence.write(to: evidenceURL)
        try updateDescriptor(
            in: fixture,
            path: ReconstructionPackageLayout.evidenceManifestPath,
            data: hostileEvidence
        )

        let checkpointURL = fixture.packageURL.appendingPathComponent(
            ReconstructionPackageLayout.checkpointManifestPath
        )
        let checkpointPackage: ReconstructionPackageCheckpointManifest = try JSONDecoder().decode(
            ReconstructionPackageCheckpointManifest.self,
            from: Data(contentsOf: checkpointURL)
        )
        let original = try XCTUnwrap(checkpointPackage.checkpoints.first)
        let hostileCheckpoint = try checkpoint(
            copying: original,
            toolReceiptIDs: [receipt.receiptID],
            modelReceiptIDs: original.modelReceiptIDs
        )
        let hostileCheckpointData = try ReconstructionCanonicalJSON.encode(
            ReconstructionPackageCheckpointManifest(
                jobs: checkpointPackage.jobs,
                tasks: checkpointPackage.tasks,
                checkpoints: [hostileCheckpoint]
            )
        )
        try hostileCheckpointData.write(to: checkpointURL)
        try updateDescriptor(
            in: fixture,
            path: ReconstructionPackageLayout.checkpointManifestPath,
            data: hostileCheckpointData
        )
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("evidence receipt provenance")
            )
        }
    }

    func testCheckpointReceiptClaimsBindExactRevisionExactlyOnce() throws {
        enum ReceiptKind: CaseIterable {
            case tool
            case model
        }

        for kind in ReceiptKind.allCases {
            let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
            defer { fixture.remove() }
            let originalJob = try XCTUnwrap(fixture.state.jobs.first)
            let originalCheckpoint = try XCTUnwrap(fixture.state.checkpoints.first)
            let task = try XCTUnwrap(fixture.state.tasks.first)
            let producer = try XCTUnwrap(fixture.state.evidence.first).producer
            let receiptID = UUID()
            let secondCheckpointID = UUID()
            let receiptRevision: UInt64 = 1
            let firstCheckpoint = try checkpoint(
                copying: originalCheckpoint,
                toolReceiptIDs: kind == .tool ? [receiptID] : [],
                modelReceiptIDs: kind == .model ? [receiptID] : []
            )
            let secondCheckpoint = try checkpoint(
                copying: originalCheckpoint,
                checkpointID: secondCheckpointID,
                revision: receiptRevision,
                parentCheckpointID: originalCheckpoint.checkpointID,
                parentCheckpointSHA256: originalCheckpoint.canonicalSHA256,
                toolReceiptIDs: kind == .tool ? [receiptID] : [],
                modelReceiptIDs: kind == .model ? [receiptID] : []
            )
            let job = try ReconstructionJobRecord(
                jobID: originalJob.jobID,
                reconstructionProjectID: originalJob.reconstructionProjectID,
                objective: originalJob.objective,
                objectiveSHA256: originalJob.objectiveSHA256,
                creationCorpusManifestSHA256: originalJob.creationCorpusManifestSHA256,
                state: originalJob.state,
                currentCheckpointID: secondCheckpointID,
                terminalReason: originalJob.terminalReason,
                budget: originalJob.budget,
                creationOrdinal: try XCTUnwrap(originalJob.creationOrdinal),
                pauseContext: originalJob.pauseContext
            )
            let toolReceipts: [ReconstructionToolReceipt] = kind == .tool ? [
                try ReconstructionToolReceipt(
                    receiptID: receiptID,
                    jobID: originalJob.jobID,
                    taskID: task.identity.taskID,
                    checkpointRevision: receiptRevision,
                    requestIdentitySHA256: String(repeating: "a", count: 64),
                    producer: producer,
                    terminalState: .completed,
                    outputEvidenceIDs: [],
                    diagnostic: nil,
                    canonicalSHA256: String(repeating: "b", count: 64)
                ),
            ] : []
            let modelReceipts: [ReconstructionModelReceipt] = kind == .model ? [
                try ReconstructionModelReceipt(
                    receiptID: receiptID,
                    jobID: originalJob.jobID,
                    taskID: task.identity.taskID,
                    checkpointRevision: receiptRevision,
                    requestIdentitySHA256: String(repeating: "c", count: 64),
                    producer: producer,
                    terminalState: .completed,
                    selectedHandleIDs: [],
                    acceptedEvidenceIDs: [],
                    diagnostic: nil,
                    canonicalSHA256: String(repeating: "d", count: 64)
                ),
            ] : []
            let hostile = try ReconstructionWorkspaceState(
                projects: fixture.state.projects,
                corpusManifests: fixture.state.corpusManifests,
                evidence: fixture.state.evidence,
                evidenceRelations: fixture.state.evidenceRelations,
                evidenceGaps: fixture.state.evidenceGaps,
                jobs: [job],
                tasks: fixture.state.tasks,
                checkpoints: [firstCheckpoint, secondCheckpoint],
                toolReceipts: toolReceipts,
                modelReceipts: modelReceipts
            )

            XCTAssertThrowsError(
                try ReconstructionPackageCodec.encode(hostile),
                "\(kind) receipt was claimed by both its own revision and another checkpoint"
            )
        }
    }

    func testPackageBoundaryRejectsJobObjectiveDigestMismatch() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let original = try XCTUnwrap(fixture.state.jobs.first)
        let hostileJob = try ReconstructionJobRecord(
            jobID: original.jobID,
            reconstructionProjectID: original.reconstructionProjectID,
            objective: original.objective,
            objectiveSHA256: String(repeating: "f", count: 64),
            creationCorpusManifestSHA256: original.creationCorpusManifestSHA256,
            state: original.state,
            currentCheckpointID: original.currentCheckpointID,
            terminalReason: original.terminalReason,
            budget: original.budget,
            creationOrdinal: try XCTUnwrap(original.creationOrdinal),
            pauseContext: original.pauseContext
        )
        let hostile = try ReconstructionWorkspaceState(
            projects: fixture.state.projects,
            corpusManifests: fixture.state.corpusManifests,
            evidence: fixture.state.evidence,
            evidenceRelations: fixture.state.evidenceRelations,
            evidenceGaps: fixture.state.evidenceGaps,
            jobs: [hostileJob],
            tasks: fixture.state.tasks,
            checkpoints: fixture.state.checkpoints,
            toolReceipts: fixture.state.toolReceipts,
            modelReceipts: fixture.state.modelReceipts
        )

        XCTAssertThrowsError(try ReconstructionPackageCodec.encode(hostile))
    }

    func testWriterAndReaderShareExactByteCeilingForEveryDetachedManifest() throws {
        struct BoundaryCase {
            let path: String
            let state: ReconstructionWorkspaceState
            let data: (ReconstructionPackageEncodedManifests) -> Data
        }

        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let cases = [
            BoundaryCase(
                path: ReconstructionPackageLayout.corpusManifestPath,
                state: try corpusDominantState(from: fixture.state),
                data: { $0.corpusData }
            ),
            BoundaryCase(
                path: ReconstructionPackageLayout.evidenceManifestPath,
                state: try evidenceDominantState(from: fixture.state),
                data: { $0.evidenceData }
            ),
            BoundaryCase(
                path: ReconstructionPackageLayout.checkpointManifestPath,
                state: try checkpointDominantState(from: fixture.state),
                data: { $0.checkpointData }
            ),
        ]

        for boundary in cases {
            let baseline = try ReconstructionPackageCodec.encode(boundary.state)
            let exactByteCount = boundary.data(baseline).count
            let otherByteCounts = [
                baseline.corpusData.count,
                baseline.evidenceData.count,
                baseline.checkpointData.count,
            ].filter { $0 != exactByteCount }
            XCTAssertTrue(
                otherByteCounts.allSatisfy { $0 < exactByteCount },
                "Fixture must make \(boundary.path) the unique size boundary"
            )

            let exact = try ReconstructionPackageCodec.encode(
                boundary.state,
                manifestByteLimit: exactByteCount
            )
            XCTAssertEqual(boundary.data(exact).count, exactByteCount)
            XCTAssertEqual(
                try ReconstructionPackageCodec.decode(
                    descriptor: exact.descriptor,
                    corpusData: exact.corpusData,
                    evidenceData: exact.evidenceData,
                    checkpointData: exact.checkpointData
                ),
                boundary.state
            )

            XCTAssertThrowsError(
                try ReconstructionPackageCodec.encode(
                    boundary.state,
                    manifestByteLimit: exactByteCount - 1
                ),
                boundary.path
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionPackageValidationError,
                    .noncanonicalManifest(boundary.path)
                )
            }
        }
    }

    func testManifestPreflightByteCountMatchesCanonicalJSONForRepresentativeValues() throws {
        struct Fixture: Encodable {
            let unicodeAndEscapes: String
            let data: Data
            let present: String?
            let absent: String?
            let identifier: UUID
            let date: Date
            let nestedArrays: [[[Int]]]
            let nestedDictionaries: [String: [String: [String]]]
        }

        let fixture = Fixture(
            unicodeAndEscapes: "U+2028:\u{2028} U+2029:\u{2029} quote:\" backslash:\\ "
                + "controls:\u{0000}\u{0001}\u{0008}\t\n\u{000C}\r multibyte:é漢😀 slash:/",
            data: Data([0x00, 0x01, 0x7f, 0x80, 0xfe, 0xff]),
            present: "present/value",
            absent: nil,
            identifier: UUID(uuidString: "53000000-0000-0000-0000-000000000777")!,
            date: Date(timeIntervalSinceReferenceDate: 12_345.625),
            nestedArrays: [[[1, -2], []], [[Int.max]]],
            nestedDictionaries: [
                "z/key": ["quoted\"key": ["\\", "\u{2028}\u{2029}"]],
                "a": [:],
            ]
        )
        try assertManifestPreflightByteCountMatchesCanonicalJSON(fixture, label: "fixture")

        for byteCount in 0...7 {
            try assertManifestPreflightByteCountMatchesCanonicalJSON(
                Data((0..<byteCount).map(UInt8.init)),
                label: "base64 payload with \(byteCount) bytes"
            )
        }
    }

    func testOversizedDetachedManifestIsRejectedBeforeUnboundedRead() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let url = fixture.packageURL.appendingPathComponent(
            ReconstructionPackageLayout.corpusManifestPath
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ReconstructionPackageLayout.maximumManifestBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
    }

    func testDurableImageEvidenceLeavesCurrentWorkspaceFreshnessProjectionToCaller() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        try fixture.write()
        let evidenceURL = fixture.packageURL.appendingPathComponent(
            ReconstructionPackageLayout.evidenceManifestPath
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String: Any]
        )
        var evidence = try XCTUnwrap(object["evidence"] as? [[String: Any]])
        let coordinate = try ReconstructionImageCoordinate(
            artifact: ReconstructionArtifactCoordinate(
                occurrenceID: try XCTUnwrap(fixture.state.corpusManifests.first?.artifacts.first?.occurrenceID),
                contentIdentity: fixture.contentIdentity
            ),
            image: ReconstructionImageBinding(
                binaryID: UUID(),
                imageSlot: .primary,
                selectedSliceIndex: nil,
                architecture: .arm64,
                machOIdentity: nil
            ),
            analysisFingerprintSHA256: String(repeating: "f", count: 64)
        )
        evidence[0]["subject"] = try JSONSerialization.jsonObject(
            with: ReconstructionCanonicalJSON.encode(
                ReconstructionSubjectCoordinate.image(coordinate)
            )
        )
        object["evidence"] = evidence
        let hostile = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try hostile.write(to: evidenceURL)
        try updateDescriptor(in: fixture, path: ReconstructionPackageLayout.evidenceManifestPath, data: hostile)

        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.reconstructionState.evidence.first?.subject, .image(coordinate))
        XCTAssertEqual(
            opened.reconstructionState.evidence.first?.classification,
            .acceptedCurrent,
            "Package reopen preserves immutable acceptance; it does not project current freshness."
        )
    }

    func testCreatingJobProjectAndCreationManifestOwnTaskAndEvidenceSubjects() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let foreign = try foreignCorpus()
        let base = fixture.state
        let originalTask = try XCTUnwrap(base.tasks.first)
        let foreignTask = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: originalTask.identity.taskID,
                jobID: originalTask.identity.jobID,
                kind: originalTask.identity.kind,
                subject: foreign.subject,
                dependencyTaskIDs: originalTask.identity.dependencyTaskIDs,
                operationContractIdentity: originalTask.identity.operationContractIdentity
            ),
            state: originalTask.state,
            diagnostic: originalTask.diagnostic
        )
        let taskState = try replacing(
            base,
            projects: base.projects + [foreign.project],
            corpusManifests: base.corpusManifests + [foreign.manifest],
            tasks: [foreignTask]
        )
        try assertGraphRejects(taskState, reason: "task subject corpus ownership")

        let originalEvidence = try XCTUnwrap(base.evidence.first)
        let foreignEvidence = try evidence(
            copying: originalEvidence,
            subject: foreign.subject,
            citations: [try ReconstructionEvidenceCitation(
                citationID: try XCTUnwrap(originalEvidence.citations.first?.citationID),
                sourceEvidenceID: nil,
                subject: foreign.subject,
                locator: nil
            )]
        )
        let evidenceState = try replacing(
            base,
            projects: base.projects + [foreign.project],
            corpusManifests: base.corpusManifests + [foreign.manifest],
            evidence: [foreignEvidence]
        )
        try assertGraphRejects(evidenceState, reason: "evidence subject corpus ownership")
    }

    func testCitationMayUseRetainedCreationProjectCorpusButNeverAnotherProject() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let base = fixture.state
        let originalEvidence = try XCTUnwrap(base.evidence.first)
        let project = try XCTUnwrap(base.projects.first)
        let retainedOccurrence = try foreignOccurrence(namespace: 701)
        let retainedManifest = try canonicalManifest(
            projectID: project.projectID,
            artifacts: [retainedOccurrence]
        )
        let retainedSubject = ReconstructionSubjectCoordinate.artifact(
            ReconstructionArtifactCoordinate(
                occurrenceID: retainedOccurrence.occurrenceID,
                contentIdentity: retainedOccurrence.contentIdentity
            )
        )
        let sameProjectCitation = try ReconstructionEvidenceCitation(
            citationID: try XCTUnwrap(originalEvidence.citations.first?.citationID),
            sourceEvidenceID: nil,
            subject: retainedSubject,
            locator: "retained-corpus"
        )
        let sameProjectState = try replacing(
            base,
            corpusManifests: base.corpusManifests + [retainedManifest],
            evidence: [try evidence(
                copying: originalEvidence,
                citations: [sameProjectCitation]
            )]
        )
        XCTAssertNoThrow(try ReconstructionPackageCodec.encode(sameProjectState))

        let foreign = try foreignCorpus()
        let foreignCitation = try ReconstructionEvidenceCitation(
            citationID: sameProjectCitation.citationID,
            sourceEvidenceID: nil,
            subject: foreign.subject,
            locator: "foreign-project"
        )
        let foreignState = try replacing(
            base,
            projects: base.projects + [foreign.project],
            corpusManifests: base.corpusManifests + [foreign.manifest],
            evidence: [try evidence(
                copying: originalEvidence,
                citations: [foreignCitation]
            )]
        )
        try assertGraphRejects(foreignState, reason: "evidence citation project ownership")
    }

    func testCrossProjectResolvesGapEdgeFailsAfterBothEndpointsValidateIndependently() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let base = fixture.state
        let foreign = try foreignCorpus()
        let provisionalGap = try ReconstructionEvidenceGap(
            gapID: UUID(uuidString: "53000000-0000-0000-0000-000000000711")!,
            subject: foreign.subject,
            operationID: ReconstructionOperationID.evidenceQuery.rawValue,
            reason: .sanitizing("foreign project gap"),
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        let gap = try ReconstructionEvidenceGap(
            gapID: provisionalGap.gapID,
            subject: provisionalGap.subject,
            operationID: provisionalGap.operationID,
            reason: provisionalGap.reason,
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalGapSHA256(provisionalGap)
        )
        let originalCheckpoint = try XCTUnwrap(base.checkpoints.first)
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: originalCheckpoint.checkpointID,
            schemaVersion: originalCheckpoint.schemaVersion,
            jobID: originalCheckpoint.jobID,
            revision: originalCheckpoint.revision,
            parentCheckpointID: originalCheckpoint.parentCheckpointID,
            parentCheckpointSHA256: originalCheckpoint.parentCheckpointSHA256,
            corpusManifestSHA256: originalCheckpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: originalCheckpoint.evidenceFrontierSHA256,
            pendingTaskIDs: originalCheckpoint.pendingTaskIDs,
            runningTaskIDs: originalCheckpoint.runningTaskIDs,
            completedTaskIDs: originalCheckpoint.completedTaskIDs,
            failedTaskIDs: originalCheckpoint.failedTaskIDs,
            blockedTaskIDs: originalCheckpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier
                .canonicalSHA256(for: [gap]),
            modelReceiptIDs: originalCheckpoint.modelReceiptIDs,
            toolReceiptIDs: originalCheckpoint.toolReceiptIDs,
            coordinatorState: originalCheckpoint.coordinatorState,
            terminalReason: originalCheckpoint.terminalReason
        )
        let endpointState = try replacing(
            base,
            projects: base.projects + [foreign.project],
            corpusManifests: base.corpusManifests + [foreign.manifest],
            evidenceGaps: [gap],
            checkpoints: [checkpoint]
        )
        XCTAssertNoThrow(try ReconstructionPackageCodec.encode(endpointState))

        let relation = ReconstructionEvidenceRelation(
            relationID: UUID(uuidString: "53000000-0000-0000-0000-000000000712")!,
            kind: .resolvesGap,
            sourceEvidenceID: try XCTUnwrap(base.evidence.first?.evidenceID),
            targetEvidenceID: gap.gapID
        )
        let crossProjectState = try replacing(
            endpointState,
            evidenceRelations: [relation]
        )
        try assertGraphRejects(
            crossProjectState,
            reason: "evidence relation project ownership"
        )
    }

    func testDurableAdmissionRejectsOversizedCitationLocatorBeforeIndexAllocation() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let original = try XCTUnwrap(fixture.state.evidence.first)
        let locator = String(
            repeating: "x",
            count: ReconstructionEvidenceIntegrity.DurableLimits.maximumStringUTF8Bytes + 1
        )
        let citation = try ReconstructionEvidenceCitation(
            citationID: try XCTUnwrap(original.citations.first?.citationID),
            sourceEvidenceID: nil,
            subject: original.subject,
            locator: locator
        )

        XCTAssertThrowsError(
            try replacing(
                fixture.state,
                evidence: [try evidence(copying: original, citations: [citation])]
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionEvidenceIntegrity.DurableAdmissionFailure,
                .stringUTF8Limit(field: "evidence citation locator")
            )
        }
    }

    func testDurableAdmissionRejectsProducerIdentityFanoutBeforeMetadataWalk() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let original = try XCTUnwrap(fixture.state.evidence.first)
        let capabilities = (0...ReconstructionEvidenceIntegrity.DurableLimits
            .maximumProducerIdentityValueCount).map { "capability-\($0)" }
        let producer = try producer(
            copying: original.producer,
            nativeCapabilityIdentities: capabilities
        )
        let oversized = try evidence(copying: original, producer: producer)

        XCTAssertThrowsError(
            try ReconstructionEvidenceIntegrity.validateDurableBounds(
                projects: [],
                corpusManifests: [],
                evidence: [oversized],
                relations: [],
                gaps: [],
                jobs: [],
                tasks: [],
                checkpoints: [],
                toolReceipts: [],
                modelReceipts: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionEvidenceIntegrity.DurableAdmissionFailure,
                .collectionCount(field: "producer identity values")
            )
        }
    }

    func testDetachedManifestRejectsOversizedCollectionBeforeCanonicalSorting() throws {
        let relation = ReconstructionEvidenceRelation(
            relationID: UUID(uuidString: "53000000-0000-0000-0000-000000000718")!,
            kind: .supports,
            sourceEvidenceID: UUID(uuidString: "53000000-0000-0000-0000-000000000719")!,
            targetEvidenceID: UUID(uuidString: "53000000-0000-0000-0000-000000000720")!
        )
        let relations = Array(
            repeating: relation,
            count: ReconstructionEvidenceIntegrity.DurableLimits
                .maximumAggregateRecordCount + 1
        )

        XCTAssertThrowsError(
            try ReconstructionPackageEvidenceManifest(
                evidence: [],
                evidenceRelations: relations,
                evidenceGaps: [],
                toolReceipts: [],
                modelReceipts: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionEvidenceIntegrity.DurableAdmissionFailure,
                .collectionCount(field: "evidence relations")
            )
        }
    }

    func testDurableAdmissionLimitsArePermanentAndRejectAggregateOverflowFirst() throws {
        XCTAssertEqual(
            ReconstructionEvidenceIntegrity.DurableLimits.maximumAggregateRecordCount,
            100_000
        )
        XCTAssertEqual(
            ReconstructionEvidenceIntegrity.DurableLimits.maximumCitationsPerEvidence,
            100_000
        )
        XCTAssertEqual(
            ReconstructionEvidenceIntegrity.DurableLimits.maximumFacetDependenciesPerEvidence,
            100_000
        )
        XCTAssertEqual(
            ReconstructionEvidenceIntegrity.DurableLimits.maximumSelectedHandleIDsPerReceipt,
            100_000
        )
        XCTAssertEqual(
            ReconstructionEvidenceIntegrity.DurableLimits.maximumProducerIdentityValueCount,
            64
        )
        XCTAssertEqual(
            ReconstructionEvidenceIntegrity.DurableLimits.maximumMetadataUTF8BytesPerRecord,
            ReconstructionPackageLayout.maximumManifestBytes
        )
        let project = try ReconstructionProjectRecord(
            projectID: UUID(uuidString: "53000000-0000-0000-0000-000000000719")!,
            name: "pre-allocation aggregate bound",
            currentCorpusManifestSHA256: nil
        )
        let projects = Array(
            repeating: project,
            count: ReconstructionEvidenceIntegrity.DurableLimits.maximumAggregateRecordCount + 1
        )

        XCTAssertThrowsError(
            try ReconstructionEvidenceIntegrity.validateDurableBounds(
                projects: projects,
                corpusManifests: [],
                evidence: [],
                relations: [],
                gaps: [],
                jobs: [],
                tasks: [],
                checkpoints: [],
                toolReceipts: [],
                modelReceipts: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionEvidenceIntegrity.DurableAdmissionFailure,
                .collectionCount(field: "projects")
            )
        }
    }

    func testCheckpointAndTaskGroupingReportsLinearValidationWork() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let project = try XCTUnwrap(fixture.state.projects.first)
        let manifest = try XCTUnwrap(fixture.state.corpusManifests.first)
        let subject = ReconstructionSubjectCoordinate.artifact(
            ReconstructionArtifactCoordinate(
                occurrenceID: try XCTUnwrap(manifest.artifacts.first?.occurrenceID),
                contentIdentity: try XCTUnwrap(manifest.artifacts.first?.contentIdentity)
            )
        )
        var jobs: [ReconstructionJobRecord] = []
        var tasks: [ReconstructionTaskRecord] = []
        var checkpoints: [ReconstructionCheckpoint] = []
        let jobCount = 64
        for index in 0..<jobCount {
            let jobID = deterministicUUID(namespace: 720, value: index * 3)
            let taskID = deterministicUUID(namespace: 720, value: index * 3 + 1)
            let checkpointID = deterministicUUID(namespace: 720, value: index * 3 + 2)
            let objective = "linear validation job \(index)"
            tasks.append(ReconstructionTaskRecord(
                identity: try ReconstructionTaskIdentity.make(
                    taskID: taskID,
                    jobID: jobID,
                    kind: .retrieveEvidence,
                    subject: subject,
                    dependencyTaskIDs: [],
                    operationContractIdentity: ReconstructionOperationID.evidenceQuery.rawValue
                ),
                state: .completed,
                diagnostic: nil
            ))
            checkpoints.append(try ReconstructionCheckpoint.make(
                checkpointID: checkpointID,
                jobID: jobID,
                revision: 0,
                parentCheckpointID: nil,
                parentCheckpointSHA256: nil,
                corpusManifestSHA256: manifest.canonicalSHA256,
                evidenceFrontierSHA256: ReconstructionPackageFixture.digest(
                    Data("frontier-\(index)".utf8)
                ),
                pendingTaskIDs: [],
                runningTaskIDs: [],
                completedTaskIDs: [taskID],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier
                    .canonicalSHA256(for: []),
                modelReceiptIDs: [],
                toolReceiptIDs: [],
                coordinatorState: .completed,
                terminalReason: nil
            ))
            jobs.append(try ReconstructionJobRecord(
                jobID: jobID,
                reconstructionProjectID: project.projectID,
                objective: objective,
                objectiveSHA256: ReconstructionPackageFixture.digest(Data(objective.utf8)),
                creationCorpusManifestSHA256: manifest.canonicalSHA256,
                state: .completed,
                currentCheckpointID: checkpointID,
                terminalReason: nil,
                budget: try ReconstructionJobBudget(
                    maxRounds: 1,
                    maxTasks: 1,
                    maxEvidenceRecords: 1,
                    maxEncodedBytes: 1_024
                ),
                creationOrdinal: UInt64(index + 1)
            ))
        }
        let state = try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: [manifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: jobs,
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: [],
            modelReceipts: []
        )

        let work = try ReconstructionPackageCodec.validateGraph(state)
        XCTAssertEqual(work.jobVisits, jobCount)
        XCTAssertEqual(work.checkpointGroupingVisits, checkpoints.count)
        XCTAssertEqual(work.checkpointChainVisits, checkpoints.count)
        XCTAssertEqual(work.taskGroupingVisits, tasks.count)
        XCTAssertEqual(work.authoritativeTaskVisits, tasks.count)
    }

    func testEveryPersistedSubjectRevalidatesNestedImageFingerprints() throws {
        enum Location: String, CaseIterable {
            case historicalEvidence
            case citation
            case task
            case gap
        }

        for location in Location.allCases {
            let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
            defer { fixture.remove() }
            try fixture.write()
            let malformedSubject = try malformedImageSubject(in: fixture)
            let path: String

            switch location {
            case .historicalEvidence, .citation, .gap:
                path = ReconstructionPackageLayout.evidenceManifestPath
                let url = fixture.packageURL.appendingPathComponent(path)
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                )
                var evidence = try XCTUnwrap(object["evidence"] as? [[String: Any]])
                switch location {
                case .historicalEvidence:
                    evidence[0]["classification"] = "acceptedHistorical"
                    evidence[0]["subject"] = malformedSubject
                case .citation:
                    evidence[0]["citations"] = [[
                        "citationID": UUID().uuidString,
                        "subject": malformedSubject,
                        "locator": "persisted citation",
                    ]]
                case .gap:
                    object["evidenceGaps"] = [[
                        "gapID": UUID().uuidString,
                        "subject": malformedSubject,
                        "operationID": "reconstruction.test.gap.v1",
                        "reason": "unresolved",
                        "canonicalSHA256": String(repeating: "9", count: 64),
                    ]]
                case .task:
                    XCTFail("unreachable task mutation")
                }
                object["evidence"] = evidence
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try data.write(to: url)
                try updateDescriptor(in: fixture, path: path, data: data)

            case .task:
                path = ReconstructionPackageLayout.checkpointManifestPath
                let url = fixture.packageURL.appendingPathComponent(path)
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                )
                var tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
                var identity = try XCTUnwrap(tasks[0]["identity"] as? [String: Any])
                identity["subject"] = malformedSubject
                tasks[0]["identity"] = identity
                object["tasks"] = tasks
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try data.write(to: url)
                try updateDescriptor(in: fixture, path: path, data: data)
            }

            XCTAssertThrowsError(
                try MacScopeDocumentPackage.openPackage(from: fixture.packageURL),
                location.rawValue
            )
        }
    }

    func testRollbackRenameFailureRetainsAndReportsRecoverableOriginalPackage() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let originalBytes = try recursiveFileBytes(at: fixture.packageURL)
        var replacementManifest = fixture.manifest
        replacementManifest.workspaceName = "Replacement left published after rollback failure"

        struct InjectedSynchronizationFailure: Error {}
        struct InjectedRollbackRenameFailure: Error {}
        var reportedRecoveryURL: URL?
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                replacementManifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [fixture.source],
                to: fixture.packageURL,
                testHooks: .init(
                    beforeDestinationParentSynchronization: {
                        throw InjectedSynchronizationFailure()
                    },
                    beforePublicationRollbackRename: {
                        throw InjectedRollbackRenameFailure()
                    }
                )
            )
        ) { error in
            guard case MacScopeDocumentPackage.PackageError.packagePublicationRollbackFailed(
                let recoveryURL
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            reportedRecoveryURL = recoveryURL
        }

        let recoveryURL = try XCTUnwrap(reportedRecoveryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        XCTAssertEqual(try recursiveFileBytes(at: recoveryURL), originalBytes)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: recoveryURL).manifest.workspaceName,
            fixture.manifest.workspaceName
        )
    }

    func testRollbackParentSyncFailureRetainsAndReportsRestoredOriginalPackage() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let originalBytes = try recursiveFileBytes(at: fixture.packageURL)
        var replacementManifest = fixture.manifest
        replacementManifest.workspaceName = "Replacement that cannot become durable"

        struct InjectedPublicationSynchronizationFailure: Error {}
        struct InjectedRollbackSynchronizationFailure: Error {}
        var reportedRecoveryURL: URL?
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                replacementManifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [fixture.source],
                to: fixture.packageURL,
                testHooks: .init(
                    beforeDestinationParentSynchronization: {
                        throw InjectedPublicationSynchronizationFailure()
                    },
                    beforePublicationRollbackParentSynchronization: {
                        throw InjectedRollbackSynchronizationFailure()
                    }
                )
            )
        ) { error in
            guard case MacScopeDocumentPackage.PackageError.packagePublicationRollbackFailed(
                let recoveryURL
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            reportedRecoveryURL = recoveryURL
        }

        let recoveryURL = try XCTUnwrap(reportedRecoveryURL)
        XCTAssertEqual(recoveryURL.standardizedFileURL, fixture.packageURL.standardizedFileURL)
        XCTAssertEqual(try recursiveFileBytes(at: recoveryURL), originalBytes)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: recoveryURL).manifest.workspaceName,
            fixture.manifest.workspaceName
        )
    }

    func testSuccessfulPublicationRollbackRemovesOwnedReplacementStage() throws {
        struct InjectedPublicationSynchronizationFailure: Error {}

        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let originalBytes = try recursiveFileBytes(at: fixture.packageURL)
        var replacementManifest = fixture.manifest
        replacementManifest.workspaceName = "Replacement rolled back before durability"

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                replacementManifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [fixture.source],
                to: fixture.packageURL,
                testHooks: .init(beforeDestinationParentSynchronization: {
                    throw InjectedPublicationSynchronizationFailure()
                })
            )
        ) { error in
            XCTAssertTrue(
                error is InjectedPublicationSynchronizationFailure,
                "Unexpected error: \(error)"
            )
        }

        XCTAssertEqual(try recursiveFileBytes(at: fixture.packageURL), originalBytes)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
                .manifest.workspaceName,
            fixture.manifest.workspaceName
        )
        let parent = fixture.packageURL.deletingLastPathComponent()
        let stagePrefix = ".\(fixture.packageURL.lastPathComponent)."
        let remainingStages = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(stagePrefix) && $0.hasSuffix(".tmp") }
        XCTAssertEqual(remainingStages, [])
    }

    func testRetiredPackageCleanupRefusesForeignReplacementAndLeavesBothRootsUntouched() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        var replacementManifest = fixture.manifest
        replacementManifest.workspaceName = "Published replacement"
        let parent = fixture.packageURL.deletingLastPathComponent()
        var foreignRecoveryURL: URL?

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                replacementManifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [fixture.source],
                to: fixture.packageURL,
                testHooks: .init(beforeRetiredPackageCleanup: {
                    let stagePrefix = ".\(fixture.packageURL.lastPathComponent)."
                    let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
                    let name = try XCTUnwrap(
                        names.first { $0.hasPrefix(stagePrefix) && $0.hasSuffix(".tmp") }
                    )
                    let stageURL = parent.appendingPathComponent(name, isDirectory: true)
                    try FileManager.default.removeItem(at: stageURL)
                    try FileManager.default.createDirectory(
                        at: stageURL,
                        withIntermediateDirectories: false
                    )
                    try Data("foreign".utf8).write(
                        to: stageURL.appendingPathComponent("foreign.txt")
                    )
                    foreignRecoveryURL = stageURL
                })
            )
        ) { error in
            guard case MacScopeDocumentPackage.PackageError
                .packagePublicationCleanupOwnershipUnproven(let recoveryURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(recoveryURL, foreignRecoveryURL)
        }

        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
                .manifest.workspaceName,
            "Published replacement"
        )
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(foreignRecoveryURL)
                .appendingPathComponent("foreign.txt")),
            Data("foreign".utf8)
        )
    }

    func testRetiredPackageCleanupHookFailureRetainsPriorPackageForRecovery() throws {
        struct InjectedCleanupFailure: Error {}

        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        var replacementManifest = fixture.manifest
        replacementManifest.workspaceName = "Published replacement"
        var recoveryURL: URL?

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                replacementManifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [fixture.source],
                to: fixture.packageURL,
                testHooks: .init(beforeRetiredPackageCleanup: {
                    throw InjectedCleanupFailure()
                })
            )
        ) { error in
            guard case MacScopeDocumentPackage.PackageError
                .packagePublicationCleanupOwnershipUnproven(let recovered) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            recoveryURL = recovered
        }

        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
                .manifest.workspaceName,
            "Published replacement"
        )
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: try XCTUnwrap(recoveryURL))
                .manifest.workspaceName,
            fixture.manifest.workspaceName
        )
    }

    private func assertGraphRejects(
        _ state: ReconstructionWorkspaceState,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try ReconstructionPackageCodec.encode(state),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .stateGraphInvalid(reason),
                file: file,
                line: line
            )
        }
    }

    private func foreignCorpus() throws -> (
        project: ReconstructionProjectRecord,
        manifest: ReconstructionCorpusManifest,
        subject: ReconstructionSubjectCoordinate
    ) {
        let projectID = UUID(uuidString: "53000000-0000-0000-0000-000000000700")!
        let occurrence = try foreignOccurrence(namespace: 700)
        let manifest = try canonicalManifest(projectID: projectID, artifacts: [occurrence])
        return (
            try ReconstructionProjectRecord(
                projectID: projectID,
                name: "Foreign reconstruction project",
                currentCorpusManifestSHA256: manifest.canonicalSHA256
            ),
            manifest,
            .artifact(ReconstructionArtifactCoordinate(
                occurrenceID: occurrence.occurrenceID,
                contentIdentity: occurrence.contentIdentity
            ))
        )
    }

    private func foreignOccurrence(namespace: Int) throws
        -> ReconstructionArtifactOccurrenceRecord {
        let bytes = Data("foreign occurrence \(namespace)".utf8)
        return try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(
                rawValue: deterministicUUID(namespace: namespace, value: 1)
            ),
            contentIdentity: try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: ReconstructionPackageFixture.digest(bytes),
                byteCount: UInt64(bytes.count)
            ),
            kind: .opaque,
            roles: [.referenceSource],
            executableMode: false,
            originalName: "foreign-\(namespace).bin",
            diagnostic: nil
        )
    }

    private func canonicalManifest(
        projectID: UUID,
        artifacts: [ReconstructionArtifactOccurrenceRecord],
        relations: [ReconstructionArtifactRelationRecord] = []
    ) throws -> ReconstructionCorpusManifest {
        let provisional = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: artifacts,
            relations: relations,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        return try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: artifacts,
            relations: relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: provisional)
        )
    }

    private func evidence(
        copying record: ReconstructionEvidenceRecord,
        subject: ReconstructionSubjectCoordinate? = nil,
        citations: [ReconstructionEvidenceCitation]? = nil,
        producer: ReconstructionProducerIdentity? = nil
    ) throws -> ReconstructionEvidenceRecord {
        try ReconstructionEvidenceRecord(
            evidenceID: record.evidenceID,
            schemaVersion: record.schemaVersion,
            subject: subject ?? record.subject,
            operationID: record.operationID,
            payloadKind: record.payloadKind,
            payload: record.payload,
            payloadByteCount: record.payloadByteCount,
            payloadSHA256: record.payloadSHA256,
            facetDependencies: record.facetDependencies,
            producer: producer ?? record.producer,
            citations: citations ?? record.citations,
            creatingJobID: record.creatingJobID,
            creatingTaskID: record.creatingTaskID,
            creatingCheckpointID: record.creatingCheckpointID,
            modelReceiptID: record.modelReceiptID,
            toolReceiptID: record.toolReceiptID,
            classification: record.classification,
            supersedesEvidenceID: record.supersedesEvidenceID,
            supersededByEvidenceID: record.supersededByEvidenceID,
            diagnostic: record.diagnostic
        )
    }

    private func producer(
        copying producer: ReconstructionProducerIdentity,
        nativeCapabilityIdentities: [String]
    ) throws -> ReconstructionProducerIdentity {
        try ReconstructionProducerIdentity(
            schemaVersion: producer.schemaVersion,
            macScopeBuildIdentity: producer.macScopeBuildIdentity,
            macScopeSourceIdentity: producer.macScopeSourceIdentity,
            operationIdentity: producer.operationIdentity,
            registryIdentity: producer.registryIdentity,
            protocolIdentity: producer.protocolIdentity,
            nativeProviderIdentity: producer.nativeProviderIdentity,
            nativeCapabilityIdentities: nativeCapabilityIdentities,
            modelKey: producer.modelKey,
            endpointOrigin: producer.endpointOrigin,
            observedModelInventorySHA256: producer.observedModelInventorySHA256,
            observedConfigurationSHA256: producer.observedConfigurationSHA256,
            toolchainIdentity: producer.toolchainIdentity,
            canonicalSHA256: producer.canonicalSHA256
        )
    }

    private func deterministicUUID(namespace: Int, value: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "53%06d-0000-0000-0000-%012d",
                namespace,
                value
            )
        )!
    }

    private func checkpoint(
        copying checkpoint: ReconstructionCheckpoint,
        checkpointID: UUID? = nil,
        revision: UInt64? = nil,
        parentCheckpointID: UUID? = nil,
        parentCheckpointSHA256: String? = nil,
        toolReceiptIDs: [UUID],
        modelReceiptIDs: [UUID]
    ) throws -> ReconstructionCheckpoint {
        try ReconstructionCheckpoint.make(
            checkpointID: checkpointID ?? checkpoint.checkpointID,
            schemaVersion: checkpoint.schemaVersion,
            jobID: checkpoint.jobID,
            revision: revision ?? checkpoint.revision,
            parentCheckpointID: parentCheckpointID ?? checkpoint.parentCheckpointID,
            parentCheckpointSHA256: parentCheckpointSHA256 ?? checkpoint.parentCheckpointSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: checkpoint.pendingTaskIDs,
            runningTaskIDs: checkpoint.runningTaskIDs,
            completedTaskIDs: checkpoint.completedTaskIDs,
            failedTaskIDs: checkpoint.failedTaskIDs,
            blockedTaskIDs: checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: modelReceiptIDs,
            toolReceiptIDs: toolReceiptIDs,
            coordinatorState: checkpoint.coordinatorState,
            terminalReason: checkpoint.terminalReason
        )
    }

    private func assertManifestPreflightByteCountMatchesCanonicalJSON<Value: Encodable>(
        _ value: Value,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let canonicalByteCount = try ReconstructionCanonicalJSON.encode(value).count
        let preflightByteCount = try ReconstructionPackageCodec
            .preflightCanonicalEncodedByteCount(value)
        XCTAssertEqual(
            preflightByteCount,
            canonicalByteCount,
            label,
            file: file,
            line: line
        )
    }

    private func corpusDominantState(
        from state: ReconstructionWorkspaceState
    ) throws -> ReconstructionWorkspaceState {
        let project = try XCTUnwrap(state.projects.first)
        let expandedProject = try ReconstructionProjectRecord(
            projectID: project.projectID,
            schemaVersion: project.schemaVersion,
            name: String(repeating: "corpus-manifest-authority/", count: 512),
            currentCorpusManifestSHA256: project.currentCorpusManifestSHA256
        )
        return try replacing(state, projects: [expandedProject])
    }

    private func evidenceDominantState(
        from state: ReconstructionWorkspaceState
    ) throws -> ReconstructionWorkspaceState {
        let manifest = try XCTUnwrap(state.corpusManifests.first)
        let occurrence = try XCTUnwrap(manifest.artifacts.first)
        let subject = ReconstructionSubjectCoordinate.artifact(
            ReconstructionArtifactCoordinate(
                occurrenceID: occurrence.occurrenceID,
                contentIdentity: occurrence.contentIdentity
            )
        )
        let reason = ReconstructionDiagnostic.sanitizing(
            String(repeating: "evidence-gap-authority/", count: 32)
        )
        let gaps = try (0..<16).map { index -> ReconstructionEvidenceGap in
            let gapID = UUID(
                uuidString: String(
                    format: "53000000-0000-0000-0000-%012d",
                    index + 1
                )
            )!
            let provisional = try ReconstructionEvidenceGap(
                gapID: gapID,
                subject: subject,
                operationID: ReconstructionOperationID.functionReview.rawValue,
                reason: reason,
                canonicalSHA256: ReconstructionPackageFixture.digest(
                    Data("gap-\(index)-provisional".utf8)
                )
            )
            return try ReconstructionEvidenceGap(
                gapID: provisional.gapID,
                subject: provisional.subject,
                operationID: provisional.operationID,
                reason: provisional.reason,
                canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalGapSHA256(provisional)
            )
        }
        return try replacing(state, evidenceGaps: gaps)
    }

    private func checkpointDominantState(
        from state: ReconstructionWorkspaceState
    ) throws -> ReconstructionWorkspaceState {
        let project = try XCTUnwrap(state.projects.first)
        let manifest = try XCTUnwrap(state.corpusManifests.first)
        let objective = String(repeating: "checkpoint-objective-authority/", count: 512)
        let job = try ReconstructionJobRecord(
            jobID: UUID(uuidString: "53000000-0000-0000-0000-000000000100")!,
            reconstructionProjectID: project.projectID,
            objective: objective,
            objectiveSHA256: ReconstructionPackageFixture.digest(Data(objective.utf8)),
            creationCorpusManifestSHA256: manifest.canonicalSHA256,
            state: .created,
            currentCheckpointID: nil,
            terminalReason: nil,
            budget: try ReconstructionJobBudget(
                maxRounds: 1,
                maxTasks: 1,
                maxEvidenceRecords: 1,
                maxEncodedBytes: 1_024
            )
        )
        return try replacing(state, jobs: [job])
    }

    private func replacing(
        _ state: ReconstructionWorkspaceState,
        projects: [ReconstructionProjectRecord]? = nil,
        corpusManifests: [ReconstructionCorpusManifest]? = nil,
        evidence: [ReconstructionEvidenceRecord]? = nil,
        evidenceRelations: [ReconstructionEvidenceRelation]? = nil,
        evidenceGaps: [ReconstructionEvidenceGap]? = nil,
        jobs: [ReconstructionJobRecord]? = nil,
        tasks: [ReconstructionTaskRecord]? = nil,
        checkpoints: [ReconstructionCheckpoint]? = nil,
        toolReceipts: [ReconstructionToolReceipt]? = nil,
        modelReceipts: [ReconstructionModelReceipt]? = nil
    ) throws -> ReconstructionWorkspaceState {
        try ReconstructionWorkspaceState(
            schemaVersion: state.schemaVersion,
            projects: projects ?? state.projects,
            corpusManifests: corpusManifests ?? state.corpusManifests,
            evidence: evidence ?? state.evidence,
            evidenceRelations: evidenceRelations ?? state.evidenceRelations,
            evidenceGaps: evidenceGaps ?? state.evidenceGaps,
            jobs: jobs ?? state.jobs,
            tasks: tasks ?? state.tasks,
            checkpoints: checkpoints ?? state.checkpoints,
            toolReceipts: toolReceipts ?? state.toolReceipts,
            modelReceipts: modelReceipts ?? state.modelReceipts
        )
    }

    private func assertRejectedDetachedMutation(
        path: String,
        includesEvidenceGraph: Bool = false,
        mutation: (Data) throws -> (data: Data, updatesDigest: Bool)
    ) throws {
        let fixture = try ReconstructionPackageFixture.make(
            includesEvidenceGraph: includesEvidenceGraph
        )
        defer { fixture.remove() }
        try fixture.write()
        let url = fixture.packageURL.appendingPathComponent(path)
        let mutated = try mutation(Data(contentsOf: url))
        try mutated.data.write(to: url)
        if mutated.updatesDigest {
            try updateDescriptor(in: fixture, path: path, data: mutated.data)
        }
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
    }

    private func malformedImageSubject(
        in fixture: ReconstructionPackageFixture
    ) throws -> [String: Any] {
        let coordinate = try ReconstructionImageCoordinate(
            artifact: ReconstructionArtifactCoordinate(
                occurrenceID: try XCTUnwrap(
                    fixture.state.corpusManifests.first?.artifacts.first?.occurrenceID
                ),
                contentIdentity: fixture.contentIdentity
            ),
            image: ReconstructionImageBinding(
                binaryID: fixture.binaryID,
                imageSlot: .primary,
                selectedSliceIndex: nil,
                architecture: .arm64,
                machOIdentity: nil
            ),
            analysisFingerprintSHA256: String(repeating: "f", count: 64)
        )
        var subject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(
                    ReconstructionSubjectCoordinate.image(coordinate)
                )
            ) as? [String: Any]
        )
        var imageCase = try XCTUnwrap(subject["image"] as? [String: Any])
        var value = try XCTUnwrap(imageCase["_0"] as? [String: Any])
        value["analysisFingerprintSHA256"] = "not-a-sha256"
        imageCase["_0"] = value
        subject["image"] = imageCase
        return subject
    }

    private func recursiveFileBytes(at root: URL) throws -> [String: Data] {
        let canonicalRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let canonicalFilePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalFilePath.hasPrefix(canonicalRootPath + "/") else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "test fixture escaped recovery root"
                )
            }
            result[String(canonicalFilePath.dropFirst(canonicalRootPath.count + 1))]
                = try Data(contentsOf: url)
        }
        return result
    }

    private static func mutateWorkspaceDescriptor(
        in fixture: ReconstructionPackageFixture,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var descriptor = try XCTUnwrap(object["reconstruction"] as? [String: Any])
        try mutation(&descriptor)
        object["reconstruction"] = descriptor
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL)
    }

    private func updateDescriptor(
        in fixture: ReconstructionPackageFixture,
        path: String,
        data: Data
    ) throws {
        var manifest = try MacScopeDocumentPackage.readManifest(from: fixture.packageURL)
        let descriptor = try XCTUnwrap(manifest.reconstruction)
        manifest.reconstruction = try ReconstructionPackageDescriptor(
            corpusManifestPath: descriptor.corpusManifestPath,
            evidenceManifestPath: descriptor.evidenceManifestPath,
            checkpointManifestPath: descriptor.checkpointManifestPath,
            corpusManifestSHA256: path == descriptor.corpusManifestPath
                ? ReconstructionPackageFixture.digest(data) : descriptor.corpusManifestSHA256,
            evidenceManifestSHA256: path == descriptor.evidenceManifestPath
                ? ReconstructionPackageFixture.digest(data) : descriptor.evidenceManifestSHA256,
            checkpointManifestSHA256: path == descriptor.checkpointManifestPath
                ? ReconstructionPackageFixture.digest(data) : descriptor.checkpointManifestSHA256
        )
        try MacScopeDocumentPackage.encodedManifest(manifest)
            .write(to: MacScopeDocumentPackage.manifestURL(in: fixture.packageURL))
    }
}
