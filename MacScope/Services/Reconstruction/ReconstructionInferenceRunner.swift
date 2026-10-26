import Foundation

protocol ReconstructionInferenceProviding: Sendable {
    func runSourceRevision(requestID: UUID, request: ReconstructionSourceRevisionRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt
    func runRound(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt

    func runFinalSynthesis(
        requestID: UUID,
        request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt

    func runRoundR2(requestID: UUID, request: ReconstructionInferenceRoundRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt
    func runFinalSynthesisR2(requestID: UUID, request: ReconstructionFinalSynthesisRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt

    func cancel(requestID: UUID) async
    func finishRequest() async
}

extension ReconstructionInferenceProviding {
    func runSourceRevision(requestID: UUID, request: ReconstructionSourceRevisionRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt { throw AIAgentXPCTransportError.protocolMismatch }
    func finishRequest() async {}
    func runRoundR2(requestID: UUID, request: ReconstructionInferenceRoundRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt { throw AIAgentXPCTransportError.protocolMismatch }
    func runFinalSynthesisR2(requestID: UUID, request: ReconstructionFinalSynthesisRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt { throw AIAgentXPCTransportError.protocolMismatch }
}

extension ReconstructionXPCInferenceProvider: ReconstructionInferenceProviding {}

enum ReconstructionInferenceRunnerError: Error, Equatable, Sendable {
    case duplicateCandidate
    case missingCandidate
    case duplicateUsage
    case missingUsage
    case unexpectedEvent
    case missingCompletion
    case invalidTerminalReceipt
    case invalidSourceCandidate
    case invalidFinalCandidate
    case invalidFinalEvidence
}

struct ReconstructionSourceRevisionExecutionResult: Equatable, Sendable {
    let candidate: ReconstructionSourceRevisionCandidate
    let usage: Phase2AIWorkerWireUsage
    let terminalReceipt: ReconstructionTerminalReceipt
}

struct ReconstructionInferenceExecutionResult: Equatable, Sendable {
    let candidate: ReconstructionInferenceRoundCandidate
    let usage: Phase2AIWorkerWireUsage
    let terminalReceipt: ReconstructionTerminalReceipt
}

struct ReconstructionFinalSynthesisExecutionResult: Equatable, Sendable {
    let candidate: ReconstructionFinalSynthesisCandidate
    let usage: Phase2AIWorkerWireUsage
    let terminalReceipt: ReconstructionTerminalReceipt
}

enum ReconstructionReadyInferenceFailure: Error, Equatable, Sendable {
    case cancelled
    case providerFailure
    case retryableProviderFailure(Phase2AIWorkerTerminal.Reason?)
    case providerFailureReason(Phase2AIWorkerTerminal.Reason)
    /// Terminal and never retried: replay admission found this exact request already answered
    /// under a different selected model (ReconstructionReplayError.modelChanged).
    case modelChanged

    /// Replay admission failures stay retryable (journal contention, a lease/inventory race),
    /// except a model change, which no retry under the same selection can resolve.
    static func replayAdmission(_ error: any Error) -> Self {
        (error as? ReconstructionReplayError) == .modelChanged ? .modelChanged : .retryableProviderFailure(nil)
    }

    static func providerFailure(reason: Phase2AIWorkerTerminal.Reason?) -> Self {
        guard let reason else { return .providerFailure }
        switch reason {
        case .workerNotConfigured, .workerHandlerFailed, .outputLimitExceeded,
             .contextBudgetExceeded, .overallDeadlineExceeded, .streamInactivityTimeout:
            return .retryableProviderFailure(reason)
        case .requestIdentityMismatch, .duplicateRequest, .invalidRequest:
            return .providerFailureReason(reason)
        }
    }
    case runner(ReconstructionInferenceRunnerError)
}

/// A provider returned an exact terminal receipt before model validation failed. Retaining this
/// pair lets the ready coordinator seal the app-owned request together with the provider's
/// terminal identity; thrown provider errors that return no receipt never construct this value.
struct ReconstructionInferenceRunnerTerminalFailure: Error, Equatable, Sendable {
    let failure: ReconstructionReadyInferenceFailure
    let terminalReceipt: ReconstructionTerminalReceipt
}

enum ReconstructionReadyInferenceExecutionResult: Equatable, Sendable {
    case notReady(Phase2LocalAIProviderReadiness)
    case busy
    case invalidRequest
    case providerAuthorityChanged
    case failedWithoutTerminalAuthority(ReconstructionReadyInferenceFailure)
    case failedWithTerminalAuthority(
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        failure: ReconstructionReadyInferenceFailure
    )
    case finished(
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        outcome: ReconstructionInferenceExecutionResult
    )
}

enum ReconstructionReadySourceRevisionExecutionResult: Equatable, Sendable {
    case notReady(Phase2LocalAIProviderReadiness)
    case busy
    case invalidRequest
    case providerAuthorityChanged
    case failedWithoutTerminalAuthority(ReconstructionReadyInferenceFailure)
    case failedWithTerminalAuthority(
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        failure: ReconstructionReadyInferenceFailure
    )
    case finished(
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        outcome: ReconstructionSourceRevisionExecutionResult
    )
}

enum ReconstructionReadyFinalSynthesisExecutionResult: Equatable, Sendable {
    case notReady(Phase2LocalAIProviderReadiness)
    case busy
    case invalidRequest
    case providerAuthorityChanged
    case failedWithoutTerminalAuthority(ReconstructionReadyInferenceFailure)
    case failedWithTerminalAuthority(
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        failure: ReconstructionReadyInferenceFailure
    )
    case finished(
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        outcome: ReconstructionFinalSynthesisExecutionResult
    )
}

struct ReconstructionInferenceRunner: Sendable {
    typealias CompletedTerminalObservation = @Sendable (
        ReconstructionTerminalReceipt
    ) async -> Void

    private static let maximumFinalSynthesisUTF8Bytes = 60_000
    private static let maximumInsufficientEvidenceUTF8Bytes = 4_096
    private static let maximumFinalEvidenceIDs = 4_096
    private let completedTerminalObservation: CompletedTerminalObservation

    init(
        completedTerminalObservation: @escaping CompletedTerminalObservation = { _ in }
    ) {
        self.completedTerminalObservation = completedTerminalObservation
    }

    func runSourceRevision(
        requestID: UUID,
        request: ReconstructionSourceRevisionRequest,
        provider: any ReconstructionInferenceProviding
    ) async throws -> ReconstructionSourceRevisionExecutionResult {
        let accumulator = ReconstructionSourceEventAccumulator()
        try request.validate()
        let terminal = try await withTaskCancellationHandler {
            try await provider.runSourceRevision(requestID: requestID, request: request,
                emit: { event in try await accumulator.accept(event) })
        } onCancel: {
            Task { await provider.cancel(requestID: requestID) }
        }
        guard terminal.requestID == requestID,
              terminal.jobID == request.jobID,
              terminal.checkpointRevision == request.checkpointRevision,
              terminal.roundID == request.roundID else {
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .runner(.invalidTerminalReceipt),
                terminalReceipt: terminal
            )
        }
        switch terminal.status {
        case .cancelled:
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: Task.isCancelled ? .cancelled : .retryableProviderFailure(nil),
                terminalReceipt: terminal
            )
        case .failed:
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .providerFailure(reason: terminal.providerFailureReason),
                terminalReceipt: terminal
            )
        case .completed:
            await completedTerminalObservation(terminal)
            if Task.isCancelled {
                throw ReconstructionInferenceRunnerTerminalFailure(
                    failure: .cancelled,
                    terminalReceipt: terminal
                )
            }
        }
        let snapshot: ReconstructionSourceEventAccumulator.Snapshot
        do {
            snapshot = try await accumulator.finish()
            try snapshot.candidate.validate(for: request)
        } catch {
            let error = (error as? ReconstructionInferenceRunnerError) ?? .invalidSourceCandidate
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .runner(error),
                terminalReceipt: terminal
            )
        }
        return .init(
            candidate: snapshot.candidate,
            usage: snapshot.usage,
            terminalReceipt: terminal
        )
    }

    func run(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        provider: any ReconstructionInferenceProviding,
        objective: ReconstructionRequestObjective? = nil
    ) async throws -> ReconstructionInferenceExecutionResult {
        let accumulator = ReconstructionRoundEventAccumulator()
        let terminal = try await withTaskCancellationHandler {
            if let objective {
                return try await provider.runRoundR2(
                    requestID: requestID,
                    request: ReconstructionInferenceRoundRequestR2(protocolVersion: 9, objective: objective, request: request),
                    emit: { event in try await accumulator.accept(event) }
                )
            }
            return try await provider.runRound(
                requestID: requestID,
                request: request,
                emit: { event in try await accumulator.accept(event) }
            )
        } onCancel: {
            Task { await provider.cancel(requestID: requestID) }
        }
        guard terminal.requestID == requestID,
              terminal.jobID == request.jobID,
              terminal.checkpointRevision == request.checkpointRevision,
              terminal.roundID == request.roundID else {
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .runner(.invalidTerminalReceipt),
                terminalReceipt: terminal
            )
        }
        switch terminal.status {
        case .cancelled:
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: Task.isCancelled ? .cancelled : .retryableProviderFailure(nil),
                terminalReceipt: terminal
            )
        case .failed:
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .providerFailure(reason: terminal.providerFailureReason),
                terminalReceipt: terminal
            )
        case .completed:
            await completedTerminalObservation(terminal)
            if Task.isCancelled {
                throw ReconstructionInferenceRunnerTerminalFailure(
                    failure: .cancelled,
                    terminalReceipt: terminal
                )
            }
        }
        let snapshot: ReconstructionRoundEventAccumulator.Snapshot
        do {
            snapshot = try await accumulator.finish()
        } catch let error as ReconstructionInferenceRunnerError {
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .runner(error),
                terminalReceipt: terminal
            )
        }
        return .init(
            candidate: snapshot.candidate,
            usage: snapshot.usage,
            terminalReceipt: terminal
        )
    }

