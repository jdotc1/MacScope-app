import XCTest
@testable import MacScope

final class ReconstructionReceiptAuthorityTests: XCTestCase {
    func testToolReceiptDigestMatchesAnIndependentExhaustivePreimage() throws {
        let producer = try makeProducer()
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: uuid(1),
            jobID: uuid(2),
            taskID: uuid(3),
            checkpointRevision: 7,
            requestIdentitySHA256: digest("a"),
            producer: producer,
            terminalState: .truncated,
            outputEvidenceIDs: [uuid(5), uuid(4)],
            diagnostic: .sanitizing("bounded tool diagnostic")
        )

        let independentDigest = try ReconstructionCanonicalJSON.sha256(of: ToolPreimage(
            schemaVersion: ReconstructionToolReceipt.schemaVersion,
            receiptID: receipt.receiptID,
            jobID: receipt.jobID,
            taskID: receipt.taskID,
            checkpointRevision: receipt.checkpointRevision,
            requestIdentitySHA256: receipt.requestIdentitySHA256,
            producer: receipt.producer,
            terminalState: receipt.terminalState,
            outputEvidenceIDs: receipt.outputEvidenceIDs,
            diagnostic: receipt.diagnostic
        ))

        XCTAssertEqual(receipt.outputEvidenceIDs, [uuid(4), uuid(5)])
        XCTAssertEqual(receipt.canonicalSHA256, independentDigest)
        XCTAssertTrue(try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt))
    }

    func testModelReceiptDigestMatchesAnIndependentExhaustivePreimage() throws {
        let producer = try makeProducer()
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: uuid(10),
            jobID: uuid(11),
            taskID: uuid(12),
            checkpointRevision: 13,
            requestIdentitySHA256: digest("b"),
            producer: producer,
            terminalState: .completed,
            selectedHandleIDs: ["function:two", "function:one"],
            acceptedEvidenceIDs: [uuid(15), uuid(14)],
            diagnostic: .sanitizing("bounded model diagnostic")
        )

        let independentDigest = try ReconstructionCanonicalJSON.sha256(of: ModelPreimage(
            schemaVersion: ReconstructionModelReceipt.schemaVersion,
            receiptID: receipt.receiptID,
            jobID: receipt.jobID,
            taskID: receipt.taskID,
            checkpointRevision: receipt.checkpointRevision,
            requestIdentitySHA256: receipt.requestIdentitySHA256,
            producer: receipt.producer,
            terminalState: receipt.terminalState,
            selectedHandleIDs: receipt.selectedHandleIDs,
            acceptedEvidenceIDs: receipt.acceptedEvidenceIDs,
            diagnostic: receipt.diagnostic
        ))

        XCTAssertEqual(receipt.selectedHandleIDs, ["function:two", "function:one"])
        XCTAssertEqual(receipt.acceptedEvidenceIDs, [uuid(14), uuid(15)])
        XCTAssertEqual(receipt.canonicalSHA256, independentDigest)
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
    }

    func testRetainingDigestWhileChangingTaskIDInvalidatesToolAndModelReceipts() throws {
        let producer = try makeProducer()
        let tool = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: uuid(20),
            jobID: uuid(21),
            taskID: uuid(22),
            checkpointRevision: 23,
            requestIdentitySHA256: digest("c"),
            producer: producer,
            terminalState: .completed,
            outputEvidenceIDs: [],
            diagnostic: nil
        )
        let tamperedTool = try ReconstructionToolReceipt(
            receiptID: tool.receiptID,
            jobID: tool.jobID,
            taskID: uuid(24),
            checkpointRevision: tool.checkpointRevision,
            requestIdentitySHA256: tool.requestIdentitySHA256,
            producer: tool.producer,
            terminalState: tool.terminalState,
            outputEvidenceIDs: tool.outputEvidenceIDs,
            diagnostic: tool.diagnostic,
            canonicalSHA256: tool.canonicalSHA256
        )
        XCTAssertFalse(
            try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(tamperedTool)
        )

        let model = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: uuid(30),
            jobID: uuid(31),
            taskID: uuid(32),
            checkpointRevision: 33,
            requestIdentitySHA256: digest("d"),
            producer: producer,
            terminalState: .failed,
            selectedHandleIDs: [],
            acceptedEvidenceIDs: [],
            diagnostic: .sanitizing("model failed")
        )
        let tamperedModel = try ReconstructionModelReceipt(
            receiptID: model.receiptID,
            jobID: model.jobID,
            taskID: uuid(34),
            checkpointRevision: model.checkpointRevision,
            requestIdentitySHA256: model.requestIdentitySHA256,
            producer: model.producer,
            terminalState: model.terminalState,
            selectedHandleIDs: model.selectedHandleIDs,
            acceptedEvidenceIDs: model.acceptedEvidenceIDs,
            diagnostic: model.diagnostic,
            canonicalSHA256: model.canonicalSHA256
        )
        XCTAssertFalse(
            try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(tamperedModel)
        )
    }

    func testFinalResultAndTerminalModelReceiptBindEveryDurableField() throws {
        let producer = try makeProducer()
        let payload = Data("A bounded, cited final synthesis.".utf8)
        let result = try ReconstructionReceiptAuthority.makeFinalResult(
            resultID: uuid(60),
            jobID: uuid(61),
            taskID: uuid(62),
            checkpointID: uuid(63),
            checkpointRevision: 64,
            requestID: uuid(65),
            requestIdentitySHA256: digest("a"),
            kind: .synthesis,
            payloadUTF8: payload,
            citedEvidenceIDs: [uuid(67), uuid(66)],
            producer: producer,
            modelReceiptID: uuid(65)
        )
        let independentDigest = try ReconstructionCanonicalJSON.sha256(of: FinalResultPreimage(
            resultID: result.resultID,
            schemaVersion: result.schemaVersion,
            jobID: result.jobID,
            taskID: result.taskID,
            checkpointID: result.checkpointID,
            checkpointRevision: result.checkpointRevision,
            requestID: result.requestID,
            requestIdentitySHA256: result.requestIdentitySHA256,
            kind: result.kind,
            payloadUTF8: result.payloadUTF8,
            payloadByteCount: result.payloadByteCount,
            payloadSHA256: result.payloadSHA256,
            citedEvidenceIDs: result.citedEvidenceIDs,
            producer: result.producer,
            modelReceiptID: result.modelReceiptID
        ))
        XCTAssertEqual(result.citedEvidenceIDs, [uuid(66), uuid(67)])
        XCTAssertEqual(result.canonicalSHA256, independentDigest)
        XCTAssertTrue(try ReconstructionReceiptAuthority.finalResultHasCanonicalIdentity(result))

        let commitment = try ReconstructionFinalResultCommitment(
            resultID: result.resultID,
            canonicalSHA256: result.canonicalSHA256
        )
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: result.modelReceiptID,
            jobID: result.jobID,
            taskID: result.taskID,
            checkpointRevision: result.checkpointRevision,
            requestIdentitySHA256: result.requestIdentitySHA256,
            producer: result.producer,
            terminalState: .completed,
            selectedHandleIDs: [],
            acceptedEvidenceIDs: result.citedEvidenceIDs,
            diagnostic: nil,
            finalResultCommitment: commitment
        )
        XCTAssertEqual(receipt.finalResultCommitment, commitment)
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))

        let substitutedPayload = Data("A different final synthesis.".utf8)
        let tampered = try ReconstructionFinalResultRecord(
            resultID: result.resultID,
            schemaVersion: result.schemaVersion,
            jobID: result.jobID,
            taskID: result.taskID,
            checkpointID: result.checkpointID,
            checkpointRevision: result.checkpointRevision,
            requestID: result.requestID,
            requestIdentitySHA256: result.requestIdentitySHA256,
            kind: result.kind,
            payloadUTF8: substitutedPayload,
            payloadByteCount: UInt64(substitutedPayload.count),
            payloadSHA256: result.payloadSHA256,
            citedEvidenceIDs: result.citedEvidenceIDs,
            producer: result.producer,
            modelReceiptID: result.modelReceiptID,
            canonicalSHA256: result.canonicalSHA256
        )
        XCTAssertFalse(try ReconstructionReceiptAuthority.finalResultHasCanonicalIdentity(tampered))
    }

    func testLegacyEmptyEvidenceManifestPreservesAbsentFinalResultsKeyByteForByte() throws {
        let legacy = Data(
            #"{"evidence":[],"evidenceGaps":[],"evidenceRelations":[],"modelReceipts":[],"schemaVersion":1,"toolReceipts":[]}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            ReconstructionPackageEvidenceManifest.self,
            from: legacy
        )
        XCTAssertTrue(decoded.finalResults.isEmpty)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(decoded), legacy)

        let producer = try makeProducer()
        let result = try ReconstructionReceiptAuthority.makeFinalResult(
            resultID: uuid(70),
            jobID: uuid(71),
            taskID: uuid(72),
            checkpointID: uuid(73),
            checkpointRevision: 74,
            requestID: uuid(75),
            requestIdentitySHA256: digest("b"),
            kind: .insufficientEvidence,
            payloadUTF8: Data("Insufficient durable evidence.".utf8),
            citedEvidenceIDs: [],
            producer: producer,
            modelReceiptID: uuid(75)
        )
        let manifest = try ReconstructionPackageEvidenceManifest(
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            toolReceipts: [],
            modelReceipts: [],
            finalResults: [result]
        )
        let encoded = try ReconstructionCanonicalJSON.encode(manifest)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""finalResults""#))
    }

    func testPackageAdmissionRecomputesTheToolReceiptDigest() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        let receipt = try XCTUnwrap(fixture.state.toolReceipts.first)
        let tampered = try ReconstructionToolReceipt(
            receiptID: receipt.receiptID,
            jobID: receipt.jobID,
            taskID: receipt.taskID,
            checkpointRevision: receipt.checkpointRevision,
            requestIdentitySHA256: receipt.requestIdentitySHA256,
            producer: receipt.producer,
            terminalState: receipt.terminalState,
            outputEvidenceIDs: receipt.outputEvidenceIDs,
            diagnostic: .sanitizing("tampered after receipt creation"),
            canonicalSHA256: receipt.canonicalSHA256
        )
        let hostile = try ReconstructionWorkspaceState(
            schemaVersion: fixture.state.schemaVersion,
            projects: fixture.state.projects,
            corpusManifests: fixture.state.corpusManifests,
            evidence: fixture.state.evidence,
            evidenceRelations: fixture.state.evidenceRelations,
            evidenceGaps: fixture.state.evidenceGaps,
            jobs: fixture.state.jobs,
            tasks: fixture.state.tasks,
            checkpoints: fixture.state.checkpoints,
            toolReceipts: [tampered],
            modelReceipts: fixture.state.modelReceipts
        )

        XCTAssertThrowsError(try ReconstructionPackageCodec.encode(hostile)) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("tool receipt digest")
            )
        }
    }

    func testModelProducerIdentityBindsEveryConfigurationFieldButNotProviderRevision() throws {
        let configuration = try makeConfiguration()
        let context = ReconstructionModelProducerIdentityContext(
            macScopeBuildIdentity: "macscope-build-receipt-authority",
            macScopeSourceIdentity: "macscope-source-receipt-authority",
            operationIdentity: "model.synthesis",
            registryIdentity: "reconstruction.v1",
            protocolIdentity: "reconstruction.r1",
            toolchainIdentity: "xcode-27-swift-6"
        )
        let inventorySHA256 = digest("d")
        let first = try ReconstructionReceiptAuthority.makeModelProducerIdentity(
            lease: .init(
                providerRevision: 1,
                configuration: configuration,
                observedModelInventorySHA256: inventorySHA256
            ),
            context: context
        )
        let sameConfigurationAtAnotherRevision = try ReconstructionReceiptAuthority
            .makeModelProducerIdentity(
                lease: .init(
                    providerRevision: 999,
                    configuration: configuration,
                    observedModelInventorySHA256: inventorySHA256
                ),
                context: context
            )

        XCTAssertEqual(first, sameConfigurationAtAnotherRevision)
        XCTAssertEqual(first.modelKey, configuration.model)
        XCTAssertEqual(first.endpointOrigin, configuration.endpointOrigin)
        XCTAssertEqual(first.observedModelInventorySHA256, inventorySHA256)
        XCTAssertEqual(
            first.observedConfigurationSHA256,
            try ReconstructionCanonicalJSON.sha256(of: ConfigurationPreimage(
                schemaVersion: ReconstructionReceiptAuthority
                    .modelConfigurationIdentitySchemaVersion,
                profileID: configuration.profileID,
                endpointOrigin: configuration.endpointOrigin,
                model: configuration.model,
                maximumTokens: configuration.maximumTokens,
                requestTimeoutMilliseconds: configuration.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: configuration.resourceTimeoutMilliseconds
            ))
        )
        XCTAssertEqual(
            first.canonicalSHA256,
            try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(first)
        )

        let sameDurableConfigurationAtAnotherConnectionGeneration = try
            ReconstructionReceiptAuthority.makeModelProducerIdentity(
                lease: .init(
                    providerRevision: 1_000,
                    configuration: makeConfiguration(generation: 3),
                    observedModelInventorySHA256: inventorySHA256
                ),
                context: context
            )
        XCTAssertEqual(first, sameDurableConfigurationAtAnotherConnectionGeneration)

        let changedConfigurations = try [
            makeConfiguration(profileID: uuid(41)),
            makeConfiguration(endpointOrigin: "http://127.0.0.1:1235"),
            makeConfiguration(model: "fixture-model-v2"),
            makeConfiguration(maximumTokens: 2_048),
            makeConfiguration(requestTimeoutMilliseconds: 11_000),
            makeConfiguration(resourceTimeoutMilliseconds: 61_000),
        ]
        for changed in changedConfigurations {
            XCTAssertNotEqual(
                first.observedConfigurationSHA256,
                try ReconstructionReceiptAuthority.canonicalModelConfigurationSHA256(changed)
            )
        }
    }

    func testObservedInventoryIdentityExcludesConnectionAndInstanceIDsButBindsConfiguration() throws {
        let first = try makeInventory(
            generation: 1,
            instanceID: "runtime-instance-a",
            effectiveContextLength: 8_192
        )
        let reconnected = try makeInventory(
            generation: 99,
            instanceID: "runtime-instance-b",
            effectiveContextLength: 8_192
        )
        let changedConfiguration = try makeInventory(
            generation: 99,
            instanceID: "runtime-instance-b",
            effectiveContextLength: 4_096
        )

        XCTAssertEqual(
            Phase2LocalModelInventoryIdentity.canonicalSHA256(first),
            Phase2LocalModelInventoryIdentity.canonicalSHA256(reconnected)
        )
        XCTAssertNotEqual(
            Phase2LocalModelInventoryIdentity.canonicalSHA256(first),
            Phase2LocalModelInventoryIdentity.canonicalSHA256(changedConfiguration)
        )
    }

    private func makeProducer() throws -> ReconstructionProducerIdentity {
        let provisional = try ReconstructionProducerIdentity(
            macScopeBuildIdentity: "macscope-build-receipt-authority",
            macScopeSourceIdentity: "macscope-source-receipt-authority",
            operationIdentity: "function.review",
            registryIdentity: "reconstruction.v1",
            protocolIdentity: "reconstruction.r1",
            nativeProviderIdentity: "native-provider-v1",
            nativeCapabilityIdentities: ["capability-b", "capability-a"],
            modelKey: "fixture-model",
            endpointOrigin: "http://127.0.0.1:1234",
            observedModelInventorySHA256: digest("e"),
            observedConfigurationSHA256: digest("f"),
            toolchainIdentity: "xcode-27-swift-6",
            canonicalSHA256: digest("0")
        )
        return try ReconstructionProducerIdentity(
            schemaVersion: provisional.schemaVersion,
            macScopeBuildIdentity: provisional.macScopeBuildIdentity,
            macScopeSourceIdentity: provisional.macScopeSourceIdentity,
            operationIdentity: provisional.operationIdentity,
            registryIdentity: provisional.registryIdentity,
            protocolIdentity: provisional.protocolIdentity,
            nativeProviderIdentity: provisional.nativeProviderIdentity,
            nativeCapabilityIdentities: provisional.nativeCapabilityIdentities,
            modelKey: provisional.modelKey,
            endpointOrigin: provisional.endpointOrigin,
            observedModelInventorySHA256: provisional.observedModelInventorySHA256,
            observedConfigurationSHA256: provisional.observedConfigurationSHA256,
            toolchainIdentity: provisional.toolchainIdentity,
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(provisional)
        )
    }

    private func makeConfiguration(
        profileID: UUID? = nil,
        generation: UInt64 = 2,
        endpointOrigin: String = "http://127.0.0.1:1234",
        model: String = "fixture-model",
        maximumTokens: Int = 1_024,
        requestTimeoutMilliseconds: Int = 10_000,
        resourceTimeoutMilliseconds: Int = 60_000
    ) throws -> Phase2AIProviderConfiguration {
        try Phase2AIProviderConfiguration(
            profileID: profileID ?? uuid(40),
            generation: generation,
            endpointOrigin: endpointOrigin,
            model: model,
            maximumTokens: maximumTokens,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: resourceTimeoutMilliseconds
        )
    }

    private func makeInventory(
        generation: UInt64,
        instanceID: String,
        effectiveContextLength: Int
    ) throws -> Phase2LocalModelInventory {
        try Phase2LocalModelInventory(
            profileID: uuid(70),
            generation: generation,
            models: [
                Phase2LocalModelDescriptor(
                    type: .language,
                    publisher: "Fixture Publisher",
                    key: "fixture-model",
                    displayName: "Fixture Model",
                    architecture: "fixture-arch",
                    quantization: .init(name: "Q8", bitsPerWeight: 8),
                    sizeBytesOnDisk: 1_024,
                    parameterCountDescription: "1B",
                    maximumContextLength: 16_384,
                    format: .mlx,
                    capabilities: .init(
                        supportsVision: false,
                        trainedForToolUse: true,
                        reasoning: .init(allowedOptions: [.off, .on], defaultOption: .on)
                    ),
                    summary: "fixture",
                    variants: ["base"],
                    providerSelectedVariant: "base",
                    loadedInstances: [
                        .init(
                            id: instanceID,
                            configuration: .init(
                                effectiveContextLength: effectiveContextLength,
                                evaluationBatchSize: 128,
                                parallelPredictions: 1,
                                flashAttention: true,
                                expertCount: nil,
                                offloadsKVCacheToGPU: true
                            )
                        )
                    ]
                )
            ]
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: character, count: 64)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "a7000000-0000-0000-0000-%012d", value))!
    }
}

