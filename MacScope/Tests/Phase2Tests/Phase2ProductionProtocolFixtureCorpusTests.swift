import Foundation
import XCTest

@testable import MacScope

final class Phase2ProductionProtocolFixtureCorpusTests: XCTestCase {
    func testRecipeExpectedOutcomesAreDerivedFromFrozenProbeCatalog() {
        let probes = MacScope.Phase2ProductionProtocolProbeCatalog().probes

        XCTAssertEqual(Phase2ProductionProtocolFixtureRecipe.allCases.count, probes.count)
        for (recipe, probe) in zip(Phase2ProductionProtocolFixtureRecipe.allCases, probes) {
            XCTAssertEqual(recipe.rawValue, probe.id)
            XCTAssertEqual(recipe.expectedOutcome, probe.expectedOutcome, probe.id)
        }
    }

    func testStandardCorpusBindsEveryFrozenDescriptorExactlyOnceInCatalogOrder() {
        let catalog = MacScope.Phase2ProductionProtocolProbeCatalog().probes
        let corpus = Phase2ProductionProtocolFixtureCorpus.standard

        XCTAssertEqual(corpus.entries.count, 99)
        XCTAssertEqual(corpus.entries.map(\.probeID), catalog.map(\.id))
        XCTAssertEqual(corpus.entries.map(\.fixtureID), catalog.map(\.fixtureID))
        XCTAssertEqual(Set(corpus.entries.map(\.fixtureID)).count, 99)
        XCTAssertEqual(Set(corpus.entries.map(\.recipe)).count, 99)
        XCTAssertEqual(corpus.identity.id, "phase2.r1.deterministic-fixture-corpus.v1")
        XCTAssertEqual(corpus.identity.version, 1)
        XCTAssertEqual(
            corpus.identity.sha256,
            Phase2ProductionQualificationPolicy.standard
                .deterministicFixtureCorpusIdentity.sha256
        )
        XCTAssertTrue(corpus.entries.allSatisfy { $0.subcaseCount > 0 })
    }

    func testUnknownFixtureIDFailsClosedWithoutConstructingARecipe() {
        let corpus = Phase2ProductionProtocolFixtureCorpus.standard

        XCTAssertNil(corpus.entry(fixtureID: "phase2.fixture.unknown.v1"))
        XCTAssertNil(corpus.entry(probeID: "unknown"))
    }

    func testStandardExecutorProducesOnlyExactTypedOracleMatches() async throws {
        let corpus = Phase2ProductionProtocolFixtureCorpus.standard
        let evidence = await Phase2ProductionProtocolFixtureExecutor.executeStandard()

        XCTAssertEqual(evidence.corpusIdentity, corpus.identity)
        XCTAssertEqual(evidence.receipts.count, 99)
        XCTAssertEqual(evidence.receipts.map(\.fixtureIdentity), corpus.entries.map(\.identity))
        XCTAssertTrue(evidence.receipts.allSatisfy(\.matchesOracle))
        XCTAssertEqual(
            evidence.receipts.map(\.observedOutcome),
            corpus.entries.map { .protocolOutcome($0.expectedOutcome) }
        )
        XCTAssertEqual(evidence.receipts.map(\.observedStage), corpus.entries.map(\.expectedStage))
        XCTAssertEqual(evidence.receipts.map(\.observedCode), corpus.entries.map(\.expectedCode))
        XCTAssertEqual(evidence.receipts.map(\.subcaseCount), corpus.entries.map(\.subcaseCount))
        XCTAssertTrue(evidence.receipts.allSatisfy { $0.evidenceDigest.count == 64 })

        let observations = try evidence.qualificationObservations()
        XCTAssertEqual(observations.count, 99)
        XCTAssertEqual(observations.map(\.probeID), corpus.entries.map(\.probeID))
        XCTAssertTrue(observations.allSatisfy {
            $0.trial == 1 && $0.attempt == 1 && $0.outcome == .passed
                && $0.reasonCode == nil && $0.evidenceDigest != nil
        })
    }

