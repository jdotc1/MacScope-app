import Combine
import Foundation

/// One bounded race for installed-smoke operations whose underlying continuation does not observe
/// cooperative task cancellation. Timeout and caller cancellation invoke the supplied reset seam,
/// which must resolve the exact pending continuation before the task-group scope is drained.
enum Phase2InstalledSmokeOperationDeadline {
    struct Timeout: Error, Equatable, CustomStringConvertible, Sendable {
        let operationDescription: String

        var description: String {
            "Timed out waiting for \(operationDescription)."
        }
    }

    static func perform<Value: Sendable>(
        timeoutSeconds: Double,
        operationDescription: String,
        reset: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let boundedDuration = timeoutSeconds.isFinite
            ? min(max(0, timeoutSeconds), 30)
            : 0
        guard boundedDuration > 0 else {
            await reset()
            throw Timeout(operationDescription: operationDescription)
        }
        let timeoutNanoseconds = UInt64(boundedDuration * 1_000_000_000)
        let race = RaceState()

        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(
                of: ChildResult<Value>.self,
                returning: Value.self
            ) { group in
                group.addTask {
                    race.markOperationStarted()
                    do {
                        let value = try await operation()
                        return race.finishOperationAndClaimWinner()
                            ? .operationSucceeded(value)
                            : .superseded
                    } catch {
                        let failure = OperationFailure(error: error)
                        return race.finishOperationAndClaimWinner()
                            ? .operationFailed(failure)
                            : .superseded
                    }
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return .superseded
                    }
                    guard race.claimTimeout() else { return .superseded }
                    await resetUntilOperationFinishes(race: race, reset: reset)
                    return .timedOut
                }
                defer { group.cancelAll() }
                while let result = try await group.next() {
                    switch result {
                    case let .operationSucceeded(value):
                        return value
                    case let .operationFailed(failure):
                        throw failure.error
                    case .timedOut:
                        throw Timeout(operationDescription: operationDescription)
                    case .superseded:
                        if race.winner == .cancellation {
                            throw CancellationError()
                        }
                    }
                }
                if race.winner == .cancellation { throw CancellationError() }
                throw Timeout(operationDescription: operationDescription)
            }
        }, onCancel: {
            guard race.claimCancellation() else { return }
            Task {
                await resetUntilOperationFinishes(race: race, reset: reset)
            }
        })
    }

    private static func resetUntilOperationFinishes(
        race: RaceState,
        reset: @escaping @Sendable () async -> Void
    ) async {
        while !race.operationStarted, !race.operationFinished {
            await Task.yield()
        }
        while !race.operationFinished {
            await reset()
            guard !race.operationFinished else { return }
            do {
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                await Task.yield()
            }
        }
    }

    private struct OperationFailure: @unchecked Sendable {
        let error: any Error
    }

    private enum ChildResult<Value: Sendable>: Sendable {
        case operationSucceeded(Value)
        case operationFailed(OperationFailure)
        case timedOut
        case superseded
    }

    private final class RaceState: @unchecked Sendable {
        enum Winner: Equatable {
            case undecided
            case operation
            case timeout
            case cancellation
        }

        private let lock = NSLock()
        private var storedWinner: Winner = .undecided
        private var storedOperationStarted = false
        private var storedOperationFinished = false

        var winner: Winner {
            lock.lock()
            defer { lock.unlock() }
            return storedWinner
        }

        var operationStarted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedOperationStarted
        }

        var operationFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedOperationFinished
        }

        func markOperationStarted() {
            lock.lock()
            storedOperationStarted = true
            lock.unlock()
        }

        func finishOperationAndClaimWinner() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            storedOperationFinished = true
            guard storedWinner == .undecided else { return false }
            storedWinner = .operation
            return true
        }

        func claimTimeout() -> Bool {
            claim(.timeout)
        }

        func claimCancellation() -> Bool {
            claim(.cancellation)
        }

        private func claim(_ winner: Winner) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard storedWinner == .undecided else { return false }
            storedWinner = winner
            return true
        }
    }
}

/// App-owned bridge between the installed smoke runner and the renderer lifecycle ledger.
///
/// The adapter never records renderer evidence. It publishes the runner's real shell snapshot to
/// the separately owned presentation host, waits for that host to return its lifecycle-derived
/// binding, and accepts proof only from a fresh `rendererEvidenceShared` ledger entry emitted by
/// the mounted terminal view.
@MainActor
final class Phase2InstalledRendererEvidenceAdapter: ObservableObject {
    typealias Runner = Phase2InstalledShellSmokeRunner
    typealias Diagnostics = MacScopeGhosttySurfaceDiagnostics

