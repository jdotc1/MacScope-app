import Foundation

/// Converts actual broker observations into the worker-neutral durable representation. No
/// observation, expected output, process receipt or source identity is inferred here.
enum ReconstructionSourceEvaluationCapture {
    static func capture(_ outcome: ReconstructionSourceExecutionWorkflow.Outcome) throws
        -> ReconstructionSourceEvaluation.CapturedOutcome {
        typealias Evaluation = ReconstructionSourceEvaluation
        func terminal(_ value: Phase2SourceExecutionTerminal) throws -> Evaluation.Terminal {
            guard let kind = Evaluation.Terminal.Kind(rawValue: value.kind.rawValue) else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
            return .init(kind: kind, status: value.status)
        }
        let phases = try outcome.phases.map { phase -> Evaluation.Phase in
            guard let operation = Evaluation.Operation(rawValue: phase.request.operation.rawValue) else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
            let response = phase.response
            let cleanup = try response?.cleanup.map { value in
                Evaluation.Cleanup(sessionID: value.sessionID, requestID: value.requestID,
                    processIdentifier: value.processIdentifier,
                    observedProcessAbsent: value.observedProcessAbsent, outcome: try terminal(value.outcome))
            }
            let status: Evaluation.Phase.Status = response.map { $0.status == .completed ? .completed : .rejected }
                ?? .transportFailed
            return .init(operation: operation, requestID: phase.request.requestID,
                sessionID: phase.request.sessionID,
                requestIdentitySHA256: try ReconstructionCanonicalJSON.sha256(of: phase.request),
                status: status, terminal: try response?.terminal.map(terminal),
                failure: response?.failure?.rawValue ?? phase.transportError.map(bounded),
                diagnostics: response?.diagnostics ?? Data(), cleanup: cleanup,
                sampledProcessIDs: response?.sampledProcessIDs ?? [],
                peakGroupResidentBytes: response?.peakGroupResidentBytes ?? 0,
                elapsedMilliseconds: UInt64((response?.elapsedSeconds ?? 0) * 1_000))
        }
        let status: Evaluation.Status
        switch outcome.failure {
        case nil: status = .accepted
        case .behaviorMismatch: status = .behaviorMismatch
        case .cancelled: status = .cancelled
        case .invalidTools, .invalidAuthority: status = .invalidAuthority
        case .changedInputs: status = .changedInputs
        case .transport: status = .transportFailed
        case .phaseRejected(let operation):
            switch operation {
            case .inspect: status = .inspectionRejected
            case .compile: status = .buildRejected
            case .behavior: status = .behaviorRejected
            }
        case .invalidInspection: status = .invalidInspection
        case .astRejected: status = .inspectionRejected
        case .invalidExecutable: status = .invalidExecutable
        case .invalidBehaviorOutput: status = .invalidBehaviorOutput
        }
        return .init(status: status, failureDetail: outcome.failure.map { bounded(String(describing: $0)) },
            runnerSHA256: outcome.toolAuthority.runnerSHA256,
            compilerSHA256: outcome.toolAuthority.compilerSHA256,
            sdkSettingsSHA256: outcome.toolAuthority.sdkSettingsSHA256,
            harnessSHA256: outcome.harnessSHA256, inspectionSHA256: outcome.inspection?.sha256,
            astSHA256: outcome.astAdmission?.astSHA256, executableSHA256: outcome.executable?.sha256,
            phases: phases, observations: outcome.observations.map { .init(input: $0.input, output: $0.output) },
            mismatches: outcome.mismatches.map { .init(index: $0.index, input: $0.input, expected: $0.expected, actual: $0.actual) })
    }
    private static func bounded(_ text: String) -> String {
        var result = ""
        for character in text where character != "\0" {
            guard result.utf8.count + String(character).utf8.count <= 2_048 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Execution observation unavailable" : result
    }
}
