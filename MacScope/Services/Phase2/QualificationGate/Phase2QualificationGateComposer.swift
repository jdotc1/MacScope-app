import Darwin
import Foundation
@testable import MacScope

/// CoreTests-only owner of the complete 163-trial Gate-G4 artifact. Ordinary CoreTests never call
/// the live entry point: the explicit certificate-signed F4C Gate-G4 command must set the closed
/// opt-in before this type can construct a provider or emit a request.
@MainActor
enum Phase2QualificationGateComposer {
    enum ComposerError: Error, Equatable, Sendable {
        case explicitLiveGateOptInRequired
        case invalidDeterministicEvidence
        case invalidLiveEvidence
        case noncanonicalObservationDenominator
        case evaluationTimeUnavailable
        case oneShotClaimUnavailable
        case checkpointUnavailable
        case reportUnavailable
    }

    static let liveGateOptInEnvironmentKey =
        "MACSCOPE_RUN_PHASE2_F4C_SIGNED_GATE"

    /// The sole real-live Gate entry point. It accepts operational state needed to reach the
    /// already-preflighted local provider, but no fixtures, scorer, pass set, aggregate, process
    /// roots, provenance, or observations. Every evidentiary authority is constructed below.
    static func executeSignedStandardGate(
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) async throws -> Phase2ModelQualificationReport {
        guard ProcessInfo.processInfo.environment[liveGateOptInEnvironmentKey] == "1" else {
            throw ComposerError.explicitLiveGateOptInRequired
        }
        let session = try await Phase2QualificationGateRuntimeCollector.collectCurrent(selector: selector)
        let profileEvidence = try Phase2QualificationGateProfileEvidence.current(session: session)
        let claimIdentity = try Phase2QualificationGateOneShotClaimIdentity.current(
            session: session
        )
        guard let oneShotClaim = Phase2QualificationGateOneShotClaimWriter().claim(
            runID: session.runID,
            identity: claimIdentity
        ) else { throw ComposerError.oneShotClaimUnavailable }
        let outcomeWriter = Phase2QualificationGateOutcomeWriter(
            runID: session.runID,
            oneShotClaim: oneShotClaim,
            profileEvidence: profileEvidence
        )
        let canaryAuthorization: Phase2QualificationGateCanaryBarrier.Authorization
        do {
            canaryAuthorization = try await Phase2QualificationGateCanaryBarrier.executeOneShot(
                session: session
            )
        } catch {
            guard outcomeWriter.recordInconclusive(
                canaryEvidenceDigest: nil,
                checkpointEvidence: nil,
                reportID: nil,
                verdict: nil,
                reasonCode: "canary-failed"
            ) else { throw ComposerError.checkpointUnavailable }
            throw error
        }
        let deterministicEvidence =
            await Phase2ProductionProtocolFixtureExecutor.executeStandard()
        return try await executeAuthorizedStandard(
            session: session,
            authorization: canaryAuthorization,
            deterministicEvidence: deterministicEvidence,
            outcomeWriter: outcomeWriter
        )
    }

    private static func executeAuthorizedStandard(
        session: Phase2QualificationGateRuntimeSession,
        authorization canaryAuthorization: Phase2QualificationGateCanaryBarrier.Authorization,
        deterministicEvidence: Phase2ProductionProtocolVerifiedFixtureEvidence,
        outcomeWriter: Phase2QualificationGateOutcomeWriter
    ) async throws -> Phase2ModelQualificationReport {
        let prepared = session.preparedQualification
        let processAuthority = Phase2QualificationGateProcessAuthority(
            prepared: prepared,
            workerProcessValidator: session.buildAuthority
        )
        let checkpointWriter = Phase2QualificationGateCheckpointWriter(
            runID: session.runID,
            canaryEvidenceDigest: canaryAuthorization.evidenceDigest,
            profileEvidence: try Phase2QualificationGateProfileEvidence.current(session: session)
        )
        var candidateReport: Phase2ModelQualificationReport?
        do {
            try Phase2QualificationGateCanaryBarrier.consume(
                canaryAuthorization,
                for: session
            )
            let liveEvidence = try await Phase2ProductionLiveQualificationExecutor.executeStandard(
                prepared: prepared,
                controller: session.controllerAuthority,
                processAuthority: processAuthority,
                captureFreshObservation: session.captureFreshObservation,
                onFinalizedTrial: checkpointWriter.record,
                onTerminalExecution: checkpointWriter.recordTerminal,
                selector: session.profileContract.selector
            )
            guard session.validateArtifactCryptographically() else {
                throw ComposerError.invalidLiveEvidence
            }
            let report = try composeStandardReport(
                prepared: prepared,
                deterministicEvidence: deterministicEvidence,
                liveEvidence: liveEvidence,
                evaluatedAtEpochMilliseconds: try currentEpochMilliseconds(
                    notBefore: liveEvidence.execution.terminalEpochMilliseconds
                ),
                selector: session.profileContract.selector
            )
            candidateReport = report
            guard let checkpointEvidence = checkpointWriter.evidenceBinding,
                  let preparedOutcome = outcomeWriter.prepareReport(
                      canaryEvidenceDigest: canaryAuthorization.evidenceDigest,
                      checkpointEvidence: checkpointEvidence,
                      reportID: report.reportID,
                      verdict: report.verdict
                  )
            else { throw ComposerError.checkpointUnavailable }
            guard Phase2QualificationGateArtifactWriter.write(
                report,
                preparedOutcome: preparedOutcome,
                outcomeWriter: outcomeWriter
            ) != nil else { throw ComposerError.reportUnavailable }
            return report
        } catch {
            if !outcomeWriter.hasRecordedOutcome {
                guard outcomeWriter.recordInconclusive(
                    canaryEvidenceDigest: canaryAuthorization.evidenceDigest,
                    checkpointEvidence: checkpointWriter.evidenceBinding,
                    reportID: candidateReport?.reportID,
                    verdict: candidateReport?.verdict,
                    reasonCode: "standard-run-failed"
                ) else { throw ComposerError.checkpointUnavailable }
            }
            throw error
        }
    }

    /// Pure unit-test seam for already-closed evidence. It cannot dispatch inference and remains
    /// in CoreTests support, outside every shipped target and production composition path.
    static func composeStandardReportForTesting(
        prepared: Phase2PreparedLiveQualification,
        deterministicEvidence: Phase2ProductionProtocolVerifiedFixtureEvidence,
        liveEvidence: Phase2LiveQualificationEvidence,
        evaluatedAtEpochMilliseconds: Int64,
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) throws -> Phase2ModelQualificationReport {
        try composeStandardReport(
            prepared: prepared,
            deterministicEvidence: deterministicEvidence,
            liveEvidence: liveEvidence,
            evaluatedAtEpochMilliseconds: evaluatedAtEpochMilliseconds,
            selector: selector
        )
    }

