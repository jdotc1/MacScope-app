import Foundation

/// Resolution is captured from the same committed owner cut as the batch task. A model cannot
/// supply stages, original coordinates, tool selection, oracle assembly, or authority fields.
protocol ReconstructionProductionSourceTaskResolving: Sendable {
    func resolve(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
                 cancellation: ReconstructionCancellation) async throws -> ReconstructionProductionSourceTaskResolution
}
struct ReconstructionProductionSourceTaskResolution: Sendable {
    struct Evaluation: Sendable {
        let stage: ReconstructionSourceExecutionStage
        let revision: ReconstructionSourceRevision
        let authority: ReconstructionSourceRevisionAuthority
        let oracle: ReconstructionSourceExecutionWorkflow.ValidatedOracle
    }
    enum Original: Sendable {
        case qualified(stage: ReconstructionSourceExecutionStage, function: ReconstructionFunctionCoordinate)
        case prepared(ReconstructionSourceExecutionWorkflow.PreparedOriginal, function: ReconstructionFunctionCoordinate)
        var function: ReconstructionFunctionCoordinate {
            switch self { case .qualified(_, let value), .prepared(_, let value): value }
        }
    }
    enum Work: Sendable { case evaluation(Evaluation), oracle(Original) }
    let projectID: UUID
    let taskID: UUID
    let authority: ReconstructionBatchAuthority
    let work: Work
}

/// This owner seam only assembles immutable provenance from the actual outcome. Receipt creation
/// and database publication remain outside this executor. Missing composition fails closed.
protocol ReconstructionProductionSourceOracleAssembling: Sendable {
    func authority(projectID: UUID, task: ReconstructionTaskRecord,
                   batchAuthority: ReconstructionBatchAuthority,
                   outcome: ReconstructionSourceExecutionWorkflow.Outcome) async throws -> ReconstructionSourceOracleAuthority
}

