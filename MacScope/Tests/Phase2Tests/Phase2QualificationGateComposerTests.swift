import Darwin
import Foundation
import XCTest

@testable import MacScope

final class Phase2QualificationGateComposerTests: XCTestCase {
    @MainActor
    func testExplicitSignedStandardGateProducesCertifiedF4AArtifact() async throws {
        guard ProcessInfo.processInfo.environment[
            Phase2QualificationGateComposer.liveGateOptInEnvironmentKey
        ] == "1" else {
            throw XCTSkip("Set the closed F4C signed-Gate opt-in to run real qualification.")
        }

        let report = try await Phase2QualificationGateComposer.executeSignedStandardGate()

        XCTAssertEqual(report.version, 2)
        XCTAssertEqual(report.verdict, .certified)
        XCTAssertEqual(report.declaredTrialCount, 163)
        XCTAssertEqual(report.observedTrialCount, 163)
        XCTAssertEqual(report.observedAttemptCount, 163)
        XCTAssertEqual(report.passedTrialCount, 163)
        XCTAssertEqual(report.passedAttemptCount, 163)
        XCTAssertEqual(report.failedTrialCount, 0)
        XCTAssertEqual(report.failedAttemptCount, 0)
        XCTAssertEqual(report.retryAttemptCount, 0)
        XCTAssertTrue(report.failedProbeIDs.isEmpty)
        XCTAssertTrue(report.missingTrialIDs.isEmpty)
        XCTAssertTrue(report.inconclusiveReasonCodes.isEmpty)
        XCTAssertEqual(report.terminationStatus, .completed)
        XCTAssertEqual(report.attemptMeasurements.count, 64)
        XCTAssertEqual(report.observations.count, 163)
        XCTAssertTrue(report.observations.allSatisfy {
            $0.attempt == 1 && $0.evidenceDigest.map(phase2IsSHA256Hex) == true
        })
        let artifact = try XCTUnwrap(
            Phase2QualificationGateArtifactWriter.artifactURL(for: report.reportID)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: artifact))
                as? [String: Any]
        )
        XCTAssertEqual(object["report_id"] as? String, report.reportID.rawValue)
        XCTAssertEqual(object["declared_trial_count"] as? Int, 163)
        XCTAssertEqual((object["observations"] as? [Any])?.count, 163)
        print("MACSCOPE_F4C_GATE_REPORT=\(report.reportID.rawValue)")
        let reportDigest = String(report.reportID.rawValue.dropFirst("sha256:".count))
        print("MACSCOPE_F4C_GATE_ARTIFACT=reports/\(reportDigest)/report.json")
    }

    func testFrozenGateG4StandardIdentitiesDenominatorSeverityAndThresholds() throws {
        let standard = Phase2ProductionQualificationPolicy.standard
        XCTAssertEqual(
            standard.protocolProbeCatalogIdentity.sha256,
            "7632aaeceb8a3b6946443f6d102233ad7abd95689a203115407ba27d6aaf33d5"
        )
        XCTAssertEqual(
            standard.liveScenarioCatalog.identity.sha256,
            "606e41c5f2d486baea7b67e30b3ea5d2d5900dd22f64c3f50c211f967900914c"
        )
        XCTAssertEqual(
            Phase2ProductionProtocolFixtureCorpus.standard.identity.sha256,
            "a0d3fdecde2d39f0723ec2f2a5f65aa6f5be5942b8fc18671a4114bace4eb27f"
        )
        XCTAssertEqual(
            standard.policyIdentity.sha256,
            "f4e0d43b2b975840686c302740fe946578619eab309896e183225c65e1747559"
        )
        XCTAssertEqual(
            standard.definitionIdentity.sha256,
            "8f17c3acd8e42c50d942108e26ae3342953196d6c910a33b0aa06a0821b05523"
        )
        XCTAssertEqual(
            Phase2ModelProfileCanonicalizer().protocolManifestDigest(
                for: .productionGroundedReadOnly
            ),
            "2b98d08de9e06dfc7f13cd90611f40a698986d2ff94b5359de47ddac01830168"
        )
        XCTAssertEqual(
            standard.metricSemanticsIdentity.sha256,
            "1b9b8aaac574ed0f0a560c36d34d20066bc900e7844a59d929b990d97f138560"
        )
        XCTAssertEqual(
            standard.modelRevision.identity.sha256,
            "9bfbcfcdddce120fa0643ee0deb776798cd3a943cd42197be5f6578e3bf23062"
        )
        XCTAssertEqual(
            standard.thresholdSet.identity.sha256,
            "b37ce53b78a8d2a20bdd35714ac72407fc76c86b0faf4eb26fd2d1d4e7b76f3b"
        )
        XCTAssertEqual(standard.policy.requirements.count, 119)
        XCTAssertEqual(standard.policy.declaredTrialCount, 163)
        XCTAssertEqual(trialCount(.hard, in: standard.policy), 141)
        XCTAssertEqual(trialCount(.core, in: standard.policy), 0)
        XCTAssertEqual(trialCount(.quality, in: standard.policy), 22)
        XCTAssertEqual(standard.policy.maximumEvidenceAgeMilliseconds, 300_000)
        XCTAssertEqual(Phase2ProductionProtocolFixtureCorpus.standard.entries.count, 99)

        let thresholds = Dictionary(uniqueKeysWithValues: standard.thresholdSet.thresholds.map {
            ($0.rule.measurement, $0.rule)
        })
        XCTAssertEqual(thresholds[.totalLatencyMilliseconds]?.threshold, 120_000)
        XCTAssertEqual(
            thresholds[.timeToFirstSemanticEventMilliseconds]?.threshold,
            30_000
        )
        XCTAssertEqual(thresholds[.throughputMilliTokensPerSecond]?.threshold, 5_000)
        XCTAssertEqual(thresholds[.peakResidentBytes]?.threshold, 60_129_542_144)
        XCTAssertEqual(thresholds[.varianceBasisPoints]?.threshold, 2_500)
        XCTAssertEqual(thresholds[.cancellationLatencyMilliseconds]?.threshold, 2_000)
        XCTAssertEqual(thresholds[.peakResidentBytes]?.scope, .runAggregate)
        XCTAssertEqual(thresholds.values.filter { $0.scope == .perAttempt }.count, 4)
        XCTAssertEqual(thresholds.values.filter { $0.scope == .runAggregate }.count, 2)
    }

    func testLiveEntryIsZeroInputAndUsesDirectF4COptIn() throws {
        let source = try supportSource("Phase2QualificationGateComposer.swift")

        XCTAssertTrue(source.contains(
            "static func executeSignedStandardGate("
        ))
        XCTAssertTrue(source.contains(
            "MACSCOPE_RUN_PHASE2_F4C_SIGNED_GATE"
        ))
        XCTAssertTrue(source.contains(
            "ProcessInfo.processInfo.environment[liveGateOptInEnvironmentKey]"
        ))
        XCTAssertFalse(source.contains("MACSCOPE_RUN_PHASE2_F4B_SIGNED_GATE"))
        XCTAssertFalse(source.contains("environment: [String: String]"))
        XCTAssertFalse(source.contains(
            "executeSignedStandardGate(\n        prepared:"
        ))
    }

    func testLiveEntryCollectsAuthorityThenRequiresCanaryBeforeStandardRun() throws {
        let source = try supportSource("Phase2QualificationGateComposer.swift")
        let entry = try XCTUnwrap(source.range(
            of: "static func executeSignedStandardGate("
        ))
        let collector = try XCTUnwrap(source.range(
            of: "Phase2QualificationGateRuntimeCollector.collectCurrent(selector: selector)",
            range: entry.lowerBound..<source.endIndex
        ))
        let oneShotClaim = try XCTUnwrap(source.range(
            of: "Phase2QualificationGateOneShotClaimWriter(",
            range: collector.upperBound..<source.endIndex
        ))
        let canary = try XCTUnwrap(source.range(
            of: "Phase2QualificationGateCanaryBarrier.executeOneShot",
            range: oneShotClaim.upperBound..<source.endIndex
        ))
        let standard = try XCTUnwrap(source.range(
            of: "Phase2ProductionLiveQualificationExecutor.executeStandard",
            range: canary.upperBound..<source.endIndex
        ))

        XCTAssertLessThan(collector.lowerBound, oneShotClaim.lowerBound)
        XCTAssertLessThan(oneShotClaim.lowerBound, canary.lowerBound)
        XCTAssertLessThan(canary.lowerBound, standard.lowerBound)
        XCTAssertTrue(source.contains("authorization: canaryAuthorization"))
    }

    func testProductionCollectorOwnsDiscoveryPreflightAndFreshRecapture() throws {
        let source = try supportSource("Phase2QualificationGateRuntimeCollector.swift")

        XCTAssertTrue(source.contains("static func collectCurrent("))
        XCTAssertTrue(source.contains(
            "preferenceStore: InMemoryPhase2LocalAIProviderPreferenceStore("
        ))
        XCTAssertTrue(source.contains("initialPreference: preference"))
        XCTAssertFalse(source.contains("try await controller.select("))
        XCTAssertTrue(source.contains("try await controller.refresh()"))
        // This private path remains historical-only; the candidate is rejected before entry
        // until its provider closure has a reviewed compiled expectation.
        XCTAssertTrue(source.contains("Phase2LiveQualificationPreflight().evaluate"))
        XCTAssertTrue(source.contains("func captureFreshObservation()"))
        XCTAssertTrue(source.contains("artifactSeal.isCurrent"))
        XCTAssertTrue(source.contains("environmentSeal.isCurrent"))
        XCTAssertTrue(source.contains(
            "private static func collectCurrent(\n        installationMode: Phase2QualificationGateInstallationMode"
        ))
        XCTAssertFalse(source.contains("observation: Phase2QualificationEnvironmentObservation"))
    }

    @MainActor
    func testGateOutcomeManifestBindsCanaryCheckpointAndReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runID = UUID()
        let canaryDigest = String(repeating: "a", count: 64)
        let terminalDigest = String(repeating: "b", count: 64)
        let checkpointDigest = String(repeating: "c", count: 64)
        let reportID = try Phase2ModelQualificationReportID(
            rawValue: "sha256:\(String(repeating: "d", count: 64))"
        )
        let checkpoint = try Phase2QualificationGateCheckpointEvidenceBinding(
            finalizedAttemptCount: 64,
            checkpointEvidenceDigest: checkpointDigest,
            terminalExecutionEvidenceDigest: terminalDigest,
            terminationStatus: .completed
        )
        let claim = try XCTUnwrap(
            Phase2QualificationGateOneShotClaimWriter(baseDirectory: root).claim(
                runID: runID,
                identity: oneShotIdentity()
            )
        )
        let writer = Phase2QualificationGateOutcomeWriter(
            runID: runID,
            oneShotClaim: claim,
            baseDirectory: root
        )
        let prepared = try XCTUnwrap(writer.prepareReport(
            canaryEvidenceDigest: canaryDigest,
            checkpointEvidence: checkpoint,
            reportID: reportID,
            verdict: .certified
        ))
        let reportData = try JSONSerialization.data(
            withJSONObject: [
                "report_id": reportID.rawValue,
                "schema_version": 1,
                "verdict": Phase2ModelQualificationVerdict.certified.rawValue,
            ],
            options: [.sortedKeys]
        )
        let artifact = try XCTUnwrap(Phase2QualificationGateArtifactWriter.publish(
            reportID: reportID,
            serializedReport: reportData,
            preparedOutcome: prepared,
            outcomeWriter: writer,
            baseDirectory: root
        ))
        XCTAssertEqual(
            artifact,
            Phase2QualificationGateArtifactWriter.artifactURL(
                for: reportID,
                baseDirectory: root
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: artifact.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            ["gate-outcome.json", "publication-closure.json", "report.json"]
        )
        XCTAssertFalse(writer.recordInconclusive(
            canaryEvidenceDigest: canaryDigest,
            checkpointEvidence: checkpoint,
            reportID: nil,
            verdict: nil,
            reasonCode: "late-rewrite"
        ))

        let object = try publishedOutcomeObject(root: root, reportID: reportID)
        XCTAssertEqual(object["state"] as? String, "gate-outcome")
        XCTAssertEqual(object["outcome"] as? String, "certified")
        XCTAssertEqual(object["run_id"] as? String, runID.uuidString.lowercased())
        XCTAssertEqual(object["one_shot_claim_digest"] as? String, claim.digest)
        XCTAssertEqual(
            object["one_shot_claim_artifact_evidence_sha256"] as? String,
            claim.artifactEvidenceSHA256
        )
        XCTAssertEqual(object["canary_evidence_digest"] as? String, canaryDigest)
        XCTAssertEqual(object["checkpoint_evidence_digest"] as? String, checkpointDigest)
        XCTAssertEqual(
            object["terminal_execution_evidence_digest"] as? String,
            terminalDigest
        )
        XCTAssertEqual(object["terminal_execution_status"] as? String, "completed")
        XCTAssertEqual(object["finalized_attempt_count"] as? Int, 64)
        XCTAssertEqual(object["report_id"] as? String, reportID.rawValue)
        XCTAssertEqual(object["verdict"] as? String, "certified")
        XCTAssertTrue(object["reason_code"] is NSNull)
        try FileManager.default.removeItem(
            at: artifact.deletingLastPathComponent()
                .appendingPathComponent("publication-closure.json")
        )
        XCTAssertNil(Phase2QualificationGateArtifactWriter.artifactURL(
            for: reportID,
            baseDirectory: root
        ))
    }

    @MainActor
    func testOutcomeWriteFailureLeavesNoDiscoverableCertifiedReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runID = UUID()
        let claim = Phase2QualificationGateOneShotClaim(
            digest: String(repeating: "e", count: 64),
            artifactEvidenceSHA256: String(repeating: "f", count: 64)
        )
        let reportID = try Phase2ModelQualificationReportID(
            rawValue: "sha256:\(String(repeating: "d", count: 64))"
        )
        let checkpoint = try Phase2QualificationGateCheckpointEvidenceBinding(
            finalizedAttemptCount: 64,
            checkpointEvidenceDigest: String(repeating: "c", count: 64),
            terminalExecutionEvidenceDigest: String(repeating: "b", count: 64),
            terminationStatus: .completed
        )
        let writer = Phase2QualificationGateOutcomeWriter(
            runID: runID,
            oneShotClaim: claim,
            baseDirectory: root
        )
        let prepared = try XCTUnwrap(writer.prepareReport(
            canaryEvidenceDigest: String(repeating: "a", count: 64),
            checkpointEvidence: checkpoint,
            reportID: reportID,
            verdict: .certified
        ))
        let reportData = try JSONSerialization.data(
            withJSONObject: [
                "report_id": reportID.rawValue,
                "schema_version": 1,
                "verdict": Phase2ModelQualificationVerdict.certified.rawValue,
            ],
            options: [.sortedKeys]
        )

        let published = Phase2QualificationGateArtifactWriter.publish(
            reportID: reportID,
            serializedReport: reportData,
            preparedOutcome: prepared,
            outcomeWriter: writer,
            baseDirectory: root
        ) { data, components, fileName, existingPolicy, baseDirectory in
            guard fileName != "gate-outcome.json" else { return nil }
            return Phase2QualificationGateSecureFileStore.write(
                data,
                relativeDirectoryComponents: components,
                fileName: fileName,
                existingPolicy: existingPolicy,
                baseDirectory: baseDirectory
            )
        }

        XCTAssertNil(published)
        XCTAssertFalse(writer.hasRecordedOutcome)
        XCTAssertNil(Phase2QualificationGateArtifactWriter.artifactURL(
            for: reportID,
            baseDirectory: root
        ))
        let reports = root.appendingPathComponent(
            "MacScope/Qualification/F4C/reports",
            isDirectory: true
        )
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? [],
            []
        )
    }

    @MainActor
    func testGateOutcomeManifestRecordsPreStandardCanaryFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runID = UUID()
        let claimDigest = String(repeating: "e", count: 64)
        let claimArtifactEvidence = String(repeating: "f", count: 64)
        let writer = Phase2QualificationGateOutcomeWriter(
            runID: runID,
            oneShotClaim: .init(
                digest: claimDigest,
                artifactEvidenceSHA256: claimArtifactEvidence
            ),
            baseDirectory: root
        )

        XCTAssertTrue(writer.recordInconclusive(
            canaryEvidenceDigest: nil,
            checkpointEvidence: nil,
            reportID: nil,
            verdict: nil,
            reasonCode: "canary-failed"
        ))

        let object = try outcomeObject(root: root, runID: runID)
        XCTAssertEqual(object["outcome"] as? String, "inconclusive")
        XCTAssertEqual(object["reason_code"] as? String, "canary-failed")
        XCTAssertEqual(object["finalized_attempt_count"] as? Int, 0)
        XCTAssertTrue(object["canary_evidence_digest"] is NSNull)
        XCTAssertTrue(object["checkpoint_evidence_digest"] is NSNull)
        XCTAssertTrue(object["terminal_execution_evidence_digest"] is NSNull)
        XCTAssertTrue(object["terminal_execution_status"] is NSNull)
        XCTAssertTrue(object["report_id"] is NSNull)
        XCTAssertTrue(object["verdict"] is NSNull)
        XCTAssertEqual(object["one_shot_claim_digest"] as? String, claimDigest)
        XCTAssertEqual(
            object["one_shot_claim_artifact_evidence_sha256"] as? String,
            claimArtifactEvidence
        )
    }

    func testOneShotClaimRejectsQualificationDriftAndNewRunForTheSameF4CBDelivery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try oneShotIdentity(
            appExecutableSHA256: String(repeating: "a", count: 64),
            workerExecutableSHA256: String(repeating: "b", count: 64),
            signingRequirementSHA256: String(repeating: "c", count: 64)
        )
        let standard = Phase2ProductionQualificationPolicy.standard
        let driftedEvidence: [(String, Phase2QualificationGateOneShotClaimIdentity)] = [
            ("app-executable", try oneShotIdentity(
                appExecutableSHA256: String(repeating: "d", count: 64),
                workerExecutableSHA256: String(repeating: "b", count: 64),
                signingRequirementSHA256: String(repeating: "c", count: 64)
            )),
            ("worker-executable", try oneShotIdentity(
                appExecutableSHA256: String(repeating: "a", count: 64),
                workerExecutableSHA256: String(repeating: "e", count: 64),
                signingRequirementSHA256: String(repeating: "c", count: 64)
            )),
            ("signing", try oneShotIdentity(
                appExecutableSHA256: String(repeating: "a", count: 64),
                workerExecutableSHA256: String(repeating: "b", count: 64),
                signingRequirementSHA256: String(repeating: "f", count: 64)
            )),
            ("profile", try oneShotIdentity(
                profileDigest: String(repeating: "6", count: 64)
            )),
            ("policy", try oneShotIdentity(
                policyIdentity: changedComponent(
                    standard.policyIdentity,
                    digest: String(repeating: "7", count: 64)
                )
            )),
            ("manifest", try oneShotIdentity(
                protocolManifestDigest: String(repeating: "8", count: 64)
            )),
            ("probe-catalog", try oneShotIdentity(
                protocolProbeCatalogIdentity: changedComponent(
                    standard.protocolProbeCatalogIdentity,
                    digest: String(repeating: "9", count: 64)
                )
            )),
            ("deterministic-corpus", try oneShotIdentity(
                deterministicCorpusIdentity: .init(
                    id: Phase2ProductionProtocolFixtureCorpus.standard.identity.id,
                    version: Phase2ProductionProtocolFixtureCorpus.standard.identity.version,
                    sha256: String(repeating: "a", count: 64)
                )
            )),
            ("model", try oneShotIdentity(
                modelRevisionIdentity: changedComponent(
                    standard.modelRevision.identity,
                    digest: String(repeating: "b", count: 64)
                )
            )),
            ("environment", try oneShotIdentity(
                qualificationEnvironmentIdentity: try Phase2ProtocolComponentIdentity(
                    id: "phase2.r1.f4c-b-claim-environment.v1",
                    version: 1,
                    sha256: String(repeating: "c", count: 64)
                )
            )),
        ]
        for (field, drifted) in driftedEvidence {
            XCTAssertEqual(identity.digest, drifted.digest)
            XCTAssertNotEqual(
                identity.attachedEvidenceSHA256,
                drifted.attachedEvidenceSHA256,
                "\(field) drift must remain evidence without authorizing a new event"
            )
        }

        let writer = Phase2QualificationGateOneShotClaimWriter(baseDirectory: root)
        let firstRunID = UUID()

        let first = try XCTUnwrap(writer.claim(runID: firstRunID, identity: identity))
        XCTAssertTrue(phase2IsSHA256Hex(first.digest))
        XCTAssertEqual(first.artifactEvidenceSHA256, identity.artifactEvidence.digest)
        for (_, drifted) in driftedEvidence {
            XCTAssertNil(writer.claim(runID: UUID(), identity: drifted))
        }

        let file = root
            .appendingPathComponent("MacScope/Qualification/F4C/claims", isDirectory: true)
            .appendingPathComponent(first.digest + ".json")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(object["state"] as? String, "one-shot-claimed")
        XCTAssertEqual(object["claim_digest"] as? String, first.digest)
        XCTAssertEqual(object["run_id"] as? String, firstRunID.uuidString.lowercased())
        XCTAssertEqual(
            object["qualification_event_id"] as? String,
            Phase2QualificationGateOneShotClaimIdentity.qualificationEventID
        )
        XCTAssertEqual(
            object["qualification_event_version"] as? Int,
            Phase2QualificationGateOneShotClaimIdentity.qualificationEventVersion
        )
        XCTAssertEqual(
            object["deterministic_corpus_sha256"] as? String,
            Phase2ProductionProtocolFixtureCorpus.standard.identity.sha256
        )
        XCTAssertEqual(
            object["artifact_evidence_sha256"] as? String,
            identity.artifactEvidence.digest
        )
        XCTAssertEqual(
            object["attached_evidence_sha256"] as? String,
            identity.attachedEvidenceSHA256
        )
        let artifact = try XCTUnwrap(object["artifact_evidence"] as? [String: Any])
        XCTAssertEqual(
            artifact["app_executable_sha256"] as? String,
            identity.artifactEvidence.appExecutableSHA256
        )
        XCTAssertEqual(
            artifact["worker_executable_sha256"] as? String,
            identity.artifactEvidence.workerExecutableSHA256
        )
        XCTAssertEqual(
            artifact["signing_requirement_sha256"] as? String,
            identity.artifactEvidence.signingRequirementSHA256
        )
    }

    func testOneShotClaimKeyChangesOnlyForIntentionalEventOrSourceDeliveryInputs() throws {
        let baseline = try oneShotIdentity()
        let changed: [(String, Phase2QualificationGateOneShotClaimIdentity)] = [
            ("event-id", try oneShotIdentity(
                qualificationEventID: "phase2.r1.f4c-b-delivery.v2"
            )),
            ("event-version", try oneShotIdentity(qualificationEventVersion: 2)),
            ("commit", try oneShotIdentity(
                gitHeadCommit: String(repeating: "2", count: 40)
            )),
            ("tree", try oneShotIdentity(
                gitHeadTree: String(repeating: "3", count: 40)
            )),
            ("selected-inputs", try oneShotIdentity(
                selectedBuildInputsSHA256: String(repeating: "4", count: 64)
            )),
            ("project", try oneShotIdentity(
                projectYAMLSHA256: String(repeating: "5", count: 64)
            )),
        ]

        for (field, identity) in changed {
            XCTAssertNotEqual(
                identity.digest,
                baseline.digest,
                "\(field) drift must create a new explicitly reviewable claim namespace"
            )
        }
        XCTAssertEqual(
            Set(changed.map { $0.1.digest }).count,
            changed.count,
            "each frozen input must independently participate in the claim key"
        )
    }

    @MainActor
    func testCanaryNormalFixtureUsesCanonicalTwoPhaseProductionScorerPath() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let fixtures = try catalog.productionFixtures()
        let fixture = try XCTUnwrap(
            Phase2QualificationGateCanaryFixtureSelector.normalFixture(in: fixtures)
        )
        let scenario = try XCTUnwrap(
            catalog.scenarios.first(where: { $0.id == fixture.key.probeID })
        )
        XCTAssertEqual(fixture.key.probeID, "live.performance.standard-turn")
        XCTAssertEqual(fixture.key.trial, 1)
        XCTAssertEqual(scenario.phaseFlow, .toolSelectionAndFinalization)

        let scorer = Phase2ProductionLiveQualificationScorer()
        let selection = scorer.classifySelection(
            canaryCanonicalSelectionOutcome(scenario: scenario, fixture: fixture),
            fixture: fixture
        )
        guard case .accepted(let selectionDigest) = selection else {
            return XCTFail("canonical canary selection must pass production scoring")
        }
        let final = scorer.classifyFinalization(
            canaryCanonicalFinalizationOutcome(fixture: fixture),
            fixture: fixture,
            selectionEvidenceDigest: selectionDigest
        )
        XCTAssertEqual(final.outcome, .passed)
        XCTAssertNil(final.reason)
        XCTAssertTrue(phase2IsSHA256Hex(final.evidenceDigest))
    }

    func testCanaryAuthorizationCarriesItsPersistedEvidenceDigestIntoGateComposition() throws {
        let canary = try supportSource("Phase2QualificationGateCanaryBarrier.swift")
        let composer = try supportSource("Phase2QualificationGateComposer.swift")

        XCTAssertTrue(canary.contains("let evidenceDigest: String"))
        XCTAssertTrue(canary.contains("evidenceDigest: payloadFreeDigest"))
        XCTAssertTrue(composer.contains("canaryAuthorization.evidenceDigest"))
        XCTAssertTrue(composer.contains("Phase2QualificationGateOutcomeWriter("))
        XCTAssertTrue(composer.contains("Phase2QualificationGateOneShotClaimWriter("))
        XCTAssertTrue(composer.contains("prepareReport("))
        XCTAssertTrue(composer.contains("gate-publication-closure"))
    }

    func testCanaryDecisionRequiresNormalUsageCancellationRedactionWritingAndFreshness() {
        let accepted = Phase2QualificationGateCanaryEvidenceSummary(
            normalPhaseCount: 2,
            completeUsagePhaseCount: 2,
            cancellationPhaseCount: 1,
            cancellationDrained: true,
            cancellationOrderingProven: true,
            retainedEvidenceIsPayloadFree: true,
            boundedEvidenceWasWritten: true,
            runtimeRemainedCurrent: true
        )
        XCTAssertTrue(Phase2QualificationGateCanaryDecision.accepts(accepted))

        for rejected in [
            accepted.replacing(normalPhaseCount: 1),
            accepted.replacing(completeUsagePhaseCount: 1),
            accepted.replacing(cancellationPhaseCount: 0),
            accepted.replacing(cancellationDrained: false),
            accepted.replacing(cancellationOrderingProven: false),
            accepted.replacing(retainedEvidenceIsPayloadFree: false),
            accepted.replacing(boundedEvidenceWasWritten: false),
            accepted.replacing(runtimeRemainedCurrent: false),
        ] {
            XCTAssertFalse(Phase2QualificationGateCanaryDecision.accepts(rejected))
        }
    }

    func testArtifactManifestUsesFrozenSortedPathSizeFileDigestRecordsAndSealsTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("yz".utf8).write(to: root.appendingPathComponent("sub/b.bin"))

        let manifest = try Phase2QualificationGateArtifactManifest.collect(at: root)

        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.totalBytes, 3)
        XCTAssertEqual(
            manifest.sha256,
            "a7e751c2898ce58b6d6de3306b41891a53893a92a8f70ff2c7b6f027d22dcda4"
        )
        XCTAssertTrue(manifest.seal.isCurrent())

        let a = root.appendingPathComponent("a.txt")
        let originalDate = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate]
                as? Date
        )
        try Data("q".utf8).write(to: a)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: a.path
        )
        XCTAssertFalse(manifest.seal.isCurrent())
    }

    func testArtifactManifestIncludesHiddenFilesAndSealRejectsHiddenTreeDrift() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".model-state"))

        let manifest = try Phase2QualificationGateArtifactManifest.collect(at: root)

        XCTAssertEqual(manifest.fileCount, 1)
        XCTAssertTrue(manifest.seal.isCurrent())
        try Data("new".utf8).write(to: root.appendingPathComponent(".untracked-state"))
        XCTAssertFalse(manifest.seal.isCurrent())
    }

    func testCanaryUsesDedicatedCorrelationsOutsideCanonicalTrialAccounting() throws {
        let source = try supportSource("Phase2QualificationGateCanaryBarrier.swift")

        XCTAssertTrue(source.contains("live.gate-canary.normal"))
        XCTAssertTrue(source.contains("live.gate-canary.cancellation"))
        XCTAssertTrue(source.contains("private static func canaryMetricPlan"))
        XCTAssertTrue(source.contains("private static func canaryUUID"))
        XCTAssertTrue(source.contains("[F4C one-shot provider canary]"))
        XCTAssertTrue(source.contains("Phase2ProductionLiveQualificationScorer()"))
        XCTAssertTrue(source.contains("waitForProviderDispatch()"))
        XCTAssertTrue(source.contains("hasProvenDispatchBeforeCancellation"))
        XCTAssertTrue(source.contains("cancellationLatencyMilliseconds <= 2_000"))
        XCTAssertTrue(source.contains("\"dispatch_receipt_boundary\": \"http-response-headers\""))
        XCTAssertTrue(source.contains("selectionEvidenceDigest: selectionDigest"))
        XCTAssertTrue(source.contains(
            "finalizationEvidenceDigest: finalClassification.evidenceDigest"
        ))
        XCTAssertFalse(source.contains("request: try factory.selectionRequest"))
        XCTAssertFalse(source.contains("request: try factory.finalizationRequest"))
    }

    func testDirectCatalogRecaptureRejectsRedirectsAndCapsStreamingBody() throws {
        let source = try supportSource("Phase2QualificationGateRuntimeCollector.swift")

        XCTAssertTrue(source.contains("willPerformHTTPRedirection"))
        XCTAssertTrue(source.contains("completionHandler(nil)"))
        XCTAssertTrue(source.contains("body.count <= maximumBytes - data.count"))
        XCTAssertFalse(source.contains("dataTask(with: request) { data, response, error in"))
    }

    func testSecureEvidenceStoreAcceptsExistingOwnerReadOnlyAppRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appRoot = root.appendingPathComponent("MacScope", isDirectory: true)
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(appRoot.path, 0o755), 0)

        let written = Phase2QualificationGateSecureFileStore.write(
            Data("evidence".utf8),
            relativeDirectoryComponents: ["MacScope", "Qualification", "F4C", "test"],
            fileName: "evidence.json",
            existingPolicy: .reject,
            baseDirectory: root
        )

        let file = try XCTUnwrap(written)
        XCTAssertEqual(mode(of: appRoot), 0o755)
        XCTAssertEqual(mode(of: appRoot.appendingPathComponent("Qualification")), 0o700)
        XCTAssertEqual(mode(of: file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(mode(of: file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file), Data("evidence".utf8))
    }

    func testSecureEvidenceStoreSynchronizesContainingDirectoryAfterExclusiveCreation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var synchronizedDirectoryState: stat?

        let written = Phase2QualificationGateSecureFileStore.write(
            Data("one-shot-claim".utf8),
            relativeDirectoryComponents: ["MacScope", "Qualification", "F4C", "claims"],
            fileName: "claim.json",
            existingPolicy: .reject,
            baseDirectory: root,
            directorySynchronizer: { descriptor in
                var state = stat()
                guard Darwin.fstat(descriptor, &state) == 0 else { return false }
                synchronizedDirectoryState = state
                return true
            }
        )

        XCTAssertNotNil(written)
        let state = try XCTUnwrap(synchronizedDirectoryState)
        XCTAssertEqual(state.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(state.st_uid, geteuid())
        XCTAssertEqual(state.st_mode & 0o777, 0o700)
    }

    func testSecureEvidenceStoreRejectsWritableOrSymlinkedAppRoot() throws {
        for modeValue in [mode_t(0o775), mode_t(0o777)] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let appRoot = root.appendingPathComponent("MacScope", isDirectory: true)
            try FileManager.default.createDirectory(
                at: appRoot,
                withIntermediateDirectories: false
            )
            XCTAssertEqual(chmod(appRoot.path, modeValue), 0)
            XCTAssertNil(Phase2QualificationGateSecureFileStore.write(
                Data("evidence".utf8),
                relativeDirectoryComponents: ["MacScope", "Qualification"],
                fileName: "evidence.json",
                existingPolicy: .reject,
                baseDirectory: root
            ))
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("MacScope"),
            withDestinationURL: target
        )
        XCTAssertNil(Phase2QualificationGateSecureFileStore.write(
            Data("evidence".utf8),
            relativeDirectoryComponents: ["MacScope", "Qualification"],
            fileName: "evidence.json",
            existingPolicy: .reject,
            baseDirectory: root
        ))
    }

    func testPureCompositionSeamRemainsSeparateAndCannotDispatch() throws {
        let source = try supportSource("Phase2QualificationGateComposer.swift")
        let pure = try XCTUnwrap(source.range(
            of: "static func composeStandardReportForTesting("
        ))
        let bodyEnd = try XCTUnwrap(source.range(
            of: "private static func composeStandardReport(",
            range: pure.upperBound..<source.endIndex
        ))
        let body = String(source[pure.lowerBound..<bodyEnd.lowerBound])

        XCTAssertFalse(body.contains("Phase2ReadyInferenceCoordinator"))
        XCTAssertFalse(body.contains("executeStandard"))
        XCTAssertFalse(body.contains("URLSession"))
        XCTAssertFalse(body.contains("ProcessInfo.processInfo.environment"))
    }

    private func supportSource(_ name: String) throws -> String {
        let macScope = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: macScope
                .appendingPathComponent("Services/Phase2/QualificationGate", isDirectory: true)
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func trialCount(
        _ severity: Phase2QualificationProbeSeverity,
        in policy: Phase2ModelQualificationPolicy
    ) -> Int {
        policy.requirements
            .filter { $0.severity == severity }
            .reduce(0) { $0 + $1.requiredTrialCount }
    }

    private func outcomeObject(root: URL, runID: UUID) throws -> [String: Any] {
        let file = root
            .appendingPathComponent("MacScope/Qualification/F4C", isDirectory: true)
            .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("live/gate-outcome.json")
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
    }

    private func publishedOutcomeObject(
        root: URL,
        reportID: Phase2ModelQualificationReportID
    ) throws -> [String: Any] {
        let digest = String(reportID.rawValue.dropFirst("sha256:".count))
        let file = root
            .appendingPathComponent(
                "MacScope/Qualification/F4C/reports/\(digest)",
                isDirectory: true
            )
            .appendingPathComponent("gate-outcome.json")
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
    }

    func testCandidateClaimRequiresProfileEvidenceAndUsesDisjointStableNamespace() throws {
        let contract = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K)
        XCTAssertThrowsError(try oneShotIdentity(
            qualificationEventID: contract.qualificationEventID,
            modelRevisionIdentity: contract.modelRevisionIdentity
        ))
        let evidence = try candidateEvidence()
        let first = try oneShotIdentity(
            qualificationEventID: contract.qualificationEventID,
            modelRevisionIdentity: contract.modelRevisionIdentity,
            profileEvidence: evidence
        )
        let drifted = try oneShotIdentity(
            qualificationEventID: contract.qualificationEventID,
            modelRevisionIdentity: contract.modelRevisionIdentity,
            profileEvidence: candidateEvidence(digest: String(repeating: "b", count: 64))
        )
        XCTAssertNotEqual(first.digest, try oneShotIdentity().digest)
        XCTAssertEqual(first.digest, drifted.digest)
        XCTAssertNotEqual(first.attachedEvidenceSHA256, drifted.attachedEvidenceSHA256)
        XCTAssertEqual(Set(evidence.attachedObject.keys), Set([
            "profile_selector", "qualification_definition", "provider_admission_policy",
            "provider_build", "runtime_closure", "template_authority", "generation_admission",
        ]))
        let terminal = evidence.adding(to: ["schema_version": 1], state: .canaryPassed)
        XCTAssertEqual(terminal["schema_version"] as? Int, 2)
        XCTAssertEqual(terminal["admission_state"] as? String, "canary-passed")
        XCTAssertEqual(terminal["qualification_definition_sha256"] as? String, contract.definitionIdentity.sha256)
        XCTAssertEqual(terminal["provider_build_sha256"] as? String, evidence.admission.providerBuildIdentity.sha256)
    }

    func testHistoricalPublicationRequiresExplicitSchemaWithoutCandidateMetadata() {
        let historical: [String: Any] = ["schema_version": 1]
        XCTAssertTrue(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
            report: historical, outcome: historical
        ))
        // The production report writer always emits schema_version. Synthetic publication
        // fixtures must preserve that field instead of weakening the reader for partial JSON.
        XCTAssertFalse(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
            report: [:], outcome: historical
        ))
        XCTAssertFalse(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
            report: ["schema_version": 1, "profile_selector": "qwen38-v2-q6k"],
            outcome: historical
        ))
    }

    func testCandidatePublicationRejectsHistoricalAndDriftedMetadata() throws {
        let evidence = try candidateEvidence()
        let candidate = evidence.adding(to: ["verdict": "certified"], state: .qualified)
        XCTAssertTrue(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
            report: candidate, outcome: candidate
        ))
        XCTAssertFalse(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
            report: ["schema_version": 1], outcome: candidate
        ))
        XCTAssertFalse(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
            report: candidate, outcome: ["schema_version": 1]
        ))
        for key in ["profile_selector", "qualification_definition_sha256", "provider_build_sha256",
                    "runtime_closure_sha256", "template_authority_sha256", "admission_state"] {
            var changed = candidate
            changed[key] = NSNull()
            XCTAssertFalse(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
                report: changed, outcome: candidate
            ), key)
        }
        var wrongState = candidate
        wrongState["admission_state"] = "canary-passed"
        XCTAssertFalse(Phase2QualificationGateArtifactWriter.candidateMetadataMatches(
            report: wrongState, outcome: wrongState
        ))
    }

    private func candidateEvidence(digest: String = String(repeating: "a", count: 64)) throws -> Phase2QualificationGateProfileEvidence {
        func identity(_ id: String) throws -> Phase2ProtocolComponentIdentity {
            try .init(id: id, version: 1, sha256: digest)
        }
        let contract = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K)
        return try .init(
            contract: contract,
            admission: .init(
                providerPolicyIdentity: contract.providerPolicyIdentity,
                providerBuildIdentity: identity("phase2.local.llmster-provider-build.v1"),
                runtimeClosureIdentity: identity("phase2.local.llmster-runtime-closure.v1"),
                templateAuthorityIdentity: identity("phase2.local.llmster-template-authority.v1"),
                runtimeIdentity: .init(
                    endpoint: identity("phase2.r1.provider-endpoint.v1"),
                    processStart: identity("phase2.r1.provider-process-start.v1"),
                    executableBuild: identity("phase2.r1.provider-executable-build.v1"),
                    apiProbe: identity("phase2.r1.provider-api-probe.v1")
                )
            ),
            gitHeadCommit: String(repeating: "0", count: 40),
            appExecutableSHA256: String(repeating: "6", count: 64),
            workerExecutableSHA256: String(repeating: "7", count: 64)
        )
    }

    private func oneShotIdentity(
        qualificationEventID: String =
            Phase2QualificationGateOneShotClaimIdentity.qualificationEventID,
        qualificationEventVersion: Int =
            Phase2QualificationGateOneShotClaimIdentity.qualificationEventVersion,
        gitHeadCommit: String = String(repeating: "0", count: 40),
        gitHeadTree: String = String(repeating: "1", count: 40),
        selectedBuildInputsSHA256: String = String(repeating: "2", count: 64),
        projectYAMLSHA256: String = String(repeating: "3", count: 64),
        profileDigest: String = String(repeating: "4", count: 64),
        policyIdentity: Phase2ProtocolComponentIdentity =
            Phase2ProductionQualificationPolicy.standard.policyIdentity,
        protocolManifestDigest: String = String(repeating: "5", count: 64),
        protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity =
            Phase2ProductionQualificationPolicy.standard.protocolProbeCatalogIdentity,
        deterministicCorpusIdentity: Phase2ProductionProtocolFixtureContentIdentity =
            Phase2ProductionProtocolFixtureCorpus.standard.identity,
        modelRevisionIdentity: Phase2ProtocolComponentIdentity =
            Phase2ProductionQualificationPolicy.standard.modelRevision.identity,
        qualificationEnvironmentIdentity: Phase2ProtocolComponentIdentity? = nil,
        appExecutableSHA256: String = String(repeating: "6", count: 64),
        workerExecutableSHA256: String = String(repeating: "7", count: 64),
        signingRequirementSHA256: String = String(repeating: "8", count: 64),
        profileEvidence: Phase2QualificationGateProfileEvidence? = nil
    ) throws -> Phase2QualificationGateOneShotClaimIdentity {
        let environment = try qualificationEnvironmentIdentity
            ?? Phase2ProtocolComponentIdentity(
                id: "phase2.r1.f4c-b-claim-environment.v1",
                version: 1,
                sha256: String(repeating: "9", count: 64)
            )
        return try .init(
            qualificationEventID: qualificationEventID,
            qualificationEventVersion: qualificationEventVersion,
            gitHeadCommit: gitHeadCommit,
            gitHeadTree: gitHeadTree,
            selectedBuildInputsSHA256: selectedBuildInputsSHA256,
            projectYAMLSHA256: projectYAMLSHA256,
            profileID: Phase2ModelProfileID(rawValue: "sha256:\(profileDigest)"),
            policyIdentity: policyIdentity,
            protocolManifestDigest: protocolManifestDigest,
            protocolProbeCatalogIdentity: protocolProbeCatalogIdentity,
            deterministicCorpusIdentity: deterministicCorpusIdentity,
            modelRevisionIdentity: modelRevisionIdentity,
            qualificationEnvironmentIdentity: environment,
            artifactEvidence: try .init(
                appExecutableSHA256: appExecutableSHA256,
                workerExecutableSHA256: workerExecutableSHA256,
                signingRequirementSHA256: signingRequirementSHA256
            ),
            profileEvidence: profileEvidence
        )
    }

    private func changedComponent(
        _ value: Phase2ProtocolComponentIdentity,
        digest: String
    ) throws -> Phase2ProtocolComponentIdentity {
        try .init(id: value.id, version: value.version, sha256: digest)
    }

    private func mode(of url: URL) -> mode_t? {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { lstat($0, &value) } ?? -1
        }) == 0 else { return nil }
        return value.st_mode & 0o777
    }
}