    func testExecutorReceiptsAreDeterministicAndPayloadFree() async {
        let first = await Phase2ProductionProtocolFixtureExecutor.executeStandard()
        let second = await Phase2ProductionProtocolFixtureExecutor.executeStandard()

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.receipts.allSatisfy { receipt in
            !receipt.fixtureIdentity.id.contains("/")
                && !receipt.evidenceDigest.contains("/")
        })
    }

    func testRequestFixturesBindTheActiveV3GenerationBytes() throws {
        let handle = Phase2ProductionToolHandle(
            handleID: try XCTUnwrap(UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )),
            operationID: "workspace.summary"
        )
        let fixtures: [(String, Phase2OpenAIProductionChatRequestInput)] = [
            (
                "request.tool-selection.byte-fixture",
                .init(
                    model: "local/model", systemPrompt: "system",
                    userPrompt: #"{"phase":"toolSelection"}"#, maximumTokens: 512,
                    phase: .toolSelection(handles: [handle]), generationVariant: .stagedV2
                )
            ),
            (
                "request.finalization.byte-fixture",
                .init(
                    model: "local/model", systemPrompt: "system",
                    userPrompt: #"{"phase":"finalization"}"#, maximumTokens: 512,
                    phase: .finalization, generationVariant: .stagedV2,
                    allowsFinalizationProposalTools: false
                )
            ),
        ]

        for (probeID, input) in fixtures {
            let bytes = try Phase2OpenAIChatRequestEncoder().encodeProduction(input)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            )
            XCTAssertEqual(object["temperature"] as? NSNumber, 0, probeID)
            XCTAssertEqual(object["top_p"] as? NSNumber, 1, probeID)
            XCTAssertNil(object["seed"], probeID)
            XCTAssertNil(object["stop"], probeID)

            let entry = try XCTUnwrap(
                Phase2ProductionProtocolFixtureCorpus.standard.entry(probeID: probeID)
            )
            XCTAssertTrue(entry.inputDigests.contains(phase2FixtureSHA256(bytes)), probeID)
        }
    }

    func testFinalResourceLimitFixturesUseTheAcceptedFinalDecodingSeam() throws {
        for probeID in [
            "json.final.depth-maximum", "json.final.depth-plus-one",
            "json.final.tokens-maximum", "json.final.tokens-plus-one",
            "json.final.members-maximum", "json.final.members-plus-one",
        ] {
            let entry = try XCTUnwrap(
                Phase2ProductionProtocolFixtureCorpus.standard.entry(probeID: probeID)
            )
            XCTAssertEqual(entry.expectedStage, .finalDecoding, probeID)
        }
    }

    func testClosedRecipesUseOnlySyntheticInputsAndAcceptedComponentStages() {
        let entries = Phase2ProductionProtocolFixtureCorpus.standard.entries
        let allowedStages: Set<Phase2ProductionProtocolFixtureStage> = [
            .registryProjection,
            .requestEncoding,
            .toolCallAssembly,
            .strictJSONParsing,
            .streamDecoding,
            .finalDecoding,
            .promptCompilation,
            .artifactCanonicalization,
            .inferenceBoundary,
        ]

        XCTAssertTrue(entries.allSatisfy { allowedStages.contains($0.expectedStage) })
        XCTAssertTrue(entries.allSatisfy { entry in
            !entry.generationParameters.contains(where: { parameter in
                parameter.contains("http")
                    || parameter.contains("file")
                    || parameter.contains("path")
                    || parameter.contains("read")
                    || parameter.contains("provider")
            })
        })
        XCTAssertTrue(entries.allSatisfy { $0.inputDigests.allSatisfy { $0.count == 64 } })
    }

    func testExecutorSourceHasNoNetworkFilesystemCorpusOrReadExecutionAuthority() throws {
        let qualificationGate = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Services/Phase2/QualificationGate", isDirectory: true)
        let source = try [
            "Phase2ProductionProtocolFixtureCorpus.swift",
            "Phase2ProductionProtocolFixtureExecutor.swift",
        ].map {
            try String(contentsOf: qualificationGate.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "Phase2PreparedRead",
            "Phase2OpenAIChatHTTPClient",
            "URLSession",
            "FileManager",
            "Process(",
            "/v1/chat/completions",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(source.contains("fileprivate init(\n        corpusIdentity:"))
        XCTAssertTrue(source.contains("static func executeStandard()"))
        XCTAssertFalse(source.contains("passedTrialKeys"))
        XCTAssertTrue(source.contains("let inputs = toolPlanInputs(plan)"))
        XCTAssertTrue(source.contains("for fragment in plan.fragments"))
        XCTAssertTrue(source.contains("encodeProduction(plan.input)"))
        XCTAssertTrue(source.contains("let events = try decoder.append(record:"))
        XCTAssertTrue(source.contains("consumedInputDigest = phase2FixtureSHA256(partialFixture)"))
        XCTAssertTrue(source.contains("[Data(finalChunk(delta: completeToolDelta()).utf8)]"))
        XCTAssertTrue(source.contains("executeGroundedFinalResourceLimitRecipe"))
        XCTAssertTrue(source.contains("Phase2FinalJSONParser(\n                data: inputs[0]"))
        XCTAssertFalse(source.contains("inputs ?? fixtureInputs"))
        XCTAssertFalse(source.contains("cancelledFixture()"))
    }
}
