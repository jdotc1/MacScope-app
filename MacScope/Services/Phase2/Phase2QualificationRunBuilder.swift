import Foundation

/// App-owned output of one complete live qualification execution. It deliberately contains no
/// deterministic-probe receipts, verdict, or full qualification report: the closed CoreTests-only
/// Gate-G4 composer is the sole authority allowed to combine this live evidence with the 99
/// deterministic fixture receipts.
struct Phase2LiveQualificationEvidence: Hashable, Sendable {
    let execution: Phase2LiveQualificationExecution
    let evidenceBundle: Phase2QualificationEvidenceBundle
}

/// Rebuilds measurement aggregates from the retained execution denominator before they can enter
/// an evidence bundle. It has no API that accepts deterministic observations or emits a certifying
/// `Phase2ModelQualificationRun`.
struct Phase2QualificationRunBuilder: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case incompleteExecution
        case runtimeTimingMismatch
    }

    func buildLiveEvidence(
        environment: Phase2QualificationEnvironmentV2,
        runtimeProvenance: Phase2QualificationRuntimeProvenance,
        execution: Phase2LiveQualificationExecution
    ) throws -> Phase2LiveQualificationEvidence {
        guard execution.terminationStatus == .completed else {
            throw Error.incompleteExecution
        }
        guard let start = execution.firstAdmissionEpochMilliseconds,
              let end = execution.terminalEpochMilliseconds,
              start <= end,
              runtimeProvenance.startedAtEpochMilliseconds == start,
              runtimeProvenance.endedAtEpochMilliseconds == end
        else { throw Error.runtimeTimingMismatch }
        return try .init(
            execution: execution,
            evidenceBundle: .init(
                environment: environment,
                runtimeProvenance: runtimeProvenance,
                execution: execution
            )
        )
    }
}