private extension Phase2QualificationGateCanaryEvidenceSummary {
    func replacing(
        normalPhaseCount: Int? = nil,
        completeUsagePhaseCount: Int? = nil,
        cancellationPhaseCount: Int? = nil,
        cancellationDrained: Bool? = nil,
        cancellationOrderingProven: Bool? = nil,
        retainedEvidenceIsPayloadFree: Bool? = nil,
        boundedEvidenceWasWritten: Bool? = nil,
        runtimeRemainedCurrent: Bool? = nil
    ) -> Self {
        .init(
            normalPhaseCount: normalPhaseCount ?? self.normalPhaseCount,
            completeUsagePhaseCount: completeUsagePhaseCount ?? self.completeUsagePhaseCount,
            cancellationPhaseCount: cancellationPhaseCount ?? self.cancellationPhaseCount,
            cancellationDrained: cancellationDrained ?? self.cancellationDrained,
            cancellationOrderingProven:
                cancellationOrderingProven ?? self.cancellationOrderingProven,
            retainedEvidenceIsPayloadFree:
                retainedEvidenceIsPayloadFree ?? self.retainedEvidenceIsPayloadFree,
            boundedEvidenceWasWritten:
                boundedEvidenceWasWritten ?? self.boundedEvidenceWasWritten,
            runtimeRemainedCurrent: runtimeRemainedCurrent ?? self.runtimeRemainedCurrent
        )
    }
}

