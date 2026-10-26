import Foundation
@testable import MacScope

struct Phase2QualificationGateCanaryEvidenceSummary: Equatable, Sendable {
    let normalPhaseCount: Int
    let completeUsagePhaseCount: Int
    let cancellationPhaseCount: Int
    let cancellationDrained: Bool
    let cancellationOrderingProven: Bool
    let retainedEvidenceIsPayloadFree: Bool
    let boundedEvidenceWasWritten: Bool
    let runtimeRemainedCurrent: Bool
}

enum Phase2QualificationGateCanaryDecision {
    static func accepts(_ value: Phase2QualificationGateCanaryEvidenceSummary) -> Bool {
        value.normalPhaseCount == 2
            && value.completeUsagePhaseCount == 2
            && value.cancellationPhaseCount == 1
            && value.cancellationDrained
            && value.cancellationOrderingProven
            && value.retainedEvidenceIsPayloadFree
            && value.boundedEvidenceWasWritten
            && value.runtimeRemainedCurrent
    }
}

enum Phase2QualificationGateCanaryFixtureSelector {
    static func normalFixture(
        in fixtures: [Phase2LiveQualificationTrialFixture]
    ) -> Phase2LiveQualificationTrialFixture? {
        fixtures.first {
            $0.key.probeID == "live.performance.standard-turn" && $0.key.trial == 1
        }
    }

    static func cancellationFixture(
        in fixtures: [Phase2LiveQualificationTrialFixture]
    ) -> Phase2LiveQualificationTrialFixture? {
        fixtures.first {
            $0.key.probeID == "live.safety.cancellation-without-semantic-output"
                && $0.key.trial == 1
        }
    }
}

@MainActor
enum Phase2QualificationGateCanaryBarrier {
    enum CanaryError: Error, Equatable, Sendable {
        case alreadyAttempted
        case fixtureUnavailable
        case runtimeChanged
        case normalPhaseFailed
        case usageIncomplete
        case cancellationFailed
        case evidenceWriteFailed
        case authorizationInvalid
    }

    struct Authorization: Sendable {
        fileprivate let runID: UUID
        fileprivate let nonce: UUID
        let evidenceDigest: String
        fileprivate let profileContract: Phase2QualificationProfileContract

        private init(runID: UUID, nonce: UUID, evidenceDigest: String,
                     profileContract: Phase2QualificationProfileContract) {
            self.runID = runID
            self.nonce = nonce
            self.evidenceDigest = evidenceDigest
            self.profileContract = profileContract
        }

        fileprivate static func issue(
            runID: UUID,
            nonce: UUID,
            evidenceDigest: String,
            profileContract: Phase2QualificationProfileContract
        ) -> Self {
            .init(runID: runID, nonce: nonce, evidenceDigest: evidenceDigest,
                  profileContract: profileContract)
        }
    }

    private static var attemptedRunIDs: Set<UUID> = []
    private static var outstandingAuthorizations: [UUID: UUID] = [:]

