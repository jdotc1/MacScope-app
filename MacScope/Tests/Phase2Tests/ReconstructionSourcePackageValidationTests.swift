import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourcePackageValidationTests: XCTestCase {
    func testProfileDispatchRetainsLegacySourceGraphAndRejectsPresentForeignJobProfile() throws {
        let graph = try fixture(bound: true)
        XCTAssertTrue(graph.jobs.values.allSatisfy { $0.sourceProfileID == nil })
        XCTAssertNoThrow(try graph.validate())
        let bytes = try ReconstructionCanonicalJSON.encode(graph)
        let decoded = try JSONDecoder().decode(Graph.self, from: bytes)
        XCTAssertNoThrow(try decoded.validate())
        for (id, job) in graph.jobs {
            XCTAssertEqual(try ReconstructionCanonicalJSON.encode(XCTUnwrap(decoded.jobs[id])),
                try ReconstructionCanonicalJSON.encode(job))
        }
        for (id, record) in graph.evidence { XCTAssertEqual(decoded.evidence[id]?.payload, record.payload) }
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            let job = try XCTUnwrap(graph.jobs.values.first)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(job)) as? [String: Any])
            object["sourceProfileID"] = profile
            XCTAssertThrowsError(try JSONDecoder().decode(ReconstructionJobRecord.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "ac100000-0000-0000-0000-%012d", n))! }
    private func hash(_ text: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(text.utf8)) }
    private struct Graph: Codable {
        var jobs: [UUID: ReconstructionJobRecord]
        var tasks: [UUID: ReconstructionTaskRecord]
        var checkpoints: [UUID: [UInt64: ReconstructionCheckpoint]]
        var evidence: [UUID: ReconstructionEvidenceRecord]
        var receipts: [UUID: ReconstructionModelReceipt]
        var toolReceipts: [UUID: ReconstructionToolReceipt] = [:]
        func validate() throws {
            try ReconstructionPackageCodec.validateModelTaskReceiptBindings(tasks: tasks,
                checkpointsByJobID: checkpoints, toolReceipts: toolReceipts, modelReceipts: Array(receipts.values))
            try ReconstructionPackageCodec.validateSourceRevisionGraph(jobs: jobs, tasks: tasks,
                checkpointsByJobID: checkpoints, evidence: evidence, modelReceipts: receipts, toolReceipts: toolReceipts)
            try ReconstructionPackageCodec.validateSourceEvaluationGraph(tasks: tasks, jobs: jobs,
                checkpointsByJobID: checkpoints, evidence: evidence, toolReceipts: toolReceipts)
        }
    }
    private func producer(_ operation: String, model: Bool = true) throws -> ReconstructionProducerIdentity {
        let value = try ReconstructionProducerIdentity(macScopeBuildIdentity: hash("build"), macScopeSourceIdentity: hash("source"),
            operationIdentity: operation, registryIdentity: hash("registry"),
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest,
            modelKey: model ? "fixture" : nil, endpointOrigin: model ? "http://127.0.0.1:8000" : nil, canonicalSHA256: hash("placeholder"))
        return try .init(macScopeBuildIdentity: value.macScopeBuildIdentity, macScopeSourceIdentity: value.macScopeSourceIdentity,
            operationIdentity: value.operationIdentity, registryIdentity: value.registryIdentity, protocolIdentity: value.protocolIdentity,
            modelKey: value.modelKey, endpointOrigin: value.endpointOrigin,
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(value))
    }
    private func fixture(revisions: Int = 1, bound: Bool = false, wrongCorpus: Bool = false, tamperedOffer: Bool = false, wrongOracle: Bool = false,
                         aggregateParent: Bool = false, excludedDiagnostics: [ReconstructionEvidenceClassification] = [],
                         contextMutation: ((inout [String: Any]) -> Void)? = nil) throws -> Graph {
        let jobID = id(1), projectID = id(2)
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: id(3)),
            contentIdentity: try .init(algorithm: .sha256, digest: hash("binary"), byteCount: 32))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: id(4), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: hash("analysis"), startAddress: 4096, endAddressExclusive: 4112,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let job = try ReconstructionJobRecord(jobID: jobID, reconstructionProjectID: projectID,
            objective: "increment", objectiveSHA256: hash("increment"), creationCorpusManifestSHA256: hash("corpus"),
            state: .checkpointing, currentCheckpointID: id(30 + revisions + (aggregateParent ? 1 : 0)), terminalReason: nil,
            budget: .init(maxRounds: 10, maxTasks: 20, maxEvidenceRecords: 20, maxEncodedBytes: 1_000_000))
        func makeCut(_ records: [ReconstructionEvidenceRecord]) throws -> ReconstructionEvidenceCut {
            let classifications = Dictionary(uniqueKeysWithValues: records.map { ($0.evidenceID, $0.classification) })
            let checkpointRevisions = Dictionary(uniqueKeysWithValues: Set(records.map(\.creatingCheckpointID)).map { checkpointID in
                (checkpointID, checkpointID == id(85) ? 2 : UInt64((0...(revisions + 1)).first { id(30 + $0) == checkpointID } ?? 0))
            })
            let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(corpusManifestSHA256: hash("corpus"),
                records: records, projectedClassificationsByEvidenceID: classifications, relations: [], gaps: [],
                checkpointRevisionsByID: checkpointRevisions)
            return try .init(corpusManifestSHA256: hash("corpus"), records: records, relations: [], gaps: [],
                frontierSHA256: frontier, projectedClassificationsByEvidenceID: classifications,
                checkpointRevisionsByID: checkpointRevisions)
        }
        func checkpoint(_ revision: Int, parent: ReconstructionCheckpoint?, completed: [UUID], receipts: [UUID],
                        records: [ReconstructionEvidenceRecord]? = nil, toolReceipts: [UUID]? = nil) throws -> ReconstructionCheckpoint {
            try .make(checkpointID: id(30 + revision), jobID: jobID, revision: UInt64(revision),
                parentCheckpointID: parent?.checkpointID, parentCheckpointSHA256: parent?.canonicalSHA256,
                corpusManifestSHA256: hash("corpus"), evidenceFrontierSHA256: try records.map { try makeCut($0).frontierSHA256 } ?? hash("frontier-\(revision)"),
                pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: completed, failedTaskIDs: [], blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: hash("gaps"), modelReceiptIDs: receipts, toolReceiptIDs: toolReceipts ?? (bound ? [id(77)] : []),
                coordinatorState: .checkpointing, terminalReason: nil)
        }
        var parent = try checkpoint(0, parent: nil, completed: bound ? [id(76)] : [], receipts: [])
        let evidenceBytes = Data((bound ? String(repeating: "x", count: 3_086) : "oracle observation").utf8)
        let cited = try ReconstructionEvidenceRecord(evidenceID: id(5), subject: .function(function), operationID: MacScopeAnalysisCore.ReconstructionOperationID.checkpointStatus.rawValue,
            payloadKind: .text, payload: evidenceBytes, payloadByteCount: UInt64(evidenceBytes.count), payloadSHA256: ReconstructionSourceInferenceContract.sha256(evidenceBytes),
            facetDependencies: [], producer: producer(MacScopeAnalysisCore.ReconstructionOperationID.checkpointStatus.rawValue), citations: [], creatingJobID: jobID,
            creatingTaskID: id(6), creatingCheckpointID: parent.checkpointID, modelReceiptID: nil, toolReceiptID: id(7),
            classification: .acceptedCurrent, supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        var graph = Graph(jobs: [jobID: job], tasks: [:], checkpoints: [jobID: [0: parent]], evidence: [cited.evidenceID: cited], receipts: [:])
        var cut = [cited]
        var oracleSuite = hash("oracle")
        if bound {
            let oracleTask = ReconstructionTaskRecord(identity: try .make(taskID: id(76), jobID: jobID,
                kind: .executeSource, subject: .function(function), dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.source.oracle.v1"), state: .completed, diagnostic: nil)
            let oracleProducer = try producer("reconstruction.source.oracle", model: false)
            let oracleReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: id(77), jobID: jobID,
                taskID: id(76), checkpointRevision: 0, requestIdentitySHA256: hash("original request"),
                producer: oracleProducer, terminalState: .completed, outputEvidenceIDs: [id(78)], diagnostic: nil)
            let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
            let execution = ReconstructionSourceOracle.Execution(originalImageSHA256: artifact.contentIdentity.digest,
                originalExecutableSHA256: artifact.contentIdentity.digest, originalSourceSHA256: nil,
                harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                compilerSHA256: hash("compiler"), sdkIdentitySHA256: hash("sdk"), compileProfileSHA256: hash("profile"),
                compileArgumentsSHA256: hash("compile"), executionArgumentsSHA256: hash("execute"),
                producerSHA256: oracleProducer.canonicalSHA256,
                standardOutput: Data(harness.inputs.map { "\($0):7\n" }.joined().utf8), sessionID: id(79), requestID: id(80),
                processIdentifier: 123, sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true)
            let oracleRecord = try ReconstructionSourceOracleEvidence.make(evidenceID: id(78), context: .init(
                authority: .init(projectID: projectID, jobID: jobID, function: function, execution: execution, evidenceIDs: [cited.evidenceID]),
                task: oracleTask, checkpoint: parent, toolReceipt: oracleReceipt,
                expectedRequestIdentitySHA256: oracleReceipt.requestIdentitySHA256, expectedProducer: oracleProducer, committedEvidenceCut: [cited]))
            oracleSuite = try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: oracleRecord.payload).suiteSHA256
            graph.tasks[id(76)] = oracleTask; graph.toolReceipts[id(77)] = oracleReceipt; graph.evidence[id(78)] = oracleRecord
            cut.append(oracleRecord)
            parent = try checkpoint(0, parent: nil, completed: [id(76)], receipts: [], records: cut)
            graph.checkpoints[jobID]?[0] = parent
        }
        var prior: ReconstructionSourceRevision?
        var priorRecords: [ReconstructionEvidenceRecord] = []
        var priorContexts: [ReconstructionSourceRevisionEvidence.Context] = []
        for n in 1...revisions {
            let completionRevision = n + (aggregateParent && n > 1 ? 1 : 0)
            let task = ReconstructionTaskRecord(identity: try .make(taskID: id(40 + n), jobID: jobID, kind: .modelRound,
                subject: .function(function), dependencyTaskIDs: [], operationContractIdentity: ReconstructionSourceRevisionEvidence.taskContract),
                state: .completed, diagnostic: nil)
            var next = try checkpoint(completionRevision, parent: parent, completed: Array(graph.tasks.keys) + [task.identity.taskID],
                receipts: Array(graph.receipts.keys) + [id(50 + n)], toolReceipts: Array(graph.toolReceipts.keys))
            var authority = ReconstructionSourceRevisionAuthority(projectID: projectID, jobID: jobID, function: function,
                objectiveSHA256: job.objectiveSHA256, evidenceFrontierSHA256: parent.evidenceFrontierSHA256,
                oracleSuiteSHA256: oracleSuite, admissibleEvidenceIDs: Set(cut.map(\.evidenceID)), currentRevision: prior)
            if bound {
                let capturedCut = try makeCut(cut)
                XCTAssertEqual(capturedCut.frontierSHA256, parent.evidenceFrontierSHA256)
                let query = try ReconstructionRetrievalQuery(corpusManifestSHA256: parent.corpusManifestSHA256,
                    subject: .function(function), operationIDs: MacScopeAnalysisCore.ReconstructionOperationID.allCases,
                    classifications: [.acceptedCurrent], cursor: nil, maximumRecords: 4, maximumEncodedBytes: ReconstructionSourceContextCompiler.maximumBaseContextBytes)
                let delivered = try ReconstructionSourceContextCompiler().compile(cut: capturedCut, query: query,
                    function: function, oracleSuiteSHA256: oracleSuite, parentRevisionSHA256: prior?.revisionSHA256)
                XCTAssertLessThanOrEqual(delivered.canonicalBytes.count, ReconstructionSourceContextCompiler.maximumContextBytes)
                let deliveredEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: delivered.canonicalBytes) as? [String: Any])
                XCTAssertLessThanOrEqual(try deliveredBase(deliveredEnvelope).count, ReconstructionSourceContextCompiler.maximumBaseContextBytes)
                XCTAssertGreaterThan(try deliveredBase(deliveredEnvelope).count, 4_096,
                    "Bound package validation must exercise a complete observation beyond the former base cap")
                XCTAssertTrue(delivered.evidenceIDs.contains(cited.evidenceID), "Complete ordinary evidence must fit the paired source base budget")
                var contextBytes = delivered.canonicalBytes
                if tamperedOffer {
                    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: contextBytes) as? [String: Any])
                    var base = try XCTUnwrap(JSONSerialization.jsonObject(with: deliveredBase(envelope)) as? [String: Any])
                    let packetData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(base["retrievalPacket"] as? String)))
                    var packet = try XCTUnwrap(JSONSerialization.jsonObject(with: packetData) as? [String: Any])
                    var records = try XCTUnwrap(packet["records"] as? [[String: Any]])
                    var wrapper = try XCTUnwrap(records.first)
                    var record = try XCTUnwrap(wrapper["record"] as? [String: Any])
                    let bytes = Data("forged offered observation".utf8)
                    record["payload"] = bytes.base64EncodedString(); record["payloadByteCount"] = bytes.count
                    record["payloadSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(bytes)
                    wrapper["record"] = record; records[0] = wrapper; packet["records"] = records
                    let packetBytes = try JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys, .withoutEscapingSlashes])
                    base["retrievalPacket"] = packetBytes.base64EncodedString()
                    base["retrievalPacketSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(packetBytes)
                    let baseBytes = try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys, .withoutEscapingSlashes])
                    envelope["baseContext"] = baseBytes.base64EncodedString()
                    envelope["baseContextSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(baseBytes)
                    contextBytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
                }
                if let contextMutation {
                    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: contextBytes) as? [String: Any])
                    contextMutation(&envelope)
                    contextBytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
                }
                let offered = delivered.evidenceIDs
                // Only actual compiler output must satisfy producer bounds. Deliberate context
                // mutations below can exceed them and must be rejected by request admission.
                if contextMutation == nil {
                    XCTAssertLessThanOrEqual(contextBytes.count, ReconstructionSourceRequestBinding.maximumContextBytes)
                }
                let request = ReconstructionSourceRevisionRequest(protocolVersion: 10,
                    objective: try .init(jobID: jobID, text: job.objective, sha256: job.objectiveSHA256),
                    projectID: projectID, jobID: jobID, taskID: task.identity.taskID, checkpointRevision: parent.revision,
                    roundID: id(90 + n), function: function, corpusManifestSHA256: wrongCorpus ? hash("other corpus") : parent.corpusManifestSHA256,
                    evidenceFrontierSHA256: parent.evidenceFrontierSHA256,
                    oracleSuiteSHA256: wrongOracle ? hash("invented oracle") : oracleSuite,
                    profileID: ReconstructionSourceRevision.profileID, parentRevisionSHA256: prior?.revisionSHA256,
                    context: .init(canonicalBytes: contextBytes, canonicalSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(contextBytes), evidenceIDs: offered))
                if wrongOracle {
                    authority = .init(projectID: projectID, jobID: jobID, function: function,
                        objectiveSHA256: job.objectiveSHA256, evidenceFrontierSHA256: parent.evidenceFrontierSHA256,
                        oracleSuiteSHA256: request.oracleSuiteSHA256, admissibleEvidenceIDs: Set(offered), currentRevision: prior)
                }
                let requestBytes = try ReconstructionCanonicalJSON.encode(request)
                let binding = try ReconstructionSourceRevisionAdmission.makeRequestBinding(canonicalRequestBytes: requestBytes,
                    requestSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(requestBytes), authority: authority,
                    expectedTaskID: task.identity.taskID, expectedRoundID: request.roundID, expectedCheckpointRevision: parent.revision)
                authority = .init(projectID: projectID, jobID: jobID, function: function, objectiveSHA256: job.objectiveSHA256,
                    evidenceFrontierSHA256: parent.evidenceFrontierSHA256, oracleSuiteSHA256: request.oracleSuiteSHA256,
                    admissibleEvidenceIDs: Set(offered), currentRevision: prior, requestBinding: binding)
            }
            let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(receiptID: id(50 + n), jobID: jobID, taskID: task.identity.taskID,
                checkpointRevision: UInt64(completionRevision), requestIdentitySHA256: authority.requestBinding?.requestSHA256 ?? hash("request-\(n)"),
                producer: producer(ReconstructionSourceRevisionEvidence.operationID), terminalState: .completed,
                selectedHandleIDs: [], acceptedEvidenceIDs: [id(60 + n)], diagnostic: nil)
            var context = ReconstructionSourceRevisionEvidence.Context(admissionAuthority: authority, task: task, checkpoint: next,
                modelReceipt: receipt, expectedRequestIdentitySHA256: receipt.requestIdentitySHA256, committedEvidenceCut: cut,
                committedPriorRevisionRecords: priorRecords, priorRevisionContexts: priorContexts)
            let source = Data("unsigned int reconstructed(unsigned int x){return x;}".utf8)
            let record = try ReconstructionSourceRevisionEvidence.make(evidenceID: id(60 + n),
                proposal: .init(parentRevisionSHA256: prior?.revisionSHA256, sourceUTF8: source,
                    claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source), evidenceIDs: [cited.evidenceID]), context: context)
            if bound {
                next = try checkpoint(completionRevision, parent: parent, completed: Array(graph.tasks.keys) + [task.identity.taskID],
                    receipts: Array(graph.receipts.keys) + [receipt.receiptID], records: cut + [record],
                    toolReceipts: Array(graph.toolReceipts.keys))
                context = .init(admissionAuthority: authority, task: task, checkpoint: next,
                    modelReceipt: receipt, expectedRequestIdentitySHA256: receipt.requestIdentitySHA256, committedEvidenceCut: cut,
                    committedPriorRevisionRecords: priorRecords, priorRevisionContexts: priorContexts)
            }
            prior = try ReconstructionSourceRevisionEvidence.validate(record: record, context: context)
            priorRecords.append(record); priorContexts.append(context)
            graph.tasks[task.identity.taskID] = task; graph.receipts[receipt.receiptID] = receipt
            graph.evidence[record.evidenceID] = record; graph.checkpoints[jobID]?[UInt64(completionRevision)] = next
            if bound { cut.append(record) }
            if bound && n == 1 && !excludedDiagnostics.isEmpty {
                let revision = try XCTUnwrap(prior)
                for (index, classification) in excludedDiagnostics.enumerated() {
                    let payload = try ReconstructionCanonicalJSON.encode(ReconstructionSourceDiagnosticPayload(
                        version: 1, profileID: revision.profileID, function: function,
                        revisionSHA256: revision.revisionSHA256, sourceSHA256: revision.sourceSHA256,
                        diagnostic: "excluded retained diagnostic"))
                    let diagnostic = try ReconstructionEvidenceRecord(evidenceID: id(800 + index),
                        subject: .function(function), operationID: "reconstruction.source.build",
                        payloadKind: .structuredJSON, payload: payload, payloadByteCount: UInt64(payload.count),
                        payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(payload), facetDependencies: [],
                        producer: producer("reconstruction.source.build", model: false), citations: [],
                        creatingJobID: jobID, creatingTaskID: id(810 + index), creatingCheckpointID: next.checkpointID,
                        modelReceiptID: nil, toolReceiptID: id(820 + index), classification: classification,
                        supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
                    graph.evidence[diagnostic.evidenceID] = diagnostic; cut.append(diagnostic)
                }
                next = try checkpoint(completionRevision, parent: parent, completed: Array(graph.tasks.keys),
                    receipts: Array(graph.receipts.keys), records: cut, toolReceipts: Array(graph.toolReceipts.keys))
                graph.checkpoints[jobID]?[UInt64(completionRevision)] = next
                priorContexts[priorContexts.count - 1] = .init(admissionAuthority: authority, task: task,
                    checkpoint: next, modelReceipt: receipt, expectedRequestIdentitySHA256: receipt.requestIdentitySHA256,
                    committedEvidenceCut: context.committedEvidenceCut,
                    committedPriorRevisionRecords: context.committedPriorRevisionRecords,
                    priorRevisionContexts: context.priorRevisionContexts)
            }
            if aggregateParent && n == 1 {
                let evaluated = try evaluatedFixture(mismatch: true)
                let aggregate = try XCTUnwrap(evaluated.evidence[id(84)])
                let evaluationTask = try XCTUnwrap(evaluated.tasks[id(82)])
                let evaluationReceipt = try XCTUnwrap(evaluated.toolReceipts[id(83)])
                graph.evidence[aggregate.evidenceID] = aggregate; cut.append(aggregate)
                graph.tasks[id(82)] = evaluationTask; graph.toolReceipts[id(83)] = evaluationReceipt
                let evaluationCheckpoint = try ReconstructionCheckpoint.make(checkpointID: id(85), jobID: jobID,
                    revision: 2, parentCheckpointID: next.checkpointID, parentCheckpointSHA256: next.canonicalSHA256,
                    corpusManifestSHA256: next.corpusManifestSHA256, evidenceFrontierSHA256: makeCut(cut).frontierSHA256,
                    pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: Array(graph.tasks.keys),
                    failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: hash("gaps"),
                    modelReceiptIDs: Array(graph.receipts.keys), toolReceiptIDs: [id(77), id(83)],
                    coordinatorState: .checkpointing, terminalReason: nil)
                graph.checkpoints[jobID]?[2] = evaluationCheckpoint
                parent = evaluationCheckpoint
            } else { parent = next }
        }
        return graph
    }
    private func deliveredBase(_ envelope: [String: Any]) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["baseContext"] as? String)))
    }

    private func mutate<T: Codable>(_ value: T, _ edit: (inout [String: Any]) -> Void) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(value)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testCanonicalInitialAndParentRevisionGraphsValidate() throws {
        try fixture().validate()
        try fixture(revisions: 2).validate()
    }
    func testCompletedSourceRequiresReceiptAndInlineEvidence() throws {
        var graph = try fixture(); graph.receipts = [:]
        XCTAssertThrowsError(try graph.validate())
        graph = try fixture(); graph.evidence[id(61)] = nil
        XCTAssertThrowsError(try graph.validate())
    }
    func testVersionedProducerOperationIsRejected() throws {
        var graph = try fixture()
        graph.receipts[id(51)] = try mutate(XCTUnwrap(graph.receipts[id(51)])) { object in
            var producer = object["producer"] as! [String: Any]
            producer["operationIdentity"] = ReconstructionSourceRevisionEvidence.taskContract; object["producer"] = producer
        }
        XCTAssertThrowsError(try graph.validate())
    }
    func testTamperedPayloadAndMissingParentRecordReject() throws {
        var graph = try fixture()
        graph.evidence[id(61)] = try mutate(XCTUnwrap(graph.evidence[id(61)])) { $0["payload"] = Data("{}".utf8).base64EncodedString() }
        XCTAssertThrowsError(try graph.validate())
        graph = try fixture(revisions: 2); graph.evidence[id(61)] = nil
        XCTAssertThrowsError(try graph.validate())
    }
    func testReceiptCompletionRevisionAndCheckpointMembershipReject() throws {
        var graph = try fixture()
        graph.receipts[id(51)] = try mutate(XCTUnwrap(graph.receipts[id(51)])) { $0["checkpointRevision"] = 0 }
        XCTAssertThrowsError(try graph.validate())
        graph = try fixture()
        let checkpoint = try XCTUnwrap(graph.checkpoints[id(1)]?[1])
        graph.checkpoints[id(1)]?[1] = try mutate(checkpoint) { $0["modelReceiptIDs"] = [] }
        XCTAssertThrowsError(try graph.validate())
    }
    func testNoncanonicalAndWrongProfilePayloadRejectAfterOuterHashRepair() throws {
        for profile in ["unsupported-profile", ReconstructionSourceRevision.profileID] {
            var graph = try fixture()
            let record = try XCTUnwrap(graph.evidence[id(61)])
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
            payload["profileID"] = profile
            // Even the unchanged profile is encoded with noncanonical whitespace.
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            graph.evidence[id(61)] = try mutate(record) {
                $0["payload"] = bytes.base64EncodedString(); $0["payloadByteCount"] = bytes.count
                $0["payloadSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(bytes)
            }
            XCTAssertThrowsError(try graph.validate())
        }
    }
    func testThirdRecordAndEarlierTaskCompletionReject() throws {
        var graph = try fixture(revisions: 2)
        let record = try XCTUnwrap(graph.evidence[id(62)])
        graph.evidence[id(63)] = try mutate(record) { $0["evidenceID"] = id(63).uuidString }
        XCTAssertThrowsError(try graph.validate())
        graph = try fixture()
        let initial = try XCTUnwrap(graph.checkpoints[id(1)]?[0])
        graph.checkpoints[id(1)]?[0] = try mutate(initial) { $0["completedTaskIDs"] = [id(41).uuidString] }
        XCTAssertThrowsError(try graph.validate())
    }

    func testBoundInitialAndParentRequestsValidateWithStrictSubsetCitations() throws {
        try fixture(bound: true).validate()
        try fixture(revisions: 2, bound: true).validate()
    }
    func testCompactContextRejectsUnknownKeysOracleSubstitutionAndParentPresentationTamper() throws {
        for edit: (inout [String: Any]) -> Void in [
            { $0["unknown"] = "untrusted" },
            { envelope in
                var oracle = envelope["oracle"] as! [String: Any]
                var outputs = oracle["outputs"] as! [NSNumber]
                outputs[0] = NSNumber(value: 99)
                oracle["outputs"] = outputs; envelope["oracle"] = oracle
            },
            { envelope in
                guard var parent = envelope["parent"] as? [String: Any] else { return }
                parent["sourceText"] = "unsigned int reconstructed(unsigned int x){return 0;}"
                envelope["parent"] = parent
            },
        ] {
            let graph = try fixture(revisions: 2, bound: true, contextMutation: edit)
            XCTAssertThrowsError(try graph.validate())
        }
    }

    func testCompactSourceGraphSurvivesDurableCodableRoundTrip() throws {
        for graph in [try fixture(bound: true), try fixture(revisions: 2, bound: true),
                      try fixture(revisions: 2, bound: true, aggregateParent: true)] {
            let bytes = try ReconstructionCanonicalJSON.encode(graph)
            let restored = try JSONDecoder().decode(Graph.self, from: bytes)
            XCTAssertEqual(Set(restored.evidence.keys), Set(graph.evidence.keys))
            for (id, record) in graph.evidence {
                XCTAssertEqual(restored.evidence[id]?.payload, record.payload)
                XCTAssertEqual(restored.evidence[id]?.payloadSHA256, record.payloadSHA256)
            }
            try restored.validate()
        }
    }

    func testCompactProducerExcludesCancelledAndHistoricalFallbackDiagnostics() throws {
        let graph = try fixture(revisions: 2, bound: true,
            excludedDiagnostics: [.cancelled, .acceptedHistorical])
        try graph.validate()
        let revision = try JSONDecoder().decode(ReconstructionSourceRevision.self,
            from: XCTUnwrap(graph.evidence[id(62)]).payload)
        let binding = try XCTUnwrap(revision.requestBinding)
        let request = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
            from: binding.canonicalRequestBytes)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: request.context.canonicalBytes) as? [String: Any])
        XCTAssertEqual((envelope["diagnostics"] as? [Any])?.count, 0)
        XCTAssertFalse(request.context.evidenceIDs.contains(id(800)))
        XCTAssertFalse(request.context.evidenceIDs.contains(id(801)))
    }

    func testCompactAggregateRepairContextValidatesActualProducerAndRejectsPresentationTamper() throws {
        try fixture(revisions: 2, bound: true, aggregateParent: true).validate()
        for field in ["diagnostic", "sourceSHA256", "payloadSHA256", "operationID", "checkpointRevision"] {
            let graph = try fixture(revisions: 2, bound: true, aggregateParent: true, contextMutation: { envelope in
                guard var diagnostics = envelope["diagnostics"] as? [[String: Any]], !diagnostics.isEmpty else { return }
                if field == "checkpointRevision" { diagnostics[0][field] = NSNumber(value: 0) }
                else { diagnostics[0][field] = "forged" }
                envelope["diagnostics"] = diagnostics
            })
            XCTAssertThrowsError(try graph.validate(), field)
        }
        XCTAssertThrowsError(try fixture(revisions: 2, bound: true, aggregateParent: true, contextMutation: { envelope in
            guard var diagnostics = envelope["diagnostics"] as? [[String: Any]], !diagnostics.isEmpty else { return }
            diagnostics[0]["diagnostic"] = String(repeating: "x", count: 2_049)
            envelope["diagnostics"] = diagnostics
        }).validate())
    }

    func testCompactNestedBaseRejectsNoncanonicalBytesAndUnknownKeys() throws {
        for unknown in [false, true] {
            let graph = try fixture(bound: true, contextMutation: { envelope in
                let original = Data(base64Encoded: envelope["baseContext"] as! String)!
                var base = try! JSONSerialization.jsonObject(with: original) as! [String: Any]
                if unknown { base["unknown"] = true }
                var bytes = try! JSONSerialization.data(withJSONObject: base, options: [.sortedKeys, .withoutEscapingSlashes])
                if !unknown { bytes.append(0x20) }
                envelope["baseContext"] = bytes.base64EncodedString()
                envelope["baseContextSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(bytes)
            })
            XCTAssertThrowsError(try graph.validate())
        }
    }

    func testBoundReceiptRequestMismatchAndMissingOfferedOracleReject() throws {
        var graph = try fixture(bound: true)
        graph.receipts[id(51)] = try mutate(XCTUnwrap(graph.receipts[id(51)])) { $0["requestIdentitySHA256"] = hash("other request") }
        XCTAssertThrowsError(try graph.validate())
        graph = try fixture(bound: true); graph.evidence[id(78)] = nil
        XCTAssertThrowsError(try graph.validate())
    }
    func testBoundUncitedOfferedPayloadTamperAndOracleReceiptMismatchReject() throws {
        var graph = try fixture(bound: true)
        let oracle = try XCTUnwrap(graph.evidence[id(78)])
        graph.evidence[id(78)] = try mutate(oracle) { $0["payloadSHA256"] = hash("wrong offered hash") }
        XCTAssertThrowsError(try graph.validate())
        graph = try fixture(bound: true); graph.toolReceipts[id(77)] = nil
        XCTAssertThrowsError(try graph.validate())
    }

    func testCanonicalBoundRequestsCannotReplaceCommittedCorpusOfferedPayloadOrOracle() throws {
        XCTAssertThrowsError(try fixture(bound: true, wrongCorpus: true).validate())
        XCTAssertThrowsError(try fixture(bound: true, tamperedOffer: true).validate())
        XCTAssertThrowsError(try fixture(bound: true, wrongOracle: true).validate())
    }

    func testBoundProductionOracleRequiresExplicitSourceExecutionTaskKind() throws {
        var graph = try fixture(bound: true)
        let original = try XCTUnwrap(graph.tasks[id(76)])
        graph.tasks[id(76)] = ReconstructionTaskRecord(identity: try .make(taskID: original.identity.taskID,
            jobID: original.identity.jobID, kind: .retrieveEvidence, subject: original.identity.subject,
            dependencyTaskIDs: original.identity.dependencyTaskIDs,
            operationContractIdentity: original.identity.operationContractIdentity), state: .completed, diagnostic: nil)
        XCTAssertThrowsError(try graph.validate())
        // Deliberate legacy source fixtures retain nil request binding.
        try fixture().validate()
    }

    private func evaluatedFixture(mismatch: Bool = false, forgedAccepted: Bool = false) throws -> Graph {
        var graph = try fixture(bound: true)
        let source = try XCTUnwrap(graph.evidence[id(61)]), oracleRecord = try XCTUnwrap(graph.evidence[id(78)])
        let revision = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: source.payload)
        let oracle = try JSONDecoder().decode(ReconstructionSourceOracle.self, from: oracleRecord.payload)
        let binding = try XCTUnwrap(revision.requestBinding), parent = try XCTUnwrap(graph.checkpoints[id(1)]?[1])
        let task = ReconstructionTaskRecord(identity: try .make(taskID: id(82), jobID: id(1), kind: .executeSource,
            subject: source.subject, dependencyTaskIDs: [source.creatingTaskID],
            operationContractIdentity: "reconstruction.source.evaluate.v1"), state: .completed, diagnostic: nil)
        let p = try producer("reconstruction.source.evaluate", model: false)
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: id(83), jobID: id(1), taskID: id(82),
            checkpointRevision: 2, requestIdentitySHA256: hash("evaluation request"), producer: p,
            terminalState: .completed, outputEvidenceIDs: [id(84)], diagnostic: nil)
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: id(85), jobID: id(1), revision: 2,
            parentCheckpointID: parent.checkpointID, parentCheckpointSHA256: parent.canonicalSHA256,
            corpusManifestSHA256: parent.corpusManifestSHA256, evidenceFrontierSHA256: hash("evaluation frontier"),
            pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: Array(graph.tasks.keys) + [id(82)], failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: hash("gaps"), modelReceiptIDs: Array(graph.receipts.keys), toolReceiptIDs: [id(77), id(83)],
            coordinatorState: .checkpointing, terminalReason: nil)
        let terminal = ReconstructionSourceEvaluation.Terminal(kind: .exited, status: 0)
        let phases = [ReconstructionSourceEvaluation.Operation.inspect, .compile, .behavior].enumerated().map { index, operation in
            ReconstructionSourceEvaluation.Phase(operation: operation, requestID: id(700 + index), sessionID: id(710),
                requestIdentitySHA256: hash("phase-\(index)"), status: .completed, terminal: terminal, failure: nil, diagnostics: Data(),
                cleanup: .init(sessionID: id(710), requestID: id(700 + index), processIdentifier: 123,
                    observedProcessAbsent: true, outcome: terminal), sampledProcessIDs: [123], peakGroupResidentBytes: 1_024, elapsedMilliseconds: 1)
        }
        let outputs = oracle.outputs.enumerated().map { index, output in index == 0 && (mismatch || forgedAccepted) ? output + 1 : output }
        let observations = zip(oracle.inputs, outputs).map { ReconstructionSourceEvaluation.Observation(input: $0.0, output: $0.1) }
        let mismatches: [ReconstructionSourceEvaluation.Mismatch] = mismatch ? [.init(index: 0, input: oracle.inputs[0], expected: oracle.outputs[0], actual: outputs[0])] : []
        let evaluation = ReconstructionSourceEvaluation(version: 1, profileID: ReconstructionSourceEvaluation.profileID,
            projectID: id(2), jobID: id(1), taskID: id(82), checkpointRevision: 2, evaluationRequestSHA256: receipt.requestIdentitySHA256,
            function: revision.function, sourceEvidenceID: source.evidenceID, sourcePayloadSHA256: source.payloadSHA256,
            revisionSHA256: revision.revisionSHA256, sourceSHA256: revision.sourceSHA256, sourceRequestSHA256: binding.requestSHA256,
            oracleEvidenceID: oracleRecord.evidenceID, oraclePayloadSHA256: oracleRecord.payloadSHA256, oracleSuiteSHA256: oracle.suiteSHA256,
            producerSHA256: p.canonicalSHA256, capturedOutcome: .init(status: mismatch ? .behaviorMismatch : .accepted,
                failureDetail: mismatch ? "observed mismatch" : nil, runnerSHA256: hash("runner"), compilerSHA256: hash("compiler"),
                sdkSettingsSHA256: hash("sdk"), harnessSHA256: oracle.execution.harnessSHA256, inspectionSHA256: hash("ast"),
                astSHA256: hash("ast"), executableSHA256: hash("executable"), phases: phases, observations: observations, mismatches: mismatches),
            evaluationSHA256: hash("placeholder"))
        let identity = try ReconstructionSourceEvaluationCodec.canonicalIdentity(evaluation)
        let value: ReconstructionSourceEvaluation = try mutate(evaluation) { $0["evaluationSHA256"] = identity }
        let payload = try ReconstructionSourceEvaluationCodec.encode(value)
        let record = try ReconstructionEvidenceRecord(evidenceID: id(84), subject: source.subject, operationID: "reconstruction.source.evaluate",
            payloadKind: .structuredJSON, payload: payload, payloadByteCount: UInt64(payload.count),
            payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(payload), facetDependencies: [], producer: p,
            citations: [try .init(citationID: id(61), sourceEvidenceID: id(61), subject: nil, locator: nil),
                try .init(citationID: id(78), sourceEvidenceID: id(78), subject: nil, locator: nil)],
            creatingJobID: id(1), creatingTaskID: id(82), creatingCheckpointID: checkpoint.checkpointID,
            modelReceiptID: nil, toolReceiptID: receipt.receiptID, classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        graph.tasks[id(82)] = task; graph.toolReceipts[id(83)] = receipt
        graph.evidence[id(84)] = record; graph.checkpoints[id(1)]?[2] = checkpoint
        return graph
    }
    func testImportedAggregateAcceptanceAndObservedMismatchBindActualOracle() throws {
        try evaluatedFixture().validate()
        try evaluatedFixture(mismatch: true).validate()
        // Canonical/hash-valid local acceptance cannot replace the actual oracle outputs.
        XCTAssertThrowsError(try evaluatedFixture(forgedAccepted: true).validate())
    }
    func testImportedAggregateRequiresActualTaskReceiptAndEarlierSource() throws {
        var graph = try evaluatedFixture(); graph.toolReceipts[id(83)] = nil
        XCTAssertThrowsError(try graph.validate())
        graph = try evaluatedFixture(); graph.evidence[id(61)] = nil
        XCTAssertThrowsError(try graph.validate())
        graph = try evaluatedFixture(); graph.tasks[id(82)] = nil
        XCTAssertThrowsError(try graph.validate())
    }
    func testCompletedEvaluationCannotOmitAggregateEvidence() throws {
        var graph = try evaluatedFixture(); graph.evidence[id(84)] = nil
        XCTAssertThrowsError(try graph.validate())
    }

    func testCanonicalInfrastructureOutcomeCannotBecomeCompletedEvaluationEvidence() throws {
        var graph = try evaluatedFixture()
        let record = try XCTUnwrap(graph.evidence[id(84)])
        let original = try JSONDecoder().decode(ReconstructionSourceEvaluation.self, from: record.payload)
        let changed: ReconstructionSourceEvaluation = try mutate(original) {
            var outcome = $0["capturedOutcome"] as! [String: Any]
            outcome["status"] = "cancelled"; $0["capturedOutcome"] = outcome
        }
        let identity = try ReconstructionSourceEvaluationCodec.canonicalIdentity(changed)
        let rebuilt: ReconstructionSourceEvaluation = try mutate(changed) { $0["evaluationSHA256"] = identity }
        let bytes = try ReconstructionSourceEvaluationCodec.encode(rebuilt)
        graph.evidence[id(84)] = try mutate(record) {
            $0["payload"] = bytes.base64EncodedString(); $0["payloadByteCount"] = bytes.count
            $0["payloadSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(bytes)
        }
        XCTAssertThrowsError(try graph.validate())
    }

    private func completed(_ original: Graph, revision: UInt64) throws -> Graph {
        var graph = original
        let checkpoint = try XCTUnwrap(graph.checkpoints[id(1)]?[revision])
        graph.checkpoints[id(1)]?[revision] = try ReconstructionCheckpoint.make(checkpointID: checkpoint.checkpointID,
            jobID: checkpoint.jobID, revision: checkpoint.revision, parentCheckpointID: checkpoint.parentCheckpointID,
            parentCheckpointSHA256: checkpoint.parentCheckpointSHA256, corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256, pendingTaskIDs: checkpoint.pendingTaskIDs,
            runningTaskIDs: checkpoint.runningTaskIDs, completedTaskIDs: checkpoint.completedTaskIDs,
            failedTaskIDs: checkpoint.failedTaskIDs, blockedTaskIDs: checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: checkpoint.modelReceiptIDs, toolReceiptIDs: checkpoint.toolReceiptIDs,
            coordinatorState: .completed, terminalReason: nil)
        graph.jobs[id(1)] = try mutate(XCTUnwrap(graph.jobs[id(1)])) {
            $0["state"] = "completed"; $0["currentCheckpointID"] = checkpoint.checkpointID.uuidString
        }
        return graph
    }
    func testCompletedSourceJobRequiresAcceptedEvaluationOfLatestRevision() throws {
        try completed(evaluatedFixture(), revision: 2).validate()
        XCTAssertThrowsError(try completed(evaluatedFixture(mismatch: true), revision: 2).validate()) { error in
            XCTAssertEqual(error as? ReconstructionPackageValidationError, .stateGraphInvalid("completed source job acceptance"))
        }
        XCTAssertThrowsError(try completed(fixture(bound: true), revision: 1).validate())
        // Nonexecuted legacy fixtures do not acquire a new source acceptance requirement.
        try completed(fixture(), revision: 1).validate()
    }
    func testOlderAcceptanceCannotCompleteNewerCanonicalSourceRevision() throws {
        var graph = try fixture(revisions: 2, bound: true)
        let oldAccepted = try evaluatedFixture()
        let oldRecord = try XCTUnwrap(oldAccepted.evidence[id(84)])
        let oldValue = try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: oldRecord.payload)
        let changed: ReconstructionSourceEvaluation = try mutate(oldValue) { $0["checkpointRevision"] = 3 }
        let identity = try ReconstructionSourceEvaluationCodec.canonicalIdentity(changed)
        let value: ReconstructionSourceEvaluation = try mutate(changed) { $0["evaluationSHA256"] = identity }
        let payload = try ReconstructionSourceEvaluationCodec.encode(value)
        let parent = try XCTUnwrap(graph.checkpoints[id(1)]?[2])
        let task = try XCTUnwrap(oldAccepted.tasks[id(82)]), oldReceipt = try XCTUnwrap(oldAccepted.toolReceipts[id(83)])
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: oldReceipt.receiptID, jobID: oldReceipt.jobID,
            taskID: oldReceipt.taskID, checkpointRevision: 3, requestIdentitySHA256: oldReceipt.requestIdentitySHA256,
            producer: oldReceipt.producer, terminalState: .completed, outputEvidenceIDs: oldReceipt.outputEvidenceIDs, diagnostic: nil)
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: id(95), jobID: id(1), revision: 3,
            parentCheckpointID: parent.checkpointID, parentCheckpointSHA256: parent.canonicalSHA256,
            corpusManifestSHA256: parent.corpusManifestSHA256, evidenceFrontierSHA256: hash("older acceptance frontier"),
            pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: Array(graph.tasks.keys) + [task.identity.taskID],
            failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: hash("gaps"),
            modelReceiptIDs: Array(graph.receipts.keys), toolReceiptIDs: [id(77), receipt.receiptID],
            coordinatorState: .checkpointing, terminalReason: nil)
        graph.evidence[id(84)] = try mutate(oldRecord) {
            $0["creatingCheckpointID"] = checkpoint.checkpointID.uuidString
            $0["payload"] = payload.base64EncodedString(); $0["payloadByteCount"] = payload.count
            $0["payloadSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(payload)
        }
        graph.tasks[id(82)] = task; graph.toolReceipts[id(83)] = receipt; graph.checkpoints[id(1)]?[3] = checkpoint
        // The imported evaluation itself is authenticated, but evaluates the older source.
        try graph.validate()
        XCTAssertThrowsError(try completed(graph, revision: 3).validate()) { error in
            XCTAssertEqual(error as? ReconstructionPackageValidationError, .stateGraphInvalid("completed source job acceptance"))
        }
    }

    func testOlderAcceptedEvaluationCannotHideLaterObservedMismatch() throws {
        var graph = try evaluatedFixture()
        let mismatchGraph = try evaluatedFixture(mismatch: true)
        let record = try XCTUnwrap(mismatchGraph.evidence[id(84)])
        let original = try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: record.payload)
        let changed: ReconstructionSourceEvaluation = try mutate(original) {
            $0["taskID"] = id(92).uuidString; $0["checkpointRevision"] = 3
            $0["evaluationRequestSHA256"] = hash("later evaluation request")
        }
        let identity = try ReconstructionSourceEvaluationCodec.canonicalIdentity(changed)
        let value: ReconstructionSourceEvaluation = try mutate(changed) { $0["evaluationSHA256"] = identity }
        let payload = try ReconstructionSourceEvaluationCodec.encode(value)
        let parent = try XCTUnwrap(graph.checkpoints[id(1)]?[2])
        let task = ReconstructionTaskRecord(identity: try .make(taskID: id(92), jobID: id(1), kind: .executeSource,
            subject: record.subject, dependencyTaskIDs: [id(41)], operationContractIdentity: "reconstruction.source.evaluate.v1"),
            state: .completed, diagnostic: nil)
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: id(93), jobID: id(1), taskID: id(92),
            checkpointRevision: 3, requestIdentitySHA256: value.evaluationRequestSHA256, producer: record.producer,
            terminalState: .completed, outputEvidenceIDs: [id(94)], diagnostic: nil)
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: id(95), jobID: id(1), revision: 3,
            parentCheckpointID: parent.checkpointID, parentCheckpointSHA256: parent.canonicalSHA256,
            corpusManifestSHA256: parent.corpusManifestSHA256, evidenceFrontierSHA256: hash("later mismatch frontier"),
            pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: Array(graph.tasks.keys) + [id(92)],
            failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: hash("gaps"),
            modelReceiptIDs: Array(graph.receipts.keys), toolReceiptIDs: Array(graph.toolReceipts.keys) + [id(93)],
            coordinatorState: .checkpointing, terminalReason: nil)
        graph.evidence[id(94)] = try mutate(record) {
            $0["evidenceID"] = id(94).uuidString; $0["creatingTaskID"] = id(92).uuidString
            $0["creatingCheckpointID"] = checkpoint.checkpointID.uuidString; $0["toolReceiptID"] = id(93).uuidString
            $0["payload"] = payload.base64EncodedString(); $0["payloadByteCount"] = payload.count
            $0["payloadSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(payload)
        }
        graph.tasks[id(92)] = task; graph.toolReceipts[id(93)] = receipt; graph.checkpoints[id(1)]?[3] = checkpoint
        try graph.validate()
        XCTAssertThrowsError(try completed(graph, revision: 3).validate()) { error in
            XCTAssertEqual(error as? ReconstructionPackageValidationError, .stateGraphInvalid("completed source job acceptance"))
        }
    }

    func testExplicitSourceProfileCannotCompleteWithoutAuthenticatedSourceAcceptance() throws {
        var graph = try completed(fixture(), revision: 1)
        graph.jobs[id(1)] = try mutate(XCTUnwrap(graph.jobs[id(1)])) {
            $0["sourceProfileID"] = ReconstructionSourceExecutionTaskContract.profileID
        }
        XCTAssertThrowsError(try graph.validate()) { error in
            XCTAssertEqual(error as? ReconstructionPackageValidationError, .stateGraphInvalid("completed source job acceptance"))
        }
        // The explicit profile also prevents an empty ordinary-looking task graph from bypassing admission.
        graph.tasks = [:]; graph.receipts = [:]; graph.evidence[id(61)] = nil
        XCTAssertThrowsError(try graph.validate())
        try completed(fixture(), revision: 1).validate()
        graph = try completed(evaluatedFixture(), revision: 2)
        graph.jobs[id(1)] = try mutate(XCTUnwrap(graph.jobs[id(1)])) {
            $0["sourceProfileID"] = ReconstructionSourceExecutionTaskContract.profileID
        }
        try graph.validate()
    }

}