private func canaryCanonicalSelectionOutcome(
    scenario: Phase2LiveQualificationScenario,
    fixture: Phase2LiveQualificationTrialFixture
) -> Phase2InferenceOutcome {
    let handles = Dictionary(uniqueKeysWithValues: fixture.toolHandles.map {
        ($0.operationID, $0.handleID)
    })
    let proposals = scenario.expectedToolOperationIDs.enumerated().map { index, rawOperation in
        let operation = Phase2ReadOperationID(rawValue: rawOperation)
        let functionName = switch operation {
        case .workspaceSummary: "macscope_workspace_summary_v1"
        case .selectionExplain: "macscope_selection_explain_v1"
        case .functionReview: "macscope_function_review_v1"
        default: preconditionFailure("unexpected canary operation")
        }
        return Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(
                rawValue: "gate-canary-\(fixture.key.trialID)-\(index)"
            )!,
            handleID: handles[operation]!,
            functionName: functionName,
            operationID: operation
        )
    }
    return Phase2InferenceOutcome(
        disposition: .awaitingTools,
        previewDeltas: [],
        toolProposals: proposals,
        finalCandidate: nil,
        providerUsage: .init(promptTokens: 10, completionTokens: 5, totalTokens: 15),
        violation: nil,
        acceptedEventCount: proposals.count + 2,
        cumulativeEventBytes: 512
    )
}

private func canaryCanonicalFinalizationOutcome(
    fixture: Phase2LiveQualificationTrialFixture
) -> Phase2InferenceOutcome {
    let candidate = Phase2InferenceFinalCandidate(
        text: "performance_sentinel=qualified",
        evidenceIDs: fixture.finalizationContext.records.map(\.evidenceID)
    )
    return Phase2InferenceOutcome(
        disposition: .completed,
        previewDeltas: [candidate.text],
        toolProposals: [],
        finalCandidate: candidate,
        providerUsage: .init(promptTokens: 20, completionTokens: 10, totalTokens: 30),
        violation: nil,
        acceptedEventCount: 4,
        cumulativeEventBytes: 1_024
    )
}