    private static func composeStandardReport(
        prepared: Phase2PreparedLiveQualification,
        deterministicEvidence: Phase2ProductionProtocolVerifiedFixtureEvidence,
        liveEvidence: Phase2LiveQualificationEvidence,
        evaluatedAtEpochMilliseconds: Int64,
        selector: Phase2QualificationProfileSelector
    ) throws -> Phase2ModelQualificationReport {
        let standard = Phase2QualificationProfileContract.resolve(selector).production
        guard prepared.evidenceBinding.productionDefinition == standard.definitionIdentity,
              liveEvidence.execution.terminationStatus == .completed,
              liveEvidence.evidenceBundle.environment
                == prepared.evidenceBinding.qualificationEnvironment,
              liveEvidence.evidenceBundle.runtimeProvenance.startedAtEpochMilliseconds
                == liveEvidence.execution.firstAdmissionEpochMilliseconds,
              liveEvidence.evidenceBundle.runtimeProvenance.endedAtEpochMilliseconds
                == liveEvidence.execution.terminalEpochMilliseconds
        else { throw ComposerError.invalidLiveEvidence }

        let deterministicObservations: [Phase2QualificationProbeObservation]
        do {
            deterministicObservations = try deterministicEvidence
                .qualificationObservations()
        } catch {
            throw ComposerError.invalidDeterministicEvidence
        }
        let observations = deterministicObservations
            + liveEvidence.execution.observations
        let expectedAttemptIDs = standard.policy.requirements.flatMap { requirement in
            (1...requirement.requiredTrialCount).map { trial in
                "\(requirement.probeID)#\(trial)#1"
            }
        }
        guard observations.count == 163,
              deterministicObservations.count == 99,
              liveEvidence.execution.observations.count == 64,
              observations.map(\.attemptID) == expectedAttemptIDs
        else { throw ComposerError.noncanonicalObservationDenominator }

        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let run = try Phase2ModelQualificationRun(
            version: 2,
            profileID: canonicalizer.stableID(for: prepared.profile),
            policyIdentity: standard.policyIdentity,
            protocolManifestDigest: canonicalizer.protocolManifestDigest(
                for: prepared.profile.protocolManifest
            ),
            protocolProbeCatalogIdentity: standard.protocolProbeCatalogIdentity,
            liveQualificationCorpusIdentity: standard.liveScenarioCatalog.identity,
            metricSemanticsIdentity: standard.metricSemanticsIdentity,
            evidenceBundle: liveEvidence.evidenceBundle,
            hardwareTier: prepared.profile.hardwareTier,
            terminationStatus: .completed,
            observations: observations,
        )
        let maximumAge = try requiredMaximumEvidenceAge(standard.policy)
        let context = try Phase2ModelQualificationEvaluationContext(
            evidenceBundle: liveEvidence.evidenceBundle,
            evaluatedAtEpochMilliseconds: evaluatedAtEpochMilliseconds,
            maximumEvidenceAgeMilliseconds: maximumAge
        )
        guard let report = try Phase2ModelQualificationHarness().evaluate(
            profile: prepared.profile,
            policy: standard.policy,
            run: run,
            context: context
        ), report.declaredTrialCount == 163,
           report.observations.count == 163,
           report.observedAttemptCount == 163,
           report.retryAttemptCount == 0
        else {
            throw ComposerError.reportUnavailable
        }
        return report
    }

    private static func requiredMaximumEvidenceAge(
        _ policy: Phase2ModelQualificationPolicy
    ) throws -> Int64 {
        guard let value = policy.maximumEvidenceAgeMilliseconds else {
            throw ComposerError.reportUnavailable
        }
        return value
    }

    private static func currentEpochMilliseconds(
        notBefore terminal: Int64?
    ) throws -> Int64 {
        guard let terminal else { throw ComposerError.invalidLiveEvidence }
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(Int64.max)
        else { throw ComposerError.evaluationTimeUnavailable }
        let value = Int64(milliseconds.rounded(.down))
        guard value >= terminal else {
            throw ComposerError.evaluationTimeUnavailable
        }
        return value
    }
}

/// Candidate-only metadata. Its presence is reporting, never session or dispatch authority.
/// Historical evidence remains byte-for-byte unchanged because nil contributes no keys.
struct Phase2QualificationGateProfileEvidence: Equatable, Sendable {
    let contract: Phase2QualificationProfileContract
    let admission: Phase2ProviderAdmissionEvidence
    let gitHeadCommit: String
    let appExecutableSHA256: String
    let workerExecutableSHA256: String

    @MainActor
    static func current(session: Phase2QualificationGateRuntimeSession) throws -> Self? {
        guard session.profileContract.requiresProviderAdmission else { return nil }
        guard let admission = session.providerAdmission,
              admission.providerPolicyIdentity == session.profileContract.providerPolicyIdentity,
              session.preparedQualification.evidenceBinding.productionDefinition
                == session.profileContract.definitionIdentity
        else { throw Phase2QualificationGateComposer.ComposerError.invalidLiveEvidence }
        return .init(contract: session.profileContract, admission: admission,
                     gitHeadCommit: session.buildAuthority.provenance.gitHeadCommit,
                     appExecutableSHA256: session.buildAuthority.appExecutableSHA256,
                     workerExecutableSHA256: session.buildAuthority.workerExecutableSHA256)
    }

    var attachedObject: [String: Any] {
        [
            "profile_selector": contract.selector.rawValue,
            "qualification_definition": component(contract.definitionIdentity),
            "provider_admission_policy": component(contract.providerPolicyIdentity),
            "provider_build": component(admission.providerBuildIdentity),
            "runtime_closure": component(admission.runtimeClosureIdentity),
            "template_authority": component(admission.templateAuthorityIdentity),
            "generation_admission": component(contract.generationAdmissionIdentity),
        ]
    }

    func adding(to object: [String: Any], state: Phase2QualificationProfileAdmissionState) -> [String: Any] {
        var result = object
        result["schema_version"] = 2
        result["profile_selector"] = contract.selector.rawValue
        result["qualification_definition_sha256"] = contract.definitionIdentity.sha256!
        result["provider_build_sha256"] = admission.providerBuildIdentity.sha256!
        result["runtime_closure_sha256"] = admission.runtimeClosureIdentity.sha256!
        result["template_authority_sha256"] = admission.templateAuthorityIdentity.sha256!
        result["admission_state"] = state.rawValue
        result["git_head_commit"] = gitHeadCommit
        result["app_executable_sha256"] = appExecutableSHA256
        result["worker_executable_sha256"] = workerExecutableSHA256
        return result
    }

    private func component(_ value: Phase2ProtocolComponentIdentity) -> [String: Any] {
        ["id": value.id, "version": value.version, "sha256": value.sha256!]
    }
}

/// Volatile signed-artifact evidence retained beside a stable one-shot claim key. Rebuilding or
/// re-signing the same frozen F4C-B delivery changes this evidence, but must not mint another live
/// qualification opportunity.
struct Phase2QualificationGateOneShotArtifactEvidence: Equatable, Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidEvidence
        case encodingFailed
    }

    let appExecutableSHA256: String
    let workerExecutableSHA256: String
    let signingRequirementSHA256: String
    let digest: String

    init(
        appExecutableSHA256: String,
        workerExecutableSHA256: String,
        signingRequirementSHA256: String
    ) throws {
        guard [
            appExecutableSHA256, workerExecutableSHA256, signingRequirementSHA256,
        ].allSatisfy(phase2IsSHA256Hex) else { throw Error.invalidEvidence }
        self.appExecutableSHA256 = appExecutableSHA256
        self.workerExecutableSHA256 = workerExecutableSHA256
        self.signingRequirementSHA256 = signingRequirementSHA256
        let object = [
            "app_executable_sha256": appExecutableSHA256,
            "signing_requirement_sha256": signingRequirementSHA256,
            "worker_executable_sha256": workerExecutableSHA256,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { throw Error.encodingFailed }
        digest = Phase2QualificationGateHash.sha256(data)
    }

    fileprivate var evidenceObject: [String: Any] {
        [
            "app_executable_sha256": appExecutableSHA256,
            "signing_requirement_sha256": signingRequirementSHA256,
            "worker_executable_sha256": workerExecutableSHA256,
        ]
    }
}