    func synthesize(
        requestID: UUID,
        request: ReconstructionFinalSynthesisRequest,
        provider: any ReconstructionInferenceProviding,
        objective: ReconstructionRequestObjective? = nil
    ) async throws -> ReconstructionFinalSynthesisExecutionResult {
        let accumulator = ReconstructionFinalEventAccumulator()
        let terminal = try await withTaskCancellationHandler {
            if let objective {
                return try await provider.runFinalSynthesisR2(
                    requestID: requestID,
                    request: ReconstructionFinalSynthesisRequestR2(protocolVersion: 9, objective: objective, request: request),
                    emit: { event in try await accumulator.accept(event) }
                )
            }
            return try await provider.runFinalSynthesis(
                requestID: requestID,
                request: request,
                emit: { event in try await accumulator.accept(event) }
            )
        } onCancel: {
            Task { await provider.cancel(requestID: requestID) }
        }
        guard terminal.requestID == requestID,
              terminal.jobID == request.jobID,
              terminal.checkpointRevision == request.checkpointRevision,
              terminal.roundID == nil else {
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .runner(.invalidTerminalReceipt),
                terminalReceipt: terminal
            )
        }
        switch terminal.status {
        case .cancelled:
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: Task.isCancelled ? .cancelled : .retryableProviderFailure(nil),
                terminalReceipt: terminal
            )
        case .failed:
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .providerFailure(reason: terminal.providerFailureReason),
                terminalReceipt: terminal
            )
        case .completed:
            await completedTerminalObservation(terminal)
            if Task.isCancelled {
                throw ReconstructionInferenceRunnerTerminalFailure(
                    failure: .cancelled,
                    terminalReceipt: terminal
                )
            }
        }
        let snapshot: ReconstructionFinalEventAccumulator.Snapshot
        do {
            snapshot = try await accumulator.finish()
            let candidate = snapshot.candidate
            let evidenceIDs = candidate.evidenceIDs
            guard !candidate.text.isEmpty else {
                throw ReconstructionInferenceRunnerError.invalidFinalCandidate
            }
            switch candidate.kind {
            case .synthesis:
                guard candidate.text.utf8.count <= Self.maximumFinalSynthesisUTF8Bytes,
                      !evidenceIDs.isEmpty
                else {
                    throw ReconstructionInferenceRunnerError.invalidFinalCandidate
                }
            case .insufficientEvidence:
                guard candidate.text.utf8.count
                        <= Self.maximumInsufficientEvidenceUTF8Bytes,
                      evidenceIDs.isEmpty
                else {
                    throw ReconstructionInferenceRunnerError.invalidFinalCandidate
                }
            }
            guard evidenceIDs.count <= Self.maximumFinalEvidenceIDs,
                  Set(evidenceIDs).count == evidenceIDs.count,
                  Set(evidenceIDs).isSubset(of: Set(request.acceptedEvidenceIDs)) else {
                throw ReconstructionInferenceRunnerError.invalidFinalEvidence
            }
        } catch let error as ReconstructionInferenceRunnerError {
            throw ReconstructionInferenceRunnerTerminalFailure(
                failure: .runner(error),
                terminalReceipt: terminal
            )
        }
        // Normalize only an already validated citation set. Duplicate, unknown and
        // excessive citations must be rejected above, not repaired by normalization.
        let candidate = ReconstructionFinalSynthesisCandidate(
            kind: snapshot.candidate.kind,
            text: snapshot.candidate.text,
            evidenceIDs: ReconstructionValidation.sortedUUIDs(snapshot.candidate.evidenceIDs)
        )
        return .init(
            candidate: candidate,
            usage: snapshot.usage,
            terminalReceipt: terminal
        )
    }
}

