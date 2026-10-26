import Foundation
import XCTest

final class Phase2ProductionToolRegistryTests: XCTestCase {
    func testRegistryContainsWorkspaceAndExactDebuggerReadsInFrozenOrder() throws {
        let registry = Phase2ProductionToolRegistry(version: .assistantR2)

        XCTAssertEqual(registry.entries.map(\.operationID), [
            "workspace.summary",
            "selection.explain",
            "function.review",
            "decompiler.native.result",
            "decompiler.macscope.result",
            "decompiler.compare",
            "debugger.summary",
            "debugger.frames",
            "debugger.registers",
            "debugger.variables",
            "debugger.memory",
            "rea.results.list",
            "rea.results.get",
        ])
        XCTAssertEqual(registry.entries.map(\.functionName), [
            "macscope_workspace_summary_v1",
            "macscope_selection_explain_v1",
            "macscope_function_review_v1",
            "macscope_native_decompilation_v1",
            "macscope_decompilation_v1",
            "macscope_decompiler_compare_v1",
            "macscope_debugger_summary_v1",
            "macscope_debugger_frames_v1",
            "macscope_debugger_registers_v1",
            "macscope_debugger_variables_v1",
            "macscope_debugger_memory_v1",
            "macscope_rea_results_list_v1",
            "macscope_rea_results_get_v1",
        ])
        XCTAssertEqual(Set(registry.entries.map(\.functionName)).count, 13)
        XCTAssertNil(registry.entry(forOperationID: "filesystem.read"))
        XCTAssertNil(registry.entry(forFunctionName: "workspace.summary"))
    }

    func testQualificationRegistryRetainsFrozenR1WorkspaceOnlySurface() {
        let registry = Phase2ProductionToolRegistry(version: .qualificationR1)

        XCTAssertEqual(registry.entries.map(\.operationID), [
            "workspace.summary",
            "selection.explain",
            "function.review",
            "decompiler.native.result",
            "decompiler.macscope.result",
            "decompiler.compare",
        ])
        XCTAssertEqual(Phase2ProductionToolRegistry.registryID, "phase2.r1.read-tools.v1")
        XCTAssertEqual(Phase2ProductionToolRegistry.assistantRegistryID, "phase2.r2.read-tools.v2")
    }

    func testDecompilerProjectionAcceptsOnlyExactAppIssuedHandles() throws {
        let nativeID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let macScopeID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let compareID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let tools = try Phase2ProductionToolRegistry(version: .assistantR2).project([
            .init(handleID: compareID, operationID: "decompiler.compare"),
            .init(handleID: nativeID, operationID: "decompiler.native.result"),
            .init(handleID: macScopeID, operationID: "decompiler.macscope.result"),
        ])

        XCTAssertEqual(tools.map(\.functionName), [
            "macscope_native_decompilation_v1",
            "macscope_decompilation_v1",
            "macscope_decompiler_compare_v1",
        ])
        for tool in tools {
            let schema = String(decoding: tool.parameters.canonicalJSONBytes(), as: UTF8.self)
            XCTAssertTrue(schema.contains(tool.handleID.uuidString))
            XCTAssertFalse(schema.contains("address"))
            XCTAssertFalse(schema.contains("function"))
            XCTAssertFalse(schema.contains("path"))
            XCTAssertFalse(schema.contains("image"))
        }
    }

    func testProjectionUsesOnlyExactCompatibleHandleEnum() throws {
        let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let selectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tools = try Phase2ProductionToolRegistry(version: .assistantR2).project([
            .init(handleID: selectionID, operationID: "selection.explain"),
            .init(handleID: workspaceID, operationID: "workspace.summary"),
        ])

        XCTAssertEqual(tools.map(\.functionName), [
            "macscope_workspace_summary_v1",
            "macscope_selection_explain_v1",
        ])
        XCTAssertEqual(
            String(decoding: tools[0].parameters.canonicalJSONBytes(), as: UTF8.self),
            #"{"additionalProperties":false,"properties":{"handle_id":{"enum":["00000000-0000-0000-0000-000000000001"],"type":"string"}},"required":["handle_id"],"type":"object"}"#
        )
        XCTAssertFalse(String(decoding: tools[0].parameters.canonicalJSONBytes(), as: UTF8.self).contains("address"))
        XCTAssertFalse(String(decoding: tools[0].parameters.canonicalJSONBytes(), as: UTF8.self).contains("path"))
    }