    static func executeOneShot(
        session: Phase2QualificationGateRuntimeSession
    ) async throws -> Authorization {
        let profileEvidence = try Phase2QualificationGateProfileEvidence.current(session: session)
        guard attemptedRunIDs.insert(session.runID).inserted else {
            throw CanaryError.alreadyAttempted
        }
        let catalog = session.profileContract.production.liveScenarioCatalog
        let fixtures = try catalog.productionFixtures()
        guard let normal = Phase2QualificationGateCanaryFixtureSelector.normalFixture(
            in: fixtures
        ), let cancellation = Phase2QualificationGateCanaryFixtureSelector.cancellationFixture(
            in: fixtures
        ) else { throw CanaryError.fixtureUnavailable }
        guard session.captureFreshObservation() != nil else {
            throw CanaryError.runtimeChanged
        }

        let processAuthority = Phase2QualificationGateProcessAuthority(
            prepared: session.preparedQualification,
            workerProcessValidator: session.buildAuthority
        )
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: session.controllerAuthority,
            workerProcessReceiptObserver: processAuthority
        )
        let normalTrialKey = try Phase2QualificationTrialKey(
            requirementID: "live.gate-canary.normal",
            trialIndex: 1,
            attempt: 1
        )
        let cancellationTrialKey = try Phase2QualificationTrialKey(
            requirementID: "live.gate-canary.cancellation",
            trialIndex: 1,
            attempt: 1
        )
        let measurement = Phase2LiveQualificationMeasurementConfiguration(
            metricPlan: try canaryMetricPlan(
                normal: normalTrialKey,
                cancellation: cancellationTrialKey
            ),
            clock: Phase2ContinuousMonotonicClock(),
            residentSetSampler: processAuthority.residentSetSampler,
            maximumCancellationDrainMilliseconds: 2_000
        )
        let scorer = Phase2ProductionLiveQualificationScorer()
        let factory = Phase2LiveQualificationRequestFactory()
        let normalSessionID = canaryUUID(runID: session.runID, label: "normal.session")
        let normalTurnID = canaryUUID(runID: session.runID, label: "normal.turn")
        let selectionRequest = canaryRequest(
            basedOn: try factory.selectionRequest(for: normal),
            sessionID: normalSessionID,
            turnID: normalTurnID,
            requestID: canaryUUID(runID: session.runID, label: "normal.selection")
        )
        let finalizationRequest = canaryRequest(
            basedOn: try factory.finalizationRequest(for: normal),
            sessionID: normalSessionID,
            turnID: normalTurnID,
            requestID: canaryUUID(runID: session.runID, label: "normal.finalization")
        )
        let normalObserver = Phase2LiveQualificationAttemptMeasurementObserver(
            trialKey: normalTrialKey,
            configuration: measurement
        )
        let selection = await coordinator.run(
            request: selectionRequest,
            measurementObserver: normalObserver
        )
        guard case .finished(let selectionLease, let selectionOutcome) = selection,
              selectionLease == session.preparedQualification.runtimeBinding.readyLease,
              session.captureFreshObservation() != nil,
              case .accepted(let selectionDigest) = scorer.classifySelection(
                selectionOutcome,
                fixture: normal
              )
        else { throw CanaryError.normalPhaseFailed }
        let finalization = await coordinator.run(
            request: finalizationRequest,
            measurementObserver: normalObserver
        )
        guard case .finished(let finalLease, let finalOutcome) = finalization,
              finalLease == session.preparedQualification.runtimeBinding.readyLease,
              session.captureFreshObservation() != nil
        else { throw CanaryError.normalPhaseFailed }
        let finalClassification = scorer.classifyFinalization(
            finalOutcome,
            fixture: normal,
            selectionEvidenceDigest: selectionDigest
        )
        guard finalClassification.outcome == .passed else {
            throw CanaryError.normalPhaseFailed
        }
        normalObserver.recordValidatedTerminalBoundary()
        guard normalObserver.hasCompletePhaseClosure,
              !normalObserver.hasFailed,
              let normalMeasurement = normalObserver.finish(),
              normalMeasurement.phaseUsages.count == 2,
              normalMeasurement.phaseUsages.allSatisfy({ phase in
                let (expectedTotalTokens, tokenCountOverflow) = phase.usage.promptTokens
                    .addingReportingOverflow(phase.usage.completionTokens)
                return !tokenCountOverflow
                    && phase.usage.totalTokens == expectedTotalTokens
              })
        else { throw CanaryError.usageIncomplete }

        let cancellationObserver = Phase2LiveQualificationAttemptMeasurementObserver(
            trialKey: cancellationTrialKey,
            configuration: measurement
        )
        let cancellationRequest = canaryRequest(
            basedOn: try factory.finalizationRequest(for: cancellation),
            sessionID: canaryUUID(runID: session.runID, label: "cancellation.session"),
            turnID: canaryUUID(runID: session.runID, label: "cancellation.turn"),
            requestID: canaryUUID(runID: session.runID, label: "cancellation.request")
        )
        let cancellationBarrier = Phase2ControlledCancellationBarrier(
            requestID: cancellationRequest.requestID
        )
        let cancellationTask = Task { @MainActor in
            await coordinator.run(
                request: cancellationRequest,
                measurementObserver: cancellationObserver,
                controlledCancellationBarrier: cancellationBarrier
            )
        }
        guard await cancellationBarrier.waitForProviderDispatch() else {
            cancellationTask.cancel()
            _ = await cancellationTask.value
            throw CanaryError.cancellationFailed
        }
        cancellationTask.cancel()
        let cancellationResult = await cancellationTask.value
        guard case .finished(let cancellationLease, let cancellationOutcome) = cancellationResult,
              cancellationLease == session.preparedQualification.runtimeBinding.readyLease,
              cancellationOutcome.disposition == .cancelled,
              cancellationOutcome.previewDeltas.isEmpty,
              cancellationOutcome.toolProposals.isEmpty,
              cancellationOutcome.finalCandidate == nil,
              session.captureFreshObservation() != nil
        else { throw CanaryError.cancellationFailed }
        cancellationObserver.recordValidatedTerminalBoundary()
        guard cancellationObserver.hasCompletePhaseClosure,
              !cancellationObserver.hasFailed,
              let cancellationMeasurement = cancellationObserver.finish(),
              let cancellationLatencyMilliseconds =
                cancellationMeasurement.cancellationLatencyMilliseconds,
              cancellationLatencyMilliseconds <= 2_000,
              cancellationBarrier.hasProvenDispatchBeforeCancellation
        else { throw CanaryError.cancellationFailed }