actor ReconstructionProductionSourceTaskExecutor: ReconstructionSourceTaskExecuting {
    enum Reason: Equatable, Sendable {
        case paused, retired, busy, cancelled, invalidTask, staleAuthority, oracleAssemblyUnavailable
        case resolutionFailed(String), oracleAssemblyFailed(String), workflowFailed(ReconstructionSourceExecutionWorkflow.Failure)
        case invalidOracle, invalidPayload
    }
    struct Diagnostic: Equatable, Sendable {
        let taskID: UUID
        let authority: ReconstructionBatchAuthority
        let reason: Reason
        /// Exact actual phase responses/diagnostics/cleanup survive a failed or cancelled terminal.
        let actualOutcome: ReconstructionSourceExecutionWorkflow.Outcome?
    }
    private struct Execution: Sendable {
        let payload: ReconstructionSourceTaskExecutionPayload?
        let reason: Reason?
        let actualOutcome: ReconstructionSourceExecutionWorkflow.Outcome?
    }
    private struct Active {
        let id: UUID
        let task: Task<Execution, Never>
    }
    private let resolver: any ReconstructionProductionSourceTaskResolving
    private let workflow: ReconstructionSourceExecutionWorkflow
    private let oracleAssembler: (any ReconstructionProductionSourceOracleAssembling)?
    private var active: Active?
    private var paused = false
    private var lifecycleGeneration: UInt64 = 0
    private var retired = false
    private var diagnostics: [UUID: Diagnostic] = [:]
    private var diagnosticOrder: [UUID] = []
    private static let maximumDiagnostics = 64

    init(resolver: any ReconstructionProductionSourceTaskResolving,
         workflow: ReconstructionSourceExecutionWorkflow,
         oracleAssembler: (any ReconstructionProductionSourceOracleAssembling)? = nil) {
        self.resolver = resolver; self.workflow = workflow; self.oracleAssembler = oracleAssembler
    }
    func diagnostic(for taskID: UUID) -> Diagnostic? { diagnostics[taskID] }
    func takeDiagnostic(for taskID: UUID) -> Diagnostic? {
        diagnosticOrder.removeAll { $0 == taskID }; return diagnostics.removeValue(forKey: taskID)
    }

    func execute(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
                 cancellation: ReconstructionCancellation) async -> ReconstructionTerminalTaskResult {
        let rejection: Reason?
        if retired { rejection = .retired }
        else if paused { rejection = .paused }
        else if active != nil { rejection = .busy }
        else if cancellation.isCancelled || Task.isCancelled { rejection = .cancelled }
        else if task.identity.jobID != authority.jobID { rejection = .staleAuthority }
        else if !ReconstructionSourceExecutionTaskContract.admits(task)
            || (try? task.identity.verifyCanonicalIdentity()) == nil { rejection = .invalidTask }
        else { rejection = nil }
        if let rejection {
            retain(.init(taskID: task.identity.taskID, authority: authority, reason: rejection, actualOutcome: nil))
            return terminal(task, authority, reason: rejection, payload: nil, actualOutcome: nil)
        }
        let id = UUID()
        let admittedGeneration = lifecycleGeneration
        let operation = Task { [resolver, workflow, oracleAssembler] in
            await Self.perform(task: task, authority: authority, cancellation: cancellation,
                resolver: resolver, workflow: workflow, assembler: oracleAssembler)
        }
        active = .init(id: id, task: operation)
        let result = await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
        if active?.id == id { active = nil }
        let reason = cancellation.isCancelled || Task.isCancelled || paused || retired || admittedGeneration != lifecycleGeneration
            ? Reason.cancelled : result.reason
        if let reason {
            retain(.init(taskID: task.identity.taskID, authority: authority, reason: reason,
                         actualOutcome: result.actualOutcome))
        } else {
            // A retry cannot expose a stale failure under the successful task identity.
            _ = takeDiagnostic(for: task.identity.taskID)
        }
        return terminal(task, authority, reason: reason, payload: reason == nil ? result.payload : nil,
            actualOutcome: result.actualOutcome)
    }

    func pause() async {
        paused = true; lifecycleGeneration &+= 1
        let current = active?.task; current?.cancel()
        // Cancellation reaches the existing broker transport. Await its terminal cleanup reply.
        _ = await current?.value
    }
    func resume() async { if !retired { paused = false } }
    func retire() async {
        retired = true; paused = true; lifecycleGeneration &+= 1
        let current = active?.task; current?.cancel(); _ = await current?.value
    }

    private static func perform(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
                                cancellation: ReconstructionCancellation,
                                resolver: any ReconstructionProductionSourceTaskResolving,
                                workflow: ReconstructionSourceExecutionWorkflow,
                                assembler: (any ReconstructionProductionSourceOracleAssembling)?) async -> Execution {
        var actual: ReconstructionSourceExecutionWorkflow.Outcome?
        do {
            try cancellation.check()
            let resolution = try await resolver.resolve(task: task, authority: authority, cancellation: cancellation)
            try cancellation.check()
            guard resolution.taskID == task.identity.taskID, resolution.authority == authority,
                  case .function(let function)? = task.identity.subject else {
                return .init(payload: nil, reason: .staleAuthority, actualOutcome: nil)
            }
            let payload: ReconstructionSourceTaskExecutionPayload
            switch resolution.work {
            case .evaluation(let evaluation):
                guard task.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.evaluate,
                      evaluation.revision.projectID == resolution.projectID,
                      evaluation.revision.jobID == authority.jobID,
                      evaluation.revision.function == function,
                      evaluation.authority.projectID == resolution.projectID,
                      evaluation.authority.jobID == authority.jobID,
                      evaluation.authority.function == function else {
                    return .init(payload: nil, reason: .staleAuthority, actualOutcome: nil)
                }
                let outcome = await workflow.run(stage: evaluation.stage,
                    purpose: .revision(revision: evaluation.revision, authority: evaluation.authority, oracle: evaluation.oracle))
                actual = outcome
                try cancellation.check()
                if let failure = outcome.failure, failure != .behaviorMismatch,
                   !canRecordEvaluationFailure(outcome, task: task, authority: authority) {
                    return .init(payload: nil, reason: failure == .cancelled ? .cancelled : .workflowFailed(failure), actualOutcome: outcome)
                }
                // Correlated source failures and mismatches are completed observations for repair,
                // never acceptance. Infrastructure failures remain transient diagnostics.
                payload = .evaluation(outcome)
            case .oracle(let original):
                guard task.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle,
                      original.function == function else {
                    return .init(payload: nil, reason: .staleAuthority, actualOutcome: nil)
                }
                guard let assembler else {
                    return .init(payload: nil, reason: .oracleAssemblyUnavailable, actualOutcome: nil)
                }
                let outcome: ReconstructionSourceExecutionWorkflow.Outcome
                switch original {
                case .qualified(let stage, let function):
                    outcome = await workflow.run(stage: stage, purpose: .original(function: function))
                case .prepared(let prepared, let function):
                    outcome = await workflow.observeOriginal(prepared: prepared, function: function)
                }
                actual = outcome
                try cancellation.check()
                guard outcome.observedOriginal else {
                    return .init(payload: nil, reason: outcome.failure.map(Reason.workflowFailed) ?? .invalidOracle,
                                 actualOutcome: outcome)
                }
                let oracleAuthority: ReconstructionSourceOracleAuthority
                do {
                    oracleAuthority = try await assembler.authority(projectID: resolution.projectID, task: task,
                        batchAuthority: authority, outcome: outcome)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    return .init(payload: nil, reason: .oracleAssemblyFailed(String(String(describing: error).prefix(1024))),
                                 actualOutcome: outcome)
                }
                try cancellation.check()
                guard validateOracleAuthority(oracleAuthority, projectID: resolution.projectID,
                    task: task, authority: authority, outcome: outcome) else {
                    return .init(payload: nil, reason: .invalidOracle, actualOutcome: outcome)
                }
                payload = .oracle(try ReconstructionSourceOracleEvidence.admit(authority: oracleAuthority))
            }
            guard payload.isValid(for: task, authority: authority) else {
                return .init(payload: nil, reason: .invalidPayload, actualOutcome: actual)
            }
            return .init(payload: payload, reason: nil, actualOutcome: actual)
        } catch is CancellationError { return .init(payload: nil, reason: .cancelled, actualOutcome: actual) }
        catch { return .init(payload: nil, reason: .resolutionFailed(String(String(describing: error).prefix(1024))), actualOutcome: actual) }
    }

    private static func canRecordEvaluationFailure(_ outcome: ReconstructionSourceExecutionWorkflow.Outcome,
        task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority) -> Bool {
        guard let failure = outcome.failure else { return false }
        switch failure {
        case .astRejected, .phaseRejected, .invalidInspection, .invalidExecutable, .invalidBehaviorOutput: break
        default: return false
        }
        guard ReconstructionSourceTaskExecutionPayload.evaluation(outcome).isValid(for: task, authority: authority) else {
            return false
        }
        // The payload bridge validates correlation and process absence. Require an actual terminal
        // process result here too: a cleanup record with unknown outcome cannot become an observation.
        return outcome.phases.allSatisfy { phase in
            guard let response = phase.response, let terminal = response.terminal,
                  let cleanup = response.cleanup, cleanup.outcome == terminal,
                  cleanup.observedProcessAbsent else { return false }
            return terminal.kind == .exited || terminal.kind == .signaled
        }
    }

    private static func validateOracleAuthority(_ oracle: ReconstructionSourceOracleAuthority,
                                               projectID: UUID, task: ReconstructionTaskRecord,
                                               authority: ReconstructionBatchAuthority,
                                               outcome: ReconstructionSourceExecutionWorkflow.Outcome) -> Bool {
        guard oracle.projectID == projectID, oracle.jobID == authority.jobID,
              oracle.function == outcome.function, task.identity.subject == .function(oracle.function),
              outcome.observedOriginal, outcome.phases.count == (outcome.executableOrigin == .retained ? 2 : 3),
              let executable = outcome.executable,
              let behavior = outcome.phases.last, behavior.request.operation == .behavior,
              let response = behavior.response, let cleanup = response.cleanup,
              response.status == .completed, response.failure == nil,
              response.terminal == .init(kind: .exited, status: 0), cleanup.observedProcessAbsent,
              oracle.execution.originalImageSHA256 == outcome.function.artifact.contentIdentity.digest,
              oracle.execution.originalExecutableSHA256 == executable.sha256,
              executable.sha256 == outcome.function.artifact.contentIdentity.digest,
              oracle.execution.originalSourceSHA256 == outcome.sourceSHA256,
              oracle.execution.harnessSHA256 == outcome.harnessSHA256,
              oracle.execution.compilerSHA256 == outcome.toolAuthority.compilerSHA256,
              oracle.execution.sdkIdentitySHA256 == outcome.toolAuthority.sdkSettingsSHA256,
              oracle.execution.standardOutput == response.diagnostics,
              oracle.execution.sessionID == behavior.request.sessionID,
              oracle.execution.requestID == behavior.request.requestID,
              oracle.execution.processIdentifier == cleanup.processIdentifier,
              oracle.execution.sampledProcessIDs == response.sampledProcessIDs,
              oracle.execution.exitCode == 0, oracle.execution.observedProcessAbsent else { return false }
        return true
    }
    private func retain(_ diagnostic: Diagnostic) {
        diagnostics[diagnostic.taskID] = diagnostic
        diagnosticOrder.removeAll { $0 == diagnostic.taskID }; diagnosticOrder.append(diagnostic.taskID)
        while diagnosticOrder.count > Self.maximumDiagnostics {
            diagnostics.removeValue(forKey: diagnosticOrder.removeFirst())
        }
    }
    /// The concrete, bounded failure text a failed source task records in its durable diagnostic
    /// and the job's terminal reason: the reason kind, the failing broker phase and its error kind
    /// or exit, the first behaviour mismatch (harness case index and values), and an excerpt of the
    /// phase diagnostics (e.g. the compiler error).
    static func failureText(reason: Reason, actualOutcome: ReconstructionSourceExecutionWorkflow.Outcome?) -> String {
        var parts: [String]
        switch reason {
        case .paused: parts = ["paused"]
        case .retired: parts = ["executor retired"]
        case .busy: parts = ["executor busy"]
        case .cancelled: parts = ["cancelled"]
        case .invalidTask: parts = ["invalid source task"]
        case .staleAuthority: parts = ["stale authority"]
        case .oracleAssemblyUnavailable: parts = ["oracle assembler unavailable"]
        case .resolutionFailed(let text): parts = ["source resolution failed: \(text)"]
        case .oracleAssemblyFailed(let text): parts = ["oracle assembly failed: \(text)"]
        case .invalidOracle: parts = ["invalid oracle observation"]
        case .invalidPayload: parts = ["invalid execution payload"]
        case .workflowFailed(let failure):
            switch failure {
            case .transport(let operation, let text): parts = ["broker transport error in \(operation.rawValue): \(text)"]
            case .phaseRejected(let operation): parts = ["\(operation.rawValue) phase rejected"]
            case .astRejected(let text): parts = ["source AST rejected: \(text)"]
            default: parts = ["workflow failed: \(failure)"]
            }
        }
        if let outcome = actualOutcome {
            if let phase = outcome.phases.last(where: { $0.response?.status != .completed || $0.transportError != nil })
                ?? outcome.phases.last {
                var phaseText = "phase=\(phase.request.operation.rawValue)"
                if let response = phase.response {
                    if response.status != .completed { phaseText += " status=\(response.status.rawValue)" }
                    if let failure = response.failure { phaseText += " brokerError=\(failure.rawValue)" }
                    if let terminal = response.terminal {
                        phaseText += " terminal=\(terminal.kind.rawValue)" + (terminal.status.map { "(\($0))" } ?? "")
                    }
                    if let cleanup = response.cleanup, !cleanup.observedProcessAbsent || cleanup.outcome.kind == .outcomeUnknown {
                        phaseText += " cleanup=\(cleanup.outcome.kind.rawValue)"
                    }
                }
                if let transport = phase.transportError { phaseText += " transport=\(transport)" }
                parts.append(phaseText)
                if let response = phase.response, !response.diagnostics.isEmpty {
                    let excerpt = String(decoding: response.diagnostics.prefix(320), as: UTF8.self)
                        .split(whereSeparator: \.isNewline).joined(separator: " | ")
                    parts.append("diagnostics: \(excerpt)")
                }
            }
            if let mismatch = outcome.mismatches.first {
                parts.append("harness case \(mismatch.index) of \(outcome.observations.count): input=\(mismatch.input) expected=\(mismatch.expected) actual=\(mismatch.actual)"
                    + (outcome.mismatches.count > 1 ? " (+\(outcome.mismatches.count - 1) more)" : ""))
            }
        }
        return parts.joined(separator: "; ")
    }

    private func terminal(_ task: ReconstructionTaskRecord, _ authority: ReconstructionBatchAuthority,
                          reason: Reason?, payload: ReconstructionSourceTaskExecutionPayload?,
                          actualOutcome: ReconstructionSourceExecutionWorkflow.Outcome?) -> ReconstructionTerminalTaskResult {
        let outcome: ReconstructionTerminalTaskOutcome
        switch reason {
        case nil: outcome = .completed
        case .cancelled, .paused: outcome = .cancelled
        case .staleAuthority: outcome = .staleAuthority
        default: outcome = .failed
        }
        return .init(jobID: authority.jobID, taskID: task.identity.taskID, checkpointID: authority.checkpointID,
            checkpointRevision: authority.checkpointRevision, corpusManifestSHA256: authority.corpusManifestSHA256,
            outcome: outcome, sourceExecution: payload,
            failureDiagnostic: reason.map { .sanitizing(Self.failureText(reason: $0, actualOutcome: actualOutcome)) })
    }
}