struct Phase2QualificationGateOneShotClaimIdentity: Equatable, Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidIdentity
        case encodingFailed
    }

    /// An intentionally versioned authorization boundary for this exact F4C-B delivery. A future
    /// qualification attempt must change this reviewed source constant rather than obtaining a new
    /// namespace accidentally from a rebuild, re-sign, or random run UUID.
    static let qualificationEventID = "phase2.r1.f4c-b-delivery.v1"
    static let qualificationEventVersion = 1

    let qualificationEventID: String
    let qualificationEventVersion: Int
    let gitHeadCommit: String
    let gitHeadTree: String
    let selectedBuildInputsSHA256: String
    let projectYAMLSHA256: String
    let profileID: Phase2ModelProfileID
    let policyIdentity: Phase2ProtocolComponentIdentity
    let protocolManifestDigest: String
    let protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity
    let deterministicCorpusIdentity: Phase2ProductionProtocolFixtureContentIdentity
    let modelRevisionIdentity: Phase2ProtocolComponentIdentity
    let qualificationEnvironmentIdentity: Phase2ProtocolComponentIdentity
    let artifactEvidence: Phase2QualificationGateOneShotArtifactEvidence
    let profileEvidence: Phase2QualificationGateProfileEvidence?
    let attachedEvidenceSHA256: String
    let digest: String

    init(
        qualificationEventID: String,
        qualificationEventVersion: Int,
        gitHeadCommit: String,
        gitHeadTree: String,
        selectedBuildInputsSHA256: String,
        projectYAMLSHA256: String,
        profileID: Phase2ModelProfileID,
        policyIdentity: Phase2ProtocolComponentIdentity,
        protocolManifestDigest: String,
        protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity,
        deterministicCorpusIdentity: Phase2ProductionProtocolFixtureContentIdentity,
        modelRevisionIdentity: Phase2ProtocolComponentIdentity,
        qualificationEnvironmentIdentity: Phase2ProtocolComponentIdentity,
        artifactEvidence: Phase2QualificationGateOneShotArtifactEvidence,
        profileEvidence: Phase2QualificationGateProfileEvidence? = nil
    ) throws {
        guard phase2IsCategoricalToken(qualificationEventID),
              qualificationEventVersion > 0,
              Self.lowercaseHex(gitHeadCommit, count: 40),
              Self.lowercaseHex(gitHeadTree, count: 40),
              phase2IsSHA256Hex(selectedBuildInputsSHA256),
              phase2IsSHA256Hex(projectYAMLSHA256),
              policyIdentity.availability == .available,
              policyIdentity.sha256.map(phase2IsSHA256Hex) == true,
              phase2IsSHA256Hex(protocolManifestDigest),
              protocolProbeCatalogIdentity.availability == .available,
              protocolProbeCatalogIdentity.sha256.map(phase2IsSHA256Hex) == true,
              phase2IsCategoricalToken(deterministicCorpusIdentity.id),
              deterministicCorpusIdentity.version > 0,
              phase2IsSHA256Hex(deterministicCorpusIdentity.sha256),
              modelRevisionIdentity.availability == .available,
              modelRevisionIdentity.sha256.map(phase2IsSHA256Hex) == true,
              qualificationEnvironmentIdentity.availability == .available,
              qualificationEnvironmentIdentity.sha256.map(phase2IsSHA256Hex) == true
        else { throw Error.invalidIdentity }
        self.qualificationEventID = qualificationEventID
        self.qualificationEventVersion = qualificationEventVersion
        self.gitHeadCommit = gitHeadCommit
        self.gitHeadTree = gitHeadTree
        self.selectedBuildInputsSHA256 = selectedBuildInputsSHA256
        self.projectYAMLSHA256 = projectYAMLSHA256
        self.profileID = profileID
        self.policyIdentity = policyIdentity
        self.protocolManifestDigest = protocolManifestDigest
        self.protocolProbeCatalogIdentity = protocolProbeCatalogIdentity
        self.deterministicCorpusIdentity = deterministicCorpusIdentity
        self.modelRevisionIdentity = modelRevisionIdentity
        self.qualificationEnvironmentIdentity = qualificationEnvironmentIdentity
        self.artifactEvidence = artifactEvidence
        self.profileEvidence = profileEvidence
        guard profileEvidence.map({
            qualificationEventID == $0.contract.qualificationEventID
                && qualificationEventVersion == $0.contract.qualificationEventVersion
                && modelRevisionIdentity == $0.contract.modelRevisionIdentity
        }) ?? (qualificationEventID != Phase2QualificationProfileContract.resolve(.qwen38V2Q6K).qualificationEventID)
        else { throw Error.invalidIdentity }
        guard let attachedEvidenceData = Self.serialized(
            Self.attachedEvidenceObject(
                profileID: profileID,
                policyIdentity: policyIdentity,
                protocolManifestDigest: protocolManifestDigest,
                protocolProbeCatalogIdentity: protocolProbeCatalogIdentity,
                deterministicCorpusIdentity: deterministicCorpusIdentity,
                modelRevisionIdentity: modelRevisionIdentity,
                qualificationEnvironmentIdentity: qualificationEnvironmentIdentity,
                artifactEvidence: artifactEvidence,
                profileEvidence: profileEvidence
            )
        ), let namespaceData = Self.serialized(
            Self.namespaceObject(
                qualificationEventID: qualificationEventID,
                qualificationEventVersion: qualificationEventVersion,
                gitHeadCommit: gitHeadCommit,
                gitHeadTree: gitHeadTree,
                selectedBuildInputsSHA256: selectedBuildInputsSHA256,
                projectYAMLSHA256: projectYAMLSHA256
            )
        ) else { throw Error.encodingFailed }
        attachedEvidenceSHA256 = Phase2QualificationGateHash.sha256(attachedEvidenceData)
        digest = Phase2QualificationGateHash.sha256(namespaceData)
    }

    @MainActor
    static func current(
        session: Phase2QualificationGateRuntimeSession
    ) throws -> Self {
        let build = session.buildAuthority
        let provenance = build.provenance
        let standard = session.profileContract.production
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        return try .init(
            qualificationEventID: session.profileContract.qualificationEventID,
            qualificationEventVersion: session.profileContract.qualificationEventVersion,
            gitHeadCommit: provenance.gitHeadCommit,
            gitHeadTree: provenance.gitHeadTree,
            selectedBuildInputsSHA256: provenance.selectedBuildInputsSHA256,
            projectYAMLSHA256: provenance.projectYAMLSHA256,
            profileID: canonicalizer.stableID(for: session.preparedQualification.profile),
            policyIdentity: standard.policyIdentity,
            protocolManifestDigest: canonicalizer.protocolManifestDigest(
                for: session.preparedQualification.profile.protocolManifest
            ),
            protocolProbeCatalogIdentity: standard.protocolProbeCatalogIdentity,
            deterministicCorpusIdentity: Phase2ProductionProtocolFixtureCorpus.standard.identity,
            modelRevisionIdentity: standard.modelRevision.identity,
            qualificationEnvironmentIdentity: try session.preparedQualification
                .evidenceBinding.qualificationEnvironment.contentIdentity(),
            artifactEvidence: try .init(
                appExecutableSHA256: build.appExecutableSHA256,
                workerExecutableSHA256: build.workerExecutableSHA256,
                signingRequirementSHA256: build.signingRequirementSHA256
            ),
            profileEvidence: try Phase2QualificationGateProfileEvidence.current(session: session)
        )
    }

    fileprivate var evidenceObject: [String: Any] {
        var value = Self.namespaceObject(
            qualificationEventID: qualificationEventID,
            qualificationEventVersion: qualificationEventVersion,
            gitHeadCommit: gitHeadCommit,
            gitHeadTree: gitHeadTree,
            selectedBuildInputsSHA256: selectedBuildInputsSHA256,
            projectYAMLSHA256: projectYAMLSHA256
        )
        for (key, evidence) in Self.attachedEvidenceObject(
            profileID: profileID,
            policyIdentity: policyIdentity,
            protocolManifestDigest: protocolManifestDigest,
            protocolProbeCatalogIdentity: protocolProbeCatalogIdentity,
            deterministicCorpusIdentity: deterministicCorpusIdentity,
            modelRevisionIdentity: modelRevisionIdentity,
            qualificationEnvironmentIdentity: qualificationEnvironmentIdentity,
            artifactEvidence: artifactEvidence,
            profileEvidence: profileEvidence
        ) {
            value[key] = evidence
        }
        value["attached_evidence_sha256"] = attachedEvidenceSHA256
        return value
    }

    private static func serialized(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The exclusive-creation filename is intentionally limited to authorization: the explicit
    /// event and immutable source delivery. Every exact qualification input is validated before
    /// this point and retained in attached evidence, but cannot mint a retry namespace after drift.
    private static func namespaceObject(
        qualificationEventID: String,
        qualificationEventVersion: Int,
        gitHeadCommit: String,
        gitHeadTree: String,
        selectedBuildInputsSHA256: String,
        projectYAMLSHA256: String
    ) -> [String: Any] {
        [
            "claim_namespace_schema_version": 1,
            "git_head_commit": gitHeadCommit,
            "git_head_tree": gitHeadTree,
            "project_yml_sha256": projectYAMLSHA256,
            "qualification_event_id": qualificationEventID,
            "qualification_event_version": qualificationEventVersion,
            "repository_clean": true,
            "selected_build_inputs_sha256": selectedBuildInputsSHA256,
        ]
    }

    private static func attachedEvidenceObject(
        profileID: Phase2ModelProfileID,
        policyIdentity: Phase2ProtocolComponentIdentity,
        protocolManifestDigest: String,
        protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity,
        deterministicCorpusIdentity: Phase2ProductionProtocolFixtureContentIdentity,
        modelRevisionIdentity: Phase2ProtocolComponentIdentity,
        qualificationEnvironmentIdentity: Phase2ProtocolComponentIdentity,
        artifactEvidence: Phase2QualificationGateOneShotArtifactEvidence,
        profileEvidence: Phase2QualificationGateProfileEvidence?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "artifact_evidence": artifactEvidence.evidenceObject,
            "artifact_evidence_sha256": artifactEvidence.digest,
            "attached_evidence_schema_version": 1,
            "configuration": "Release",
            "deterministic_corpus_id": deterministicCorpusIdentity.id,
            "deterministic_corpus_sha256": deterministicCorpusIdentity.sha256,
            "deterministic_corpus_version": deterministicCorpusIdentity.version,
            "model_revision": componentObject(modelRevisionIdentity),
            "policy": componentObject(policyIdentity),
            "profile_id": profileID.rawValue,
            "protocol_manifest_sha256": protocolManifestDigest,
            "protocol_probe_catalog": componentObject(protocolProbeCatalogIdentity),
            "qualification_environment": componentObject(
                qualificationEnvironmentIdentity
            ),
        ]
        if let profileEvidence {
            object["attached_evidence_schema_version"] = 2
            object.merge(profileEvidence.attachedObject) { _, new in new }
        }
        return object
    }

    private static func lowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func componentObject(
        _ value: Phase2ProtocolComponentIdentity
    ) -> [String: Any] {
        [
            "availability": value.availability.rawValue,
            "id": value.id,
            "sha256": value.sha256!,
            "version": value.version,
        ]
    }
}

