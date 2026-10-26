import CryptoKit
import XCTest

@testable import MacScope

final class WS24InstalledAppQualificationTests: XCTestCase {
    func testCompleteInstalledQualificationRequiresEveryCoreGateOnSameArtifact() {
        let result = evaluator.evaluate(Self.completeEvidence())

        XCTAssertEqual(
            result,
            .accepted(.init(
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest,
                acceptedGates: WS24InstalledAppQualificationEvaluator.requiredGates
            ))
        )
    }

    func testXCUITestIsOptionalForCoreInstalledQualification() {
        let evidence = Self.completeEvidence().filter {
            $0.gate != .incrementalXCUITest
        }

        XCTAssertEqual(
            evaluator.evaluate(evidence),
            .accepted(.init(
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest,
                acceptedGates: WS24InstalledAppQualificationEvaluator.requiredGates
            ))
        )
    }

    func testXCUITestCannotSubstituteForDirectTransportContracts() {
        let evidence = Self.completeEvidence().filter {
            $0.gate != .directDebuggerTransportContracts
        } + [
            .init(
                gate: .incrementalXCUITest,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ),
        ]

        XCTAssertEqual(
            evaluator.evaluate(evidence),
            .rejected([
                .init(.duplicateGateEvidence, gate: .incrementalXCUITest),
                .init(.missingRequiredGate, gate: .directDebuggerTransportContracts),
            ])
        )
    }

    func testSmokeCannotSubstituteForRepeatedStressAttempts() {
        var evidence = Self.completeEvidence()
        replace(
            &evidence,
            gate: .repeatedAttachDetachStress,
            with: .init(
                gate: .repeatedAttachDetachStress,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest,
                acceptedAttempts: 1
            )
        )

        XCTAssertEqual(
            evaluator.evaluate(evidence),
            .rejected([
                .init(.insufficientAcceptedAttempts, gate: .repeatedAttachDetachStress),
            ])
        )
    }

    func testRejectsFailedStaleDuplicateAndDigestDriftEvidence() {
        var evidence = Self.completeEvidence()
        replace(
            &evidence,
            gate: .securityGate,
            with: .init(
                gate: .securityGate,
                status: .failed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
        replace(
            &evidence,
            gate: .performanceGate,
            with: .init(
                gate: .performanceGate,
                status: .passed,
                sourceCommit: Self.staleCommit,
                installedExecutableSHA256: Self.digest
            )
        )
        replace(
            &evidence,
            gate: .sourceInstallEquality,
            with: .init(
                gate: .sourceInstallEquality,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: String(repeating: "b", count: 64)
            )
        )
        evidence.append(evidence.first { $0.gate == .installedLaunchSmoke }!)

        XCTAssertEqual(
            evaluator.evaluate(evidence),
            .rejected([
                .init(.duplicateGateEvidence, gate: .installedLaunchSmoke),
                .init(.gateFailed, gate: .securityGate),
                .init(.inconsistentInstalledExecutableDigest),
                .init(.staleSourceCommit, gate: .performanceGate),
            ])
        )
    }

    func testRejectsMalformedAndEmptyInstalledDigest() {
        var evidence = Self.completeEvidence()
        replace(
            &evidence,
            gate: .sealedReleaseProvenance,
            with: .init(
                gate: .sealedReleaseProvenance,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: ""
            )
        )
        replace(
            &evidence,
            gate: .localSigningPolicy,
            with: .init(
                gate: .localSigningPolicy,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: String(repeating: "A", count: 64)
            )
        )

        XCTAssertEqual(
            evaluator.evaluate(evidence),
            .rejected([
                .init(.emptyInstalledExecutableDigest, gate: .sealedReleaseProvenance),
                .init(.malformedInstalledExecutableDigest, gate: .localSigningPolicy),
            ])
        )
    }

    func testArtifactCollectorProducesPassingSourceInstallEvidenceForSameExecutableBytes() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source-MacScope")
        let installed = directory.appendingPathComponent("installed-MacScope")
        let bytes = Data("same executable bytes".utf8)
        try bytes.write(to: source)
        try bytes.write(to: installed)

        let collected = try WS24InstalledAppArtifactCollector()
            .collectSourceInstallEqualityEvidence(
                sourceExecutableURL: source,
                installedExecutableURL: installed,
                sourceCommit: Self.sourceCommit
            )

        XCTAssertTrue(collected.digest.sourceMatchesInstall)
        XCTAssertEqual(collected.digest.sourceCommit, Self.sourceCommit)
        XCTAssertEqual(collected.digest.sourceExecutableSHA256, collected.digest.installedExecutableSHA256)
        XCTAssertEqual(
            collected.evidence,
            .init(
                gate: .sourceInstallEquality,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: collected.digest.installedExecutableSHA256
            )
        )
    }

    func testArtifactCollectorProducesFailedSourceInstallEvidenceForDigestDrift() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source-MacScope")
        let installed = directory.appendingPathComponent("installed-MacScope")
        try Data("source executable bytes".utf8).write(to: source)
        try Data("installed executable bytes".utf8).write(to: installed)

        let collected = try WS24InstalledAppArtifactCollector()
            .collectSourceInstallEqualityEvidence(
                sourceExecutableURL: source,
                installedExecutableURL: installed,
                sourceCommit: Self.sourceCommit
            )

        XCTAssertFalse(collected.digest.sourceMatchesInstall)
        XCTAssertEqual(collected.evidence.status, .failed)
        XCTAssertEqual(collected.evidence.gate, .sourceInstallEquality)
        XCTAssertEqual(collected.evidence.installedExecutableSHA256, collected.digest.installedExecutableSHA256)
    }

    func testArtifactCollectorResolvesMacOSAppExecutablePath() {
        let app = URL(fileURLWithPath: "/Applications/MacScope.app", isDirectory: true)

        XCTAssertEqual(
            WS24InstalledAppArtifactCollector.executableURL(inAppBundle: app).path,
            "/Applications/MacScope.app/Contents/MacOS/MacScope"
        )
    }

    func testArtifactCollectorResolvesReleaseProvenancePath() {
        let app = URL(fileURLWithPath: "/Applications/MacScope.app", isDirectory: true)

        XCTAssertEqual(
            WS24InstalledAppArtifactCollector.releaseProvenanceURL(inAppBundle: app).path,
            "/Applications/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json"
        )
    }