private actor ReconstructionRoundEventAccumulator {
    struct Snapshot: Sendable {
        let candidate: ReconstructionInferenceRoundCandidate
        let usage: Phase2AIWorkerWireUsage
    }

    private var candidate: ReconstructionInferenceRoundCandidate?
    private var usage: Phase2AIWorkerWireUsage?
    private var completed = false

    func accept(_ event: ReconstructionAIWorkerEvent) throws {
        guard !completed else { throw ReconstructionInferenceRunnerError.unexpectedEvent }
        switch event.body {
        case .roundCandidate(let value):
            guard candidate == nil else {
                throw ReconstructionInferenceRunnerError.duplicateCandidate
            }
            candidate = value
        case .usage(let value):
            guard usage == nil else { throw ReconstructionInferenceRunnerError.duplicateUsage }
            usage = value
        case .completed:
            completed = true
        case .finalCandidate, .sourceCandidate:
            throw ReconstructionInferenceRunnerError.unexpectedEvent
        }
    }

    func finish() throws -> Snapshot {
        guard completed else { throw ReconstructionInferenceRunnerError.missingCompletion }
        guard let candidate else { throw ReconstructionInferenceRunnerError.missingCandidate }
        guard let usage else { throw ReconstructionInferenceRunnerError.missingUsage }
        return Snapshot(candidate: candidate, usage: usage)
    }
}

