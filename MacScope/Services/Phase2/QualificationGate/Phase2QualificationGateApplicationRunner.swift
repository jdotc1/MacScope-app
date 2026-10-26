import Darwin
import Foundation

struct Phase2QualificationGateRequest: Equatable, Sendable {
    let mode: Phase2QualificationGateApplicationRunner.LaunchDecision
    let selector: Phase2QualificationProfileSelector
}

/// Non-injected, Release-only entry point for the signed F4C Gate.
///
/// The runner executes inside the exact MacScope candidate process. This keeps the worker's
/// designated peer requirement intact and avoids XCTest injection or a second executable with
/// broader authority. The local-development Release artifact may carry only Xcode's standard
/// `get-task-allow` entitlement so installed-app debugger qualification can prove launch/attach
/// behavior. Ordinary launches never enter this path.
@MainActor
enum Phase2QualificationGateApplicationRunner {
    static let authorityProofArgument = "--phase2-f4c-gate-authority-proof"
    static let installedCanaryArgument = "--phase2-f4c-installed-canary"
    static let liveGateArgument = "--phase2-f4c-signed-live-gate"
    static let profileArgumentPrefix = "--phase2-f4c-profile="
    static let installedCanaryOptInEnvironmentKey =
        "MACSCOPE_RUN_PHASE2_F4C_INSTALLED_CANARY"
    static let canonicalArtifactRoot = "MacScope/Qualification/F4C"

    private enum TerminalContractError: Error {
        case publishedArtifactUnavailable
        case publishedOutcomeInvalid
    }

    enum LaunchDecision: Equatable, Sendable {
        case ordinary
        case rejected
        case authorityProof
        case installedCanary
        case liveGate
    }

    static func decision(
        arguments: [String],
        environment: [String: String]
    ) -> LaunchDecision {
        parse(arguments: arguments, environment: environment).decision
    }

    static func request(
        arguments: [String],
        environment: [String: String]
    ) -> Phase2QualificationGateRequest? {
        parse(arguments: arguments, environment: environment).request
    }

    private static func parse(
        arguments: [String], environment: [String: String]
    ) -> (decision: LaunchDecision, request: Phase2QualificationGateRequest?) {
        let suppliedArguments = Array(arguments.dropFirst())
        let containsGateArgument = suppliedArguments.contains {
            $0.hasPrefix("--phase2-f4c-")
        }
        guard containsGateArgument else { return (.ordinary, nil) }
        guard !containsUnsafeGateEnvironment(environment) else { return (.rejected, nil) }
        let selector: Phase2QualificationProfileSelector
        if suppliedArguments.count == 1 {
            selector = .historicalF4C
        } else if suppliedArguments.count == 2,
                  suppliedArguments[1].hasPrefix(profileArgumentPrefix),
                  let selected = Phase2QualificationProfileSelector(rawValue:
                    String(suppliedArguments[1].dropFirst(profileArgumentPrefix.count))) {
            selector = selected
        } else { return (.rejected, nil) }
        let mode: LaunchDecision

        let liveOptIn = environment[
            Phase2QualificationGateComposer.liveGateOptInEnvironmentKey
        ]
        let canaryOptIn = environment[installedCanaryOptInEnvironmentKey]
        if suppliedArguments.first == authorityProofArgument,
           liveOptIn == nil, canaryOptIn == nil {
            mode = .authorityProof
        } else if suppliedArguments.first == installedCanaryArgument,
           canaryOptIn == "1", liveOptIn == nil {
            mode = .installedCanary
        } else if suppliedArguments.first == liveGateArgument,
           liveOptIn == "1", canaryOptIn == nil {
            mode = .liveGate
        } else { return (.rejected, nil) }
        return (mode, Phase2QualificationGateRequest(mode: mode, selector: selector))
    }