struct Phase2QualificationGateOneShotClaim: Equatable, Sendable {
    let digest: String
    let artifactEvidenceSHA256: String
}

struct Phase2QualificationGateOneShotClaimWriter: Sendable {
    private let baseDirectory: URL?

    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
    }

    func claim(
        runID: UUID,
        identity: Phase2QualificationGateOneShotClaimIdentity
    ) -> Phase2QualificationGateOneShotClaim? {
        var object = identity.evidenceObject
        object["claim_digest"] = identity.digest
        object["run_id"] = runID.uuidString.lowercased()
        object["state"] = "one-shot-claimed"
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ), Phase2QualificationGateSecureFileStore.write(
            data,
            relativeDirectoryComponents: [
                "MacScope", "Qualification", "F4C", "claims",
            ],
            fileName: identity.digest + ".json",
            existingPolicy: .reject,
            baseDirectory: baseDirectory
        ) != nil else { return nil }
        return .init(
            digest: identity.digest,
            artifactEvidenceSHA256: identity.artifactEvidence.digest
        )
    }
}

struct Phase2QualificationGateCheckpointEvidenceBinding: Equatable, Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidEvidence
    }

    let finalizedAttemptCount: Int
    let checkpointEvidenceDigest: String
    let terminalExecutionEvidenceDigest: String
    let terminationStatus: Phase2QualificationRunTerminationStatus

    init(
        finalizedAttemptCount: Int,
        checkpointEvidenceDigest: String,
        terminalExecutionEvidenceDigest: String,
        terminationStatus: Phase2QualificationRunTerminationStatus
    ) throws {
        guard (0...64).contains(finalizedAttemptCount),
              phase2IsSHA256Hex(checkpointEvidenceDigest),
              phase2IsSHA256Hex(terminalExecutionEvidenceDigest)
        else { throw Error.invalidEvidence }
        self.finalizedAttemptCount = finalizedAttemptCount
        self.checkpointEvidenceDigest = checkpointEvidenceDigest
        self.terminalExecutionEvidenceDigest = terminalExecutionEvidenceDigest
        self.terminationStatus = terminationStatus
    }
}

@MainActor
final class Phase2QualificationGateCheckpointWriter {
    private let runID: UUID
    private let canaryEvidenceDigest: String
    private let baseDirectory: URL?
    private let profileEvidence: Phase2QualificationGateProfileEvidence?
    private let expectedAttemptIDs: [String]
    private var recordedAttemptIDs: [String] = []
    private var finalizedTrialEvidenceDigests: [String] = []
    private var terminalWasWritten = false
    private(set) var evidenceBinding: Phase2QualificationGateCheckpointEvidenceBinding?

    init(
        runID: UUID,
        canaryEvidenceDigest: String,
        baseDirectory: URL? = nil,
        profileEvidence: Phase2QualificationGateProfileEvidence? = nil
    ) {
        self.runID = runID
        self.canaryEvidenceDigest = canaryEvidenceDigest
        self.baseDirectory = baseDirectory
        self.profileEvidence = profileEvidence
        expectedAttemptIDs = (profileEvidence?.contract.production ?? .standard).liveRequirements
            .flatMap { requirement in
                (1...requirement.requiredTrialCount).map {
                    "\(requirement.probeID)#\($0)#1"
                }
            }
    }

    func record(_ evidence: Phase2LiveQualificationFinalizedTrialEvidence) -> Bool {
        guard !terminalWasWritten,
              recordedAttemptIDs.count < expectedAttemptIDs.count,
              evidence.observation.attemptID == expectedAttemptIDs[recordedAttemptIDs.count],
              evidence.admittedAttemptKey.canonicalID == evidence.observation.attemptID,
              evidence.measurementSample.trialKey == evidence.admittedAttemptKey
        else { return false }
        let ordinal = recordedAttemptIDs.count + 1
        let object: [String: Any] = [
            "admitted_attempt_id": evidence.admittedAttemptKey.canonicalID,
            "canary_evidence_digest": canaryEvidenceDigest,
            "measurement": measurementObject(evidence.measurementSample),
            "observation": observationObject(evidence.observation),
            "ordinal": ordinal,
            "run_id": runID.uuidString.lowercased(),
            "schema_version": 1,
            "state": "finalized-trial",
        ]
        guard let data = serialized(object), write(
            data,
            fileName: String(format: "live-trial-%03d.json", ordinal)
        ) else { return false }
        recordedAttemptIDs.append(evidence.observation.attemptID)
        finalizedTrialEvidenceDigests.append(Phase2QualificationGateHash.sha256(data))
        return true
    }

    func recordTerminal(_ execution: Phase2LiveQualificationExecution) -> Bool {
        guard !terminalWasWritten,
              Array(execution.observations.prefix(recordedAttemptIDs.count)).map(\.attemptID)
                == recordedAttemptIDs
        else { return false }
        let object: [String: Any] = [
            "admitted_attempt_count": execution.admittedAttemptKeys.count,
            "canary_evidence_digest": canaryEvidenceDigest,
            "finalized_attempt_count": recordedAttemptIDs.count,
            "first_admission_epoch_milliseconds":
                execution.firstAdmissionEpochMilliseconds.map { $0 as Any } ?? NSNull(),
            "observation_count": execution.observations.count,
            "run_id": runID.uuidString.lowercased(),
            "schema_version": 1,
            "state": "terminal-execution",
            "terminal_epoch_milliseconds":
                execution.terminalEpochMilliseconds.map { $0 as Any } ?? NSNull(),
            "termination_status": execution.terminationStatus.rawValue,
        ]
        guard let data = serialized(object), write(
            data,
            fileName: "terminal-execution.json"
        ) else { return false }
        let terminalDigest = Phase2QualificationGateHash.sha256(data)
        guard let checkpointDigest = checkpointEvidenceDigest(
            terminalExecutionEvidenceDigest: terminalDigest,
            terminationStatus: execution.terminationStatus
        ), let binding = try? Phase2QualificationGateCheckpointEvidenceBinding(
            finalizedAttemptCount: recordedAttemptIDs.count,
            checkpointEvidenceDigest: checkpointDigest,
            terminalExecutionEvidenceDigest: terminalDigest,
            terminationStatus: execution.terminationStatus
        ) else { return false }
        evidenceBinding = binding
        terminalWasWritten = true
        return true
    }