        let payloadFreeDigest = try canaryEvidenceDigest(
            runID: session.runID,
            selectionRequestID: selectionRequest.requestID,
            finalizationRequestID: finalizationRequest.requestID,
            cancellationRequestID: cancellationRequest.requestID,
            selectionEvidenceDigest: selectionDigest,
            finalizationEvidenceDigest: finalClassification.evidenceDigest,
            normalMeasurement: normalMeasurement,
            cancellationMeasurement: cancellationMeasurement,
            profileEvidence: profileEvidence
        )
        let wrote = Phase2QualificationGateCanaryEvidenceWriter.write(
            runID: session.runID,
            evidenceDigest: payloadFreeDigest,
            normalPhaseCount: normalMeasurement.phaseUsages.count,
            cancellationLatencyMilliseconds:
                cancellationLatencyMilliseconds,
            profileEvidence: profileEvidence
        )
        let summary = Phase2QualificationGateCanaryEvidenceSummary(
            normalPhaseCount: 2,
            completeUsagePhaseCount: normalMeasurement.phaseUsages.count,
            cancellationPhaseCount: 1,
            cancellationDrained: cancellationLatencyMilliseconds <= 2_000,
            cancellationOrderingProven:
                cancellationBarrier.hasProvenDispatchBeforeCancellation,
            retainedEvidenceIsPayloadFree: phase2IsSHA256Hex(payloadFreeDigest),
            boundedEvidenceWasWritten: wrote,
            runtimeRemainedCurrent: session.captureFreshObservation() != nil
        )
        guard Phase2QualificationGateCanaryDecision.accepts(summary) else {
            throw wrote ? CanaryError.runtimeChanged : CanaryError.evidenceWriteFailed
        }
        let nonce = UUID()
        outstandingAuthorizations[session.runID] = nonce
        return .issue(
            runID: session.runID,
            nonce: nonce,
            evidenceDigest: payloadFreeDigest,
            profileContract: session.profileContract
        )
    }

    static func consume(
        _ authorization: Authorization,
        for session: Phase2QualificationGateRuntimeSession
    ) throws {
        guard authorization.runID == session.runID,
              authorization.profileContract == session.profileContract,
              outstandingAuthorizations.removeValue(forKey: session.runID)
                == authorization.nonce,
              session.captureFreshObservation() != nil
        else { throw CanaryError.authorizationInvalid }
    }

    private static func canaryEvidenceDigest(
        runID: UUID,
        selectionRequestID: UUID,
        finalizationRequestID: UUID,
        cancellationRequestID: UUID,
        selectionEvidenceDigest: String,
        finalizationEvidenceDigest: String,
        normalMeasurement: Phase2QualificationAttemptMeasurement,
        cancellationMeasurement: Phase2QualificationAttemptMeasurement,
        profileEvidence: Phase2QualificationGateProfileEvidence?
    ) throws -> String {
        let object: [String: Any] = [
                "cancellation_latency_ms":
                    cancellationMeasurement.cancellationLatencyMilliseconds!,
                "cancellation_injection_point":
                    "after-dispatch-before-first-semantic-event",
                "dispatch_receipt_boundary": "http-response-headers",
                "cancellation_request_id": cancellationRequestID.uuidString.lowercased(),
                "finalization_request_id": finalizationRequestID.uuidString.lowercased(),
                "finalization_evidence_digest": finalizationEvidenceDigest,
                "normal_phase_count": normalMeasurement.phaseUsages.count,
                "normal_total_latency_ms": normalMeasurement.totalLatencyMilliseconds,
                "run_id": runID.uuidString.lowercased(),
                "selection_request_id": selectionRequestID.uuidString.lowercased(),
                "selection_evidence_digest": selectionEvidenceDigest,
                "version": 1,
            ]
        let identity = try Phase2QualificationV2Identity.make(
            id: profileEvidence == nil ? "phase2.r1.gate-g4-canary.v1" : "phase2.local.qwen38-v2-q6k-canary.v1",
            version: 1,
            object: profileEvidence?.adding(to: object, state: .canaryPassed) ?? object
        )
        guard let digest = identity.sha256 else { throw CanaryError.evidenceWriteFailed }
        return digest
    }

    private static func canaryRequest(
        basedOn base: Phase2InferenceRequest,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID
    ) -> Phase2InferenceRequest {
        Phase2InferenceRequest(
            protocolVersion: base.protocolVersion,
            phase: base.phase,
            sessionID: sessionID,
            turnID: turnID,
            requestID: requestID,
            document: base.document,
            workspace: base.workspace,
            lifecycleRevision: base.lifecycleRevision,
            userGoal: base.userGoal + "\n\n[F4C one-shot provider canary]",
            groundedContext: base.groundedContext,
            toolHandles: base.toolHandles,
            limits: base.limits
        )
    }

    private static func canaryMetricPlan(
        normal: Phase2QualificationTrialKey,
        cancellation: Phase2QualificationTrialKey
    ) throws -> Phase2QualificationMetricPlan {
        try .init(applicableTrialKeys: [
            .totalLatencyMilliseconds: [normal],
            .timeToFirstSemanticEventMilliseconds: [normal],
            .generatedTokenCount: [normal],
            .throughputMilliTokensPerSecond: [normal],
            .peakResidentBytes: [normal, cancellation],
            .cancellationLatencyMilliseconds: [cancellation],
        ])
    }

    private static func canaryUUID(runID: UUID, label: String) -> UUID {
        let digest = Phase2QualificationGateHash.sha256(Data(
            "phase2.r1.gate-g4-canary.v1\0\(runID.uuidString.lowercased())\0\(label)".utf8
        ))
        let value = String(digest.prefix(32))
        let string = [
            value.prefix(8),
            value.dropFirst(8).prefix(4),
            value.dropFirst(12).prefix(4),
            value.dropFirst(16).prefix(4),
            value.dropFirst(20).prefix(12),
        ].map(String.init).joined(separator: "-")
        return UUID(uuidString: string)!
    }
}

