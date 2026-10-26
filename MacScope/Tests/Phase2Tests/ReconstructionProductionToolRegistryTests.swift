import Foundation
import XCTest

@testable import MacScope

final class ReconstructionProductionToolRegistryTests: XCTestCase {
    private let operationIDs = [
        "reconstruction.corpus.summary",
        "reconstruction.corpus.artifacts.page",
        "reconstruction.corpus.artifact.describe",
        "reconstruction.corpus.relations.page",
        "reconstruction.corpus.search",
        "reconstruction.images.page",
        "reconstruction.functions.page",
        "reconstruction.function.review",
        "reconstruction.decompiler.native",
        "reconstruction.decompiler.macscope",
        "reconstruction.decompiler.compare",
        "reconstruction.evidence.query",
        "reconstruction.evidence.get",
        "reconstruction.gaps.page",
        "reconstruction.checkpoint.status",
        "reconstruction.analysis.macscope.refresh",
    ]

    func testCatalogFreezesOperationOrderPriorityFunctionNamesAndIdentity() throws {
        let registry = Phase2ReconstructionProductionToolRegistry()
        let appEntries = ReconstructionAppToolCatalog.entries
        let workerEntries = Phase2ReconstructionProductionToolRegistry.orderedMetadata

        let ordinaryOperations = ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation }
        XCTAssertEqual(ordinaryOperations.map(\.rawValue), operationIDs)
        XCTAssertEqual(ordinaryOperations.map(\.priority), Array(0...15))
        XCTAssertEqual(registry.entries.map { $0.operationID.rawValue }, operationIDs)
        XCTAssertEqual(
            registry.entries.map(\.functionName),
            operationIDs.map { "macscope_\($0.replacingOccurrences(of: ".", with: "_"))_v1" }
        )
        XCTAssertEqual(Phase2ReconstructionProductionToolRegistry.registryID, "reconstruction.v1")
        XCTAssertEqual(Phase2ReconstructionProductionToolRegistry.registryVersion, 1)
        XCTAssertEqual(
            Phase2ReconstructionProductionToolRegistry.schemaSetID,
            "reconstruction.v1.schemas"
        )
        XCTAssertEqual(Phase2ReconstructionProductionToolRegistry.schemaSetVersion, 1)
        XCTAssertEqual(ReconstructionAppToolCatalog.registryID, Phase2ReconstructionProductionToolRegistry.registryID)
        XCTAssertEqual(ReconstructionAppToolCatalog.registryVersion, Phase2ReconstructionProductionToolRegistry.registryVersion)
        XCTAssertEqual(ReconstructionAppToolCatalog.schemaSetID, Phase2ReconstructionProductionToolRegistry.schemaSetID)
        XCTAssertEqual(ReconstructionAppToolCatalog.schemaSetVersion, Phase2ReconstructionProductionToolRegistry.schemaSetVersion)
        XCTAssertEqual(
            appEntries.map { $0.operationID.rawValue },
            workerEntries.map { $0.operationID.rawValue }
        )
        XCTAssertEqual(appEntries.map(\.functionName), workerEntries.map(\.functionName))
        XCTAssertEqual(appEntries.map(\.description), workerEntries.map(\.description))
        XCTAssertEqual(
            appEntries.map { $0.operationID.priority },
            workerEntries.map { $0.operationID.priority }
        )
    }

    func testWorkerProjectionAcceptsOnlyOfferedHandlesAndUsesCatalogOrder() throws {
        let first = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let second = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let tools = try Phase2ReconstructionProductionToolRegistry().project([
            .init(handleID: second, operationID: .checkpointStatus),
            .init(handleID: first, operationID: .corpusSummary),
        ])

        XCTAssertEqual(tools.map { $0.operationID.rawValue }, [
            "reconstruction.corpus.summary",
            "reconstruction.checkpoint.status",
        ])
        XCTAssertEqual(
            String(decoding: tools[0].parameters.canonicalJSONBytes(), as: UTF8.self),
            #"{"additionalProperties":false,"properties":{"handle_id":{"enum":["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"],"type":"string"}},"required":["handle_id"],"type":"object"}"#
        )
        XCTAssertEqual(tools.map(\.handleID), [first, second])
    }

    func testWorkerProjectionRejectsEmptyUnknownDuplicateUUIDAndDuplicateOperation() throws {
        let first = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let second = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let registry = Phase2ReconstructionProductionToolRegistry()

        XCTAssertThrowsError(try registry.project([])) {
            XCTAssertEqual($0 as? Phase2ReconstructionToolRegistryError, .invalidHandleSet)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            ReconstructionOfferedToolHandle.self,
            from: Data(#"{"handleID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","operationID":"reconstruction.unknown"}"#.utf8)
        ))
        XCTAssertThrowsError(try registry.project([
            .init(handleID: first, operationID: .corpusSummary),
            .init(handleID: first, operationID: .checkpointStatus),
        ])) {
            XCTAssertEqual($0 as? Phase2ReconstructionToolRegistryError, .duplicateHandle)
        }
        XCTAssertThrowsError(try registry.project([
            .init(handleID: first, operationID: .corpusSummary),
            .init(handleID: second, operationID: .corpusSummary),
        ])) {
            XCTAssertEqual($0 as? Phase2ReconstructionToolRegistryError, .duplicateOperation)
        }
    }

    func testProviderSchemaRejectsUnknownDuplicateAndCallerChosenAuthority() throws {
        let handle = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let tool = try XCTUnwrap(Phase2ReconstructionProductionToolRegistry().project([
            .init(handleID: handle, operationID: .evidenceQuery),
        ]).first)
        let schema = String(decoding: tool.parameters.canonicalJSONBytes(), as: UTF8.self)
        let prohibited = [
            "path", "sql", "address", "artifact_id", "query", "search", "cursor",
            "page", "limit", "byte", "shell", "build", "launch", "debugger", "filesystem",
        ]
        for word in prohibited {
            XCTAssertFalse(schema.lowercased().contains(word), "schema exposed \(word)")
        }

        XCTAssertThrowsError(try Phase2ReconstructionProductionToolRegistry().validateArguments(
            Data(#"{"handle_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","path":"/tmp/x"}"#.utf8),
            for: tool
        )) {
            XCTAssertEqual($0 as? Phase2ReconstructionToolRegistryError, .invalidArguments)
        }
        XCTAssertThrowsError(try Phase2ReconstructionProductionToolRegistry().validateArguments(
            Data(#"{"handle_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","handle_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}"#.utf8),
            for: tool
        )) {
            XCTAssertEqual($0 as? Phase2ReconstructionToolRegistryError, .invalidArguments)
        }
    }

    func testProviderArgumentsAcceptOnlyExactUnescapedUppercaseHandleID() throws {
        let handle = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let tool = try XCTUnwrap(Phase2ReconstructionProductionToolRegistry().project([
            .init(handleID: handle, operationID: .corpusSummary),
        ]).first)
        let registry = Phase2ReconstructionProductionToolRegistry()

        XCTAssertNoThrow(try registry.validateArguments(
            Data(#"{"handle_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}"#.utf8),
            for: tool
        ))
        XCTAssertThrowsError(try registry.validateArguments(
            Data(#"{"handle_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}"#.utf8),
            for: tool
        )) {
            XCTAssertEqual($0 as? Phase2ReconstructionToolRegistryError, .invalidArguments)
        }
        XCTAssertThrowsError(try registry.validateArguments(
            Data(#"{"handle_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAA\u0041"}"#.utf8),
            for: tool
        )) {
            XCTAssertEqual($0 as? Phase2ReconstructionToolRegistryError, .invalidArguments)
        }
    }

    func testExactUInt64SchemaUsesNumericConstWithoutDisturbingStringSchemas() throws {
        XCTAssertEqual(
            String(
                decoding: try Phase2ProductionJSONSchema.exactUInt64(UInt64.max)
                    .canonicalJSONBytes(),
                as: UTF8.self
            ),
            #"{"enum":[18446744073709551615],"type":"integer"}"#
        )
        XCTAssertEqual(
            String(
                decoding: try Phase2ProductionJSONSchema.string(enumeration: ["7"])
                    .canonicalJSONBytes(),
                as: UTF8.self
            ),
            #"{"enum":["7"],"type":"string"}"#
        )
    }

    func testReconstructionArtifactIdentitiesAreExactAndDoNotMutateAuthorizedAssistantR2() throws {
        let before = Phase2ProductionProtocolArtifacts.make(registryVersion: .assistantR2)
        let artifacts = Phase2ReconstructionProtocolArtifacts.make()
        let after = Phase2ProductionProtocolArtifacts.make(registryVersion: .assistantR2)

        XCTAssertEqual(before, after)
        XCTAssertEqual(
            before.readToolRegistry.sha256,
            "d1d1050c9624f4ede203f7a362b40432f06f08d2ef41d356bfc809fc2c0a8387"
        )
        XCTAssertEqual(before.promptModules.map(\.sha256), [
            "32757c0ee797e5b2c76e55bdf62dc59124a973caa7d562f595f9f4310e9652f7",
            "a96739aa3f11055b77213b4572891f7fc854da0e6e15c2d61773b3bf10f7c947",
            "435edf290f2e036c876963b2d7cffcba27c9a62c56325a0fd82395607ff232f7",
            "1f524d349ef8e1cfac66d6a2dd13a156cd866f59017161e647d8c5cd5381a370",
        ])
        XCTAssertEqual(
            before.finalOutputSchema.sha256,
            "e4717ea2bf4850a82bd44f0c9fa96787aa64e3e4448d5a981ba9a34726e4d2e9"
        )
        XCTAssertEqual(artifacts.all.map(\.identity.sha256), [
            "bc3470397877978412bb14a469fb8462827f1fee891ab8c816a3ae9d64cd1be3",
            "fe5ea6fcf20eea7b4879f14ca6578f561b89afd519eef04a9a22d24529cbbde5",
            "1336c2f939d7d59dc3de1044ab34671edae42568e98afaf635b381214dc274ac",
            "5b7153c8a3cc4663340d0ff83a6ed2b61d2f1e9e6f9d443ca3464c2c0e7078c5",
            "32c981f514aff96f6fc60c7ad5eab4b214cb94ae2723e95afc922cf1a7021ee5",
            "9e4fee4bcea09ed0fc1d854da849676b193b73e11cecf31825a8b22734e5ebf1",
            "706c03520ba68adb0dd6ac21981e8f01e0bcd6118649aecfac9e29124e1ea143",
            "e0a3c6a12830971352c8d9b380c5e02634abe83790ace20e430d7e9996647094",
        ])
        XCTAssertEqual(artifacts.all.map(\.canonicalBytes.count), [
            3_165, 4_790, 1_744, 1_291, 238, 214, 502, 229,
        ])
    }

    func testDynamicRoundAndFinalSchemasEnumerateOnlySuppliedValues() throws {
        let job = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let round = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let handle = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let evidence = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let gap = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        let roundSchema = try Phase2ReconstructionOutputSchemas.roundProviderSchema(
            jobID: job,
            checkpointRevision: 7,
            roundID: round,
            offeredHandles: [.init(handleID: handle, operationID: .corpusSummary)],
            allowedGapSubjects: ["function-B", "function-A"],
            allowedGapCategories: ["missing-type", "missing-branch"],
            allowedGapIDs: [gap],
            retrievedEvidenceIDs: [evidence]
        )
        let roundBytes = String(decoding: roundSchema.canonicalJSONBytes(), as: UTF8.self)
        XCTAssertTrue(roundBytes.contains(job.uuidString))
        XCTAssertTrue(roundBytes.contains(round.uuidString))
        XCTAssertTrue(roundBytes.contains(handle.uuidString))
        XCTAssertTrue(roundBytes.contains(gap.uuidString))
        XCTAssertTrue(roundBytes.contains("function-A"))
        XCTAssertTrue(roundBytes.contains("function-B"))
        XCTAssertTrue(roundBytes.contains("missing-branch"))
        XCTAssertTrue(roundBytes.contains("missing-type"))
        XCTAssertTrue(roundBytes.contains(#""unresolved_gaps""#))
        XCTAssertTrue(roundBytes.contains(#""resolved_gaps""#))
        XCTAssertTrue(roundBytes.contains(
            #""checkpoint_revision":{"enum":[7],"type":"integer"}"#
        ))
        XCTAssertFalse(roundBytes.contains(#""checkpoint_revision":{"enum":["7"]"#))
        XCTAssertTrue(roundBytes.contains(#""reason":{"maxLength":1024,"minLength":1,"type":"string"}"#))
        XCTAssertEqual(roundBytes.components(separatedBy: #""additionalProperties":false"#).count - 1, 3)
        XCTAssertTrue(roundBytes.contains(evidence.uuidString))
        XCTAssertFalse(roundBytes.contains("accepted_evidence_ids"))
        XCTAssertFalse(roundBytes.contains("unresolved_gap_ids"))
        XCTAssertFalse(roundBytes.contains("canonicalRequest"))
        XCTAssertFalse(roundBytes.contains("requestSHA256"))

        let finalSchema = try Phase2ReconstructionOutputSchemas.finalSynthesisProviderSchema(
            evidenceIDs: [evidence]
        )
        let finalBytes = String(decoding: finalSchema.canonicalJSONBytes(), as: UTF8.self)
        XCTAssertTrue(finalBytes.contains(evidence.uuidString))
        XCTAssertTrue(finalBytes.contains(#""anyOf""#))
        XCTAssertTrue(finalBytes.contains(#""enum":["synthesis"]"#))
        XCTAssertTrue(finalBytes.contains(#""enum":["insufficientEvidence"]"#))
        XCTAssertTrue(finalBytes.contains(#""minItems":1"#))
        XCTAssertTrue(finalBytes.contains(#""maxItems":0"#))
        XCTAssertTrue(finalBytes.contains(#""maxLength":4096"#))
        XCTAssertFalse(finalBytes.contains("handle"))
        XCTAssertFalse(finalBytes.contains("tool"))
        XCTAssertFalse(finalBytes.contains(job.uuidString))

        let emptyEvidenceSchema = try Phase2ReconstructionOutputSchemas
            .finalSynthesisProviderSchema(evidenceIDs: [])
        let emptyEvidenceBytes = String(
            decoding: emptyEvidenceSchema.canonicalJSONBytes(),
            as: UTF8.self
        )
        XCTAssertFalse(emptyEvidenceBytes.contains(#""synthesis""#))
        XCTAssertTrue(emptyEvidenceBytes.contains(#""insufficientEvidence""#))
        XCTAssertTrue(emptyEvidenceBytes.contains(#""maxItems":0"#))
    }

    func testFrozenRoundAndFinalBlueprintsAreCompleteClosedSymbolicSchemas() throws {
        let roundRoot = try XCTUnwrap(
            Phase2ReconstructionOutputSchemas.roundBlueprint.objectValue
        )
        XCTAssertEqual(roundRoot["type"], .string("object"))
        XCTAssertEqual(roundRoot["additionalProperties"], .bool(false))
        let roundProperties = try XCTUnwrap(roundRoot["properties"]?.objectValue)
        let roundRequired = try XCTUnwrap(roundRoot["required"]?.arrayValue)
        XCTAssertEqual(
            Set(roundRequired.compactMap(\.stringValue)),
            Set(roundProperties.keys)
        )
        XCTAssertEqual(roundRequired.count, roundProperties.count)
        XCTAssertEqual(
            roundProperties["checkpoint_revision"]?.objectValue?["type"],
            .string("integer")
        )
        XCTAssertEqual(
            roundProperties["checkpoint_revision"]?.objectValue?["enum_source"],
            .string("exact-supplied-checkpoint-revision")
        )

        let finalRoot = try XCTUnwrap(
            Phase2ReconstructionOutputSchemas.finalBlueprint.objectValue
        )
        XCTAssertEqual(finalRoot["type"], .string("object"))
        XCTAssertEqual(finalRoot["additionalProperties"], .bool(false))
        let finalProperties = try XCTUnwrap(finalRoot["properties"]?.objectValue)
        let finalRequired = try XCTUnwrap(finalRoot["required"]?.arrayValue)
        XCTAssertEqual(
            Set(finalRequired.compactMap(\.stringValue)),
            Set(finalProperties.keys)
        )
        let alternatives = try XCTUnwrap(finalRoot["anyOf"]?.arrayValue)
        XCTAssertEqual(alternatives.count, 2)
        for alternative in alternatives {
            let object = try XCTUnwrap(alternative.objectValue)
            XCTAssertEqual(object["type"], .string("object"))
            XCTAssertEqual(object["additionalProperties"], .bool(false))
            let properties = try XCTUnwrap(object["properties"]?.objectValue)
            let required = try XCTUnwrap(object["required"]?.arrayValue)
            XCTAssertEqual(Set(required.compactMap(\.stringValue)), Set(properties.keys))
            XCTAssertEqual(required.count, properties.count)
        }
        let finalBytes = String(
            decoding: Phase2ReconstructionOutputSchemas.finalBlueprint.canonicalJSONBytes(),
            as: UTF8.self
        )
        XCTAssertTrue(finalBytes.contains(#""enum":["synthesis"]"#))
        XCTAssertTrue(finalBytes.contains(#""enum":["insufficientEvidence"]"#))
        XCTAssertTrue(finalBytes.contains(#""maxItems":0"#))
        XCTAssertTrue(finalBytes.contains(#""minItems":1"#))
    }

    func testSystemPromptModulesNeverInterpolateUserOrAuthorityCutText() {
        let catalog = Phase2ReconstructionPromptCatalog()
        let untrusted = "USER_TEXT_\(UUID().uuidString)"
        let system = catalog.systemPrompt(for: .planReadObserve)

        XCTAssertEqual(catalog.modules.map(\.id), [
            "reconstruction.authority.v1",
            "reconstruction.evidence.v1",
            "reconstruction.plan-read-observe.v8",
            "reconstruction.final-synthesis.v1",
        ])
        XCTAssertEqual(
            catalog.modules[2].content,
            "Plan from the supplied checkpoint, select only exact offered handle IDs, "
                + "observe terminal results, declare only bounded unresolved gaps using "
                + "supplied subjects and categories, and identify a resolved durable gap only "
                + "by its supplied gap ID, the selected handle ID that produced it, and the exact "
                + "evidence ID present in that handle's retrieved packet. "
                + "Never choose operation arguments or infer a resolution from subject text."
        )
        XCTAssertTrue(catalog.modules[2].content.contains("gap ID"))
        XCTAssertTrue(catalog.modules[2].content.contains("evidence ID"))
        XCTAssertFalse(system.contains(untrusted))
        XCTAssertFalse(catalog.systemPrompt(for: .finalSynthesis).contains(untrusted))
    }

    func testRoundSchemaRepresentsAnEmptyGapDeclarationUniverse() throws {
        let schema = try Phase2ReconstructionOutputSchemas.roundProviderSchema(
            jobID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            checkpointRevision: 7,
            roundID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            offeredHandles: [],
            allowedGapSubjects: [],
            allowedGapCategories: [],
            allowedGapIDs: [],
            retrievedEvidenceIDs: []
        )
        let bytes = String(decoding: schema.canonicalJSONBytes(), as: UTF8.self)

        XCTAssertTrue(bytes.contains(#""unresolved_gaps":{"items":{"additionalProperties":false"#))
        XCTAssertTrue(bytes.contains(#""resolved_gaps":{"items":{"additionalProperties":false"#))
        XCTAssertTrue(bytes.contains(#""maxItems":0"#))
        XCTAssertEqual(bytes.components(separatedBy: #""additionalProperties":false"#).count - 1, 3)
    }
}