    private static func containsUnsafeGateEnvironment(
        _ environment: [String: String]
    ) -> Bool {
        let liveOptInKey = Phase2QualificationGateComposer.liveGateOptInEnvironmentKey
        let canaryOptInKey = installedCanaryOptInEnvironmentKey
        return environment.keys.contains { key in
            let normalized = key.uppercased()
            if normalized.hasPrefix("DYLD_") { return true }
            if ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains(normalized) {
                return true
            }
            return normalized.hasPrefix("MACSCOPE_")
                && key != liveOptInKey
                && key != canaryOptInKey
        }
    }

    /// Returns only when this is an ordinary app launch. A recognized Gate request owns the
    /// process until it emits one canonical terminal record and exits.
    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let mode = decision(arguments: arguments, environment: environment)
        switch mode {
        case .ordinary:
            return false
        case .rejected:
            emitTerminal([
                "schema_version": 1,
                "status": "rejected",
                "reason": "invalid-gate-request",
            ], toStandardError: true)
            Darwin.exit(EX_USAGE)
        case .authorityProof, .installedCanary, .liveGate:
            break
        }
        guard let request = request(arguments: arguments, environment: environment) else {
            Darwin.exit(EX_USAGE)
        }

        #if DEBUG
        emitTerminal(profileTerminalRecord([
            "schema_version": 1,
            "status": "rejected",
            "reason": "release-build-required",
        ], selector: request.selector, admissionState: .unqualified), toStandardError: true)
        Darwin.exit(EX_CONFIG)
        #else
        Task { @MainActor in
            do {
                switch mode {
                case .ordinary, .rejected:
                    preconditionFailure("non-Gate launch reached Gate execution")
                case .authorityProof:
                    let authority = try Phase2QualificationGateBuildAuthority.collectCurrent()
                    guard authority.isCurrent() else {
                        throw Phase2QualificationGateBuildAuthorityError.gateRunnerInvalid
                    }
                    emitTerminal(profileTerminalRecord([
                        "schema_version": 1,
                        "status": "authority-verified",
                        "git_head_commit": authority.provenance.gitHeadCommit,
                        "app_executable_sha256": authority.appExecutableSHA256,
                        "worker_executable_sha256": authority.workerExecutableSHA256,
                    ], selector: request.selector, admissionState: .unqualified))
                case .installedCanary:
                    let session = try await Phase2QualificationGateRuntimeCollector
                        .collectInstalledCanaryCurrent(selector: request.selector)
                    let authorization = try await Phase2QualificationGateCanaryBarrier
                        .executeOneShot(session: session)
                    guard session.buildAuthority.isCurrent(),
                          session.captureFreshObservation() != nil else {
                        throw Phase2QualificationGateCanaryBarrier.CanaryError.runtimeChanged
                    }
                    emitTerminal(try profileSuccessTerminalRecord(installedCanarySuccessTerminalRecord(
                        runID: session.runID,
                        evidenceDigest: authorization.evidenceDigest,
                        gitHeadCommit: session.buildAuthority.provenance.gitHeadCommit,
                        appExecutableSHA256:
                            session.buildAuthority.appExecutableSHA256,
                        workerExecutableSHA256:
                            session.buildAuthority.workerExecutableSHA256
                    ), selector: request.selector, admissionState: .canaryPassed,
                        providerAdmission: session.providerAdmission))
                case .liveGate:
                    let report = try await Phase2QualificationGateComposer
                        .executeSignedStandardGate(selector: request.selector)
                    guard let reportURL = Phase2QualificationGateArtifactWriter.artifactURL(
                        for: report.reportID
                    ), let outcomeData = Phase2QualificationGateSecureFileStore.read(
                        reportURL.deletingLastPathComponent()
                            .appendingPathComponent("gate-outcome.json")
                    ) else { throw TerminalContractError.publishedArtifactUnavailable }
                    emitTerminal(try liveSuccessTerminalRecord(
                        reportID: report.reportID,
                        verdict: report.verdict,
                        publishedOutcomeData: outcomeData,
                        selector: request.selector
                    ))
                }
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                let record: [String: Any]
                switch mode {
                case .installedCanary:
                    record = installedCanaryFailureTerminalRecord(for: error)
                case .liveGate:
                    record = liveFailureTerminalRecord(for: error)
                case .ordinary, .rejected, .authorityProof:
                    record = failureTerminalRecord(for: error)
                }
                emitTerminal(profileTerminalRecord(record, selector: request.selector,
                    admissionState: .failed, includeUnavailableProvider: mode != .authorityProof),
                    toStandardError: true)
                Darwin.exit(EX_SOFTWARE)
            }
        }
        dispatchMain()
        #endif
    }

    static func failureTerminalRecord(for error: any Error) -> [String: Any] {
        var record: [String: Any] = [
            "schema_version": 1,
            "status": "failed",
            "error_type": String(reflecting: type(of: error)),
        ]
        if let authorityError = error as? Phase2QualificationGateBuildAuthorityError {
            record["authority_error_case"] = authorityError.terminalCaseCode
        }
        return record
    }

    static func installedCanarySuccessTerminalRecord(
        runID: UUID,
        evidenceDigest: String,
        gitHeadCommit: String,
        appExecutableSHA256: String,
        workerExecutableSHA256: String
    ) throws -> [String: Any] {
        let canonicalRunID = runID.uuidString.lowercased()
        guard phase2IsSHA256Hex(evidenceDigest),
              gitHeadCommit.utf8.count == 40,
              gitHeadCommit.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
              }),
              phase2IsSHA256Hex(appExecutableSHA256),
              phase2IsSHA256Hex(workerExecutableSHA256) else {
            throw TerminalContractError.publishedOutcomeInvalid
        }
        return [
            "app_executable_sha256": appExecutableSHA256,
            "canary_evidence_sha256": evidenceDigest,
            "evidence_location":
                "\(canonicalArtifactRoot)/\(canonicalRunID)/canary.json",
            "git_head_commit": gitHeadCommit,
            "run_id": canonicalRunID,
            "schema_version": 1,
            "status": "canary-completed",
            "worker_executable_sha256": workerExecutableSHA256,
        ]
    }

    static func installedCanaryFailureTerminalRecord(
        for error: any Error
    ) -> [String: Any] {
        var record: [String: Any] = [
            "artifact_location": canonicalArtifactRoot,
            "reason": "installed-canary-failed",
            "schema_version": 1,
            "status": "failed",
        ]
        if let authorityError = error as? Phase2QualificationGateBuildAuthorityError {
            record["authority_error_case"] = authorityError.terminalCaseCode
        }
        return record
    }

    static func liveSuccessTerminalRecord(
        reportID: Phase2ModelQualificationReportID,
        verdict: Phase2ModelQualificationVerdict,
        publishedOutcomeData: Data,
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) throws -> [String: Any] {
        guard let outcome = try? JSONSerialization.jsonObject(
            with: publishedOutcomeData
        ) as? [String: Any],
              outcome["report_id"] as? String == reportID.rawValue,
              outcome["verdict"] as? String == verdict.rawValue,
              let runID = outcome["run_id"] as? String,
              let parsedRunID = UUID(uuidString: runID),
              parsedRunID.uuidString.lowercased() == runID
        else { throw TerminalContractError.publishedOutcomeInvalid }

        let digest = String(reportID.rawValue.dropFirst("sha256:".count))
        guard phase2IsSHA256Hex(digest) else {
            throw TerminalContractError.publishedOutcomeInvalid
        }
        var record: [String: Any] = [
            "artifact_location": "\(canonicalArtifactRoot)/reports/\(digest)/report.json",
            "report_id": reportID.rawValue,
            "run_id": runID,
            "schema_version": 1,
            "status": "completed",
            "verdict": verdict.rawValue,
        ]
        if selector != .historicalF4C {
            let contract = Phase2QualificationProfileContract.resolve(selector)
            let state: Phase2QualificationProfileAdmissionState = verdict == .certified ? .qualified : .failed
            guard outcome["profile_selector"] as? String == selector.rawValue,
                  outcome["qualification_definition_sha256"] as? String == contract.definitionIdentity.sha256,
                  outcome["admission_state"] as? String == state.rawValue else {
                throw TerminalContractError.publishedOutcomeInvalid
            }
            record = profileTerminalRecord(record, selector: selector, admissionState: state)
            for key in ["provider_build_sha256", "runtime_closure_sha256", "template_authority_sha256",
                        "app_executable_sha256", "worker_executable_sha256"] {
                guard let value = outcome[key] as? String, phase2IsSHA256Hex(value) else {
                    throw TerminalContractError.publishedOutcomeInvalid
                }
                record[key] = value
            }
            guard let commit = outcome["git_head_commit"] as? String,
                  commit.utf8.count == 40,
                  commit.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
                throw TerminalContractError.publishedOutcomeInvalid
            }
            record["git_head_commit"] = commit
        }
        return record
    }

    static func profileTerminalRecord(
        _ original: [String: Any], selector: Phase2QualificationProfileSelector,
        admissionState: Phase2QualificationProfileAdmissionState, includeUnavailableProvider: Bool = false
    ) -> [String: Any] {
        guard selector != .historicalF4C else { return original }
        var record = original
        record["schema_version"] = 2
        record["profile_selector"] = selector.rawValue
        record["qualification_definition_sha256"] =
            Phase2QualificationProfileContract.resolve(selector).definitionIdentity.sha256
        record["admission_state"] = admissionState.rawValue
        if includeUnavailableProvider {
            for key in ["provider_build_sha256", "runtime_closure_sha256", "template_authority_sha256"] {
                record[key] = NSNull()
            }
        }
        return record
    }

    static func profileSuccessTerminalRecord(
        _ original: [String: Any], selector: Phase2QualificationProfileSelector,
        admissionState: Phase2QualificationProfileAdmissionState, providerAdmission: Phase2ProviderAdmissionEvidence?
    ) throws -> [String: Any] {
        guard selector != .historicalF4C else { return original }
        guard let providerAdmission,
              providerAdmission.providerPolicyIdentity == Phase2QualificationProfileContract.resolve(selector).providerPolicyIdentity else {
            throw TerminalContractError.publishedOutcomeInvalid
        }
        var record = profileTerminalRecord(original, selector: selector, admissionState: admissionState)
        record["provider_build_sha256"] = providerAdmission.providerBuildIdentity.sha256
        record["runtime_closure_sha256"] = providerAdmission.runtimeClosureIdentity.sha256
        record["template_authority_sha256"] = providerAdmission.templateAuthorityIdentity.sha256
        return record
    }

    static func liveFailureTerminalRecord(for error: any Error) -> [String: Any] {
        let reason: String
        switch error {
        case let composerError as Phase2QualificationGateComposer.ComposerError:
            switch composerError {
            case .explicitLiveGateOptInRequired: reason = "live-opt-in-required"
            case .invalidDeterministicEvidence: reason = "invalid-deterministic-evidence"
            case .invalidLiveEvidence: reason = "invalid-live-evidence"
            case .noncanonicalObservationDenominator:
                reason = "noncanonical-observation-denominator"
            case .evaluationTimeUnavailable: reason = "evaluation-time-unavailable"
            case .oneShotClaimUnavailable: reason = "one-shot-claim-unavailable"
            case .checkpointUnavailable: reason = "checkpoint-unavailable"
            case .reportUnavailable: reason = "report-unavailable"
            }
        case is TerminalContractError:
            reason = "terminal-artifact-unavailable"
        default:
            reason = "live-gate-failed"
        }
        return [
            "artifact_location": canonicalArtifactRoot,
            "reason": reason,
            "schema_version": 1,
            "status": "failed",
            "verdict": Phase2ModelQualificationVerdict.inconclusive.rawValue,
        ]
    }

    private static func emitTerminal(
        _ object: [String: Any],
        toStandardError: Bool = false
    ) {
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        data.append(0x0A)
        let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
        try? handle.write(contentsOf: data)
    }
}