private enum Phase2QualificationGateCanaryEvidenceWriter {
    static func write(
        runID: UUID,
        evidenceDigest: String,
        normalPhaseCount: Int,
        cancellationLatencyMilliseconds: Int64,
        profileEvidence: Phase2QualificationGateProfileEvidence? = nil
    ) -> Bool {
        guard phase2IsSHA256Hex(evidenceDigest), normalPhaseCount == 2,
              cancellationLatencyMilliseconds >= 0,
              let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first
        else { return false }
        let directory = applicationSupport
            .appendingPathComponent("MacScope/Qualification/F4C", isDirectory: true)
            .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
        let file = directory.appendingPathComponent("canary.json")
        let object: [String: Any] = [
            "cancellation_injection_point":
                "after-dispatch-before-first-semantic-event",
            "dispatch_receipt_boundary": "http-response-headers",
            "cancellation_latency_ms": cancellationLatencyMilliseconds,
            "evidence_digest": evidenceDigest,
            "normal_phase_count": normalPhaseCount,
            "run_id": runID.uuidString.lowercased(),
            "version": 1,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: profileEvidence?.adding(to: object, state: .canaryPassed) ?? object,
            options: [.sortedKeys]
        ) else { return false }
        return Phase2QualificationGateSecureFileStore.write(
            data,
            relativeDirectoryComponents: [
                "MacScope", "Qualification", "F4C", runID.uuidString.lowercased(),
            ],
            fileName: file.lastPathComponent,
            existingPolicy: .reject
        ) != nil
    }
}