private struct ToolPreimage: Encodable {
    let schemaVersion: Int
    let receiptID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let requestIdentitySHA256: String
    let producer: ReconstructionProducerIdentity
    let terminalState: ReconstructionReceiptTerminalState
    let outputEvidenceIDs: [UUID]
    let diagnostic: ReconstructionDiagnostic?
}

private struct ModelPreimage: Encodable {
    let schemaVersion: Int
    let receiptID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let requestIdentitySHA256: String
    let producer: ReconstructionProducerIdentity
    let terminalState: ReconstructionReceiptTerminalState
    let selectedHandleIDs: [String]
    let acceptedEvidenceIDs: [UUID]
    let diagnostic: ReconstructionDiagnostic?
}

private struct FinalResultPreimage: Encodable {
    let resultID: UUID
    let schemaVersion: Int
    let jobID: UUID
    let taskID: UUID
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let requestID: UUID
    let requestIdentitySHA256: String
    let kind: ReconstructionFinalSynthesisKind
    let payloadUTF8: Data
    let payloadByteCount: UInt64
    let payloadSHA256: String
    let citedEvidenceIDs: [UUID]
    let producer: ReconstructionProducerIdentity
    let modelReceiptID: UUID
}

private struct ConfigurationPreimage: Encodable {
    let schemaVersion: Int
    let profileID: UUID
    let endpointOrigin: String
    let model: String
    let maximumTokens: Int
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
}