    private func checkpointEvidenceDigest(
        terminalExecutionEvidenceDigest: String,
        terminationStatus: Phase2QualificationRunTerminationStatus
    ) -> String? {
        guard let data = serialized([
            "canary_evidence_digest": canaryEvidenceDigest,
            "finalized_trial_evidence_digests": finalizedTrialEvidenceDigests,
            "run_id": runID.uuidString.lowercased(),
            "schema_version": 1,
            "terminal_execution_evidence_digest": terminalExecutionEvidenceDigest,
            "termination_status": terminationStatus.rawValue,
        ]) else { return nil }
        return Phase2QualificationGateHash.sha256(data)
    }

    private func serialized(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: profileEvidence?.adding(to: object, state: .canaryPassed) ?? object,
            options: [.sortedKeys]
        )
    }

    private func write(_ data: Data, fileName: String) -> Bool {
        return Phase2QualificationGateSecureFileStore.write(
            data,
            relativeDirectoryComponents: [
                "MacScope", "Qualification", "F4C", runID.uuidString.lowercased(), "live",
            ],
            fileName: fileName,
            existingPolicy: .reject,
            baseDirectory: baseDirectory
        ) != nil
    }

    private func observationObject(
        _ value: Phase2QualificationProbeObservation
    ) -> [String: Any] {
        [
            "attempt": value.attempt,
            "evidence_digest": value.evidenceDigest.map { $0 as Any } ?? NSNull(),
            "outcome": value.outcome.rawValue,
            "probe_id": value.probeID,
            "reason_code": value.reasonCode.map { $0 as Any } ?? NSNull(),
            "trial": value.trial,
        ]
    }

    private func measurementObject(
        _ value: Phase2QualificationAttemptMeasurement
    ) -> [String: Any] {
        [
            "attempt_id": value.trialKey.canonicalID,
            "cancellation_latency_milliseconds":
                value.cancellationLatencyMilliseconds.map { $0 as Any } ?? NSNull(),
            "peak_resident_bytes": value.peakResidentBytes.map { $0 as Any } ?? NSNull(),
            "phase_usage": value.phaseUsages.map { phase in
                [
                    "completion_tokens": phase.usage.completionTokens,
                    "generation_milliseconds": phase.generationMilliseconds,
                    "phase": phase.phase.rawValue,
                    "prompt_tokens": phase.usage.promptTokens,
                    "total_tokens": phase.usage.totalTokens,
                ] as [String: Any]
            },
            "time_to_first_semantic_event_milliseconds":
                value.timeToFirstSemanticEventMilliseconds.map { $0 as Any } ?? NSNull(),
            "total_latency_milliseconds": value.totalLatencyMilliseconds,
        ]
    }
}

/// Immutable run-level linkage between the one-shot canary, incremental live checkpoints, and the
/// final content-addressed Gate report. This small manifest remains useful when report composition
/// or persistence fails because it can close the run as inconclusive without fabricating evidence.
struct Phase2QualificationGatePreparedReportOutcome: Sendable {
    fileprivate let ownerID: UUID
    fileprivate let data: Data
    fileprivate let reportID: Phase2ModelQualificationReportID
    fileprivate let verdict: Phase2ModelQualificationVerdict
}

@MainActor
final class Phase2QualificationGateOutcomeWriter {
    private let ownerID = UUID()
    private let runID: UUID
    private let oneShotClaimDigest: String
    private let oneShotClaimArtifactEvidenceSHA256: String
    fileprivate let baseDirectory: URL?
    fileprivate let profileEvidence: Phase2QualificationGateProfileEvidence?
    private(set) var hasRecordedOutcome = false

    init(
        runID: UUID,
        oneShotClaim: Phase2QualificationGateOneShotClaim,
        baseDirectory: URL? = nil,
        profileEvidence: Phase2QualificationGateProfileEvidence? = nil
    ) {
        self.runID = runID
        oneShotClaimDigest = oneShotClaim.digest
        oneShotClaimArtifactEvidenceSHA256 = oneShotClaim.artifactEvidenceSHA256
        self.baseDirectory = baseDirectory
        self.profileEvidence = profileEvidence
    }

    func prepareReport(
        canaryEvidenceDigest: String,
        checkpointEvidence: Phase2QualificationGateCheckpointEvidenceBinding,
        reportID: Phase2ModelQualificationReportID,
        verdict: Phase2ModelQualificationVerdict
    ) -> Phase2QualificationGatePreparedReportOutcome? {
        guard !hasRecordedOutcome,
              checkpointEvidence.finalizedAttemptCount == 64,
              checkpointEvidence.terminationStatus == .completed,
              let data = serializedOutcome(
                  outcome: verdict.rawValue,
                  canaryEvidenceDigest: canaryEvidenceDigest,
                  checkpointEvidence: checkpointEvidence,
                  reportID: reportID,
                  verdict: verdict,
                  reasonCode: nil
              )
        else { return nil }
        return .init(
            ownerID: ownerID,
            data: data,
            reportID: reportID,
            verdict: verdict
        )
    }

    fileprivate func commit(
        _ prepared: Phase2QualificationGatePreparedReportOutcome
    ) -> Bool {
        guard !hasRecordedOutcome, prepared.ownerID == ownerID else { return false }
        hasRecordedOutcome = true
        return true
    }

    func recordInconclusive(
        canaryEvidenceDigest: String?,
        checkpointEvidence: Phase2QualificationGateCheckpointEvidenceBinding?,
        reportID: Phase2ModelQualificationReportID?,
        verdict: Phase2ModelQualificationVerdict?,
        reasonCode: String
    ) -> Bool {
        guard !hasRecordedOutcome,
              phase2IsCategoricalToken(reasonCode),
              (reportID == nil) == (verdict == nil),
              let data = serializedOutcome(
                  outcome: Phase2ModelQualificationVerdict.inconclusive.rawValue,
                  canaryEvidenceDigest: canaryEvidenceDigest,
                  checkpointEvidence: checkpointEvidence,
                  reportID: reportID,
                  verdict: verdict,
                  reasonCode: reasonCode
              ), Phase2QualificationGateSecureFileStore.write(
                  data,
                  relativeDirectoryComponents: [
                      "MacScope", "Qualification", "F4C",
                      runID.uuidString.lowercased(), "live",
                  ],
                  fileName: "gate-outcome.json",
                  existingPolicy: .reject,
                  baseDirectory: baseDirectory
              ) != nil
        else { return false }
        hasRecordedOutcome = true
        return true
    }

    private func serializedOutcome(
        outcome: String,
        canaryEvidenceDigest: String?,
        checkpointEvidence: Phase2QualificationGateCheckpointEvidenceBinding?,
        reportID: Phase2ModelQualificationReportID?,
        verdict: Phase2ModelQualificationVerdict?,
        reasonCode: String?
    ) -> Data? {
        guard phase2IsCategoricalToken(outcome),
              phase2IsSHA256Hex(oneShotClaimDigest),
              phase2IsSHA256Hex(oneShotClaimArtifactEvidenceSHA256),
              canaryEvidenceDigest.map(phase2IsSHA256Hex) ?? true
        else { return nil }
        let object: [String: Any] = [
            "canary_evidence_digest": canaryEvidenceDigest.map { $0 as Any } ?? NSNull(),
            "checkpoint_evidence_digest": checkpointEvidence.map {
                $0.checkpointEvidenceDigest as Any
            } ?? NSNull(),
            "finalized_attempt_count": checkpointEvidence?.finalizedAttemptCount ?? 0,
            "one_shot_claim_artifact_evidence_sha256":
                oneShotClaimArtifactEvidenceSHA256,
            "one_shot_claim_digest": oneShotClaimDigest,
            "outcome": outcome,
            "reason_code": reasonCode.map { $0 as Any } ?? NSNull(),
            "report_id": reportID.map { $0.rawValue as Any } ?? NSNull(),
            "run_id": runID.uuidString.lowercased(),
            "schema_version": 1,
            "state": "gate-outcome",
            "terminal_execution_evidence_digest": checkpointEvidence.map {
                $0.terminalExecutionEvidenceDigest as Any
            } ?? NSNull(),
            "terminal_execution_status": checkpointEvidence.map {
                $0.terminationStatus.rawValue as Any
            } ?? NSNull(),
            "verdict": verdict.map { $0.rawValue as Any } ?? NSNull(),
        ]
        return try? JSONSerialization.data(
            withJSONObject: profileEvidence?.adding(
                to: object, state: verdict == .certified && reasonCode == nil ? .qualified : .failed
            ) ?? object,
            options: [.sortedKeys]
        )
    }
}