    func testProjectionRejectsEmptyUnknownDuplicateAndRepeatedOperationHandles() throws {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let registry = Phase2ProductionToolRegistry(version: .assistantR2)

        XCTAssertThrowsError(try registry.project([])) {
            XCTAssertEqual($0 as? Phase2ProductionToolRegistryError, .invalidHandleSet)
        }
        XCTAssertThrowsError(try registry.project([.init(handleID: id1, operationID: "unknown")])) {
            XCTAssertEqual($0 as? Phase2ProductionToolRegistryError, .unknownOperation)
        }
        XCTAssertThrowsError(try registry.project([
            .init(handleID: id1, operationID: "workspace.summary"),
            .init(handleID: id1, operationID: "selection.explain"),
        ])) {
            XCTAssertEqual($0 as? Phase2ProductionToolRegistryError, .duplicateHandle)
        }
        XCTAssertThrowsError(try registry.project([
            .init(handleID: id1, operationID: "workspace.summary"),
            .init(handleID: id2, operationID: "workspace.summary"),
        ])) {
            XCTAssertEqual($0 as? Phase2ProductionToolRegistryError, .duplicateOperation)
        }
    }

    func testSchemaSubsetRejectsDuplicatePropertiesInvalidBoundsAndControls() throws {
        XCTAssertThrowsError(try Phase2ProductionJSONSchema.object(
            properties: [
                .init(name: "x", schema: try .string(maxLength: 10)),
                .init(name: "x", schema: try .string(maxLength: 10)),
            ],
            required: ["x"]
        ))
        XCTAssertThrowsError(try Phase2ProductionJSONSchema.string(minLength: 2, maxLength: 1))
        XCTAssertThrowsError(try Phase2ProductionJSONSchema.array(
            items: .string(), minItems: 2, maxItems: 1, uniqueItems: false
        ))
        XCTAssertThrowsError(try Phase2ProductionJSONSchema.object(
            properties: [.init(name: "bad\nname", schema: try .string(maxLength: 10))], required: []
        ))
        XCTAssertThrowsError(try Phase2ProductionJSONSchema.string())
        let branch = try Phase2ProductionJSONSchema.object(
            properties: [.init(name: "kind", schema: try .string(enumeration: ["a"]))],
            required: ["kind"]
        )
        XCTAssertThrowsError(try Phase2ProductionJSONSchema.discriminatedObject(
            properties: [.init(name: "kind", schema: try .string(enumeration: ["a"]))],
            required: ["kind"],
            alternatives: []
        ))
        XCTAssertThrowsError(try Phase2ProductionJSONSchema.discriminatedObject(
            properties: [.init(name: "kind", schema: try .string(enumeration: ["a"]))],
            required: ["kind"],
            alternatives: [branch, branch]
        ))
    }

    func testStrictParserCanRequireExactUnescapedSourceSpellingForSelectedStringFields() throws {
        let canonical = Data(
            #"{"evidence_ids":["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"],"text":"line\ntext"}"#.utf8
        )
        _ = try Phase2StrictJSONParser().parse(
            canonical,
            requiringUnescapedStringValuesForObjectKeys: ["evidence_ids"]
        )

        let escapedHyphen = Data(
            #"{"evidence_ids":["AAAAAAAA\u002DAAAA-AAAA-AAAA-AAAAAAAAAAAA"]}"#.utf8
        )
        XCTAssertThrowsError(try Phase2StrictJSONParser().parse(
            escapedHyphen,
            requiringUnescapedStringValuesForObjectKeys: ["evidence_ids"]
        )) {
            XCTAssertEqual(
                $0 as? Phase2StrictJSONError,
                .nonCanonicalStringEncoding
            )
        }
    }

    func testCanonicalSchemaAndArtifactIdentitiesAreDeterministicAndSemantic() throws {
        let first = Phase2ProductionProtocolArtifacts.make()
        let second = Phase2ProductionProtocolArtifacts.make()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.readToolRegistry.id, "phase2.r1.read-tools.v1")
        XCTAssertEqual(first.finalOutputSchema.id, "phase2.r1.grounded-final.v1")
        XCTAssertEqual(first.qualificationPolicy.id, "phase2.r1.qualification-policy.v1")
        XCTAssertEqual(first.promptModules.map(\.id), [
            "macscope.authority.v1",
            "macscope.grounded-evidence.v1",
            "macscope.tool-selection.v1",
            "macscope.finalization.v1",
        ])
        XCTAssertTrue(first.allIdentities.allSatisfy { $0.sha256.count == 64 })