    static let productionShared = Phase2InstalledRendererEvidenceAdapter(
        diagnostics: .rendererEvidenceShared,
        waitDuration: waitDuration(environment: ProcessInfo.processInfo.environment)
    )

    static let defaultWaitDuration: TimeInterval = 5
    private static let presentationPollNanoseconds: UInt64 = 2_000_000

    struct PresentationRequest: Equatable, Sendable, Identifiable {
        let requestGeneration: UUID
        let requestedMode: Runner.RendererMode
        let snapshot: Phase2HumanPTYSessionSnapshot
        let shellSessionID: UUID
        let shellRequestID: UUID
        let shellProcessIdentifier: Int32

        var id: UUID { requestGeneration }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidRequestCoordinate
        case presentationAlreadyActive
        case presentationGenerationMismatch
        case presentationCoordinateMismatch
        case presentationGenerationBindingMismatch
        case presentationFailed
        case presentationRetired
        case presentationTimedOut
        case retirementTimedOut
        case staleEvidence
        case retiredEvidence
        case shellBrokerProcessIdentifierMismatch(observed: Int32)
        case missingEvidence
        case unexpectedRendererEvidence

        var description: String {
            switch self {
            case .invalidRequestCoordinate:
                "Installed renderer request did not describe one exact running shell."
            case .presentationAlreadyActive:
                "Another installed renderer presentation is already active."
            case .presentationGenerationMismatch:
                "Installed renderer presentation used the wrong request generation."
            case .presentationCoordinateMismatch:
                "Installed renderer presentation changed the exact shell coordinate."
            case .presentationGenerationBindingMismatch:
                "Installed renderer presentation used the wrong renderer-generation binding."
            case .presentationFailed:
                "Installed renderer presentation failed before a renderer mounted."
            case .presentationRetired:
                "Installed renderer presentation retired before evidence was accepted."
            case .presentationTimedOut:
                "Installed renderer presentation did not mount within the bounded wait."
            case .retirementTimedOut:
                "Installed renderer presentation did not retire through the exact lifecycle ledger within the bounded wait."
            case .staleEvidence:
                "Installed renderer evidence was retained from an earlier presentation."
            case .retiredEvidence:
                "Installed renderer evidence described a retired presentation."
            case let .shellBrokerProcessIdentifierMismatch(observed):
                "Installed renderer evidence described a different ShellBroker PID (\(observed))."
            case .missingEvidence:
                "Installed renderer evidence was not observed within the bounded wait."
            case .unexpectedRendererEvidence:
                "Installed renderer evidence used an unapproved mode or fallback."
            }
        }
    }

    @Published private(set) var presentationRequest: PresentationRequest?

    private enum PresentationState {
        case awaitingMount
        case mounted(Diagnostics.RendererBinding)
        case failed(Failure)
        case retired(Diagnostics.RendererBinding)
    }

    private struct Transaction {
        let request: PresentationRequest
        let rendererEvidenceSequenceBaseline: UInt64
        let deadline: Date
        var state: PresentationState
    }

    private let diagnostics: Diagnostics
    private let waitDuration: TimeInterval
    private var transaction: Transaction?

    init(
        diagnostics: Diagnostics = .rendererEvidenceShared,
        waitDuration: TimeInterval = defaultWaitDuration
    ) {
        self.diagnostics = diagnostics
        self.waitDuration = Self.boundedWaitDuration(waitDuration)
    }

    static func waitDuration(environment: [String: String]) -> TimeInterval {
        guard let rawValue = environment[Runner.timeoutEnvironmentKey],
              let value = TimeInterval(rawValue),
              value >= 1,
              value <= Diagnostics.maximumRendererWaitDuration else {
            return defaultWaitDuration
        }
        return value
    }