enum Phase2QualificationGateArtifactWriter {
    typealias FileWriter = (
        Data,
        [String],
        String,
        Phase2QualificationGateSecureFileStore.ExistingPolicy,
        URL?
    ) -> URL?

    static func artifactURL(
        for reportID: Phase2ModelQualificationReportID,
        baseDirectory: URL? = nil
    ) -> URL? {
        guard let root = applicationSupport(baseDirectory),
              let directory = publicationDirectory(for: reportID, below: root),
              Phase2QualificationGateSecureFileStore.isSecureDirectory(directory)
        else { return nil }
        let reportFile = directory.appendingPathComponent("report.json")
        let outcomeFile = directory.appendingPathComponent("gate-outcome.json")
        let closureFile = directory.appendingPathComponent("publication-closure.json")
        guard let reportData = Phase2QualificationGateSecureFileStore.read(reportFile),
              let outcomeData = Phase2QualificationGateSecureFileStore.read(outcomeFile),
              let closureData = Phase2QualificationGateSecureFileStore.read(closureFile),
              let report = jsonObject(reportData),
              let outcome = jsonObject(outcomeData),
              let closure = jsonObject(closureData),
              closure["state"] as? String == "gate-publication-closure",
              closure["schema_version"] as? Int == 1,
              closure["report_id"] as? String == reportID.rawValue,
              closure["report_artifact_sha256"] as? String
                == Phase2QualificationGateHash.sha256(reportData),
              closure["gate_outcome_sha256"] as? String
                == Phase2QualificationGateHash.sha256(outcomeData),
              report["report_id"] as? String == reportID.rawValue,
              let reportVerdict = report["verdict"] as? String,
              outcome["state"] as? String == "gate-outcome",
              [1, 2].contains(outcome["schema_version"] as? Int ?? 0),
              candidateMetadataMatches(report: report, outcome: outcome),
              outcome["report_id"] as? String == reportID.rawValue,
              outcome["outcome"] as? String == reportVerdict,
              outcome["verdict"] as? String == reportVerdict,
              outcome["finalized_attempt_count"] as? Int == 64,
              outcome["terminal_execution_status"] as? String == "completed",
              let runID = outcome["run_id"] as? String,
              UUID(uuidString: runID) != nil,
              let claimDigest = outcome["one_shot_claim_digest"] as? String,
              phase2IsSHA256Hex(claimDigest),
              let claimArtifactEvidence = outcome[
                  "one_shot_claim_artifact_evidence_sha256"
              ] as? String,
              phase2IsSHA256Hex(claimArtifactEvidence),
              let claimData = Phase2QualificationGateSecureFileStore.read(
                  root.appendingPathComponent(
                      "MacScope/Qualification/F4C/claims/\(claimDigest).json"
                  )
              ),
              let claim = jsonObject(claimData),
              claim["state"] as? String == "one-shot-claimed",
              claim["claim_digest"] as? String == claimDigest,
              claim["run_id"] as? String == runID,
              claim["artifact_evidence_sha256"] as? String == claimArtifactEvidence,
              candidateClaimMatches(claim: claim, outcome: outcome)
        else { return nil }
        return reportFile
    }

    @MainActor
    static func write(
        _ report: Phase2ModelQualificationReport,
        preparedOutcome: Phase2QualificationGatePreparedReportOutcome,
        outcomeWriter: Phase2QualificationGateOutcomeWriter
    ) -> URL? {
        let reportObject = object(report)
        guard let data = try? JSONSerialization.data(
            withJSONObject: outcomeWriter.profileEvidence?.adding(
                to: reportObject, state: report.verdict == .certified ? .qualified : .failed
            ) ?? reportObject, options: [.sortedKeys]
        ) else { return nil }
        return publish(
            reportID: report.reportID,
            serializedReport: data,
            preparedOutcome: preparedOutcome,
            outcomeWriter: outcomeWriter,
            baseDirectory: outcomeWriter.baseDirectory,
            fileWriter: secureWrite
        )
    }

    @MainActor
    static func publish(
        reportID: Phase2ModelQualificationReportID,
        serializedReport: Data,
        preparedOutcome: Phase2QualificationGatePreparedReportOutcome,
        outcomeWriter: Phase2QualificationGateOutcomeWriter,
        baseDirectory: URL? = nil
    ) -> URL? {
        publish(
            reportID: reportID,
            serializedReport: serializedReport,
            preparedOutcome: preparedOutcome,
            outcomeWriter: outcomeWriter,
            baseDirectory: baseDirectory,
            fileWriter: secureWrite
        )
    }

    @MainActor
    static func publish(
        reportID: Phase2ModelQualificationReportID,
        serializedReport: Data,
        preparedOutcome: Phase2QualificationGatePreparedReportOutcome,
        outcomeWriter: Phase2QualificationGateOutcomeWriter,
        baseDirectory: URL? = nil,
        fileWriter: FileWriter
    ) -> URL? {
        guard !serializedReport.isEmpty,
              preparedOutcome.reportID == reportID,
              let report = jsonObject(serializedReport),
              report["report_id"] as? String == reportID.rawValue,
              report["verdict"] as? String == preparedOutcome.verdict.rawValue,
              let root = applicationSupport(baseDirectory)
        else { return nil }

        let stageName = ".staging-\(UUID().uuidString.lowercased())"
        let stageComponents = [
            "MacScope", "Qualification", "F4C", "reports", stageName,
        ]
        var stageDirectory: URL?
        defer {
            if let stageDirectory {
                try? FileManager.default.removeItem(at: stageDirectory)
            }
        }
        guard let reportFile = fileWriter(
            serializedReport,
            stageComponents,
            "report.json",
            .reject,
            baseDirectory
        ) else { return nil }
        stageDirectory = reportFile.deletingLastPathComponent()
        guard fileWriter(
            preparedOutcome.data,
            stageComponents,
            "gate-outcome.json",
            .reject,
            baseDirectory
        )?.deletingLastPathComponent() == stageDirectory else { return nil }
        let closure: [String: Any] = [
            "gate_outcome_sha256": Phase2QualificationGateHash.sha256(preparedOutcome.data),
            "report_artifact_sha256": Phase2QualificationGateHash.sha256(serializedReport),
            "report_id": reportID.rawValue,
            "schema_version": 1,
            "state": "gate-publication-closure",
        ]
        guard let closureData = try? JSONSerialization.data(
            withJSONObject: closure,
            options: [.sortedKeys]
        ), fileWriter(
            closureData,
            stageComponents,
            "publication-closure.json",
            .reject,
            baseDirectory
        )?.deletingLastPathComponent() == stageDirectory,
           let stagingDirectory = stageDirectory,
           let finalDirectory = publicationDirectory(for: reportID, below: root),
           Phase2QualificationGateSecureFileStore.publishDirectory(
               stagingDirectory,
               to: finalDirectory
           )
        else { return nil }
        stageDirectory = nil
        guard let published = artifactURL(for: reportID, baseDirectory: baseDirectory),
              outcomeWriter.commit(preparedOutcome)
        else {
            try? FileManager.default.removeItem(at: finalDirectory)
            return nil
        }
        return published
    }

    private static func secureWrite(
        _ data: Data,
        _ components: [String],
        _ fileName: String,
        _ policy: Phase2QualificationGateSecureFileStore.ExistingPolicy,
        _ baseDirectory: URL?
    ) -> URL? {
        Phase2QualificationGateSecureFileStore.write(
            data,
            relativeDirectoryComponents: components,
            fileName: fileName,
            existingPolicy: policy,
            baseDirectory: baseDirectory
        )
    }