        let drifted = Phase2ProductionProtocolArtifacts.make(
            registryDescriptionSuffixForTesting: " changed"
        )
        XCTAssertNotEqual(first.readToolRegistry.sha256, drifted.readToolRegistry.sha256)
        XCTAssertEqual(first.finalOutputSchema.sha256, drifted.finalOutputSchema.sha256)
    }

    func testProbeCatalogIsFrozenDeterministicAndDriftSensitive() {
        let first = Phase2ProductionProtocolProbeCatalog()
        let second = Phase2ProductionProtocolProbeCatalog()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.probes.count, 99)
        XCTAssertEqual(first.probes.map(\.id), expectedProductionProbeIDs)
        XCTAssertEqual(Set(first.probes.map(\.id)).count, expectedProductionProbeIDs.count)
        XCTAssertTrue(first.probes.allSatisfy { !$0.acceptanceCriterion.isEmpty })
        XCTAssertEqual(
            first.probes.map(\.fixtureID.rawValue),
            expectedProductionProbeIDs.map { "phase2.fixture.\($0).v1" }
        )
        XCTAssertEqual(
            Set(first.probes.map(\.fixtureID)).count,
            expectedProductionProbeIDs.count
        )
        XCTAssertEqual(
            Set(first.probes.map(\.expectedOutcome)),
            Set(Phase2ProductionProtocolExpectedOutcome.allCases)
        )
        XCTAssertEqual(
            first.probes.filter { $0.expectedOutcome == .accepted }.count,
            34
        )
        let probesByID = Dictionary(uniqueKeysWithValues: first.probes.map { ($0.id, $0) })
        let plusOneProbes = first.probes.filter { $0.id.hasSuffix("-plus-one") }
        XCTAssertEqual(plusOneProbes.count, 16)
        for plusOne in plusOneProbes {
            let maximumID = String(plusOne.id.dropLast("-plus-one".count)) + "-maximum"
            let maximum = try! XCTUnwrap(probesByID[maximumID])
            XCTAssertEqual(maximum.expectedOutcome, .accepted)
            XCTAssertEqual(plusOne.expectedOutcome, .rejected)
            XCTAssertNotEqual(maximum.fixtureID, plusOne.fixtureID)
        }
        XCTAssertEqual(
            first.probes.filter { $0.expectedOutcome == .rejected }.count,
            55
        )
        XCTAssertEqual(
            first.probes.filter { $0.expectedOutcome == .identityChanged }.count,
            7
        )
        XCTAssertEqual(
            first.probes.filter { $0.expectedOutcome == .exactBytesMatched }.count,
            2
        )
        XCTAssertEqual(
            first.probes.filter {
                $0.expectedOutcome == .cancelledWithoutSemanticOutput
            }.count,
            1
        )
        XCTAssertEqual(
            first.qualificationPolicyIdentity,
            second.qualificationPolicyIdentity
        )
        XCTAssertEqual(
            first.qualificationPolicyIdentity.sha256,
            "7632aaeceb8a3b6946443f6d102233ad7abd95689a203115407ba27d6aaf33d5"
        )

        let mutations: [Phase2ProductionProtocolProbeCatalog.TestMutation] = [
            .id(index: 0, suffix: ".drift"),
            .category(index: 0, value: .identity),
            .expectedOutcome(index: 0, value: .rejected),
            .fixtureID(index: 0, suffix: ".drift"),
            .criterion(index: 0, suffix: " drift"),
            .swap(0, 1),
        ]
        for mutation in mutations {
            XCTAssertNotEqual(
                first.qualificationPolicyIdentity.sha256,
                Phase2ProductionProtocolProbeCatalog(mutationForTesting: mutation)
                    .qualificationPolicyIdentity.sha256
            )
        }
        XCTAssertNotEqual(
            first.qualificationPolicyIdentity.sha256,
            Phase2ProductionProtocolProbeCatalog(criterionSuffixForTesting: " drift")
                .qualificationPolicyIdentity.sha256
        )
    }

    func testProbeCatalogHasExactDisjointQualificationPartition() {
        let probes = Phase2ProductionProtocolProbeCatalog().probes
        let identityProbeIDs = Set(
            probes.lazy.filter { $0.id.hasPrefix("identity.") }.map(\.id)
        )
        let allProbeIDs = Set(probes.map(\.id))
        let protocolProbeIDs = allProbeIDs
            .subtracting(identityProbeIDs)
            .subtracting(expectedSafetyProbeIDs)

        XCTAssertEqual(
            identityProbeIDs,
            Set(expectedProductionProbeIDs.filter { $0.hasPrefix("identity.") })
        )
        XCTAssertEqual(identityProbeIDs.count, 7)
        XCTAssertEqual(protocolProbeIDs.count, 62)
        XCTAssertEqual(expectedSafetyProbeIDs.count, 30)
        XCTAssertEqual(identityProbeIDs.intersection(expectedSafetyProbeIDs), [])
        XCTAssertEqual(protocolProbeIDs.intersection(expectedSafetyProbeIDs), [])
        XCTAssertEqual(identityProbeIDs.intersection(protocolProbeIDs), [])
        XCTAssertEqual(
            identityProbeIDs.union(protocolProbeIDs).union(expectedSafetyProbeIDs),
            allProbeIDs
        )
        XCTAssertTrue(expectedSafetyProbeIDs.isSubset(of: allProbeIDs))
    }

    func testEveryArtifactConstituentIsDriftSensitiveAndOwnershipIsNarrow() {
        let baseline = Phase2ProductionProtocolArtifacts.make()
        let promptBytes = Phase2ProductionProtocolArtifacts.make(
            promptModuleSuffixForTesting: " drift"
        )
        XCTAssertNotEqual(baseline.promptModules, promptBytes.promptModules)
        XCTAssertEqual(baseline.readToolRegistry, promptBytes.readToolRegistry)

        let promptOrder = Phase2ProductionProtocolArtifacts.make(
            promptModuleOrderForTesting: [1, 0, 2, 3]
        )
        XCTAssertNotEqual(baseline.promptModules, promptOrder.promptModules)

        let registryOrder = Phase2ProductionProtocolArtifacts.make(
            registryOrderForTesting: [1, 0, 2]
        )
        XCTAssertNotEqual(baseline.readToolRegistry, registryOrder.readToolRegistry)
        XCTAssertEqual(baseline.finalOutputSchema, registryOrder.finalOutputSchema)

        let schemaSemantic = Phase2ProductionProtocolArtifacts.make(
            schemaEnumSourceForTesting: "drifted-handle-enum-source"
        )
        XCTAssertNotEqual(baseline.readToolRegistry, schemaSemantic.readToolRegistry)

        let schemaVersion = Phase2ProductionProtocolArtifacts.make(
            schemaSetVersionForTesting: "phase2.r1.read-tool-schemas.v2"
        )
        XCTAssertNotEqual(baseline.readToolRegistry, schemaVersion.readToolRegistry)

        let finalSemantic = Phase2ProductionProtocolArtifacts.make(
            finalSchemaForTesting: .object([
                "type": .string("object"),
                "drift": .bool(true),
            ])
        )
        XCTAssertNotEqual(baseline.finalOutputSchema, finalSemantic.finalOutputSchema)
        XCTAssertEqual(baseline.readToolRegistry, finalSemantic.readToolRegistry)

        let probe = Phase2ProductionProtocolArtifacts.make(
            probeMutationForTesting: .criterion(index: 0, suffix: " drift")
        )
        XCTAssertNotEqual(baseline.qualificationPolicy, probe.qualificationPolicy)
        XCTAssertEqual(baseline.promptModules, probe.promptModules)
    }
}

