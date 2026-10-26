import Foundation

enum ReconstructionDestinationSessionResolutionError: Error, Equatable, Sendable {
    case durableJobRequired
    case jobIdentityMismatch(expected: UUID, actual: UUID)
    case staleResolution
    case retired
}

/// Per-window lazy composition gate for the native Reconstruction destination.
///
/// The factory is the only place permitted to acquire coordinator, model-worker, headless-analysis,
/// or native-decompiler capabilities. An empty destination therefore cannot mint runtime authority.
/// A window binds to one durable job identity until `reset()` is called, and concurrent reads for
/// that job share one in-flight construction task. Reset and terminal retirement are asynchronous
/// barriers: no replacement factory may run until every authority minted by the prior generation
/// has been retired.
actor ReconstructionDestinationSessionResolver<Session: Sendable> {
    typealias Factory = @Sendable (UUID) async throws -> Session
    typealias Retire = @Sendable (Session) async -> Void

    private struct Construction {
        let token: UUID
        let generation: UInt64
        let jobID: UUID
        let task: Task<Session, Error>
    }

    private struct RetirementBarrier {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let factory: Factory
    private let retireSession: Retire
    private var boundJobID: UUID?
    private var resolvedSession: Session?
    private var resolvedConstructionToken: UUID?
    private var construction: Construction?
    private var retirementBarrier: RetirementBarrier?
    private var generation: UInt64 = 0
    private var isTerminallyRetired = false

    init(
        factory: @escaping Factory,
        retire: @escaping Retire = { _ in }
    ) {
        self.factory = factory
        self.retireSession = retire
    }

    func resolve(forDurableJobID jobID: UUID?) async throws -> Session {
        guard let jobID else {
            throw ReconstructionDestinationSessionResolutionError.durableJobRequired
        }
        await awaitRetirementBarrier()
        guard !isTerminallyRetired else {
            throw ReconstructionDestinationSessionResolutionError.retired
        }
        if let boundJobID, boundJobID != jobID {
            throw ReconstructionDestinationSessionResolutionError.jobIdentityMismatch(
                expected: boundJobID,
                actual: jobID
            )
        }
        if let resolvedSession {
            return resolvedSession
        }

        boundJobID = jobID
        let activeConstruction: Construction
        if let construction {
            activeConstruction = construction
        } else {
            let factory = self.factory
            activeConstruction = .init(
                token: UUID(),
                generation: generation,
                jobID: jobID,
                task: Task { try await factory(jobID) }
            )
            construction = activeConstruction
        }

        do {
            let session = try await activeConstruction.task.value
            if resolvedConstructionToken == activeConstruction.token,
               let resolvedSession {
                return resolvedSession
            }
            guard !isTerminallyRetired else {
                throw ReconstructionDestinationSessionResolutionError.retired
            }
            guard generation == activeConstruction.generation,
                  boundJobID == activeConstruction.jobID,
                  construction?.token == activeConstruction.token else {
                throw ReconstructionDestinationSessionResolutionError.staleResolution
            }
            resolvedSession = session
            resolvedConstructionToken = activeConstruction.token
            construction = nil
            return session
        } catch {
            if isTerminallyRetired {
                throw ReconstructionDestinationSessionResolutionError.retired
            }
            guard generation == activeConstruction.generation else {
                throw ReconstructionDestinationSessionResolutionError.staleResolution
            }
            if construction?.token == activeConstruction.token,
               resolvedSession == nil {
                construction = nil
                boundJobID = nil
            }
            throw error
        }
    }

    /// Retires this window's current composition lease before a replacement can be activated.
    func reset() async {
        await invalidate(terminal: false)
    }

    /// Permanently retires the resolver. Every later resolution fails closed.
    func retire() async {
        await invalidate(terminal: true)
    }

    func resolvedDurableJobID() -> UUID? {
        resolvedSession == nil ? nil : boundJobID
    }

    private func invalidate(terminal: Bool) async {
        if terminal {
            isTerminallyRetired = true
        }
        if let retirementBarrier {
            await retirementBarrier.task.value
            clearRetirementBarrier(ifTokenMatches: retirementBarrier.token)
            return
        }

        generation &+= 1
        let session = resolvedSession
        let activeConstruction = construction
        construction = nil
        resolvedSession = nil
        resolvedConstructionToken = nil
        boundJobID = nil

        guard session != nil || activeConstruction != nil else { return }
        let retireSession = self.retireSession
        let barrier = RetirementBarrier(
            token: UUID(),
            task: Task {
                if let session {
                    await retireSession(session)
                }
                if let activeConstruction {
                    activeConstruction.task.cancel()
                    if let lateSession = try? await activeConstruction.task.value {
                        await retireSession(lateSession)
                    }
                }
            }
        )
        retirementBarrier = barrier
        await barrier.task.value
        clearRetirementBarrier(ifTokenMatches: barrier.token)
    }

    private func awaitRetirementBarrier() async {
        while let retirementBarrier {
            await retirementBarrier.task.value
            clearRetirementBarrier(ifTokenMatches: retirementBarrier.token)
        }
    }

    private func clearRetirementBarrier(ifTokenMatches token: UUID) {
        guard retirementBarrier?.token == token else { return }
        retirementBarrier = nil
    }
}
