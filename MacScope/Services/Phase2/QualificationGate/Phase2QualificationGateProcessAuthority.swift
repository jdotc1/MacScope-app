import Darwin
import Foundation
@testable import MacScope


protocol Phase2QualificationGateProviderProcessDiscovering: Sendable {
    func uniqueListenerProcess(
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Phase2QualificationProcessObservation?
    func processOwnsEstablishedConnection(
        _ process: Phase2QualificationProcessObservation,
        receipt: Phase2InferenceProviderConnectionReceipt,
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Bool
    func processesOwnEstablishedConnection(
        worker: Phase2QualificationProcessObservation,
        provider: Phase2QualificationProcessObservation,
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Bool
}

/// Gate-owned facade for authenticating the certificate-signed AI worker that owns a concrete
/// XPC connection receipt. The caller receives the receipt and the independently observed process
/// together, so it cannot substitute an unbound PID or validate a different worker instance.
@MainActor
protocol Phase2QualificationGateWorkerProcessValidating: AnyObject {
    func validateWorkerProcess(
        receipt: Phase2InferenceWorkerProcessReceipt,
        observation: Phase2QualificationProcessObservation
    ) -> Bool
}

/// A measurement configuration is built before the first provider connection exists. This proxy
/// is the only value handed to that configuration: it has no caller-controlled roots and remains
/// unavailable until Gate-G4 has authenticated all three concrete process roles.
final class Phase2QualificationGateDeferredProcessScopeSampler:
    Phase2QualificationBoundResidentSetSampling,
    @unchecked Sendable
{
    private enum State {
        case unbound
        case bound(Phase2QualificationProcessScopeSampler)
        case failed
    }

    private static let unavailableScope = try! Phase2ProtocolComponentIdentity.unavailable(
        id: "phase2.r1.qualification-process-scope.v1",
        version: 1
    )

    private let lock = NSLock()
    private var state: State = .unbound

    var scopeIdentity: Phase2ProtocolComponentIdentity {
        lock.lock(); defer { lock.unlock() }
        guard case .bound(let sampler) = state else { return Self.unavailableScope }
        return sampler.scopeIdentity
    }

    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        let sampler: Phase2QualificationProcessScopeSampler? = {
            lock.lock(); defer { lock.unlock() }
            guard case .bound(let value) = state else { return nil }
            return value
        }()
        return try sampler?.sample()
    }

    fileprivate var boundSampler: Phase2QualificationProcessScopeSampler? {
        lock.lock(); defer { lock.unlock() }
        guard case .bound(let sampler) = state else { return nil }
        return sampler
    }

    fileprivate func bind(_ sampler: Phase2QualificationProcessScopeSampler) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .unbound = state else { return false }
        state = .bound(sampler)
        return true
    }

    fileprivate func fail() {
        lock.lock(); defer { lock.unlock() }
        state = .failed
    }
}

/// CoreTests-only Gate-G4 authority. It converts the app-owned coordinator's per-phase worker
/// receipts into exact launch-local app/worker/provider authority and never accepts process roots,
/// identities, or RSS values from its caller.
@MainActor
final class Phase2QualificationGateProcessAuthority:
    Phase2ProductionLiveQualificationProcessAuthorizing
{
    enum ProvenanceError: Error, Equatable, Sendable {
        case authorityIncomplete
        case executionIncomplete
        case identityUnavailable
    }

    static let maximumPhaseReceiptCount: Int = Phase2LiveQualificationScenarioCatalog()
        .scenarios.reduce(into: 0) { count, scenario in
            let phases = scenario.phaseFlow == .toolSelectionAndFinalization ? 2 : 1
            count += scenario.trialCount * phases
        }

    let residentSetSampler: any Phase2QualificationBoundResidentSetSampling

    private let prepared: Phase2PreparedLiveQualification
    private let appProcessID: Int32
    private let processObserver: any Phase2QualificationProcessObserving
    private let providerDiscoverer: any Phase2QualificationGateProviderProcessDiscovering
    private let workerProcessValidator:
        (any Phase2QualificationGateWorkerProcessValidating)?
    private let deferredSampler: Phase2QualificationGateDeferredProcessScopeSampler
    private let expectedManifestDigest: String

    private var firstReceipt: Phase2InferenceWorkerProcessReceipt?
    private var appObservation: Phase2QualificationProcessObservation?
    private var workerObservation: Phase2QualificationProcessObservation?
    private var providerObservation: Phase2QualificationProcessObservation?
    private var lastReceipt: Phase2InferenceWorkerProcessReceipt?
    private var receiptCount = 0
    private var providerConnectionReceiptCount = 0
    private var providerDispatchReceiptCount = 0
    private var connectionBoundWorkerIdentities: Set<UUID> = []
    private var dispatchBoundWorkerIdentities: Set<UUID> = []
    private var providerDispatchRequestIDs: Set<UUID> = []
    private var dispatchWorkerIdentityByRequestID: [UUID: UUID] = [:]
    private var failed = false
    private var finished = false

    init(
        prepared: Phase2PreparedLiveQualification,
        workerProcessValidator:
            (any Phase2QualificationGateWorkerProcessValidating)? = nil
    ) {
        let deferred = Phase2QualificationGateDeferredProcessScopeSampler()
        self.prepared = prepared
        appProcessID = Darwin.getpid()
        processObserver = Phase2QualificationLibprocProcessObserver()
        providerDiscoverer = Phase2QualificationGateLibprocProviderDiscoverer()
        self.workerProcessValidator = workerProcessValidator
        deferredSampler = deferred
        residentSetSampler = deferred
        expectedManifestDigest = Phase2ModelProfileCanonicalizer()
            .protocolManifestDigest(for: prepared.profile.protocolManifest)
    }

    private init(
        prepared: Phase2PreparedLiveQualification,
        appProcessID: Int32,
        processObserver: any Phase2QualificationProcessObserving,
        providerDiscoverer: any Phase2QualificationGateProviderProcessDiscovering,
        workerProcessValidator:
            (any Phase2QualificationGateWorkerProcessValidating)?
    ) {
        let deferred = Phase2QualificationGateDeferredProcessScopeSampler()
        self.prepared = prepared
        self.appProcessID = appProcessID
        self.processObserver = processObserver
        self.providerDiscoverer = providerDiscoverer
        self.workerProcessValidator = workerProcessValidator
        deferredSampler = deferred
        residentSetSampler = deferred
        expectedManifestDigest = Phase2ModelProfileCanonicalizer()
            .protocolManifestDigest(for: prepared.profile.protocolManifest)
    }

    static func makeForTesting(
        prepared: Phase2PreparedLiveQualification,
        appProcessID: Int32,
        processObserver: any Phase2QualificationProcessObserving,
        providerDiscoverer: any Phase2QualificationGateProviderProcessDiscovering,
        workerProcessValidator:
            (any Phase2QualificationGateWorkerProcessValidating)? = nil
    ) -> Phase2QualificationGateProcessAuthority {
        .init(
            prepared: prepared,
            appProcessID: appProcessID,
            processObserver: processObserver,
            providerDiscoverer: providerDiscoverer,
            workerProcessValidator: workerProcessValidator
        )
    }

    var boundSampler: Phase2QualificationProcessScopeSampler? {
        deferredSampler.boundSampler
    }

    func acceptWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool {
        guard !failed, !finished, receiptCount < Self.maximumPhaseReceiptCount,
              receiptMatchesPreparedConfiguration(receipt)
        else { return fail() }

        if let firstReceipt {
            guard receipt.processIdentifier == firstReceipt.processIdentifier,
                  receipt.providerGeneration == firstReceipt.providerGeneration,
                  receipt.profileID == firstReceipt.profileID,
                  receipt.configurationGeneration == firstReceipt.configurationGeneration,
                  receipt.protocolManifestDigest == firstReceipt.protocolManifestDigest,
                  revalidateBoundRoles(
                    workerReceipt: receipt,
                    rediscoverProvider: true
                  )
            else { return fail() }
        } else {
            guard bindFirstReceipt(receipt) else { return fail() }
        }

        lastReceipt = receipt
        receiptCount += 1
        return true
    }

    func acceptProviderConnectionReceipt(
        _ receipt: Phase2InferenceProviderConnectionReceipt,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool {
        guard !failed, !finished,
              let lastReceipt,
              workerReceipt == lastReceipt,
              !connectionBoundWorkerIdentities.contains(workerReceipt.connectionIdentity),
              let providerObservation,
              let endpoint = try? Phase2LoopbackEndpoint(
                validating: prepared.runtimeBinding.readyLease.configuration.endpointOrigin
              ),
              revalidateBoundRoles(workerReceipt: workerReceipt, rediscoverProvider: true),
              providerDiscoverer.processOwnsEstablishedConnection(
                providerObservation,
                receipt: receipt,
                endpoint: endpoint,
                processObserver: processObserver
              )
        else { return fail() }
        connectionBoundWorkerIdentities.insert(workerReceipt.connectionIdentity)
        providerConnectionReceiptCount += 1
        return true
    }

    func acceptProviderDispatchReceipt(
        _ receipt: Phase2InferenceDispatchReceipt,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool {
        guard !failed, !finished,
              receipt.boundary == .httpResponseHeaders,
              let lastReceipt,
              workerReceipt == lastReceipt,
              !providerDispatchRequestIDs.contains(receipt.requestID),
              !dispatchBoundWorkerIdentities.contains(workerReceipt.connectionIdentity),
              let workerObservation,
              let providerObservation,
              let endpoint = try? Phase2LoopbackEndpoint(
                validating: prepared.runtimeBinding.readyLease.configuration.endpointOrigin
              ),
              revalidateBoundRoles(workerReceipt: workerReceipt, rediscoverProvider: true),
              providerDiscoverer.processesOwnEstablishedConnection(
                worker: workerObservation,
                provider: providerObservation,
                endpoint: endpoint,
                processObserver: processObserver
              )
        else { return fail() }
        dispatchBoundWorkerIdentities.insert(workerReceipt.connectionIdentity)
        providerDispatchRequestIDs.insert(receipt.requestID)
        dispatchWorkerIdentityByRequestID[receipt.requestID] = workerReceipt.connectionIdentity
        providerDispatchReceiptCount += 1
        return true
    }

    private func finish(
        exactPhaseReceiptCount: Int,
        exactProviderConnectionReceiptCount: Int,
        exactPhaseRequestIDs: Set<UUID>,
        exactProviderConnectionRequestIDs: Set<UUID>
    ) -> Bool {
        let connectionRequestIDs = Set(dispatchWorkerIdentityByRequestID.compactMap {
            requestID, workerIdentity in
            connectionBoundWorkerIdentities.contains(workerIdentity) ? requestID : nil
        })
        guard !failed, !finished,
              (1...Self.maximumPhaseReceiptCount).contains(exactPhaseReceiptCount),
              receiptCount == exactPhaseReceiptCount,
              providerDispatchReceiptCount == exactPhaseReceiptCount,
              providerConnectionReceiptCount == exactProviderConnectionReceiptCount,
              providerDispatchRequestIDs == exactPhaseRequestIDs,
              connectionRequestIDs == exactProviderConnectionRequestIDs,
              let lastReceipt,
              revalidateBoundRoles(
                workerReceipt: lastReceipt,
                rediscoverProvider: true
              ),
              let sampler = deferredSampler.boundSampler,
              (try? sampler.sample()) != nil
        else { return fail() }
        finished = true
        return true
    }

    func finishRuntimeProvenance(
        for execution: Phase2LiveQualificationExecution
    ) throws -> Phase2QualificationRuntimeProvenance {
        guard execution.terminationStatus == .completed,
              let receiptCounts = exactReceiptCounts(for: execution),
              let started = execution.firstAdmissionEpochMilliseconds,
              let ended = execution.terminalEpochMilliseconds,
              started >= 0,
              ended >= started
        else { throw ProvenanceError.executionIncomplete }
        guard finish(
            exactPhaseReceiptCount: receiptCounts.phases,
            exactProviderConnectionReceiptCount: receiptCounts.providerConnections,
            exactPhaseRequestIDs: receiptCounts.phaseRequestIDs,
            exactProviderConnectionRequestIDs: receiptCounts.providerConnectionRequestIDs
        ),
              let sampler = deferredSampler.boundSampler else {
            throw ProvenanceError.authorityIncomplete
        }

        let runtime = prepared.runtimeBinding
        do {
            return try .init(
                endpointProfileID: runtime.endpointProfileID,
                endpointGeneration: runtime.endpointGeneration,
                providerRevision: runtime.providerRevision,
                modelSource: prepared.profile.artifact.source,
                modelRevisionIdentity: runtime.artifactObservation.modelRevision,
                productionDefinitionIdentity: prepared.evidenceBinding.productionDefinition,
                modelKeyIdentityDigest: try runtimeDigest(
                    id: "phase2.r1.runtime-model-key.v1",
                    object: ["model_key": runtime.modelKey]
                ),
                loadedInstanceIdentityDigest: try runtimeDigest(
                    id: "phase2.r1.runtime-loaded-instance.v1",
                    object: ["loaded_instance_id": runtime.loadedInstanceID]
                ),
                loadedConfigurationIdentityDigest: try runtimeDigest(
                    id: "phase2.r1.runtime-loaded-configuration.v1",
                    object: Self.loadedConfigurationObject(runtime.loadedConfiguration)
                ),
                providerBuildObservationDigest: try runtimeDigest(
                    id: "phase2.r1.runtime-provider-build-observation.v1",
                    object: Self.providerObject(runtime.provider)
                ),
                providerRuntimeIdentity: runtime.providerRuntimeIdentity,
                workerManifestDigest: expectedManifestDigest,
                measurementScopeIdentity: sampler.scopeIdentity,
                startedAtEpochMilliseconds: started,
                endedAtEpochMilliseconds: ended
            )
        } catch let error as ProvenanceError {
            throw error
        } catch {
            throw ProvenanceError.identityUnavailable
        }
    }

    static func providerProcessStartIdentity(
        _ observation: Phase2QualificationProcessObservation
    ) throws -> Phase2ProtocolComponentIdentity {
        guard observation.hasValidIdentity,
              observation.startIdentity.seconds <= UInt64(Int64.max),
              observation.startIdentity.microseconds <= UInt64(Int64.max)
        else { throw ProvenanceError.identityUnavailable }
        return try Phase2QualificationV2Identity.make(
            id: "phase2.r1.provider-process-start.v1",
            version: 1,
            object: [
                "parent_pid": Int64(observation.parentProcessID),
                "pid": Int64(observation.processID),
                "start_microseconds": Int64(observation.startIdentity.microseconds),
                "start_seconds": Int64(observation.startIdentity.seconds),
            ]
        )
    }

    static func providerExecutableBuildIdentity(
        _ observation: Phase2QualificationProcessObservation
    ) throws -> Phase2ProtocolComponentIdentity {
        guard observation.hasValidIdentity,
              observation.executableIdentity.deviceID <= UInt64(Int64.max),
              observation.executableIdentity.fileID <= UInt64(Int64.max)
        else { throw ProvenanceError.identityUnavailable }
        return try Phase2QualificationV2Identity.make(
            id: "phase2.r1.provider-executable-build.v1",
            version: 1,
            object: [
                "device_id": Int64(observation.executableIdentity.deviceID),
                "file_id": Int64(observation.executableIdentity.fileID),
                "sha256": observation.executableIdentity.sha256,
            ]
        )
    }

    private func bindFirstReceipt(_ receipt: Phase2InferenceWorkerProcessReceipt) -> Bool {
        guard preparedBindingIsSelfConsistent(),
              appProcessID > 1,
              receipt.processIdentifier > 1,
              let endpoint = try? Phase2LoopbackEndpoint(
                validating: prepared.runtimeBinding.readyLease.configuration.endpointOrigin
              ),
              let app = try? processObserver.observation(processID: appProcessID),
              app.processID == appProcessID,
              app.executableIdentity.sha256
                == prepared.evidenceBinding.qualificationEnvironment.appExecutableDigest,
              let worker = try? processObserver.observation(
                processID: receipt.processIdentifier
              ),
              worker.processID == receipt.processIdentifier,
              worker.executableIdentity.sha256
                == prepared.evidenceBinding.qualificationEnvironment.workerExecutableDigest,
              validateWorkerProcess(receipt: receipt, observation: worker),
              let provider = providerDiscoverer.uniqueListenerProcess(
                endpoint: endpoint,
                processObserver: processObserver
              ),
              Set([app.processID, worker.processID, provider.processID]).count == 3,
              providerRuntimeMatchesPrepared(provider),
              let sampler = Phase2QualificationProcessScopeSampler(
                appProcessID: app.processID,
                aiWorkerProcessID: worker.processID,
                providerProcessID: provider.processID,
                observer: processObserver
              ),
              (try? sampler.sample()) != nil,
              deferredSampler.bind(sampler)
        else { return false }

        firstReceipt = receipt
        appObservation = app
        workerObservation = worker
        providerObservation = provider
        return true
    }

    private func receiptMatchesPreparedConfiguration(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool {
        let runtime = prepared.runtimeBinding
        return receipt.profileID == runtime.endpointProfileID
            && receipt.configurationGeneration == runtime.endpointGeneration
            && receipt.protocolManifestDigest == expectedManifestDigest
            && receipt.profileID == runtime.readyLease.configuration.profileID
            && receipt.configurationGeneration == runtime.readyLease.configuration.generation
    }

    private func preparedBindingIsSelfConsistent() -> Bool {
        let runtime = prepared.runtimeBinding
        return runtime.endpointProfileID == runtime.readyLease.configuration.profileID
            && runtime.endpointGeneration == runtime.readyLease.configuration.generation
            && runtime.providerRevision == runtime.readyLease.providerRevision
            && runtime.modelKey == runtime.readyLease.configuration.model
            && runtime.loadedConfiguration == prepared.profile.loadedConfiguration
            && runtime.provider == prepared.profile.provider
            && runtime.modelKey == prepared.profile.artifact.modelKey
    }

    /// Derives the receipt denominator only from the runner-sealed dispatch ledger and rejects
    /// any ledger that is not an exact canonical completed schedule. A two-phase trial may omit
    /// finalization only when its recorded semantic result failed after tool selection.
    private func exactReceiptCounts(
        for execution: Phase2LiveQualificationExecution
    ) -> (
        phases: Int,
        providerConnections: Int,
        phaseRequestIDs: Set<UUID>,
        providerConnectionRequestIDs: Set<UUID>
    )? {
        let standard = Phase2ProductionQualificationPolicy.standard
        let catalog = standard.liveScenarioCatalog
        guard let plan = try? Phase2LiveQualificationPlan(
            policy: standard.policy,
            catalog: catalog,
            fixtures: catalog.productionFixtures()
        ), let records = execution.dispatchEvidence?.phaseRequests,
           !records.isEmpty,
           records.count <= Self.maximumPhaseReceiptCount,
           Set(records.map(\.requestID)).count == records.count,
           execution.observations.count == plan.scheduledTrials.count
        else { return nil }

        var cursor = 0
        var providerConnections = 0
        var providerConnectionRequestIDs: Set<UUID> = []
        func consume(
            _ scheduled: Phase2LiveQualificationScheduledTrial,
            phase: Phase2InferencePhase,
            requestID: UUID,
            requiresProviderConnection: Bool = true
        ) -> Bool {
            guard cursor < records.count else { return false }
            let record = records[cursor]
            guard record.trialKey == scheduled.fixture.key,
                  record.phase == phase,
                  record.requestID == requestID
            else { return false }
            cursor += 1
            if requiresProviderConnection {
                providerConnections += 1
                providerConnectionRequestIDs.insert(requestID)
            }
            return true
        }

        for (scheduled, observation) in zip(
            plan.scheduledTrials,
            execution.observations
        ) {
            let key = scheduled.fixture.key
            guard observation.probeID == key.probeID,
                  observation.trial == key.trial,
                  observation.attempt == 1,
                  observation.outcome == .passed || observation.outcome == .failed
            else { return nil }

            switch scheduled.scenario.phaseFlow {
            case .toolSelection:
                guard consume(
                    scheduled,
                    phase: .toolSelection,
                    requestID: scheduled.fixture.selectionRequestID
                ) else { return nil }

            case .finalization, .cancellation:
                guard consume(
                    scheduled,
                    phase: .finalization,
                    requestID: scheduled.fixture.finalizationRequestID,
                    requiresProviderConnection: scheduled.scenario.phaseFlow != .cancellation
                ) else { return nil }

            case .toolSelectionAndFinalization:
                guard consume(
                    scheduled,
                    phase: .toolSelection,
                    requestID: scheduled.fixture.selectionRequestID
                ) else { return nil }
                if cursor < records.count, records[cursor].trialKey == key {
                    guard consume(
                        scheduled,
                        phase: .finalization,
                        requestID: scheduled.fixture.finalizationRequestID
                    ) else { return nil }
                } else if observation.outcome != .failed {
                    return nil
                }
            }
        }
        return cursor == records.count
            ? (
                records.count,
                providerConnections,
                Set(records.map(\.requestID)),
                providerConnectionRequestIDs
            )
            : nil
    }

    private func providerRuntimeMatchesPrepared(
        _ provider: Phase2QualificationProcessObservation
    ) -> Bool {
        guard let processStart = try? Self.providerProcessStartIdentity(provider),
              let executable = try? Self.providerExecutableBuildIdentity(provider)
        else { return false }
        return processStart == prepared.runtimeBinding.providerRuntimeIdentity.processStart
            && executable == prepared.runtimeBinding.providerRuntimeIdentity.executableBuild
    }

    private func revalidateBoundRoles(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        rediscoverProvider: Bool
    ) -> Bool {
        guard let appObservation, let workerObservation, let providerObservation,
              workerReceipt.processIdentifier == workerObservation.processID,
              let currentApp = try? processObserver.observation(
                processID: appObservation.processID
              ),
              appObservation.hasSameIdentity(as: currentApp),
              let currentWorker = try? processObserver.observation(
                processID: workerObservation.processID
              ),
              workerObservation.hasSameIdentity(as: currentWorker),
              validateWorkerProcess(
                receipt: workerReceipt,
                observation: currentWorker
              ),
              let currentProvider = try? processObserver.observation(
                processID: providerObservation.processID
              ),
              providerObservation.hasSameIdentity(as: currentProvider),
              providerRuntimeMatchesPrepared(currentProvider)
        else { return false }

        if rediscoverProvider {
            guard let endpoint = try? Phase2LoopbackEndpoint(
                validating: prepared.runtimeBinding.readyLease.configuration.endpointOrigin
            ),
                  let discovered = providerDiscoverer.uniqueListenerProcess(
                    endpoint: endpoint,
                    processObserver: processObserver
                  ),
                  providerObservation.hasSameIdentity(as: discovered)
            else { return false }
        }
        return true
    }

    private func validateWorkerProcess(
        receipt: Phase2InferenceWorkerProcessReceipt,
        observation: Phase2QualificationProcessObservation
    ) -> Bool {
        guard let workerProcessValidator else { return false }
        return workerProcessValidator.validateWorkerProcess(
            receipt: receipt,
            observation: observation
        )
    }

    private func runtimeDigest(id: String, object: [String: Any]) throws -> String {
        guard let digest = try Phase2QualificationV2Identity.make(
            id: id,
            version: 1,
            object: object
        ).sha256 else { throw ProvenanceError.identityUnavailable }
        return digest
    }

    private static func loadedConfigurationObject(
        _ value: Phase2LocalModelInstanceConfiguration
    ) -> [String: Any] {
        [
            "effective_context_length": value.effectiveContextLength,
            "evaluation_batch_size": value.evaluationBatchSize.map { $0 as Any } ?? NSNull(),
            "expert_count": value.expertCount.map { $0 as Any } ?? NSNull(),
            "flash_attention": value.flashAttention.map { $0 as Any } ?? NSNull(),
            "offloads_kv_cache_to_gpu": value.offloadsKVCacheToGPU.map { $0 as Any } ?? NSNull(),
            "parallel_predictions": value.parallelPredictions.map { $0 as Any } ?? NSNull(),
        ]
    }

    private static func providerObject(_ value: Phase2QualifiedProviderIdentity) -> [String: Any] {
        [
            "api_compatibility": value.apiCompatibility,
            "build": value.build,
            "endpoint_transport": value.endpointTransport.rawValue,
            "family": value.family,
        ]
    }

    @discardableResult
    private func fail() -> Bool {
        failed = true
        deferredSampler.fail()
        return false
    }
}

/// Discovers the sole process holding the already-prepared literal-loopback TCP listener using
/// public libproc socket-FD metadata. Two complete scans plus process-identity revalidation close
/// PID reuse, FD reuse, listener migration, and same-port ambiguity races.
struct Phase2QualificationGateLibprocProviderDiscoverer:
    Phase2QualificationGateProviderProcessDiscovering,
    Sendable
{
    private static let maximumEnumerationBytes = 4_194_304
    private static let enumerationSlackBytes = 4_096

    // Injection is below census/classification: tests exercise the same Darwin decoding path.
    struct DescriptorReadResult: Sendable {
        let byteCount: Int32
        let errorCode: Int32
    }

    private let descriptorRead: @Sendable (Int32, UnsafeMutableRawPointer?, Int32) -> DescriptorReadResult
    private let socketInfo: @Sendable (Int32, Int32) -> socket_fdinfo?

    init(
        descriptorRead: (@Sendable (Int32, UnsafeMutableRawPointer?, Int32) -> DescriptorReadResult)? = nil,
        socketRead: (@Sendable (Int32, Int32) -> socket_fdinfo?)? = nil
    ) {
        self.descriptorRead = descriptorRead ?? { processID, buffer, count in
            // libproc may translate syscall failure to zero. Clear and capture errno at
            // both sizing and read calls so zero-success differs from zero-failure.
            errno = 0
            let bytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, buffer, count)
            let error = errno
            return .init(byteCount: bytes, errorCode: error)
        }
        self.socketInfo = socketRead ?? { processID, descriptor in
            var value = socket_fdinfo()
            let expected = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(processID, descriptor, PROC_PIDFDSOCKETINFO,
                                 &value, expected) == expected else { return nil }
            return value
        }
    }

    func uniqueListenerProcess(
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Phase2QualificationProcessObservation? {
        guard let first = scan(endpoint: endpoint, processObserver: processObserver),
              let second = scan(endpoint: endpoint, processObserver: processObserver),
              first.hasSameIdentity(as: second),
              let final = try? processObserver.observation(processID: second.processID),
              second.hasSameIdentity(as: final)
        else { return nil }
        return final
    }

    func processOwnsEstablishedConnection(
        _ process: Phase2QualificationProcessObservation,
        receipt: Phase2InferenceProviderConnectionReceipt,
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Bool {
        guard receipt.remotePort == endpoint.port,
              Self.isExpectedLoopback(receipt.remoteAddress, host: endpoint.host),
              Self.isExpectedLoopback(receipt.localAddress, host: endpoint.host),
              let before = try? processObserver.observation(processID: process.processID),
              process.hasSameIdentity(as: before),
              let first = establishedSocketDescriptor(
                processID: process.processID,
                receipt: receipt,
                endpoint: endpoint
              ),
              let second = establishedSocketDescriptor(
                processID: process.processID,
                receipt: receipt,
                endpoint: endpoint
              ),
              first == second,
              let after = try? processObserver.observation(processID: process.processID),
              process.hasSameIdentity(as: after)
        else { return false }
        return true
    }

    /// A sampled established socket, not an immutable kernel socket identity.
    struct SocketObservation: Equatable, Sendable {
        let descriptor: Int32
        let receipt: Phase2InferenceProviderConnectionReceipt
    }

    enum SocketCensus: Equatable, Sendable {
        case unavailable, absent, ambiguous
        case bound(SocketObservation)
    }

    struct ConnectionCapture: Sendable {
        let client: Phase2QualificationProcessObservation
        let provider: Phase2QualificationProcessObservation
        let clientSocket: SocketObservation
        let providerSocket: SocketObservation
    }

    enum ConnectionObservation: Sendable {
        case unavailable, absent, ambiguous
        case bound(ConnectionCapture)
    }

    func processesOwnEstablishedConnection(
        worker: Phase2QualificationProcessObservation,
        provider: Phase2QualificationProcessObservation,
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Bool {
        if case .bound = establishedConnection(
            client: worker, provider: provider, endpoint: endpoint,
            processObserver: processObserver
        ) { return true }
        return false
    }

    /// No global tuple state: each independent request may capture a different connection.
    /// Supplying an original capture instead requires that exact observation to remain current.
    func establishedConnection(
        client: Phase2QualificationProcessObservation,
        provider: Phase2QualificationProcessObservation,
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving,
        preserving original: ConnectionCapture? = nil
    ) -> ConnectionObservation {
        if let original {
            guard original.client.hasSameIdentity(as: client),
                  original.provider.hasSameIdentity(as: provider) else { return .unavailable }
        }
        func identitiesMatch() -> Bool {
            guard let currentClient = try? processObserver.observation(processID: client.processID),
                  client.hasSameIdentity(as: currentClient),
                  let currentProvider = try? processObserver.observation(processID: provider.processID),
                  provider.hasSameIdentity(as: currentProvider) else { return false }
            return true
        }
        guard identitiesMatch() else { return .unavailable }
        let first = establishedSocketCensus(processID: client.processID, endpoint: endpoint)
        let second = establishedSocketCensus(processID: client.processID, endpoint: endpoint)
        guard first == second, identitiesMatch() else { return .unavailable }
        switch second {
        case .unavailable: return .unavailable
        case .absent: return .absent
        case .ambiguous: return .ambiguous
        case .bound(let clientSocket):
            if let original, original.clientSocket != clientSocket { return .unavailable }
            let peerFirst = establishedSocketCensus(
                processID: provider.processID, endpoint: endpoint,
                providerReceipt: clientSocket.receipt
            )
            let peerSecond = establishedSocketCensus(
                processID: provider.processID, endpoint: endpoint,
                providerReceipt: clientSocket.receipt
            )
            let clientFinal = establishedSocketCensus(processID: client.processID, endpoint: endpoint)
            guard peerFirst == peerSecond, clientFinal == second, identitiesMatch()
            else { return .unavailable }
            switch peerSecond {
            case .unavailable: return .unavailable
            // The client census already proved an established connection to the endpoint, so a
            // provider with no matching peer (accept queue, closing peer, another owner) cannot
            // be reported as absence; the pair is unattributable.
            case .absent: return .unavailable
            case .ambiguous: return .ambiguous
            case .bound(let providerSocket):
                if let original, original.providerSocket != providerSocket { return .unavailable }
                return .bound(.init(client: client, provider: provider,
                                    clientSocket: clientSocket, providerSocket: providerSocket))
            }
        }
    }

    /// Absence concerns established connections only, never pending connection attempts.
    /// Every socket descriptor must be readable before absence or uniqueness can be claimed.
    func establishedSocketCensus(
        processID: Int32,
        endpoint: Phase2LoopbackEndpoint,
        providerReceipt: Phase2InferenceProviderConnectionReceipt? = nil
    ) -> SocketCensus {
        guard let descriptors = stableFileDescriptors(processID: processID) else { return .unavailable }
        var matches: [SocketObservation] = []
        for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            guard let value = socketInfo(processID, descriptor.proc_fd) else { return .unavailable }
            let tcp = value.psi.soi_proto.pri_tcp
            guard value.psi.soi_kind == SOCKINFO_TCP,
                  value.psi.soi_type == SOCK_STREAM,
                  value.psi.soi_protocol == IPPROTO_TCP,
                  value.psi.soi_family == endpointAddressFamily(endpoint.host),
                  tcp.tcpsi_state == TSI_S_ESTABLISHED,
                  Self.socketAddressesAreExpectedLoopback(tcp, host: endpoint.host)
            else { continue }
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            let remote = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport)))
            let address = endpoint.host == .ipv4 ? "127.0.0.1" : "::1"
            let receipt: Phase2InferenceProviderConnectionReceipt
            if let expected = providerReceipt {
                guard expected.remotePort == endpoint.port,
                      expected.localAddress == address, expected.remoteAddress == address,
                      local == expected.remotePort, remote == expected.localPort else { continue }
                receipt = expected
            } else {
                guard remote == endpoint.port, local > 0,
                      let observed = try? Phase2InferenceProviderConnectionReceipt(
                        localAddress: address, localPort: local,
                        remoteAddress: address, remotePort: remote
                      ) else { continue }
                receipt = observed
            }
            matches.append(.init(descriptor: descriptor.proc_fd, receipt: receipt))
        }
        guard let finalDescriptors = stableFileDescriptors(processID: processID),
              descriptors.elementsEqual(finalDescriptors, by: {
                  $0.proc_fd == $1.proc_fd && $0.proc_fdtype == $1.proc_fdtype
              }) else { return .unavailable }
        if matches.isEmpty { return .absent }
        guard matches.count == 1 else { return .ambiguous }
        return .bound(matches[0])
    }

    private static func socketAddressesAreExpectedLoopback(
        _ tcp: tcp_sockinfo,
        host: Phase2LoopbackEndpoint.Host
    ) -> Bool {
        switch host {
        case .ipv4:
            var loopback = in_addr()
            guard inet_pton(AF_INET, "127.0.0.1", &loopback) == 1 else { return false }
            return tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == loopback.s_addr
                && tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4.s_addr == loopback.s_addr
        case .ipv6:
            var loopback = in6_addr()
            guard inet_pton(AF_INET6, "::1", &loopback) == 1 else { return false }
            var local = tcp.tcpsi_ini.insi_laddr.ina_6
            var remote = tcp.tcpsi_ini.insi_faddr.ina_6
            return withUnsafeBytes(of: &local) { candidate in
                withUnsafeBytes(of: &loopback) { candidate.elementsEqual($0) }
            } && withUnsafeBytes(of: &remote) { candidate in
                withUnsafeBytes(of: &loopback) { candidate.elementsEqual($0) }
            }
        }
    }

    private func establishedSocketDescriptor(
        processID: Int32,
        receipt: Phase2InferenceProviderConnectionReceipt,
        endpoint: Phase2LoopbackEndpoint
    ) -> Int32? {
        if case .bound(let observation) = establishedSocketCensus(
            processID: processID, endpoint: endpoint, providerReceipt: receipt
        ) { return observation.descriptor }
        return nil
    }

    private func scan(
        endpoint: Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Phase2QualificationProcessObservation? {
        guard let processIDs = processIDs() else { return nil }
        var matches: [Int32: Phase2QualificationProcessObservation] = [:]

        for processID in processIDs {
            guard let before = try? processObserver.observation(processID: processID),
                  let descriptors = stableFileDescriptors(processID: processID)
            else { continue }

            var foundListener = false
            for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
                if isExactListener(
                    processID: processID,
                    descriptor: descriptor.proc_fd,
                    endpoint: endpoint
                ) {
                    foundListener = true
                    break
                }
            }
            guard foundListener,
                  let after = try? processObserver.observation(processID: processID),
                  before.hasSameIdentity(as: after)
            else { continue }

            matches[processID] = after
            if matches.count > 1 { return nil }
        }
        return matches.count == 1 ? matches.values.first : nil
    }

    private func processIDs() -> [Int32]? {
        let required = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard required > 0,
              Int(required) <= Self.maximumEnumerationBytes - Self.enumerationSlackBytes
        else { return nil }
        let requestedBytes = Int(required) + Self.enumerationSlackBytes
        let capacity = (requestedBytes + MemoryLayout<Int32>.size - 1)
            / MemoryLayout<Int32>.size
        var values = [Int32](repeating: 0, count: capacity)
        let actual = values.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard actual > 0,
              Int(actual) < values.count * MemoryLayout<Int32>.size,
              Int(actual).isMultiple(of: MemoryLayout<Int32>.size)
        else { return nil }
        let count = Int(actual) / MemoryLayout<Int32>.size
        let result = values.prefix(count).filter { $0 > 1 }.sorted()
        guard Set(result).count == result.count else { return nil }
        return result
    }

    private func stableFileDescriptors(processID: Int32) -> [proc_fdinfo]? {
        guard let first = fileDescriptors(processID: processID),
              let second = fileDescriptors(processID: processID),
              first.elementsEqual(second, by: {
                  $0.proc_fd == $1.proc_fd && $0.proc_fdtype == $1.proc_fdtype
              })
        else { return nil }
        return second
    }

    private func fileDescriptors(processID: Int32) -> [proc_fdinfo]? {
        let sizing = descriptorRead(processID, nil, 0)
        let required = sizing.byteCount
        guard sizing.errorCode == 0, required >= 0,
              Int(required) <= Self.maximumEnumerationBytes - Self.enumerationSlackBytes
        else { return nil }
        let requestedBytes = max(
            Int(required) + Self.enumerationSlackBytes,
            Self.enumerationSlackBytes
        )
        let capacity = (requestedBytes + MemoryLayout<proc_fdinfo>.size - 1)
            / MemoryLayout<proc_fdinfo>.size
        var values = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let actual = values.withUnsafeMutableBytes { buffer in
            descriptorRead(processID, buffer.baseAddress, Int32(buffer.count))
        }
        guard actual.errorCode == 0, actual.byteCount >= 0,
              Int(actual.byteCount) < values.count * MemoryLayout<proc_fdinfo>.size,
              Int(actual.byteCount).isMultiple(of: MemoryLayout<proc_fdinfo>.size)
        else { return nil }
        return Array(values.prefix(Int(actual.byteCount) / MemoryLayout<proc_fdinfo>.size))
            .sorted { lhs, rhs in
                if lhs.proc_fd == rhs.proc_fd { return lhs.proc_fdtype < rhs.proc_fdtype }
                return lhs.proc_fd < rhs.proc_fd
            }
    }

    private func isExactListener(
        processID: Int32,
        descriptor: Int32,
        endpoint: Phase2LoopbackEndpoint
    ) -> Bool {
        var value = socket_fdinfo()
        let expected = Int32(MemoryLayout<socket_fdinfo>.size)
        let actual = proc_pidfdinfo(
            processID,
            descriptor,
            PROC_PIDFDSOCKETINFO,
            &value,
            expected
        )
        guard actual == expected,
              value.psi.soi_kind == SOCKINFO_TCP,
              value.psi.soi_type == SOCK_STREAM,
              value.psi.soi_protocol == IPPROTO_TCP,
              value.psi.soi_family == endpointAddressFamily(endpoint.host),
              value.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN,
              UInt16(bigEndian: UInt16(truncatingIfNeeded:
                value.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
              )) == endpoint.port
        else { return false }

        let localAddress = value.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr
        switch endpoint.host {
        case .ipv4:
            var loopback = in_addr()
            guard inet_pton(AF_INET, "127.0.0.1", &loopback) == 1 else { return false }
            return localAddress.ina_46.i46a_addr4.s_addr == loopback.s_addr
        case .ipv6:
            var loopback = in6_addr()
            guard inet_pton(AF_INET6, "::1", &loopback) == 1 else { return false }
            var candidate = localAddress.ina_6
            return withUnsafeBytes(of: &candidate) { candidateBytes in
                withUnsafeBytes(of: &loopback) { loopbackBytes in
                    candidateBytes.elementsEqual(loopbackBytes)
                }
            }
        }
    }

    private static func isExpectedLoopback(
        _ address: String,
        host: Phase2LoopbackEndpoint.Host
    ) -> Bool {
        switch host {
        case .ipv4: address == "127.0.0.1"
        case .ipv6: address == "::1"
        }
    }

    private func endpointAddressFamily(_ host: Phase2LoopbackEndpoint.Host) -> Int32 {
        switch host {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }
}