private let expectedSafetyProbeIDs: Set<String> = [
    "tool.atomic.id-mutation",
    "tool.atomic.type-mutation",
    "tool.atomic.name-mutation",
    "tool.argument.unknown",
    "tool.argument.duplicate",
    "tool.proposal.unoffered-name",
    "tool.proposal.invented-handle",
    "tool.proposal.repeated-handle",
    "tool.proposal.duplicate-call-id",
    "tool.output.content",
    "tool.output.final-answer",
    "tool.record.after-terminal",
    "tool.cancellation.partial",
    "final.evidence-id.lowercase",
    "final.evidence-id.mixed-case",
    "final.evidence-id.braced",
    "final.evidence-id.hyphenless",
    "final.evidence-id.padded",
    "final.evidence-id.other-parseable",
    "final.field.unknown",
    "final.field.duplicate",
    "final.variant.mixed",
    "final.citation.bad",
    "final.citation.duplicate",
    "final.citation.unallowed",
    "final.truncation",
    "final.prompt-injection-as-data",
    "final.tool-call",
    "limit.event-plus-one",
    "limit.cumulative-event-plus-one",
]

private let expectedProductionProbeIDs = [
    "tool.single.workspace-summary",
    "tool.single.selection-explain",
    "tool.single.function-review",
    "tool.multicall.two-ordered",
    "tool.multicall.three-ordered",
    "tool.multicall.interleaved",
    "tool.call-id.non-uuid",
    "tool.atomic.id-delayed",
    "tool.atomic.type-delayed",
    "tool.atomic.name-delayed",
    "tool.atomic.later-omission",
    "tool.atomic.id-mutation",
    "tool.atomic.type-mutation",
    "tool.atomic.name-mutation",
    "tool.arguments.fragmented",
    "tool.schema-name-handle-pairing",
    "tool.registry-order",
    "tool.argument.missing-required",
    "tool.argument.unknown",
    "tool.argument.duplicate",
    "tool.argument.wrong-type",
    "tool.argument.malformed",
    "tool.argument.trailing",
    "tool.proposal.unoffered-name",
    "tool.proposal.invented-handle",
    "tool.proposal.repeated-handle",
    "tool.proposal.duplicate-call-id",
    "tool.proposal.sparse-index",
    "tool.proposal.out-of-range-index",
    "json.ordinary.recursive-duplicate",
    "json.usage.recursive-duplicate",
    "json.ordinary.trailing",
    "json.usage.trailing",
    "json.sse.depth-maximum",
    "json.sse.depth-plus-one",
    "json.arguments.depth-maximum",
    "json.arguments.depth-plus-one",
    "json.final.depth-maximum",
    "json.final.depth-plus-one",
    "json.sse.tokens-maximum",
    "json.sse.tokens-plus-one",
    "json.arguments.tokens-maximum",
    "json.arguments.tokens-plus-one",
    "json.final.tokens-maximum",
    "json.final.tokens-plus-one",
    "json.sse.members-maximum",
    "json.sse.members-plus-one",
    "json.arguments.members-maximum",
    "json.arguments.members-plus-one",
    "json.final.members-maximum",
    "json.final.members-plus-one",
    "tool.output.content",
    "tool.output.final-answer",
    "tool.finish-reason.wrong",
    "tool.usage.incomplete",
    "tool.record.after-terminal",
    "tool.cancellation.partial",
    "request.tool-selection.byte-fixture",
    "request.finalization.byte-fixture",
    "final.answer",
    "final.insufficient-evidence",
    "final.evidence-id.lowercase",
    "final.evidence-id.mixed-case",
    "final.evidence-id.braced",
    "final.evidence-id.hyphenless",
    "final.evidence-id.padded",
    "final.evidence-id.other-parseable",
    "final.field.unknown",
    "final.field.duplicate",
    "final.variant.mixed",
    "final.citation.bad",
    "final.citation.duplicate",
    "final.citation.unallowed",
    "final.unicode",
    "final.long-output",
    "final.truncation",
    "final.prompt-injection-as-data",
    "final.tool-call",
    "identity.prompt-byte-drift",
    "identity.registry-description-drift",
    "identity.registry-order-drift",
    "identity.schema-semantic-drift",
    "identity.schema-set-version-drift",
    "identity.protocol-version-drift",
    "identity.probe-catalog-drift",
    "limit.preview-delta-maximum",
    "limit.preview-delta-plus-one",
    "limit.preview-cumulative-maximum",
    "limit.preview-cumulative-plus-one",
    "limit.answer-text-maximum",
    "limit.answer-text-plus-one",
    "limit.reason-maximum",
    "limit.reason-plus-one",
    "limit.final-envelope-maximum",
    "limit.final-envelope-plus-one",
    "limit.event-maximum",
    "limit.event-plus-one",
    "limit.cumulative-event-maximum",
    "limit.cumulative-event-plus-one",
]
