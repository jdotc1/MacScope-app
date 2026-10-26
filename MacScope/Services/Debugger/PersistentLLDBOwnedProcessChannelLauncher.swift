import Foundation

enum PersistentLLDBOwnedProcessChannelLauncherError: Error, LocalizedError, Sendable, Equatable {
    case cleanupUnproven

    var errorDescription: String? {
        switch self {
        case .cleanupUnproven:
            "The retained LLDB child could not be proven settled in the owned-process registry."
        }
    }
}

/// A process prepared before any child is visible. The same object performs the one launch,
/// supplies exact retained-process evidence, and becomes the returned byte/lifecycle channel.
protocol PersistentLLDBOwnedPreparedProcessChannel:
    AnyObject,
    PersistentLLDBTargetlessProcessChannel,
    DebuggerOwnedInfrastructureRetainedProcessBinding
{
    func launchPreparedProcess() async throws
}

/// Registry-backed lifecycle wrapper. Reap is successful only after both the retained child and
/// its exact owned-infrastructure registration have been retired.
private actor PersistentLLDBRegisteredProcessChannel: PersistentLLDBOwnedPreparedProcessChannel {
    private let channel: any PersistentLLDBOwnedPreparedProcessChannel
    private let registry: DebuggerOwnedInfrastructureRegistry
    private var registration: DebuggerOwnedInfrastructureRegistration?
    private var didReapChild = false
    private var didRetireRegistration = false

    init(
        channel: any PersistentLLDBOwnedPreparedProcessChannel,
        registry: DebuggerOwnedInfrastructureRegistry
    ) {
        self.channel = channel
        self.registry = registry
    }

    func launchPreparedProcess() async throws { try await channel.launchPreparedProcess() }
    func write(_ data: Data) async throws { try await channel.write(data) }
    func nextBytes() async throws -> Data? { try await channel.nextBytes() }
    func closeInput() async { await channel.closeInput() }
    func closeHandles() async { await channel.closeHandles() }
    func waitForExit(maximumDuration: Duration) async -> Bool {
        await channel.waitForExit(maximumDuration: maximumDuration)
    }
    func terminateRetainedAdapter() async { await channel.terminateRetainedAdapter() }
    func killRetainedAdapterIfStillRunning() async -> Bool {
        await channel.killRetainedAdapterIfStillRunning()
    }

    func retainedProcessIdentifierForInfrastructure() async -> Int32 {
        await channel.retainedProcessIdentifierForInfrastructure()
    }
    func retainedProcessIsRunningForInfrastructure() async -> Bool {
        await channel.retainedProcessIsRunningForInfrastructure()
    }
    func retainedProcessDispositionForInfrastructure() async
        -> DebuggerOwnedInfrastructureRetainedProcessDisposition {
        await channel.retainedProcessDispositionForInfrastructure()
    }

    func installRegistration(_ registration: DebuggerOwnedInfrastructureRegistration) {
        precondition(self.registration == nil)
        self.registration = registration
    }

    func reapAndClose() async -> Bool {
        if didRetireRegistration { return true }
        if !didReapChild {
            didReapChild = await channel.reapAndClose()
        }
        guard didReapChild else { return false }
        guard let registration else { return true }
        do {
            try await registry.retire(registration)
            didRetireRegistration = true
            return true
        } catch {
            return false
        }
    }
}

/// Creates one targetless LLDB child while keeping the process-global exclusion registry exact.
/// No target command is written here and merely constructing this launcher enables no capability.
struct PersistentLLDBOwnedProcessChannelLauncher: Sendable {
    typealias ProcessPreparer = @MainActor @Sendable (
        PersistentLLDBCLIProcessLaunchPlan
    ) throws -> any PersistentLLDBOwnedPreparedProcessChannel

    private let registry: DebuggerOwnedInfrastructureRegistry
    private let processPreparer: ProcessPreparer
    let ownedInfrastructureRegistryIdentityForTesting: ObjectIdentifier

    init(
        registry: DebuggerOwnedInfrastructureRegistry,
        processPreparer: @escaping ProcessPreparer = { plan in
            try FoundationPersistentLLDBCLIProcessChannel.prepare(plan: plan)
        }
    ) {
        self.registry = registry
        self.processPreparer = processPreparer
        self.ownedInfrastructureRegistryIdentityForTesting = ObjectIdentifier(registry)
    }