    private static func applicationSupport(_ baseDirectory: URL?) -> URL? {
        if let baseDirectory { return baseDirectory.standardizedFileURL }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    }

    private static func publicationDirectory(
        for reportID: Phase2ModelQualificationReportID,
        below root: URL
    ) -> URL? {
        let digest = String(reportID.rawValue.dropFirst("sha256:".count))
        guard phase2IsSHA256Hex(digest) else { return nil }
        return root
            .appendingPathComponent("MacScope/Qualification/F4C/reports", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func candidateMetadataMatches(report: [String: Any], outcome: [String: Any]) -> Bool {
        guard outcome["schema_version"] as? Int == 2 else {
            return report["schema_version"] as? Int == 1 && report["profile_selector"] == nil
                && outcome["profile_selector"] == nil
        }
        let contract = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K)
        guard report["schema_version"] as? Int == 2,
              outcome["profile_selector"] as? String == contract.selector.rawValue,
              outcome["qualification_definition_sha256"] as? String == contract.definitionIdentity.sha256,
              outcome["admission_state"] as? String == (outcome["verdict"] as? String == "certified" ? "qualified" : "failed")
        else { return false }
        let keys = ["profile_selector", "qualification_definition_sha256", "admission_state",
                    "provider_build_sha256", "runtime_closure_sha256", "template_authority_sha256",
                    "git_head_commit", "app_executable_sha256", "worker_executable_sha256"]
        return keys.allSatisfy { key in
            guard let value = outcome[key] as? String, report[key] as? String == value else { return false }
            return !key.hasSuffix("_sha256") || phase2IsSHA256Hex(value)
        }
    }

    private static func candidateClaimMatches(claim: [String: Any], outcome: [String: Any]) -> Bool {
        guard outcome["schema_version"] as? Int == 2 else {
            return claim["attached_evidence_schema_version"] as? Int == 1
        }
        let contract = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K)
        guard claim["attached_evidence_schema_version"] as? Int == 2,
              claim["profile_selector"] as? String == contract.selector.rawValue,
              claim["qualification_event_id"] as? String == contract.qualificationEventID
        else { return false }
        return ["qualification_definition", "provider_build", "runtime_closure", "template_authority"].allSatisfy {
            (claim[$0] as? [String: Any])?["sha256"] as? String == outcome[$0 + "_sha256"] as? String
        }
    }

    static func serializedData(for report: Phase2ModelQualificationReport) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: object(report),
            options: [.sortedKeys]
        )
    }

    private static func object(_ report: Phase2ModelQualificationReport) -> [String: Any] {
        let context = report.evaluationContext
        let expectations = context.evidenceExpectations
        return [
            "architecture": report.architecture,
            "attempt_measurements": report.attemptMeasurements.map(attemptObject),
            "authority_ceiling": report.authorityCeiling.rawValue,
            "claimed_policy": componentObject(report.claimedPolicyIdentity),
            "claimed_profile_id": report.claimedProfileID.rawValue,
            "corpus_digest": report.corpusDigest,
            "declared_trial_count": report.declaredTrialCount,
            "ended_at_epoch_milliseconds": report.endedAtEpochMilliseconds,
            "environment_identity": optionalComponentObject(report.environmentIdentity),
            "evaluation_context": [
                "architecture": context.architecture,
                "evaluated_at_epoch_milliseconds": context.evaluatedAtEpochMilliseconds,
                "expected_environment_identity": optionalComponentObject(
                    expectations?.environmentIdentity
                ),
                "expected_measurement_evidence_identity": optionalComponentObject(
                    expectations?.measurementEvidenceIdentity
                ),
                "expected_runtime_provenance_identity": optionalComponentObject(
                    expectations?.runtimeProvenanceIdentity
                ),
                "macscope_build": context.macScopeBuild,
                "maximum_evidence_age_milliseconds":
                    context.maximumEvidenceAgeMilliseconds,
                "operating_system_build": context.operatingSystemBuild,
                "toolchain_build": context.toolchainBuild,
            ] as [String: Any],
            "expected_policy": componentObject(report.expectedPolicyIdentity),
            "expected_profile_id": report.expectedProfileID.rawValue,
            "failed_attempt_count": report.failedAttemptCount,
            "failed_probe_ids": report.failedProbeIDs,
            "failed_trial_count": report.failedTrialCount,
            "hardware_tier": [
                "id": report.hardwareTier.id,
                "version": report.hardwareTier.version,
            ],
            "inconclusive_reason_codes": report.inconclusiveReasonCodes,
            "live_qualification_corpus": optionalComponentObject(
                report.liveQualificationCorpusIdentity
            ),
            "macscope_build": report.macScopeBuild,
            "measurement_evidence_identity": optionalComponentObject(
                report.measurementEvidenceIdentity
            ),
            "measurements": measurementObject(report.measurements),
            "metric_semantics": optionalComponentObject(report.metricSemanticsIdentity),
            "model_revision": optionalComponentObject(report.modelRevisionIdentity),
            "model_source": report.modelSource.map { $0 as Any } ?? NSNull(),
            "missing_trial_ids": report.missingTrialIDs,
            "observations": report.observations.map(observationObject),
            "observed_attempt_count": report.observedAttemptCount,
            "observed_trial_count": report.observedTrialCount,
            "operating_system_build": report.operatingSystemBuild,
            "passed_attempt_count": report.passedAttemptCount,
            "passed_trial_count": report.passedTrialCount,
            "protocol_manifest_digest": report.protocolManifestDigest,
            "protocol_probe_catalog": optionalComponentObject(
                report.protocolProbeCatalogIdentity
            ),
            "production_qualification_definition": optionalComponentObject(
                report.productionDefinitionIdentity
            ),
            "report_id": report.reportID.rawValue,
            "retry_attempt_count": report.retryAttemptCount,
            "runtime_provenance_identity": optionalComponentObject(
                report.runtimeProvenanceIdentity
            ),
            "schema_version": 1,
            "started_at_epoch_milliseconds": report.startedAtEpochMilliseconds,
            "termination_status": report.terminationStatus.rawValue,
            "toolchain_build": report.toolchainBuild,
            "verdict": report.verdict.rawValue,
            "version": report.version,
            "workflow": report.workflow.rawValue,
        ]
    }

    private static func optionalComponentObject(
        _ value: Phase2ProtocolComponentIdentity?
    ) -> Any {
        value.map(componentObject) ?? NSNull()
    }

    private static func componentObject(
        _ value: Phase2ProtocolComponentIdentity
    ) -> [String: Any] {
        [
            "availability": value.availability.rawValue,
            "id": value.id,
            "sha256": value.sha256.map { $0 as Any } ?? NSNull(),
            "version": value.version,
        ]
    }

    private static func measurementObject(
        _ value: Phase2QualificationMeasurements
    ) -> [String: Any] {
        [
            "cancellation_latency_milliseconds":
                value.cancellationLatencyMilliseconds.map { $0 as Any } ?? NSNull(),
            "generated_token_count":
                value.generatedTokenCount.map { $0 as Any } ?? NSNull(),
            "peak_resident_bytes":
                value.peakResidentBytes.map { $0 as Any } ?? NSNull(),
            "throughput_millitokens_per_second":
                value.throughputMilliTokensPerSecond.map { $0 as Any } ?? NSNull(),
            "time_to_first_semantic_event_milliseconds":
                value.timeToFirstSemanticEventMilliseconds.map { $0 as Any } ?? NSNull(),
            "total_latency_milliseconds":
                value.totalLatencyMilliseconds.map { $0 as Any } ?? NSNull(),
            "variance_basis_points":
                value.varianceBasisPoints.map { $0 as Any } ?? NSNull(),
        ]
    }

    private static func attemptObject(
        _ value: Phase2QualificationAttemptMeasurements
    ) -> [String: Any] {
        [
            "attempt": value.attempt,
            "measurements": measurementObject(value.measurements),
            "probe_id": value.probeID,
            "trial": value.trial,
        ]
    }

    private static func observationObject(
        _ value: Phase2QualificationProbeObservation
    ) -> [String: Any] {
        [
            "attempt": value.attempt,
            "evidence_digest": value.evidenceDigest.map { $0 as Any } ?? NSNull(),
            "outcome": value.outcome.rawValue,
            "probe_id": value.probeID,
            "reason_code": value.reasonCode.map { $0 as Any } ?? NSNull(),
            "trial": value.trial,
        ]
    }
}