    nonisolated static func isSmokeRequested(environment: [String: String]) -> Bool {
        guard let reportPath = environment[Runner.reportPathEnvironmentKey] else { return false }
        return !reportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func present(
        request: Runner.RendererEvidenceRequest,
        snapshot: Phase2HumanPTYSessionSnapshot
    ) async throws -> Runner.RendererPresentationLease {
        guard transaction == nil else { throw Failure.presentationAlreadyActive }
        guard request.shellProcessIdentifier > 1,
              snapshot.sessionID == request.shellSessionID,
              case .running(let snapshotRequestID, let snapshotProcessIdentifier) = snapshot.state,
              snapshotRequestID == request.shellRequestID,
              snapshotProcessIdentifier == request.shellProcessIdentifier else {
            throw Failure.invalidRequestCoordinate
        }

        let presentation = PresentationRequest(
            requestGeneration: request.generation,
            requestedMode: request.requestedMode,
            snapshot: snapshot,
            shellSessionID: snapshot.sessionID,
            shellRequestID: snapshotRequestID,
            shellProcessIdentifier: snapshotProcessIdentifier
        )
        let baseline = diagnostics.rendererSnapshot().totalRecorded
        transaction = Transaction(
            request: presentation,
            rendererEvidenceSequenceBaseline: baseline,
            deadline: Date().addingTimeInterval(waitDuration),
            state: .awaitingMount
        )
        presentationRequest = presentation

        do {
            while true {
                try Task.checkCancellation()
                guard let current = transaction,
                      current.request.requestGeneration == request.generation else {
                    throw Failure.presentationFailed
                }
                switch current.state {
                case .awaitingMount:
                    guard Date() < current.deadline else {
                        throw Failure.presentationTimedOut
                    }
                    try await Task.sleep(nanoseconds: Self.presentationPollNanoseconds)
                case let .mounted(binding):
                    try validate(
                        request: request,
                        presentation: current.request,
                        binding: binding
                    )
                    return Runner.RendererPresentationLease(
                        requestGeneration: request.generation,
                        rendererBinding: binding,
                        rendererEvidenceSequenceBaseline: baseline
                    )
                case let .failed(error):
                    throw error
                case .retired:
                    throw Failure.presentationRetired
                }
            }
        } catch {
            clearPresentation(requestGeneration: request.generation)
            throw error
        }
    }

    func rendererEvidence(
        request: Runner.RendererEvidenceRequest,
        presentation: Runner.RendererPresentationLease
    ) async throws -> Runner.RendererRuntimeEvidence {
        try Runner.validateRendererPresentationLease(request: request, lease: presentation)
        let current = try mountedTransaction(
            requestGeneration: request.generation,
            binding: presentation.rendererBinding,
            rendererEvidenceSequenceBaseline: presentation.rendererEvidenceSequenceBaseline
        )
        let binding = presentation.rendererBinding
        do {
            let instantiated = try await waitForFreshInstantiation(
                requestGeneration: request.generation,
                binding: binding,
                rendererEvidenceSequenceBaseline: presentation.rendererEvidenceSequenceBaseline,
                deadline: current.deadline
            )
            let runtimeEvidence = try runtimeEvidence(
                requestGeneration: presentation.requestGeneration,
                evidence: instantiated.evidence
            )
            try await retireAndWaitForExactEvidence(
                requestGeneration: request.generation,
                binding: binding,
                rendererEvidenceSequenceBaseline: instantiated.sequence,
                deadline: current.deadline
            )
            clearPresentation(requestGeneration: request.generation)
            return runtimeEvidence
        } catch {
            requestPresentationRetirement(requestGeneration: request.generation)
            if !Task.isCancelled {
                await waitForBestEffortRetirement(
                    requestGeneration: request.generation,
                    binding: binding
                )
            } else {
                await Task.yield()
            }
            clearPresentation(requestGeneration: request.generation)
            throw error
        }
    }

    /// Called only by the smoke-only SwiftUI host after the frozen presentation seam reports its
    /// lifecycle state. These callbacks never record diagnostics or create evidence.
    func presentationMounted(
        requestGeneration: UUID,
        sessionID: UUID,
        requestID: UUID,
        shellProcessIdentifier: Int32,
        rendererBinding: Diagnostics.RendererBinding
    ) {
        updatePresentation(
            requestGeneration: requestGeneration,
            sessionID: sessionID,
            requestID: requestID,
            shellProcessIdentifier: shellProcessIdentifier,
            rendererBinding: rendererBinding,
            nextState: .mounted(rendererBinding)
        )
    }

    func presentationFailed(requestGeneration: UUID) {
        guard var current = transaction,
              current.request.requestGeneration == requestGeneration else { return }
        switch current.state {
        case .awaitingMount, .mounted:
            current.state = .failed(.presentationFailed)
            transaction = current
        case .failed, .retired:
            return
        }
    }

    func presentationRetired(
        requestGeneration: UUID,
        sessionID: UUID,
        requestID: UUID,
        shellProcessIdentifier: Int32,
        rendererBinding: Diagnostics.RendererBinding
    ) {
        updatePresentation(
            requestGeneration: requestGeneration,
            sessionID: sessionID,
            requestID: requestID,
            shellProcessIdentifier: shellProcessIdentifier,
            rendererBinding: rendererBinding,
            nextState: .retired(rendererBinding)
        )
    }

    private func updatePresentation(
        requestGeneration: UUID,
        sessionID: UUID,
        requestID: UUID,
        shellProcessIdentifier: Int32,
        rendererBinding: Diagnostics.RendererBinding,
        nextState: PresentationState
    ) {
        guard var current = transaction,
              current.request.requestGeneration == requestGeneration else { return }
        guard current.request.shellSessionID == sessionID,
              current.request.shellRequestID == requestID,
              current.request.shellProcessIdentifier == shellProcessIdentifier,
              rendererBinding.sessionID == sessionID,
              rendererBinding.requestID == requestID,
              rendererBinding.shellBrokerProcessIdentifier == shellProcessIdentifier else {
            current.state = .failed(.presentationCoordinateMismatch)
            transaction = current
            return
        }
        switch current.state {
        case .failed, .retired:
            return
        case .awaitingMount:
            current.state = nextState
        case let .mounted(activeBinding):
            switch nextState {
            case let .mounted(candidateBinding):
                guard activeBinding == candidateBinding else {
                    current.state = .failed(.presentationCoordinateMismatch)
                    transaction = current
                    return
                }
                return
            case let .retired(candidateBinding):
                guard activeBinding == candidateBinding else {
                    current.state = .failed(.presentationCoordinateMismatch)
                    transaction = current
                    return
                }
                current.state = nextState
            case .awaitingMount, .failed:
                current.state = .failed(.presentationFailed)
            }
        }
        transaction = current
    }

    private func validate(
        request: Runner.RendererEvidenceRequest,
        presentation: PresentationRequest,
        binding: Diagnostics.RendererBinding
    ) throws {
        guard presentation.requestGeneration == request.generation else {
            throw Failure.presentationGenerationMismatch
        }
        guard binding.sessionID == presentation.shellSessionID,
              binding.requestID == presentation.shellRequestID,
              binding.shellBrokerProcessIdentifier == presentation.shellProcessIdentifier else {
            throw Failure.presentationCoordinateMismatch
        }
        switch (request.requestedMode, binding.generation) {
        case let (.defaultFullGhosttySurface, .exact(generation)) where generation > 0:
            break
        case (.forcedLegacyGridRecoveryOverride, .notAllocated):
            break
        default:
            throw Failure.presentationGenerationBindingMismatch
        }
    }

    private func mountedTransaction(
        requestGeneration: UUID,
        binding: Diagnostics.RendererBinding,
        rendererEvidenceSequenceBaseline: UInt64
    ) throws -> Transaction {
        guard let current = transaction,
              current.request.requestGeneration == requestGeneration,
              current.rendererEvidenceSequenceBaseline == rendererEvidenceSequenceBaseline else {
            throw Failure.presentationGenerationMismatch
        }
        switch current.state {
        case let .mounted(currentBinding):
            guard currentBinding == binding else {
                throw Failure.presentationCoordinateMismatch
            }
            return current
        case .awaitingMount:
            throw Failure.presentationFailed
        case let .failed(error):
            throw error
        case .retired:
            throw Failure.presentationRetired
        }
    }

    private func waitForFreshInstantiation(
        requestGeneration: UUID,
        binding: Diagnostics.RendererBinding,
        rendererEvidenceSequenceBaseline: UInt64,
        deadline: Date
    ) async throws -> (sequence: UInt64, evidence: Diagnostics.RendererEvidence) {
        while true {
            try Task.checkCancellation()
            _ = try mountedTransaction(
                requestGeneration: requestGeneration,
                binding: binding,
                rendererEvidenceSequenceBaseline: rendererEvidenceSequenceBaseline
            )
            let snapshot = diagnostics.rendererSnapshot()
            switch snapshot.resolution(for: binding) {
            case let .instantiated(evidence):
                guard let entry = snapshot.entries.last(where: {
                    $0.sequence > rendererEvidenceSequenceBaseline
                        && $0.evidence.lifecycle == .instantiated
                        && $0.evidence.observation.binding == binding
                }) else {
                    throw Failure.staleEvidence
                }
                return (entry.sequence, evidence)
            case .retired:
                throw Failure.retiredEvidence
            case .staleGeneration:
                throw Failure.staleEvidence
            case let .shellBrokerProcessIdentifierMismatch(observed):
                throw Failure.shellBrokerProcessIdentifierMismatch(observed: observed)
            case .noInstantiatedRenderer:
                guard Date() < deadline else { throw Failure.missingEvidence }
                try await Task.sleep(nanoseconds: Self.presentationPollNanoseconds)
            }
        }
    }

    private func retireAndWaitForExactEvidence(
        requestGeneration: UUID,
        binding: Diagnostics.RendererBinding,
        rendererEvidenceSequenceBaseline: UInt64,
        deadline: Date
    ) async throws {
        requestPresentationRetirement(requestGeneration: requestGeneration)
        while true {
            try Task.checkCancellation()
            guard let current = transaction,
                  current.request.requestGeneration == requestGeneration else {
                throw Failure.presentationGenerationMismatch
            }
            let didRetirePresentation: Bool
            switch current.state {
            case let .retired(retiredBinding):
                guard retiredBinding == binding else {
                    throw Failure.presentationCoordinateMismatch
                }
                didRetirePresentation = true
            case let .mounted(currentBinding):
                guard currentBinding == binding else {
                    throw Failure.presentationCoordinateMismatch
                }
                didRetirePresentation = false
            case .awaitingMount:
                throw Failure.presentationFailed
            case let .failed(error):
                throw error
            }

            let snapshot = diagnostics.rendererSnapshot()
            switch snapshot.resolution(for: binding) {
            case let .retired(evidence):
                let hasFreshRetirement = snapshot.entries.contains(where: {
                    $0.sequence > rendererEvidenceSequenceBaseline
                        && $0.evidence.lifecycle == .retired
                        && $0.evidence.observation.binding == binding
                })
                guard evidence.observation.binding == binding, hasFreshRetirement else {
                    throw Failure.staleEvidence
                }
                if didRetirePresentation { return }
            case .instantiated, .noInstantiatedRenderer:
                break
            case .staleGeneration:
                throw Failure.staleEvidence
            case let .shellBrokerProcessIdentifierMismatch(observed):
                throw Failure.shellBrokerProcessIdentifierMismatch(observed: observed)
            }
            guard Date() < deadline else { throw Failure.retirementTimedOut }
            try await Task.sleep(nanoseconds: Self.presentationPollNanoseconds)
        }
    }

    private func requestPresentationRetirement(requestGeneration: UUID) {
        guard transaction?.request.requestGeneration == requestGeneration else { return }
        presentationRequest = nil
    }

    private func waitForBestEffortRetirement(
        requestGeneration: UUID,
        binding: Diagnostics.RendererBinding
    ) async {
        let deadline = Date().addingTimeInterval(min(waitDuration, 0.25))
        while Date() < deadline {
            guard !Task.isCancelled else { return }
            guard let current = transaction,
                  current.request.requestGeneration == requestGeneration else { return }
            switch current.state {
            case let .retired(retiredBinding) where retiredBinding == binding:
                return
            case .failed:
                return
            case .awaitingMount, .mounted, .retired:
                break
            }
            do {
                try await Task.sleep(nanoseconds: Self.presentationPollNanoseconds)
            } catch {
                return
            }
        }
    }

    private func runtimeEvidence(
        requestGeneration: UUID,
        evidence: Diagnostics.RendererEvidence
    ) throws -> Runner.RendererRuntimeEvidence {
        guard evidence.lifecycle == .instantiated else { throw Failure.retiredEvidence }
        let observation = evidence.observation
        let requestedMode: Runner.RendererMode
        let backend: Runner.RendererBackend
        let fallback: Runner.RendererFallbackReason?
        switch (
            observation.binding.generation,
            observation.requestedMode,
            observation.observedMode,
            observation.fallbackReason
        ) {
        case (.exact, .ghosttyFullSurface, .ghosttyFullSurface, .none):
            requestedMode = .defaultFullGhosttySurface
            backend = .ghosttyFullSurface
            fallback = nil
        case (
            .notAllocated,
            .macScopeGhosttyVTGrid,
            .macScopeGhosttyVTGrid,
            .recoveryOverride
        ):
            requestedMode = .forcedLegacyGridRecoveryOverride
            backend = .macScopeGhosttyVTGrid
            fallback = .recoveryOverride
        default:
            throw Failure.unexpectedRendererEvidence
        }

        let binding = observation.binding
        return Runner.RendererRuntimeEvidence(
            requestedMode: requestedMode,
            generation: requestGeneration,
            selectedBackend: backend,
            fallbackReason: fallback,
            rendererPresented: true,
            transcriptOnlyFallbackPresented: false,
            shellSessionID: binding.sessionID,
            shellRequestID: binding.requestID,
            shellProcessIdentifier: binding.shellBrokerProcessIdentifier
        )
    }

    private func clearPresentation(requestGeneration: UUID) {
        guard transaction?.request.requestGeneration == requestGeneration else { return }
        presentationRequest = nil
        transaction = nil
    }

    private static func boundedWaitDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(duration, Diagnostics.maximumRendererWaitDuration)
    }
}