    func testArtifactCollectorProducesPassingSealedReleaseProvenanceEvidence() throws {
        let directory = try temporaryDirectory()
        let provenance = directory.appendingPathComponent("MacScopeBuildProvenance.json")
        try Self.releaseProvenanceJSON(
            sourceCommit: Self.sourceCommit,
            qualificationEligible: true
        ).write(to: provenance, atomically: true, encoding: .utf8)

        let evidence = try WS24InstalledAppArtifactCollector()
            .collectSealedReleaseProvenanceEvidence(
                provenanceURL: provenance,
                installedExecutableSHA256: Self.digest,
                expectedSourceCommit: Self.sourceCommit
            )

        XCTAssertEqual(
            evidence,
            .init(
                gate: .sealedReleaseProvenance,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
    }

    func testArtifactCollectorFailsSealedReleaseProvenanceEvidenceWhenIneligibleOrStale() throws {
        let directory = try temporaryDirectory()
        let ineligible = directory.appendingPathComponent("ineligible.json")
        let stale = directory.appendingPathComponent("stale.json")
        try Self.releaseProvenanceJSON(
            sourceCommit: Self.sourceCommit,
            qualificationEligible: false
        ).write(to: ineligible, atomically: true, encoding: .utf8)
        try Self.releaseProvenanceJSON(
            sourceCommit: Self.staleCommit,
            qualificationEligible: true
        ).write(to: stale, atomically: true, encoding: .utf8)

        let collector = WS24InstalledAppArtifactCollector()
        let ineligibleEvidence = try collector.collectSealedReleaseProvenanceEvidence(
            provenanceURL: ineligible,
            installedExecutableSHA256: Self.digest,
            expectedSourceCommit: Self.sourceCommit
        )
        let staleEvidence = try collector.collectSealedReleaseProvenanceEvidence(
            provenanceURL: stale,
            installedExecutableSHA256: Self.digest,
            expectedSourceCommit: Self.sourceCommit
        )

        XCTAssertEqual(ineligibleEvidence.status, .failed)
        XCTAssertEqual(ineligibleEvidence.sourceCommit, Self.sourceCommit)
        XCTAssertEqual(staleEvidence.status, .failed)
        XCTAssertEqual(staleEvidence.sourceCommit, Self.staleCommit)
    }

    func testArtifactCollectorFailsClosedForMissingAndMalformedReleaseProvenance() throws {
        let directory = try temporaryDirectory()
        let malformed = directory.appendingPathComponent("malformed.json")
        try "{not-json".write(to: malformed, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try WS24InstalledAppArtifactCollector().collectSealedReleaseProvenanceEvidence(
                provenanceURL: directory.appendingPathComponent("missing.json"),
                installedExecutableSHA256: Self.digest,
                expectedSourceCommit: Self.sourceCommit
            )
        ) { error in
            XCTAssertEqual(
                error as? WS24InstalledAppArtifactCollectorError,
                .missingReleaseProvenance(directory.appendingPathComponent("missing.json").path)
            )
        }

        XCTAssertThrowsError(
            try WS24InstalledAppArtifactCollector().collectSealedReleaseProvenanceEvidence(
                provenanceURL: malformed,
                installedExecutableSHA256: Self.digest,
                expectedSourceCommit: Self.sourceCommit
            )
        ) { error in
            XCTAssertEqual(
                error as? WS24InstalledAppArtifactCollectorError,
                .unreadableReleaseProvenance
            )
        }
    }

    func testArtifactCollectorFailsClosedForMissingAndDirectoryArtifacts() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source-MacScope")
        let installedDirectory = directory.appendingPathComponent("installed-MacScope", isDirectory: true)
        try Data("source executable bytes".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: installedDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try WS24InstalledAppArtifactCollector().collectSourceInstallEqualityEvidence(
                sourceExecutableURL: source,
                installedExecutableURL: directory.appendingPathComponent("missing-MacScope"),
                sourceCommit: Self.sourceCommit
            )
        ) { error in
            XCTAssertEqual(
                error as? WS24InstalledAppArtifactCollectorError,
                .missingInstalledExecutable(directory.appendingPathComponent("missing-MacScope").path)
            )
        }

        XCTAssertThrowsError(
            try WS24InstalledAppArtifactCollector().collectSourceInstallEqualityEvidence(
                sourceExecutableURL: source,
                installedExecutableURL: installedDirectory,
                sourceCommit: Self.sourceCommit
            )
        ) { error in
            XCTAssertEqual(
                error as? WS24InstalledAppArtifactCollectorError,
                .installedExecutableIsDirectory(installedDirectory.path)
            )
        }
    }

    func testDirectTransportCollectorRequiresEveryContractOnSameArtifact() {
        let evidence = WS24InstalledAppDirectTransportCollector().collectEvidence(
            observations: Self.completeDirectTransportObservations(),
            expectedSourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        XCTAssertEqual(
            evidence,
            .init(
                gate: .directDebuggerTransportContracts,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
    }

    func testDirectTransportCollectorRejectsMissingOrDuplicateOperations() {
        let missingRestart = Self.completeDirectTransportObservations().filter {
            $0.operation != .restart
        }
        let duplicateLaunch = Self.completeDirectTransportObservations() + [
            Self.directTransportObservation(.launch),
        ]

        let collector = WS24InstalledAppDirectTransportCollector()

        XCTAssertEqual(
            collector.collectEvidence(
                observations: missingRestart,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
        XCTAssertEqual(
            collector.collectEvidence(
                observations: duplicateLaunch,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
    }

    func testDirectTransportCollectorRejectsStaleOrDriftedArtifactObservations() {
        let stale = Self.completeDirectTransportObservations().map { observation in
            observation.operation == .attach
                ? Self.directTransportObservation(.attach, sourceCommit: Self.staleCommit)
                : observation
        }
        let drifted = Self.completeDirectTransportObservations().map { observation in
            observation.operation == .nonKillingDetach
                ? Self.directTransportObservation(
                    .nonKillingDetach,
                    installedExecutableSHA256: String(repeating: "b", count: 64)
                )
                : observation
        }
        let collector = WS24InstalledAppDirectTransportCollector()

        XCTAssertEqual(
            collector.collectEvidence(
                observations: stale,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
        XCTAssertEqual(
            collector.collectEvidence(
                observations: drifted,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
    }

    func testDirectTransportCollectorRejectsBroadKillOrResidue() {
        let broadKill = Self.completeDirectTransportObservations().map { observation in
            observation.operation == .restart
                ? Self.directTransportObservation(.restart, usedBroadProcessKill: true)
                : observation
        }
        let residue = Self.completeDirectTransportObservations().map { observation in
            observation.operation == .launch
                ? Self.directTransportObservation(.launch, leftProcessResidue: true)
                : observation
        }
        let collector = WS24InstalledAppDirectTransportCollector()

        XCTAssertEqual(
            collector.collectEvidence(
                observations: broadKill,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
        XCTAssertEqual(
            collector.collectEvidence(
                observations: residue,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
    }

    func testDirectTransportCollectorRejectsXCUITestOrSmokeSubstitution() {
        let uiOnly = WS24InstalledAppDirectTransportOperation.allCases.map { operation in
            Self.directTransportObservation(
                operation,
                source: operation == .launch ? .installedLaunchSmoke : .incrementalXCUITest
            )
        }

        let evidence = WS24InstalledAppDirectTransportCollector().collectEvidence(
            observations: uiOnly,
            expectedSourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        XCTAssertEqual(evidence.status, .failed)
        XCTAssertEqual(evidence.gate, .directDebuggerTransportContracts)
    }

    func testDirectTransportCollectorRejectsPidlessOrWrongDetachTerminatePostcondition() {
        let pidless = Self.completeDirectTransportObservations().map { observation in
            observation.operation == .attach
                ? Self.directTransportObservation(.attach, observedProcessID: nil)
                : observation
        }
        let killingDetach = Self.completeDirectTransportObservations().map { observation in
            observation.operation == .nonKillingDetach
                ? Self.directTransportObservation(
                    .nonKillingDetach,
                    targetSurvivedAfterOperation: false
                )
                : observation
        }
        let survivingTerminate = Self.completeDirectTransportObservations().map { observation in
            observation.operation == .terminate
                ? Self.directTransportObservation(
                    .terminate,
                    targetSurvivedAfterOperation: true
                )
                : observation
        }
        let collector = WS24InstalledAppDirectTransportCollector()

        XCTAssertEqual(
            collector.collectEvidence(
                observations: pidless,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
        XCTAssertEqual(
            collector.collectEvidence(
                observations: killingDetach,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
        XCTAssertEqual(
            collector.collectEvidence(
                observations: survivingTerminate,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            ).status,
            .failed
        )
    }

    @MainActor
    func testDirectTransportRunnerExecutesRequiredOperationsInOrderAndCollectsEvidence() async throws {
        let app = try temporaryInstalledAppBundle()
        let executor = RecordingDirectTransportExecutor()
        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        let evidence = try await WS24InstalledAppDirectTransportRunner(executor: executor)
            .run(configuration: configuration)

        XCTAssertEqual(evidence.status, .passed)
        XCTAssertEqual(evidence.gate, .directDebuggerTransportContracts)
        XCTAssertEqual(evidence.sourceCommit, Self.sourceCommit)
        XCTAssertEqual(evidence.installedExecutableSHA256, Self.digest)
        XCTAssertEqual(
            executor.operations,
            WS24InstalledAppDirectTransportOperation.allCases
        )
        XCTAssertEqual(
            executor.executablePaths,
            Array(
                repeating: app.appendingPathComponent("Contents/MacOS/MacScope").path,
                count: WS24InstalledAppDirectTransportOperation.allCases.count
            )
        )
    }

    @MainActor
    func testDirectTransportRunnerFailsClosedWhenExecutorLeavesResidue() async throws {
        let app = try temporaryInstalledAppBundle()
        let executor = RecordingDirectTransportExecutor(
            resultsByOperation: [
                .restart: .init(
                    operation: .restart,
                    passed: true,
                    observedProcessID: 9_001,
                    leftProcessResidue: true
                ),
            ]
        )
        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        let evidence = try await WS24InstalledAppDirectTransportRunner(executor: executor)
            .run(configuration: configuration)

        XCTAssertEqual(evidence.status, .failed)
        XCTAssertEqual(executor.operations, WS24InstalledAppDirectTransportOperation.allCases)
    }

    @MainActor
    func testDirectTransportRunnerFailsClosedWhenExecutorThrows() async throws {
        let app = try temporaryInstalledAppBundle()
        let executor = RecordingDirectTransportExecutor(failingOperation: .attach)
        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        let evidence = try await WS24InstalledAppDirectTransportRunner(executor: executor)
            .run(configuration: configuration)

        XCTAssertEqual(evidence.status, .failed)
        XCTAssertEqual(evidence.gate, .directDebuggerTransportContracts)
        XCTAssertEqual(executor.operations, WS24InstalledAppDirectTransportOperation.allCases)
    }

    @MainActor
    func testDirectTransportRunnerRejectsMissingBundleBeforeExecutorDispatch() async throws {
        let directory = try temporaryDirectory()
        let app = directory.appendingPathComponent("Missing.app", isDirectory: true)
        let executor = RecordingDirectTransportExecutor()
        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        do {
            _ = try await WS24InstalledAppDirectTransportRunner(executor: executor)
                .run(configuration: configuration)
            XCTFail("Missing installed app bundle should fail before executor dispatch.")
        } catch {
            XCTAssertEqual(
                error as? WS24InstalledAppDirectTransportRunnerError,
                .missingInstalledAppBundle(app.path)
            )
        }
        XCTAssertEqual(executor.operations, [])
    }

    func testStressCollectorAcceptsTenCleanAttemptsPerScenario() {
        for scenario in WS24InstalledAppStressScenario.allCases {
            let evidence = WS24InstalledAppStressCollector().collectEvidence(
                scenario: scenario,
                attempts: Self.completeStressAttempts(for: scenario),
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )

            XCTAssertEqual(evidence.gate, scenario.gate)
            XCTAssertEqual(evidence.status, .passed)
            XCTAssertEqual(evidence.sourceCommit, Self.sourceCommit)
            XCTAssertEqual(evidence.installedExecutableSHA256, Self.digest)
            XCTAssertEqual(evidence.acceptedAttempts, scenario.gate.minimumAcceptedAttempts)
        }
    }

    func testStressCollectorRejectsInsufficientDuplicateOrGappedAttempts() {
        let scenario = WS24InstalledAppStressScenario.launchDetach
        let empty: [WS24InstalledAppStressAttemptObservation] = []
        let insufficient = Array(Self.completeStressAttempts(for: scenario).dropLast())
        var duplicate = Self.completeStressAttempts(for: scenario)
        duplicate[9] = duplicate[8]
        var gapped = Self.completeStressAttempts(for: scenario)
        gapped[9] = Self.stressAttempt(scenario, attemptIndex: 11)

        for attempts in [empty, insufficient, duplicate, gapped] {
            let evidence = WS24InstalledAppStressCollector().collectEvidence(
                scenario: scenario,
                attempts: attempts,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )

            XCTAssertEqual(evidence.gate, .repeatedLaunchDetachStress)
            XCTAssertEqual(evidence.status, .failed)
        }
    }

    func testStressCollectorRejectsUnsafeOrStaleAttempts() {
        let scenario = WS24InstalledAppStressScenario.attachDetach
        let mutations: [[WS24InstalledAppStressAttemptObservation]] = [
            Self.completeStressAttempts(for: scenario).replacingStressAttempt(
                at: 3,
                with: Self.stressAttempt(
                    scenario,
                    attemptIndex: 3,
                    sourceCommit: Self.staleCommit
                )
            ),
            Self.completeStressAttempts(for: scenario).replacingStressAttempt(
                at: 4,
                with: Self.stressAttempt(
                    scenario,
                    attemptIndex: 4,
                    installedExecutableSHA256: String(repeating: "b", count: 64)
                )
            ),
            Self.completeStressAttempts(for: scenario).replacingStressAttempt(
                at: 5,
                with: Self.stressAttempt(
                    scenario,
                    attemptIndex: 5,
                    observedProcessID: nil
                )
            ),
            Self.completeStressAttempts(for: scenario).replacingStressAttempt(
                at: 6,
                with: Self.stressAttempt(
                    scenario,
                    attemptIndex: 6,
                    usedBroadProcessKill: true
                )
            ),
            Self.completeStressAttempts(for: scenario).replacingStressAttempt(
                at: 7,
                with: Self.stressAttempt(
                    scenario,
                    attemptIndex: 7,
                    leftProcessResidue: true
                )
            ),
            Self.completeStressAttempts(for: scenario).replacingStressAttempt(
                at: 8,
                with: Self.stressAttempt(
                    scenario,
                    attemptIndex: 8,
                    preservedTargetAfterDetach: false
                )
            ),
            Self.completeStressAttempts(for: scenario).replacingStressAttempt(
                at: 9,
                with: Self.stressAttempt(
                    scenario,
                    attemptIndex: 9,
                    terminalCleanupCompleted: false
                )
            ),
        ]

        for attempts in mutations {
            let evidence = WS24InstalledAppStressCollector().collectEvidence(
                scenario: scenario,
                attempts: attempts,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )

            XCTAssertEqual(evidence.gate, .repeatedAttachDetachStress)
            XCTAssertEqual(evidence.status, .failed)
        }
    }

    func testStressCollectorRejectsRestartAttemptsWithDetachPostconditionSubstitution() {
        let attempts = Self.completeStressAttempts(for: .restart).replacingStressAttempt(
            at: 2,
            with: Self.stressAttempt(
                .restart,
                attemptIndex: 2,
                preservedTargetAfterDetach: true
            )
        )

        let evidence = WS24InstalledAppStressCollector().collectEvidence(
            scenario: .restart,
            attempts: attempts,
            expectedSourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        XCTAssertEqual(evidence.gate, .repeatedRestartStress)
        XCTAssertEqual(evidence.status, .failed)
    }

    @MainActor
    func testStressRunnerExecutesMinimumAttemptsAndCollectsEvidence() async throws {
        for scenario in WS24InstalledAppStressScenario.allCases {
            let app = try temporaryInstalledAppBundle()
            let executor = RecordingStressExecutor()
            let configuration = WS24InstalledAppDirectTransportRunConfiguration(
                installedAppBundleURL: app,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )

            let evidence = try await WS24InstalledAppStressRunner(
                scenario: scenario,
                executor: executor
            ).run(configuration: configuration)

            XCTAssertEqual(evidence.gate, scenario.gate)
            XCTAssertEqual(evidence.status, .passed)
            XCTAssertEqual(evidence.acceptedAttempts, scenario.gate.minimumAcceptedAttempts)
            XCTAssertEqual(
                executor.attempts,
                Array(1...scenario.gate.minimumAcceptedAttempts)
            )
            XCTAssertEqual(
                executor.executablePaths,
                Array(
                    repeating: configuration.installedExecutableURL.path,
                    count: scenario.gate.minimumAcceptedAttempts
                )
            )
        }
    }

    @MainActor
    func testStressRunnerFailsClosedButCompletesAttemptSequenceWhenExecutorThrows() async throws {
        let app = try temporaryInstalledAppBundle()
        let executor = RecordingStressExecutor(failingAttemptIndex: 4)
        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        let evidence = try await WS24InstalledAppStressRunner(
            scenario: .launchDetach,
            executor: executor
        ).run(configuration: configuration)

        XCTAssertEqual(evidence.gate, .repeatedLaunchDetachStress)
        XCTAssertEqual(evidence.status, .failed)
        XCTAssertEqual(
            executor.attempts,
            Array(1...WS24InstalledAppQualificationGate.repeatedLaunchDetachStress.minimumAcceptedAttempts)
        )
    }

    @MainActor
    func testStressRunnerRejectsMissingBundleBeforeExecutorDispatch() async throws {
        let directory = try temporaryDirectory()
        let app = directory.appendingPathComponent("Missing.app", isDirectory: true)
        let executor = RecordingStressExecutor()
        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        do {
            _ = try await WS24InstalledAppStressRunner(
                scenario: .restart,
                executor: executor
            ).run(configuration: configuration)
            XCTFail("Missing installed app bundle should fail before stress dispatch.")
        } catch {
            XCTAssertEqual(
                error as? WS24InstalledAppDirectTransportRunnerError,
                .missingInstalledAppBundle(app.path)
            )
        }
        XCTAssertEqual(executor.attempts, [])
    }

    func testSecurityCollectorAcceptsOnlyCompleteSafeInstalledQualificationEvidence() {
        let observation = Self.securityObservation()

        let evidence = WS24InstalledAppSecurityCollector().collectEvidence(
            observation: observation,
            expectedSourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        XCTAssertEqual(
            evidence,
            .init(
                gate: .securityGate,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
    }

    func testSecurityCollectorRejectsEntitlementExpansionUnsafeProcessEvidenceAndMissingStress() {
        let collector = WS24InstalledAppSecurityCollector()
        let entitlementExpansion = Self.securityObservation(
            entitlementsLimitedToLocalDevelopmentPolicy: false
        )
        let unsafeDirectTransport = Self.securityObservation(
            directTransportEvidence: .init(
                gate: .directDebuggerTransportContracts,
                status: .failed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
        let missingStressScenario = Self.securityObservation(
            stressEvidence: [
                Self.stressEvidence(for: .launchDetach),
                Self.stressEvidence(for: .attachDetach),
            ]
        )

        for observation in [entitlementExpansion, unsafeDirectTransport, missingStressScenario] {
            let evidence = collector.collectEvidence(
                observation: observation,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )

            XCTAssertEqual(evidence.gate, .securityGate)
            XCTAssertEqual(evidence.status, .failed)
        }
    }

    func testPerformanceCollectorAcceptsBoundedStressMetricsForEveryScenario() {
        let evidence = WS24InstalledAppPerformanceCollector().collectEvidence(
            observations: Self.completePerformanceObservations(),
            expectedSourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        XCTAssertEqual(evidence.gate, .performanceGate)
        XCTAssertEqual(evidence.status, .passed)
        XCTAssertEqual(
            evidence.acceptedAttempts,
            WS24InstalledAppStressScenario.allCases.reduce(0) {
                $0 + $1.gate.minimumAcceptedAttempts
            }
        )
    }

    func testPerformanceCollectorRejectsMissingMalformedStaleSlowOrHighRSSMetrics() {
        let collector = WS24InstalledAppPerformanceCollector()
        let mutations: [[WS24InstalledAppPerformanceObservation]] = [
            Array(Self.completePerformanceObservations().dropLast()),
            Self.completePerformanceObservations().replacingPerformanceObservation(
                scenario: .launchDetach,
                attemptIndex: 2,
                with: Self.performanceObservation(
                    .launchDetach,
                    attemptIndex: 2,
                    sourceCommit: Self.staleCommit
                )
            ),
            Self.completePerformanceObservations().replacingPerformanceObservation(
                scenario: .attachDetach,
                attemptIndex: 3,
                with: Self.performanceObservation(
                    .attachDetach,
                    attemptIndex: 3,
                    durationMilliseconds: .infinity
                )
            ),
            Self.completePerformanceObservations().replacingPerformanceObservation(
                scenario: .attachDetach,
                attemptIndex: 4,
                with: Self.performanceObservation(
                    .attachDetach,
                    attemptIndex: 4,
                    durationMilliseconds: 15_001
                )
            ),
            Self.completePerformanceObservations().replacingPerformanceObservation(
                scenario: .restart,
                attemptIndex: 5,
                with: Self.performanceObservation(
                    .restart,
                    attemptIndex: 5,
                    peakResidentMemoryMegabytes: 2_049
                )
            ),
            Self.completePerformanceObservations().replacingPerformanceObservation(
                scenario: .restart,
                attemptIndex: 6,
                with: Self.performanceObservation(
                    .restart,
                    attemptIndex: 6,
                    timedOut: true
                )
            ),
        ]

        for observations in mutations {
            let evidence = collector.collectEvidence(
                observations: observations,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )

            XCTAssertEqual(evidence.gate, .performanceGate)
            XCTAssertEqual(evidence.status, .failed)
        }
    }

    func testToolchainCollectorAcceptsCurrentXcode27AppleSiliconMacOS27Matrix() {
        let evidence = WS24InstalledAppToolchainCollector().collectEvidence(
            observation: Self.toolchainObservation(),
            expectedSourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest
        )

        XCTAssertEqual(
            evidence,
            .init(
                gate: .supportedToolchainMatrix,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
    }

    func testToolchainCollectorRejectsWrongMajorExternalArchitectureOrStaleProvenance() {
        let collector = WS24InstalledAppToolchainCollector()
        let mutations = [
            Self.toolchainObservation(xcodeVersion: "26.4"),
            Self.toolchainObservation(swiftCompilerVersion: "5.10"),
            Self.toolchainObservation(sdkName: "macosx26.0", sdkVersion: "26.0"),
            Self.toolchainObservation(architecture: "x86_64", hostArchitecture: "x86_64"),
            Self.toolchainObservation(deploymentTarget: "26.0", hostMacOSMajorVersion: 26),
            Self.toolchainObservation(developerDirectoryUsesXcode27: false),
            Self.toolchainObservation(releaseProvenanceQualified: false),
            Self.toolchainObservation(sourceCommit: Self.staleCommit),
        ]

        for observation in mutations {
            let evidence = collector.collectEvidence(
                observation: observation,
                expectedSourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )

            XCTAssertEqual(evidence.gate, .supportedToolchainMatrix)
            XCTAssertEqual(evidence.status, .failed)
        }
    }

    func testQualificationReportCanonicalizesEvidenceAndRecordsAcceptedResult() throws {
        let evidence = Self.completeEvidence().reversed()
        let result = evaluator.evaluate(Array(evidence))
        let report = WS24InstalledAppQualificationReport(
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest,
            generatedAtUnixMilliseconds: 1_775_000_000_000,
            evidence: Array(evidence),
            result: result
        )

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.deficiencies, [])
        XCTAssertEqual(
            report.evidence.map(\.gate),
            (
                WS24InstalledAppQualificationEvaluator.requiredGates
                    + WS24InstalledAppQualificationEvaluator.optionalGates
            ).sorted { $0.rawValue < $1.rawValue }
        )
        XCTAssertEqual(
            report.acceptedGates,
            WS24InstalledAppQualificationEvaluator.requiredGates
        )
        XCTAssertEqual(report.performanceThresholds.launchDetachMaximumDurationMilliseconds, 15_000)
        XCTAssertEqual(report.performanceThresholds.attachDetachMaximumDurationMilliseconds, 15_000)
        XCTAssertEqual(report.performanceThresholds.restartMaximumDurationMilliseconds, 20_000)
        XCTAssertEqual(report.performanceThresholds.maximumPeakResidentMemoryMegabytes, 2_048)

        let encoded = try report.encodedJSONData()
        let decoded = try JSONDecoder().decode(
            WS24InstalledAppQualificationReport.self,
            from: encoded
        )
        XCTAssertEqual(decoded, report)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"schemaVersion\" : 1"))
    }

    func testQualificationReportRecordsRejectedDeficienciesWithoutReevaluatingEvidence() throws {
        var evidence = Self.completeEvidence()
        replace(
            &evidence,
            gate: .performanceGate,
            with: .init(
                gate: .performanceGate,
                status: .failed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
        let result = evaluator.evaluate(evidence)
        let report = WS24InstalledAppQualificationReport(
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest,
            evidence: evidence,
            result: result
        )

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.acceptedGates, [])
        XCTAssertEqual(
            report.deficiencies,
            [.init(.gateFailed, gate: .performanceGate)]
        )

        let encoded = try report.encodedJSONData()
        let decoded = try JSONDecoder().decode(
            WS24InstalledAppQualificationReport.self,
            from: encoded
        )
        XCTAssertEqual(decoded, report)
    }

    func testQualificationReportAssemblerEvaluatesEvidenceAndPreservesThresholds() {
        var evidence = Self.completeEvidence()
        replace(
            &evidence,
            gate: .supportedToolchainMatrix,
            with: .init(
                gate: .supportedToolchainMatrix,
                status: .failed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest
            )
        )
        let assembler = WS24InstalledAppQualificationReportAssembler(
            expectedSourceCommit: Self.sourceCommit,
            performanceThresholds: .init(
                maxAttemptDurationMillisecondsByScenario: [
                    .launchDetach: 1_000,
                    .attachDetach: 2_000,
                    .restart: 3_000,
                ],
                maxPeakResidentMemoryMegabytes: 512
            )
        )

        let report = assembler.makeReport(
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest,
            evidence: evidence,
            generatedAtUnixMilliseconds: 1_775_100_000_000
        )

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(
            report.deficiencies,
            [.init(.gateFailed, gate: .supportedToolchainMatrix)]
        )
        XCTAssertEqual(report.generatedAtUnixMilliseconds, 1_775_100_000_000)
        XCTAssertEqual(report.performanceThresholds.launchDetachMaximumDurationMilliseconds, 1_000)
        XCTAssertEqual(report.performanceThresholds.attachDetachMaximumDurationMilliseconds, 2_000)
        XCTAssertEqual(report.performanceThresholds.restartMaximumDurationMilliseconds, 3_000)
        XCTAssertEqual(report.performanceThresholds.maximumPeakResidentMemoryMegabytes, 512)
    }

    func testQualificationReportWriterCreatesParentDirectoryAndReturnsDigest() throws {
        let report = WS24InstalledAppQualificationReportAssembler(
            expectedSourceCommit: Self.sourceCommit
        ).makeReport(
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest,
            evidence: Self.completeEvidence(),
            generatedAtUnixMilliseconds: 1_775_200_000_000
        )
        let reportURL = try temporaryDirectory()
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("ws24-report.json", isDirectory: false)

        let result = try WS24InstalledAppQualificationReportWriter().writeReport(
            report,
            to: reportURL
        )

        XCTAssertEqual(result.reportURL, reportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertEqual(
            result.reportSHA256,
            try Self.sha256Hex(contentsOf: reportURL)
        )
        XCTAssertEqual(result.byteCount, try Data(contentsOf: reportURL).count)
        let decoded = try JSONDecoder().decode(
            WS24InstalledAppQualificationReport.self,
            from: try Data(contentsOf: reportURL)
        )
        XCTAssertEqual(decoded, report)
    }

    func testQualificationReportWriterRejectsDirectoryOutputURL() throws {
        let report = WS24InstalledAppQualificationReportAssembler(
            expectedSourceCommit: Self.sourceCommit
        ).makeReport(
            sourceCommit: Self.sourceCommit,
            installedExecutableSHA256: Self.digest,
            evidence: Self.completeEvidence()
        )
        let directory = try temporaryDirectory()

        XCTAssertThrowsError(try WS24InstalledAppQualificationReportWriter().writeReport(
            report,
            to: directory
        )) { error in
            XCTAssertEqual(
                error as? WS24InstalledAppQualificationReportWriterError,
                .outputURLIsDirectory(directory.path)
            )
        }
    }

    @MainActor
    func testOptInLiveInstalledAppDirectTransportRunnerAgainstApplicationsBundle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let optInFlagPath = environment["MACSCOPE_WS24_RUN_INSTALLED_DIRECT_TRANSPORT_FLAG"]
            ?? "/tmp/MacScope-WS24-run-installed-direct-transport"
        let isOptedIn = environment["MACSCOPE_WS24_RUN_INSTALLED_DIRECT_TRANSPORT"] == "1"
            || FileManager.default.fileExists(atPath: optInFlagPath)
        guard isOptedIn else {
            throw XCTSkip(
                "Set MACSCOPE_WS24_RUN_INSTALLED_DIRECT_TRANSPORT=1 or create \(optInFlagPath) "
                    + "to run live installed-app transport proof."
            )
        }

        let appPath = environment["MACSCOPE_WS24_INSTALLED_APP"] ?? "/Applications/MacScope.app"
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        let executable = WS24InstalledAppArtifactCollector.executableURL(inAppBundle: app)
        let provenance = WS24InstalledAppArtifactCollector.releaseProvenanceURL(inAppBundle: app)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw XCTSkip("Installed MacScope executable is absent at \(executable.path).")
        }
        guard FileManager.default.fileExists(atPath: provenance.path) else {
            throw XCTSkip("Installed MacScope sealed provenance is absent at \(provenance.path).")
        }

        let installedDigest = try Self.sha256Hex(contentsOf: executable)
        let installedSourceCommit = try Self.installedSourceCommit(in: provenance)
        let provenanceEvidence = try WS24InstalledAppArtifactCollector()
            .collectSealedReleaseProvenanceEvidence(
                provenanceURL: provenance,
                installedExecutableSHA256: installedDigest,
                expectedSourceCommit: installedSourceCommit
            )
        XCTAssertEqual(provenanceEvidence.status, .passed)

        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: installedSourceCommit,
            installedExecutableSHA256: installedDigest
        )
        let executor = WS24InstalledAppLocalLLDBDirectTransportExecutor()
        var observations: [WS24InstalledAppDirectTransportObservation] = []
        observations.reserveCapacity(WS24InstalledAppDirectTransportOperation.allCases.count)
        for operation in WS24InstalledAppDirectTransportOperation.allCases {
            let result: WS24InstalledAppDirectTransportStepResult
            do {
                result = try await executor.executeDirectTransportStep(
                    operation,
                    configuration: configuration
                )
            } catch {
                XCTFail("Live installed-app direct transport \(operation.rawValue) failed: \(error)")
                return
            }
            observations.append(.init(
                operation: result.operation,
                passed: result.passed,
                source: .directDebuggerClient,
                sourceCommit: installedSourceCommit,
                installedExecutableSHA256: installedDigest,
                observedProcessID: result.observedProcessID,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                targetSurvivedAfterOperation: result.targetSurvivedAfterOperation
            ))
        }

        let evidence = WS24InstalledAppDirectTransportCollector().collectEvidence(
            observations: observations,
            expectedSourceCommit: installedSourceCommit,
            installedExecutableSHA256: installedDigest
        )

        XCTAssertEqual(evidence.status, .passed)
        XCTAssertEqual(evidence.gate, .directDebuggerTransportContracts)
        XCTAssertEqual(evidence.sourceCommit, installedSourceCommit)
        XCTAssertEqual(evidence.installedExecutableSHA256, installedDigest)
    }

    @MainActor
    func testOptInLiveInstalledAppStressRunnerAgainstApplicationsBundle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let optInFlagPath = environment["MACSCOPE_WS24_RUN_INSTALLED_STRESS_FLAG"]
            ?? "/tmp/MacScope-WS24-run-installed-stress"
        let isOptedIn = environment["MACSCOPE_WS24_RUN_INSTALLED_STRESS"] == "1"
            || FileManager.default.fileExists(atPath: optInFlagPath)
        guard isOptedIn else {
            throw XCTSkip(
                "Set MACSCOPE_WS24_RUN_INSTALLED_STRESS=1 or create \(optInFlagPath) "
                    + "to run live installed-app stress proof."
            )
        }

        let appPath = environment["MACSCOPE_WS24_INSTALLED_APP"] ?? "/Applications/MacScope.app"
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        let executable = WS24InstalledAppArtifactCollector.executableURL(inAppBundle: app)
        let provenance = WS24InstalledAppArtifactCollector.releaseProvenanceURL(inAppBundle: app)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw XCTSkip("Installed MacScope executable is absent at \(executable.path).")
        }
        guard FileManager.default.fileExists(atPath: provenance.path) else {
            throw XCTSkip("Installed MacScope sealed provenance is absent at \(provenance.path).")
        }

        let installedDigest = try Self.sha256Hex(contentsOf: executable)
        let installedSourceCommit = try Self.installedSourceCommit(in: provenance)
        let provenanceEvidence = try WS24InstalledAppArtifactCollector()
            .collectSealedReleaseProvenanceEvidence(
                provenanceURL: provenance,
                installedExecutableSHA256: installedDigest,
                expectedSourceCommit: installedSourceCommit
            )
        XCTAssertEqual(provenanceEvidence.status, .passed)

        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: app,
            sourceCommit: installedSourceCommit,
            installedExecutableSHA256: installedDigest
        )
        let executor = WS24InstalledAppLocalLLDBDirectTransportExecutor()
        for scenario in WS24InstalledAppStressScenario.allCases {
            let evidence = try await Self.runLiveInstalledAppStressProof(
                scenario: scenario,
                executor: executor,
                configuration: configuration
            )

            XCTAssertEqual(evidence.status, .passed)
            XCTAssertEqual(evidence.gate, scenario.gate)
            XCTAssertEqual(evidence.sourceCommit, installedSourceCommit)
            XCTAssertEqual(evidence.installedExecutableSHA256, installedDigest)
            XCTAssertEqual(evidence.acceptedAttempts, scenario.gate.minimumAcceptedAttempts)
        }
    }

    @MainActor
    private static func runLiveInstalledAppStressProof<Executor: WS24InstalledAppStressExecuting>(
        scenario: WS24InstalledAppStressScenario,
        executor: Executor,
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppQualificationEvidence {
        var observations: [WS24InstalledAppStressAttemptObservation] = []
        observations.reserveCapacity(scenario.gate.minimumAcceptedAttempts)

        for attemptIndex in 1...scenario.gate.minimumAcceptedAttempts {
            let result: WS24InstalledAppStressAttemptResult
            do {
                result = try await executor.executeStressAttempt(
                    scenario: scenario,
                    attemptIndex: attemptIndex,
                    configuration: configuration
                )
            } catch {
                XCTFail(
                    "Live installed-app stress \(scenario.rawValue) attempt "
                        + "\(attemptIndex) failed: \(error)"
                )
                throw error
            }

            guard result.passed else {
                XCTFail(
                    "Live installed-app stress \(scenario.rawValue) attempt "
                        + "\(attemptIndex) returned failed result: \(result)"
                )
                break
            }

            observations.append(.init(
                scenario: result.scenario,
                attemptIndex: result.attemptIndex,
                passed: result.passed,
                sourceCommit: configuration.sourceCommit,
                installedExecutableSHA256: configuration.installedExecutableSHA256,
                observedProcessID: result.observedProcessID,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                preservedTargetAfterDetach: result.preservedTargetAfterDetach,
                terminalCleanupCompleted: result.terminalCleanupCompleted
            ))
        }

        return WS24InstalledAppStressCollector().collectEvidence(
            scenario: scenario,
            attempts: observations,
            expectedSourceCommit: configuration.sourceCommit,
            installedExecutableSHA256: configuration.installedExecutableSHA256
        )
    }

    @MainActor
    func testInstalledLiveGateLaunchDecisionIsOrdinaryLaunchNeutralAndFailClosed() {
        XCTAssertEqual(
            WS24InstalledLiveGateApplicationRunner.decision(
                arguments: ["/Applications/MacScope.app/Contents/MacOS/MacScope"],
                environment: ["MACSCOPE_UNRELATED": "1"]
            ),
            .ordinary
        )

        var exact = Self.installedLiveGateArguments()
        XCTAssertEqual(
            WS24InstalledLiveGateApplicationRunner.decision(
                arguments: exact,
                environment: [
                    "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer",
                ]
            ),
            .requested(.init(
                gate: .repeatedLaunchDetachStress,
                sourceCommit: String(repeating: "a", count: 40),
                sourceTree: String(repeating: "b", count: 40),
                installedExecutableSHA256: String(repeating: "c", count: 64),
                pendingExposedAtUnixNanoseconds: 1_000_000_000,
                developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer"
            ))
        )

        exact[0] = "/tmp/prepared/MacScope.app/Contents/MacOS/MacScope"
        XCTAssertEqual(
            WS24InstalledLiveGateApplicationRunner.decision(
                arguments: exact,
                environment: [:]
            ),
            .rejected
        )
        XCTAssertEqual(
            WS24InstalledLiveGateApplicationRunner.decision(
                arguments: Self.installedLiveGateArguments(),
                environment: ["DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib"]
            ),
            .rejected
        )
    }

    @MainActor
    func testInstalledLiveGateRejectsReorderedOrCallerAuthoredArguments() {
        var reordered = Self.installedLiveGateArguments()
        reordered.swapAt(3, 5)
        XCTAssertEqual(
            WS24InstalledLiveGateApplicationRunner.decision(
                arguments: reordered,
                environment: [:]
            ),
            .rejected
        )

        var extra = Self.installedLiveGateArguments()
        extra.append(contentsOf: ["--status", "passed"])
        XCTAssertEqual(
            WS24InstalledLiveGateApplicationRunner.decision(
                arguments: extra,
                environment: [:]
            ),
            .rejected
        )
    }

    @MainActor
    func testInstalledLiveGateSeedIsDeterministicAndCandidateBound() {
        let seed = WS24InstalledLiveGateApplicationRunner.deterministicSeed(
            sourceCommit: String(repeating: "a", count: 40),
            sourceTree: String(repeating: "b", count: 40),
            installedExecutableSHA256: String(repeating: "c", count: 64),
            reportGate: "repeated-launch-detach-stress",
            scenario: "repeated-launch-detach-stress",
            attemptIndex: 1
        )
        XCTAssertEqual(seed, 4_694_912_104_982_801_247)
        XCTAssertNotEqual(
            seed,
            WS24InstalledLiveGateApplicationRunner.deterministicSeed(
                sourceCommit: String(repeating: "a", count: 40),
                sourceTree: String(repeating: "b", count: 40),
                installedExecutableSHA256: String(repeating: "c", count: 64),
                reportGate: "performance-gate",
                scenario: "repeated-launch-detach-stress",
                attemptIndex: 1
            )
        )
    }

    func testInstalledLiveGateReportIsClosedCanonicalNoLFWithExplicitNulls() throws {
        let report = WS24InstalledLiveExecutionReport(
            attempts: [.init(
                attemptIndex: 1,
                endedAtUnixMilliseconds: 2,
                exitCode: 0,
                failure: nil,
                peakResidentMemoryMegabytes: nil,
                scenario: "installed-launch-smoke",
                seed: nil,
                startedAtUnixMilliseconds: 1,
                timedOut: false
            )],
            gate: "installed-launch-smoke",
            installedExecutableSHA256: String(repeating: "c", count: 64),
            sourceCommit: String(repeating: "a", count: 40),
            sourceTree: String(repeating: "b", count: 40)
        )
        let data = try report.canonicalData()
        XCTAssertNotEqual(data.last, 0x0A)
        XCTAssertNotEqual(data.last, 0x0D)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(root.keys),
            Set([
                "attempts",
                "gate",
                "installedExecutableSHA256",
                "schemaVersion",
                "sourceCommit",
                "sourceTree",
            ])
        )
        let attempts = try XCTUnwrap(root["attempts"] as? [[String: Any]])
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(
            Set(attempt.keys),
            Set([
                "attemptIndex",
                "endedAtUnixMilliseconds",
                "exitCode",
                "failure",
                "peakResidentMemoryMegabytes",
                "scenario",
                "seed",
                "startedAtUnixMilliseconds",
                "timedOut",
            ])
        )
        XCTAssertTrue(attempt["failure"] is NSNull)
        XCTAssertTrue(attempt["peakResidentMemoryMegabytes"] is NSNull)
        XCTAssertTrue(attempt["seed"] is NSNull)
        XCTAssertNil(root["status"])
        XCTAssertNil(attempt["processID"])
        XCTAssertNil(attempt["durationMilliseconds"])
    }

    private static func installedLiveGateArguments() -> [String] {
        [
            "/Applications/MacScope.app/Contents/MacOS/MacScope",
            "--ws24-installed-live-gate",
            "repeated-launch-detach-stress",
            "--source-commit",
            String(repeating: "a", count: 40),
            "--source-tree",
            String(repeating: "b", count: 40),
            "--installed-executable-sha256",
            String(repeating: "c", count: 64),
            "--pending-exposed-at-unix-nanoseconds",
            "1000000000",
            "--developer-directory",
            "/Applications/Xcode-beta.app/Contents/Developer",
        ]
    }

    private static let sourceCommit = String(repeating: "1", count: 40)
    private static let staleCommit = String(repeating: "2", count: 40)
    private static let digest = String(repeating: "a", count: 64)
    private var evaluator: WS24InstalledAppQualificationEvaluator {
        WS24InstalledAppQualificationEvaluator(expectedSourceCommit: Self.sourceCommit)
    }

    private static func completeEvidence() -> [WS24InstalledAppQualificationEvidence] {
        (
            WS24InstalledAppQualificationEvaluator.requiredGates
                + WS24InstalledAppQualificationEvaluator.optionalGates
        ).map { gate in
            .init(
                gate: gate,
                status: .passed,
                sourceCommit: Self.sourceCommit,
                installedExecutableSHA256: Self.digest,
                acceptedAttempts: gate.minimumAcceptedAttempts
            )
        }
    }

    private static func releaseProvenanceJSON(
        sourceCommit: String,
        qualificationEligible: Bool
    ) -> String {
        """
        {
          "schema_version": 1,
          "qualification_eligible": \(qualificationEligible ? "true" : "false"),
          "configuration": "Release",
          "git_head_commit": "\(sourceCommit)",
          "repository_clean": true,
          "selected_build_inputs_sha256": "\(digest)",
          "project_yml_sha256": "\(digest)",
          "xcode_version": "27.0",
          "xcode_build": "27A5218g",
          "swift_compiler_version": "6.4",
          "swift_target_triple": "arm64-apple-macosx27.0",
          "sdk_name": "macosx27.0",
          "sdk_version": "27.0",
          "architecture": "arm64",
          "deployment_target": "27.0"
        }
        """
    }

    private static func completeDirectTransportObservations() -> [WS24InstalledAppDirectTransportObservation] {
        WS24InstalledAppDirectTransportOperation.allCases.map { operation in
            directTransportObservation(operation)
        }
    }

    private static func completeStressAttempts(
        for scenario: WS24InstalledAppStressScenario
    ) -> [WS24InstalledAppStressAttemptObservation] {
        (1...scenario.gate.minimumAcceptedAttempts).map { attemptIndex in
            stressAttempt(scenario, attemptIndex: attemptIndex)
        }
    }

    private static func securityObservation(
        sourceCommit: String = sourceCommit,
        installedExecutableSHA256: String = digest,
        sealedReleaseProvenancePassed: Bool = true,
        localSigningPolicyPassed: Bool = true,
        strictDeepCodesignPassed: Bool = true,
        certificateBackedAppleDevelopmentSigning: Bool = true,
        hardenedRuntimeEnabled: Bool = true,
        entitlementsLimitedToLocalDevelopmentPolicy: Bool = true,
        directTransportEvidence: WS24InstalledAppQualificationEvidence? = nil,
        stressEvidence: [WS24InstalledAppQualificationEvidence]? = nil
    ) -> WS24InstalledAppSecurityObservation {
        .init(
            sourceCommit: sourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            sealedReleaseProvenancePassed: sealedReleaseProvenancePassed,
            localSigningPolicyPassed: localSigningPolicyPassed,
            strictDeepCodesignPassed: strictDeepCodesignPassed,
            certificateBackedAppleDevelopmentSigning: certificateBackedAppleDevelopmentSigning,
            hardenedRuntimeEnabled: hardenedRuntimeEnabled,
            entitlementsLimitedToLocalDevelopmentPolicy: entitlementsLimitedToLocalDevelopmentPolicy,
            directTransportEvidence: directTransportEvidence ?? .init(
                gate: .directDebuggerTransportContracts,
                status: .passed,
                sourceCommit: sourceCommit,
                installedExecutableSHA256: installedExecutableSHA256
            ),
            stressEvidence: stressEvidence ?? WS24InstalledAppStressScenario.allCases.map {
                Self.stressEvidence(
                    for: $0,
                    sourceCommit: sourceCommit,
                    installedExecutableSHA256: installedExecutableSHA256
                )
            }
        )
    }

    private static func stressEvidence(
        for scenario: WS24InstalledAppStressScenario,
        sourceCommit: String = sourceCommit,
        installedExecutableSHA256: String = digest
    ) -> WS24InstalledAppQualificationEvidence {
        .init(
            gate: scenario.gate,
            status: .passed,
            sourceCommit: sourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            acceptedAttempts: scenario.gate.minimumAcceptedAttempts
        )
    }

    private static func completePerformanceObservations() -> [WS24InstalledAppPerformanceObservation] {
        WS24InstalledAppStressScenario.allCases.flatMap { scenario in
            (1...scenario.gate.minimumAcceptedAttempts).map { attemptIndex in
                performanceObservation(scenario, attemptIndex: attemptIndex)
            }
        }
    }

    private static func performanceObservation(
        _ scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        sourceCommit: String = sourceCommit,
        installedExecutableSHA256: String = digest,
        durationMilliseconds: Double = 250,
        peakResidentMemoryMegabytes: Double = 256,
        timedOut: Bool = false
    ) -> WS24InstalledAppPerformanceObservation {
        .init(
            scenario: scenario,
            attemptIndex: attemptIndex,
            sourceCommit: sourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            durationMilliseconds: durationMilliseconds,
            peakResidentMemoryMegabytes: peakResidentMemoryMegabytes,
            timedOut: timedOut
        )
    }

    private static func toolchainObservation(
        sourceCommit: String = sourceCommit,
        installedExecutableSHA256: String = digest,
        releaseProvenanceQualified: Bool = true,
        xcodeVersion: String = "27.0",
        swiftCompilerVersion: String = "6.4",
        swiftTargetTriple: String = "arm64-apple-macosx27.0",
        sdkName: String = "macosx27.0",
        sdkVersion: String = "27.0",
        architecture: String = "arm64",
        deploymentTarget: String = "27.0",
        hostArchitecture: String = "arm64",
        hostMacOSMajorVersion: Int = 27,
        developerDirectoryUsesXcode27: Bool = true
    ) -> WS24InstalledAppToolchainObservation {
        .init(
            sourceCommit: sourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            releaseProvenanceQualified: releaseProvenanceQualified,
            xcodeVersion: xcodeVersion,
            swiftCompilerVersion: swiftCompilerVersion,
            swiftTargetTriple: swiftTargetTriple,
            sdkName: sdkName,
            sdkVersion: sdkVersion,
            architecture: architecture,
            deploymentTarget: deploymentTarget,
            hostArchitecture: hostArchitecture,
            hostMacOSMajorVersion: hostMacOSMajorVersion,
            developerDirectoryUsesXcode27: developerDirectoryUsesXcode27
        )
    }

    private static func stressAttempt(
        _ scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        passed: Bool = true,
        sourceCommit: String = sourceCommit,
        installedExecutableSHA256: String = digest,
        observedProcessID: Int32? = 8_000,
        usedBroadProcessKill: Bool = false,
        leftProcessResidue: Bool = false,
        preservedTargetAfterDetach: Bool? = nil,
        terminalCleanupCompleted: Bool = true
    ) -> WS24InstalledAppStressAttemptObservation {
        .init(
            scenario: scenario,
            attemptIndex: attemptIndex,
            passed: passed,
            sourceCommit: sourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            observedProcessID: observedProcessID.map { $0 + Int32(attemptIndex) },
            usedBroadProcessKill: usedBroadProcessKill,
            leftProcessResidue: leftProcessResidue,
            preservedTargetAfterDetach: preservedTargetAfterDetach
                ?? (scenario.requiresNonKillingDetachProof ? true : nil),
            terminalCleanupCompleted: terminalCleanupCompleted
        )
    }

    private static func directTransportObservation(
        _ operation: WS24InstalledAppDirectTransportOperation,
        source: WS24InstalledAppDirectTransportObservationSource = .directDebuggerClient,
        sourceCommit: String = sourceCommit,
        installedExecutableSHA256: String = digest,
        observedProcessID: Int32? = 1234,
        usedBroadProcessKill: Bool = false,
        leftProcessResidue: Bool = false,
        targetSurvivedAfterOperation overrideSurvival: Bool? = nil
    ) -> WS24InstalledAppDirectTransportObservation {
        .init(
            operation: operation,
            passed: true,
            source: source,
            sourceCommit: sourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            observedProcessID: observedProcessID,
            usedBroadProcessKill: usedBroadProcessKill,
            leftProcessResidue: leftProcessResidue,
            targetSurvivedAfterOperation: overrideSurvival ?? targetSurvival(for: operation)
        )
    }

    private static func targetSurvival(
        for operation: WS24InstalledAppDirectTransportOperation
    ) -> Bool? {
        switch operation {
        case .nonKillingDetach:
            true
        case .terminate:
            false
        case .launch, .attach, .restart:
            nil
        }
    }

    private func replace(
        _ evidence: inout [WS24InstalledAppQualificationEvidence],
        gate: WS24InstalledAppQualificationGate,
        with replacement: WS24InstalledAppQualificationEvidence
    ) {
        let index = evidence.firstIndex { $0.gate == gate }!
        evidence[index] = replacement
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WS24InstalledAppQualificationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func temporaryInstalledAppBundle() throws -> URL {
        let directory = try temporaryDirectory()
        let app = directory.appendingPathComponent("MacScope.app", isDirectory: true)
        let macOS = app
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("installed executable bytes".utf8).write(
            to: macOS.appendingPathComponent("MacScope", isDirectory: false)
        )
        return app
    }

    private static func sha256Hex(contentsOf url: URL) throws -> String {
        let bytes = try Data(contentsOf: url)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func installedSourceCommit(in provenanceURL: URL) throws -> String {
        struct Payload: Decodable {
            let gitHeadCommit: String?

            enum CodingKeys: String, CodingKey {
                case gitHeadCommit = "git_head_commit"
            }
        }

        let payload = try JSONDecoder().decode(
            Payload.self,
            from: try Data(contentsOf: provenanceURL)
        )
        guard let gitHeadCommit = payload.gitHeadCommit,
              gitHeadCommit.count == 40 else {
            throw XCTSkip("Installed MacScope provenance has no 40-character git_head_commit.")
        }
        return gitHeadCommit
    }
}

private final class RecordingDirectTransportExecutor:
    WS24InstalledAppDirectTransportExecuting,
    @unchecked Sendable
{
    enum Failure: Error {
        case requestedFailure
    }

    private(set) var operations: [WS24InstalledAppDirectTransportOperation] = []
    private(set) var executablePaths: [String] = []
    private let resultsByOperation: [WS24InstalledAppDirectTransportOperation:
        WS24InstalledAppDirectTransportStepResult]
    private let failingOperation: WS24InstalledAppDirectTransportOperation?

    init(
        resultsByOperation: [WS24InstalledAppDirectTransportOperation:
            WS24InstalledAppDirectTransportStepResult] = [:],
        failingOperation: WS24InstalledAppDirectTransportOperation? = nil
    ) {
        self.resultsByOperation = resultsByOperation
        self.failingOperation = failingOperation
    }

    func executeDirectTransportStep(
        _ operation: WS24InstalledAppDirectTransportOperation,
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppDirectTransportStepResult {
        operations.append(operation)
        executablePaths.append(configuration.installedExecutableURL.path)
        if operation == failingOperation {
            throw Failure.requestedFailure
        }
        if let result = resultsByOperation[operation] {
            return result
        }
        return .init(
            operation: operation,
            passed: true,
            observedProcessID: 9_000 + Int32(operations.count),
            targetSurvivedAfterOperation: Self.targetSurvival(for: operation)
        )
    }

    private static func targetSurvival(
        for operation: WS24InstalledAppDirectTransportOperation
    ) -> Bool? {
        switch operation {
        case .nonKillingDetach:
            true
        case .terminate:
            false
        case .launch, .attach, .restart:
            nil
        }
    }
}

private final class RecordingStressExecutor:
    WS24InstalledAppStressExecuting,
    @unchecked Sendable
{
    enum Failure: Error {
        case requestedFailure
    }

    private(set) var attempts: [Int] = []
    private(set) var executablePaths: [String] = []
    private let failingAttemptIndex: Int?

    init(failingAttemptIndex: Int? = nil) {
        self.failingAttemptIndex = failingAttemptIndex
    }

    func executeStressAttempt(
        scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppStressAttemptResult {
        attempts.append(attemptIndex)
        executablePaths.append(configuration.installedExecutableURL.path)
        if attemptIndex == failingAttemptIndex {
            throw Failure.requestedFailure
        }
        return .init(
            scenario: scenario,
            attemptIndex: attemptIndex,
            passed: true,
            observedProcessID: 10_000 + Int32(attemptIndex),
            preservedTargetAfterDetach: scenario.requiresNonKillingDetachProof ? true : nil
        )
    }
}

private extension Array where Element == WS24InstalledAppStressAttemptObservation {
    func replacingStressAttempt(
        at attemptIndex: Int,
        with replacement: WS24InstalledAppStressAttemptObservation
    ) -> [WS24InstalledAppStressAttemptObservation] {
        var copy = self
        guard let index = copy.firstIndex(where: { $0.attemptIndex == attemptIndex }) else {
            return copy
        }
        copy[index] = replacement
        return copy
    }
}

private extension Array where Element == WS24InstalledAppPerformanceObservation {
    func replacingPerformanceObservation(
        scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        with replacement: WS24InstalledAppPerformanceObservation
    ) -> [WS24InstalledAppPerformanceObservation] {
        var copy = self
        guard let index = copy.firstIndex(where: {
            $0.scenario == scenario && $0.attemptIndex == attemptIndex
        }) else {
            return copy
        }
        copy[index] = replacement
        return copy
    }
}