/// Bounded CoreTests-only evidence storage. The existing MacScope application-support root may
/// use the normal owner-owned 0700 or 0755 mode, but every Gate-owned child directory is a real
/// directory owned by the effective user with mode 0700 and every evidence file is a real regular
/// file with mode 0600. Foreign-owned, writable, or symlinked paths fail closed instead of being
/// repaired.
enum Phase2QualificationGateSecureFileStore {
    enum ExistingPolicy {
        case reject
        case requireIdentical
    }

    static func read(_ file: URL) -> Data? {
        securelyRead(file.standardizedFileURL)
    }

    static func isSecureDirectory(_ directory: URL) -> Bool {
        var state = stat()
        guard directory.standardizedFileURL.withUnsafeFileSystemRepresentation({ path in
            path.map { Darwin.lstat($0, &state) } ?? -1
        }) == 0 else { return false }
        return (state.st_mode & S_IFMT) == S_IFDIR
            && state.st_uid == geteuid()
            && (state.st_mode & 0o777) == 0o700
    }

    /// Publishes a fully written staged directory with one same-parent rename. The final pathname
    /// cannot expose a report without its outcome and closure because all three files move as one
    /// directory entry.
    static func publishDirectory(_ staged: URL, to final: URL) -> Bool {
        let staged = staged.standardizedFileURL
        let final = final.standardizedFileURL
        let parent = staged.deletingLastPathComponent()
        guard parent == final.deletingLastPathComponent(),
              validComponent(staged.lastPathComponent),
              validComponent(final.lastPathComponent),
              isSecureDirectory(parent),
              isSecureDirectory(staged)
        else { return false }
        var finalState = stat()
        let finalLookup = final.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &finalState) } ?? -1
        }
        guard finalLookup != 0, errno == ENOENT else { return false }
        return staged.withUnsafeFileSystemRepresentation { stagedPath in
            final.withUnsafeFileSystemRepresentation { finalPath in
                guard let stagedPath, let finalPath else { return false }
                return Darwin.rename(stagedPath, finalPath) == 0
            }
        }
    }

    static func write(
        _ data: Data,
        relativeDirectoryComponents: [String],
        fileName: String,
        existingPolicy: ExistingPolicy,
        baseDirectory: URL? = nil,
        directorySynchronizer: ((Int32) -> Bool)? = nil
    ) -> URL? {
        guard !data.isEmpty,
              relativeDirectoryComponents.count >= 2,
              relativeDirectoryComponents.first == "MacScope",
              relativeDirectoryComponents.allSatisfy(validComponent),
              validComponent(fileName),
              let applicationSupport = (baseDirectory.map { [$0] }
                  ?? FileManager.default.urls(
                      for: .applicationSupportDirectory, in: .userDomainMask
                  )).first,
              let applicationRoot = secureApplicationRoot(
                  below: applicationSupport,
                  component: "MacScope"
              ),
              let directory = secureDirectory(
                  below: applicationRoot,
                  components: Array(relativeDirectoryComponents.dropFirst())
              )
        else { return nil }
        let file = directory.appendingPathComponent(fileName, isDirectory: false)
        let directoryDescriptor = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) } ?? -1
        }
        guard directoryDescriptor >= 0,
              secureDirectoryDescriptor(directoryDescriptor)
        else {
            if directoryDescriptor >= 0 { _ = Darwin.close(directoryDescriptor) }
            return nil
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        var state = stat()
        let lookup = fileName.withCString { name in
            Darwin.fstatat(directoryDescriptor, name, &state, AT_SYMLINK_NOFOLLOW)
        }
        if lookup == 0 {
            guard existingPolicy == .requireIdentical,
                  secureRegularFileState(state),
                  let existing = securelyRead(
                      fileName: fileName,
                      directoryDescriptor: directoryDescriptor
                  ),
                  existing == data
            else { return nil }
            return file
        }
        guard errno == ENOENT else { return nil }

        let descriptor = fileName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else { return nil }
        var succeeded = false
        defer {
            _ = Darwin.close(descriptor)
            if !succeeded {
                _ = fileName.withCString { name in
                    Darwin.unlinkat(directoryDescriptor, name, 0)
                }
            }
        }
        succeeded = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return Darwin.fsync(descriptor) == 0
        }
        guard succeeded else { return nil }
        guard Darwin.fchmod(descriptor, 0o600) == 0,
              Darwin.fstat(descriptor, &state) == 0,
              secureRegularFileState(state)
        else {
            succeeded = false
            return nil
        }
        guard (directorySynchronizer ?? durableSynchronize)(directoryDescriptor) else {
            // The file may already be durable even though the naming directory could not be
            // proven durable. Retain it so a retry fails closed instead of risking a second live
            // qualification event against an indeterminate first claim.
            return nil
        }
        return file
    }

    private static func secureDirectoryDescriptor(_ descriptor: Int32) -> Bool {
        var state = stat()
        guard Darwin.fstat(descriptor, &state) == 0,
              (state.st_mode & S_IFMT) == S_IFDIR,
              state.st_uid == geteuid(),
              (state.st_mode & 0o777) == 0o700
        else { return false }
        return true
    }

    private static func durableSynchronize(_ descriptor: Int32) -> Bool {
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                return false
            }
            return true
        }
        return true
    }

    private static func secureApplicationRoot(
        below base: URL,
        component: String
    ) -> URL? {
        let directory = base.standardizedFileURL
            .appendingPathComponent(component, isDirectory: true)
        var state = stat()
        let lookup = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &state) } ?? -1
        }
        if lookup != 0 {
            guard errno == ENOENT else { return nil }
            let made = directory.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.mkdir($0, 0o700) } ?? -1
            }
            guard made == 0 else { return nil }
            let reread = directory.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.lstat($0, &state) } ?? -1
            }
            guard reread == 0 else { return nil }
        }
        guard (state.st_mode & S_IFMT) == S_IFDIR,
              state.st_uid == geteuid(),
              (state.st_mode & 0o022) == 0
        else { return nil }
        return directory
    }

    private static func secureDirectory(
        below base: URL,
        components: [String]
    ) -> URL? {
        var directory = base.standardizedFileURL
        for component in components {
            directory.appendPathComponent(component, isDirectory: true)
            var state = stat()
            let lookup = directory.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.lstat($0, &state) } ?? -1
            }
            if lookup != 0 {
                guard errno == ENOENT else { return nil }
                let made = directory.withUnsafeFileSystemRepresentation { path in
                    path.map { Darwin.mkdir($0, 0o700) } ?? -1
                }
                guard made == 0 else { return nil }
                let reread = directory.withUnsafeFileSystemRepresentation { path in
                    path.map { Darwin.lstat($0, &state) } ?? -1
                }
                guard reread == 0 else { return nil }
            }
            guard (state.st_mode & S_IFMT) == S_IFDIR,
                  state.st_uid == geteuid(),
                  (state.st_mode & 0o777) == 0o700
            else { return nil }
        }
        return directory
    }

    private static func securelyRead(_ file: URL) -> Data? {
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var state = stat()
        guard Darwin.fstat(descriptor, &state) == 0,
              secureRegularFileState(state),
              state.st_size >= 0,
              state.st_size <= 64 * 1_024 * 1_024
        else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try? handle.readToEnd()
    }

    private static func securelyRead(
        fileName: String,
        directoryDescriptor: Int32
    ) -> Data? {
        let descriptor = fileName.withCString { name in
            Darwin.openat(directoryDescriptor, name, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var state = stat()
        guard Darwin.fstat(descriptor, &state) == 0,
              secureRegularFileState(state),
              state.st_size >= 0,
              state.st_size <= 64 * 1_024 * 1_024
        else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try? handle.readToEnd()
    }

    private static func secureRegularFileState(_ state: stat) -> Bool {
        (state.st_mode & S_IFMT) == S_IFREG
            && state.st_uid == geteuid()
            && (state.st_mode & 0o777) == 0o600
            && state.st_nlink == 1
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }
}