private actor ReconstructionFinalEventAccumulator {
    struct Snapshot: Sendable {
        let candidate: ReconstructionFinalSynthesisCandidate
        let usage: Phase2AIWorkerWireUsage
    }

    private var candidate: ReconstructionFinalSynthesisCandidate?
    private var usage: Phase2AIWorkerWireUsage?
    private var completed = false

    func accept(_ event: ReconstructionAIWorkerEvent) throws {
        guard !completed else { throw ReconstructionInferenceRunnerError.unexpectedEvent }
        switch event.body {
        case .finalCandidate(let value):
            guard candidate == nil else {
                throw ReconstructionInferenceRunnerError.duplicateCandidate
            }
            candidate = value
        case .usage(let value):
            guard usage == nil else { throw ReconstructionInferenceRunnerError.duplicateUsage }
            usage = value
        case .completed:
            completed = true
        case .roundCandidate, .sourceCandidate:
            throw ReconstructionInferenceRunnerError.unexpectedEvent
        }
    }

    func finish() throws -> Snapshot {
        guard completed else { throw ReconstructionInferenceRunnerError.missingCompletion }
        guard let candidate else { throw ReconstructionInferenceRunnerError.missingCandidate }
        guard let usage else { throw ReconstructionInferenceRunnerError.missingUsage }
        return Snapshot(candidate: candidate, usage: usage)
    }
}

private actor ReconstructionSourceEventAccumulator {
    struct Snapshot: Sendable {
        let candidate: ReconstructionSourceRevisionCandidate
        let usage: Phase2AIWorkerWireUsage
    }

    private var candidate: ReconstructionSourceRevisionCandidate?
    private var usage: Phase2AIWorkerWireUsage?
    private var completed = false

    func accept(_ event: ReconstructionAIWorkerEvent) throws {
        guard !completed else { throw ReconstructionInferenceRunnerError.unexpectedEvent }
        switch event.body {
        case .sourceCandidate(let value):
            guard candidate == nil else {
                throw ReconstructionInferenceRunnerError.duplicateCandidate
            }
            candidate = value
        case .usage(let value):
            guard usage == nil else { throw ReconstructionInferenceRunnerError.duplicateUsage }
            usage = value
        case .completed:
            completed = true
        case .roundCandidate, .finalCandidate:
            throw ReconstructionInferenceRunnerError.unexpectedEvent
        }
    }

    func finish() throws -> Snapshot {
        guard completed else { throw ReconstructionInferenceRunnerError.missingCompletion }
        guard let candidate else { throw ReconstructionInferenceRunnerError.missingCandidate }
        guard let usage else { throw ReconstructionInferenceRunnerError.missingUsage }
        return Snapshot(candidate: candidate, usage: usage)
    }
}