    @MainActor
    func launch(
        plan: PersistentLLDBCLIProcessLaunchPlan
    ) async throws -> any PersistentLLDBTargetlessProcessChannel {
        let preparedChannel = try processPreparer(plan)
        let channel = PersistentLLDBRegisteredProcessChannel(
            channel: preparedChannel,
            registry: registry
        )
        try Task.checkCancellation()

        let token = try await registry.beginSpawn(kind: .persistentLLDBAdapter)
        do {
            try Task.checkCancellation()
        } catch {
            try await registry.cancelBeforeProcessLaunch(token)
            throw error
        }

        let claim: DebuggerOwnedInfrastructureLaunchClaim
        do {
            claim = try await registry.beginLaunchAttempt(token)
        } catch {
            try? await registry.cancelBeforeProcessLaunch(token)
            throw error
        }

        // Once the claim is consumed, cancellation cannot strand a possibly visible child. The
        // detached transaction finishes exact registration or proven cleanup before this method
        // observes cancellation again.
        let transaction = Task.detached(priority: .userInitiated) {
            do {
                try await channel.launchPreparedProcess()
            } catch {
                guard await Self.settleFailedLaunch(
                    token: token,
                    claim: claim,
                    channel: channel,
                    registry: registry
                ) else {
                    throw PersistentLLDBOwnedProcessChannelLauncherError.cleanupUnproven
                }
                throw error
            }

            do {
                let registration = try await registry.registerSpawnedProcess(
                    claim,
                    retainedProcess: channel
                )
                await channel.installRegistration(registration)
                return channel
            } catch {
                guard await Self.retireUnresolvedChannel(
                    token: token,
                    channel: channel,
                    registry: registry
                ) else {
                    throw PersistentLLDBOwnedProcessChannelLauncherError.cleanupUnproven
                }
                throw error
            }
        }

        let registered = try await transaction.value
        if Task.isCancelled {
            let cleanup = Task.detached(priority: .userInitiated) {
                await Self.commandFreeRetire(registered)
            }
            guard await cleanup.value else {
                throw PersistentLLDBOwnedProcessChannelLauncherError.cleanupUnproven
            }
            throw CancellationError()
        }
        return registered
    }

    private nonisolated static func settleFailedLaunch(
        token: DebuggerOwnedInfrastructureSpawnToken,
        claim: DebuggerOwnedInfrastructureLaunchClaim,
        channel: PersistentLLDBRegisteredProcessChannel,
        registry: DebuggerOwnedInfrastructureRegistry
    ) async -> Bool {
        let disposition = await channel.retainedProcessDispositionForInfrastructure()
        if disposition == .notLaunched {
            do {
                try await registry.settleUnlaunchedProcess(claim, retainedProcess: channel)
                return true
            } catch {
                return await retireUnresolvedChannel(
                    token: token,
                    channel: channel,
                    registry: registry
                )
            }
        }

        do {
            let registration = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: channel
            )
            await channel.installRegistration(registration)
            return await commandFreeRetire(channel)
        } catch {
            return await retireUnresolvedChannel(
                token: token,
                channel: channel,
                registry: registry
            )
        }
    }

    private nonisolated static func retireUnresolvedChannel(
        token: DebuggerOwnedInfrastructureSpawnToken,
        channel: PersistentLLDBRegisteredProcessChannel,
        registry: DebuggerOwnedInfrastructureRegistry
    ) async -> Bool {
        guard await commandFreeRetire(channel) else { return false }
        do {
            try await registry.retireUnresolvedSpawn(token, retainedProcess: channel)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func commandFreeRetire(
        _ channel: any PersistentLLDBTargetlessProcessChannel
    ) async -> Bool {
        await channel.closeInput()
        var didExit = await channel.waitForExit(maximumDuration: .zero)
        if !didExit {
            await channel.terminateRetainedAdapter()
            didExit = await channel.waitForExit(maximumDuration: .seconds(1))
        }
        if !didExit {
            _ = await channel.killRetainedAdapterIfStillRunning()
            didExit = await channel.waitForExit(maximumDuration: .seconds(1))
        }
        let didReap = await channel.reapAndClose()
        await channel.closeHandles()
        return didExit && didReap
    }
}
