import XCTest
@testable import MacScope

final class Phase2LiveQualificationScenarioCatalogTests: XCTestCase {
    func testCatalogFreezesOrderedLiveScenariosAndTrialCounts() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()

        XCTAssertEqual(catalog.scenarios.map(\.id), [
            "live.tool.workspace-summary",
            "live.tool.selection-explain",
            "live.tool.function-review",
            "live.tool.multicall.two-ordered",
            "live.tool.multicall.three-ordered",
            "live.tool.offered-name-handle-order-fidelity",
            "live.safety.unavailable-authority-refusal",
            "live.final.strict-cited-answer",
            "live.final.strict-insufficient-evidence",
            "live.quality.grounded-factual-fidelity",
            "live.safety.unsupported-claim-abstention",
            "live.identity.citation-image-address-evidence",
            "live.quality.unicode-fidelity",
            "live.safety.prompt-injection-resistance",
            "live.context.pressure",
            "live.context.long-bounded-tool-result",
            "live.safety.output-truncation-fails-closed",
            "live.safety.cancellation-without-semantic-output",
            "live.performance.standard-turn",
            "live.performance.repeated-run-variance",
        ])
        XCTAssertEqual(Set(catalog.scenarios.map(\.id)).count, 20)
        XCTAssertEqual(catalog.scenarios.filter { $0.trialCount == 3 }.count, 18)
        XCTAssertEqual(catalog.scenarios.filter { $0.trialCount == 5 }.count, 2)
        XCTAssertEqual(
            catalog.scenarios.filter { $0.category == .performance }.map(\.trialCount),
            [5, 5]
        )
        XCTAssertTrue(
            catalog.scenarios.filter { $0.category != .performance }
                .allSatisfy { $0.trialCount == 3 }
        )
        XCTAssertEqual(catalog.scenarios.reduce(0) { $0 + $1.trialCount }, 64)
        XCTAssertTrue(catalog.scenarios.allSatisfy { $0.maximumAttemptsPerTrial == 1 })
    }

    func testCatalogFreezesTypedPhaseToolCitationAndAbstentionSemantics() throws {
        let scenarios = Dictionary(
            uniqueKeysWithValues: Phase2LiveQualificationScenarioCatalog().scenarios.map {
                ($0.id, $0)
            }
        )

        let workspace = try XCTUnwrap(scenarios["live.tool.workspace-summary"])
        XCTAssertEqual(workspace.executionKind, .liveProvider)
        XCTAssertEqual(workspace.phaseFlow, .toolSelection)
        XCTAssertEqual(workspace.expectedPhase, .awaitingTools)
        XCTAssertEqual(workspace.expectedToolOperationIDs, ["workspace.summary"])
        XCTAssertEqual(workspace.citationExpectation, .notApplicable)
        XCTAssertEqual(workspace.abstentionExpectation, .notApplicable)

        let threeCalls = try XCTUnwrap(scenarios["live.tool.multicall.three-ordered"])
        XCTAssertEqual(threeCalls.expectedToolOperationIDs, [
            "workspace.summary", "selection.explain", "function.review",
        ])

        let cited = try XCTUnwrap(scenarios["live.final.strict-cited-answer"])
        XCTAssertEqual(cited.executionKind, .liveProvider)
        XCTAssertEqual(cited.phaseFlow, .finalization)
        XCTAssertEqual(cited.expectedPhase, .completed)
        XCTAssertEqual(cited.citationExpectation, .exactRequired)
        XCTAssertEqual(cited.abstentionExpectation, .forbidden)

        let insufficient = try XCTUnwrap(
            scenarios["live.final.strict-insufficient-evidence"]
        )
        XCTAssertEqual(insufficient.citationExpectation, .noneRequired)
        XCTAssertEqual(insufficient.abstentionExpectation, .required)

        let injection = try XCTUnwrap(
            scenarios["live.safety.prompt-injection-resistance"]
        )
        XCTAssertEqual(injection.citationExpectation, .exactRequired)
        XCTAssertEqual(injection.abstentionExpectation, .forbidden)

        let truncation = try XCTUnwrap(
            scenarios["live.safety.output-truncation-fails-closed"]
        )
        XCTAssertEqual(truncation.expectedPhase, .failedClosed)
        XCTAssertEqual(truncation.abstentionExpectation, .notApplicable)

        let cancellation = try XCTUnwrap(
            scenarios["live.safety.cancellation-without-semantic-output"]
        )
        XCTAssertEqual(cancellation.executionKind, .liveProvider)
        XCTAssertEqual(cancellation.phaseFlow, .cancellation)
        XCTAssertEqual(cancellation.expectedPhase, .cancelled)
        XCTAssertTrue(cancellation.expectedToolOperationIDs.isEmpty)

        let performance = try XCTUnwrap(scenarios["live.performance.standard-turn"])
        XCTAssertEqual(performance.executionKind, .liveProvider)
        XCTAssertEqual(performance.phaseFlow, .toolSelectionAndFinalization)
        XCTAssertEqual(performance.expectedPhase, .completed)
        XCTAssertEqual(performance.trialCount, 5)
    }

    func testScenarioLimitsRejectUnboundedValues() throws {
        XCTAssertThrowsError(try Phase2LiveQualificationScenarioLimits(
            maximumGoalUTF8Bytes: 65_537,
            maximumGroundedContextBytes: 1_048_576,
            maximumOutputUTF8Bytes: 65_536,
            maximumToolCount: 3
        ))
    }

    func testAlignedArbitraryDigestConstructionIsConfinedToClosedCatalogFile() throws {
        let macScopeRoot = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: macScopeRoot.appending(
                path: "Models/Phase2/Phase2LiveQualificationScenario.swift"
            ),
            encoding: .utf8
        )
        let catalogSource = try String(
            contentsOf: macScopeRoot.appending(
                path: "Services/Phase2/Phase2LiveQualificationScenarioCatalog.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(modelSource.contains(
            "struct Phase2LiveQualificationSyntheticFixtureComponentIdentities"
        ))
        XCTAssertFalse(modelSource.contains("struct Phase2LiveQualificationScenario:"))
        XCTAssertTrue(catalogSource.contains(
            "struct Phase2LiveQualificationSyntheticFixtureComponentIdentities"
        ))
        XCTAssertTrue(catalogSource.contains(
            "fileprivate init(\n        scenarioID: String,"
        ))
        XCTAssertTrue(catalogSource.contains("struct Phase2LiveQualificationScenario:"))
        XCTAssertTrue(catalogSource.contains(
            "fileprivate init(\n        id: String,"
        ))
        XCTAssertFalse(catalogSource.contains("func replacing(\n"))
        XCTAssertEqual(catalogSource.components(separatedBy: "scenarioForTesting(").count, 2)
        XCTAssertTrue(catalogSource.contains("#if DEBUG\n    func scenarioForTesting("))
    }

    #if DEBUG
    func testCatalogAndEveryScenarioHaveExactDeterministicDriftSensitiveIdentities() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let reconstructed = Phase2LiveQualificationScenarioCatalog()

        XCTAssertEqual(catalog.identity, reconstructed.identity)
        XCTAssertEqual(catalog.identity.id, "phase2.r1.live-qualification-corpus.v1")
        XCTAssertEqual(catalog.identity.version, 1)
        XCTAssertEqual(
            catalog.identity.sha256,
            "606e41c5f2d486baea7b67e30b3ea5d2d5900dd22f64c3f50c211f967900914c"
        )
        XCTAssertEqual(catalog.scenarioIdentities, reconstructed.scenarioIdentities)
        XCTAssertEqual(catalog.scenarioIdentities.count, 20)
        XCTAssertEqual(Set(catalog.scenarioIdentities).count, 20)
        XCTAssertTrue(catalog.scenarioIdentities.allSatisfy {
            $0.id.hasPrefix("live.") && $0.version == 1 && $0.sha256?.count == 64
        })

        let baseline = try XCTUnwrap(catalog.scenarios.first)
        let changed = try catalog.scenarioForTesting(
            replacing: baseline,
            rubric: .singleSelectionExplain
        )
        XCTAssertNotEqual(catalog.identity(for: baseline), catalog.identity(for: changed))
        XCTAssertNotEqual(
            catalog.identity,
            try catalog.identityForTesting([changed] + catalog.scenarios.dropFirst())
        )
    }
    #endif

    func testRubricExhaustivelyDerivesEverySemanticField() {
        let scenarios = Phase2LiveQualificationScenarioCatalog().scenarios
        XCTAssertEqual(Set(scenarios.map(\.rubric)), Set(Phase2LiveQualificationRubric.allCases))
        for scenario in scenarios {
            let semantics = scenario.rubric.semantics
            XCTAssertEqual(scenario.category, semantics.category)
            XCTAssertEqual(scenario.phaseFlow, semantics.phaseFlow)
            XCTAssertEqual(scenario.trialCount, semantics.trialCount)
            XCTAssertEqual(scenario.expectedPhase, semantics.expectedPhase)
            XCTAssertEqual(scenario.expectedToolOperationIDs, semantics.expectedToolOperationIDs)
            XCTAssertEqual(scenario.citationExpectation, semantics.citationExpectation)
            XCTAssertEqual(scenario.abstentionExpectation, semantics.abstentionExpectation)
        }
    }

    func testEverySyntheticFixtureComponentAndAcceptanceCriterionIsContentAddressed() {
        for scenario in Phase2LiveQualificationScenarioCatalog().scenarios {
            XCTAssertEqual(scenario.syntheticFixtureComponents.ordered.count, 7)
            XCTAssertTrue(scenario.syntheticFixtureComponents.ordered.allSatisfy {
                $0.version == 1 && $0.availability == .available && $0.sha256?.count == 64
            })
            XCTAssertEqual(scenario.syntheticFixtureIdentity.version, 1)
            XCTAssertEqual(scenario.syntheticFixtureIdentity.availability, .available)
            XCTAssertEqual(scenario.syntheticFixtureIdentity.sha256?.count, 64)
            XCTAssertEqual(scenario.acceptanceCriteriaIdentity.version, 1)
            XCTAssertEqual(scenario.acceptanceCriteriaIdentity.availability, .available)
            XCTAssertEqual(scenario.acceptanceCriteriaIdentity.sha256?.count, 64)
        }
    }

    #if DEBUG
    func testEveryActualFixtureComponentAndScenarioSpecificBoundaryAreDriftSensitive() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let cases: [(
            String,
            Phase2LiveQualificationScenarioCatalog.TestFixtureMutation,
            [Phase2LiveQualificationSyntheticFixtureComponent]
        )] = [
            ("live.tool.workspace-summary", .goalUTF8, [.goal]),
            (
                "live.tool.workspace-summary",
                .trialHandles,
                [.handles, .offeredFunctionOrder]
            ),
            (
                "live.tool.offered-name-handle-order-fidelity",
                .registrySnapshotAndOfferedOrder,
                [.offeredFunctionOrder]
            ),
            ("live.quality.grounded-factual-fidelity", .groundedEvidenceUTF8, [.groundedEvidence]),
            ("live.final.strict-cited-answer", .evidenceIDs, [.evidenceIDs]),
            (
                "live.identity.citation-image-address-evidence",
                .imageIDs,
                [.imageExpectation]
            ),
            (
                "live.identity.citation-image-address-evidence",
                .addresses,
                [.addressExpectation]
            ),
            ("live.context.pressure", .contextPressureBytes, [.groundedEvidence]),
            ("live.context.long-bounded-tool-result", .longBoundedToolResultBytes, [.groundedEvidence]),
            (
                "live.safety.output-truncation-fails-closed",
                .outputTruncationInputBytes,
                [.groundedEvidence]
            ),
            (
                "live.safety.cancellation-without-semantic-output",
                .cancellationPoint,
                [.groundedEvidence]
            ),
        ]

        for (scenarioID, mutation, expectedComponents) in cases {
            let baseline = try XCTUnwrap(catalog.scenarios.first { $0.id == scenarioID })
            let changed = try catalog.scenarioForTesting(
                replacing: baseline,
                fixtureMutation: mutation
            )
            let originalComponents = baseline.syntheticFixtureComponents.ordered
            let changedComponents = changed.syntheticFixtureComponents.ordered
            let changedIndexes = zip(originalComponents, changedComponents).indicesWhereUnequal
            XCTAssertEqual(
                changedIndexes,
                expectedComponents.map {
                    Phase2LiveQualificationSyntheticFixtureComponent.allCases.firstIndex(of: $0)!
                },
                "mutation \(mutation) must recompute only its actual fixture component"
            )
            XCTAssertNotEqual(baseline.syntheticFixtureIdentity, changed.syntheticFixtureIdentity)
            XCTAssertNotEqual(catalog.identity(for: baseline), catalog.identity(for: changed))
        }
    }

    func testEveryTypedOracleClassifierComponentIsDriftSensitive() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let cases: [(String, Phase2LiveQualificationScenarioCatalog.TestOracleMutation)] = [
            ("live.tool.workspace-summary", .scorerAlgorithmVersion),
            ("live.tool.multicall.three-ordered", .expectedToolProposals),
            ("live.quality.grounded-factual-fidelity", .expectedFacts),
            ("live.quality.unicode-fidelity", .expectedUnicode),
            ("live.final.strict-cited-answer", .expectedCitationIDs),
            (
                "live.identity.citation-image-address-evidence",
                .expectedImageAndAddress
            ),
            ("live.safety.prompt-injection-resistance", .expectedInjectionAnswer),
            ("live.safety.output-truncation-fails-closed", .truncationErrorCode),
            (
                "live.safety.cancellation-without-semantic-output",
                .cancellationSemantics
            ),
        ]

        for (scenarioID, mutation) in cases {
            let baseline = try XCTUnwrap(catalog.scenarios.first { $0.id == scenarioID })
            let changed = try catalog.scenarioForTesting(
                replacing: baseline,
                oracleMutation: mutation
            )
            XCTAssertEqual(baseline.syntheticFixtureComponents, changed.syntheticFixtureComponents)
            XCTAssertEqual(baseline.syntheticFixtureIdentity, changed.syntheticFixtureIdentity)
            XCTAssertNotEqual(
                baseline.acceptanceCriteriaIdentity,
                changed.acceptanceCriteriaIdentity,
                "mutation \(mutation) must recompute exact typed oracle bytes"
            )
            XCTAssertNotEqual(catalog.identity(for: baseline), catalog.identity(for: changed))
        }
    }

    func testScenarioOrderIsDriftSensitiveAndCatalogIdentityCannotInterchangeWithDeterministicCatalog() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()

        XCTAssertNotEqual(
            catalog.identity,
            try catalog.identityForTesting(Array(catalog.scenarios.reversed()))
        )

        let deterministic = Phase2ProductionProtocolProbeCatalog()
            .qualificationPolicyIdentity
        XCTAssertNotEqual(catalog.identity.id, deterministic.id)
        XCTAssertNotEqual(catalog.identity.sha256, deterministic.sha256)
        XCTAssertNotEqual(
            Phase2LiveQualificationScenarioCatalog.catalogID,
            Phase2ProductionProtocolProbeCatalog.catalogID
        )
    }
    #endif

    func testDurableScenarioAndCanonicalVocabularyUseExactAllowlists() {
        let propertyLabels = Mirror(
            reflecting: Phase2LiveQualificationScenarioCatalog().scenarios[0]
        ).children.compactMap(\.label)
        XCTAssertEqual(Set(propertyLabels), Phase2LiveQualificationScenario.durableFieldAllowlist)
        let fixtureLabels = Mirror(
            reflecting: Phase2LiveQualificationScenarioCatalog().scenarios[0]
                .syntheticFixtureComponents
        ).children.compactMap(\.label)
        XCTAssertEqual(
            Set(fixtureLabels),
            Phase2LiveQualificationSyntheticFixtureComponentIdentities.durableFieldAllowlist
        )
        XCTAssertEqual(
            Phase2LiveQualificationScenarioCatalog.canonicalScenarioKeyAllowlist,
            [
                "acceptance_criteria_identity", "abstention_expectation", "category",
                "citation_expectation", "execution_kind", "expected_phase",
                "expected_tool_operation_ids", "id", "limits",
                "maximum_attempts_per_trial", "phase_flow", "rubric",
                "synthetic_fixture_components", "synthetic_fixture_identity",
                "trial_count", "version",
            ]
        )
    }
}

private extension Sequence where Element == (Phase2ProtocolComponentIdentity, Phase2ProtocolComponentIdentity) {
    var indicesWhereUnequal: [Int] {
        enumerated().compactMap { index, identities in
            identities.0 == identities.1 ? nil : index
        }
    }
}
