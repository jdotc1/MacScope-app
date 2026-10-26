import Foundation

/// One policy source for the reconstruction loop. C3 can supply stored settings here without
/// changing transport, scheduler or coordinator defaults. Environment overrides are deliberately
/// admitted only for an explicitly selected headless host; ordinary application launches ignore
/// them.
struct ReconstructionBudgetPolicy: Codable, Hashable, Sendable {
    static let defaults = Self(warmRoundSeconds: 900, coldRoundMultiplier: 2, jobSeconds: 5_400)
    static let warmRoundEnvironmentKey = "MACSCOPE_RECONSTRUCTION_WARM_ROUND_SECONDS"
    static let coldMultiplierEnvironmentKey = "MACSCOPE_RECONSTRUCTION_COLD_ROUND_MULTIPLIER"
    static let jobEnvironmentKey = "MACSCOPE_RECONSTRUCTION_JOB_SECONDS"

    let warmRoundSeconds: Double
    let coldRoundMultiplier: Double
    let jobSeconds: Double

    var isValid: Bool {
        warmRoundSeconds.isFinite && (1...900).contains(warmRoundSeconds)
            && coldRoundMultiplier.isFinite && (1...2).contains(coldRoundMultiplier)
            && jobSeconds.isFinite && (1...86_400).contains(jobSeconds)
    }

    func roundSeconds(isColdFirstRound: Bool) -> Double {
        warmRoundSeconds * (isColdFirstRound ? coldRoundMultiplier : 1)
    }

    static func forProcess(arguments: [String] = ProcessInfo.processInfo.arguments,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard ReconstructionHeadlessHostConfiguration.isRequested(arguments: arguments,
                                                                 environment: environment) else {
            return defaults
        }
        let supplied = Self(
            warmRoundSeconds: environment[warmRoundEnvironmentKey].flatMap(Double.init)
                ?? defaults.warmRoundSeconds,
            coldRoundMultiplier: environment[coldMultiplierEnvironmentKey].flatMap(Double.init)
                ?? defaults.coldRoundMultiplier,
            jobSeconds: environment[jobEnvironmentKey].flatMap(Double.init) ?? defaults.jobSeconds)
        return supplied.isValid ? supplied : defaults
    }
}

/// Selects the cold-round allowance (§4.84). The 2x allowance exists because the first request
/// after a model load pays the load/prefill-cache warmup, which is unrelated to the job's logical
/// round index: a resumed job's first round after relaunch is cold even though its index is > 0,
/// and round 0 of a job on a model this process has already used is warm.
///
/// MacScope does not observe the provider's actual weight load, so this uses the smallest honest
/// signal it owns: the first fresh dispatch in this process to one provider endpoint configuration
/// and selected-model identity. `profileID` is minted per launch and `generation` increments when
/// the endpoint is reconfigured, so a relaunch or reconfiguration is cold again; a changed
/// selected model has a different identity digest. A replay makes no provider call, so it is never
/// cold and does not consume the claim. Process-lifetime only; nothing is persisted.
final class ReconstructionColdRoundTracker: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let profileID: UUID
        let generation: UInt64
        let modelIdentitySHA256: String
    }

    static let shared = ReconstructionColdRoundTracker()
    private let lock = NSLock()
    private var warmed: Set<Key> = []

    /// True exactly once per key in this tracker's lifetime, unless the round is a replay.
    func isColdRound(isReplay: Bool, key: Key) -> Bool {
        guard !isReplay else { return false }
        return lock.withLock { warmed.insert(key).inserted }
    }

    func isColdRound(_ session: ReconstructionReplaySession) -> Bool {
        isColdRound(isReplay: session.isReplay, key: .init(profileID: session.lease.configuration.profileID,
            generation: session.lease.configuration.generation,
            modelIdentitySHA256: session.record.identity.modelIdentitySHA256))
    }
}

enum ReconstructionHeadlessHostConfiguration {
    static let environmentKey = "MACSCOPE_HEADLESS_HOST"

    static func isRequested(arguments: [String], environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
            || arguments.dropFirst().first == "--run-script"
            || arguments.dropFirst().first == "--headless-workspace-acceptance"
    }
}

/// This counts actual coordinator activations, not test-process lifetime. A run holds its token
/// through model dispatch, reply journal publication and checkpoint/cancellation drain.
final class ReconstructionExecutionActivity: @unchecked Sendable {
    static let shared = ReconstructionExecutionActivity()
    private let lock = NSLock()
    private var activations: Set<UUID> = []

    var isExecuting: Bool { lock.withLock { !activations.isEmpty } }

    func begin() -> UUID {
        lock.withLock {
            let token = UUID()
            activations.insert(token)
            return token
        }
    }

    func end(_ token: UUID) { _ = lock.withLock { activations.remove(token) } }
}
