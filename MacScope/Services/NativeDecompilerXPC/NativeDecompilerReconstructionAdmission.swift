import Foundation

/// Immutable, presentation-free input accepted by every app-owned native-decompiler admission.
/// Reconstruction receives this capability only after a durable job identity has been validated.
struct NativeDecompilerProjectionRequest: Sendable {
    let workspace: WorkspaceSnapshot
    let imageSlot: ImageSlot
    let functionID: UUID
    let analysisInputFingerprintSHA256: String

    init(
        workspace: WorkspaceSnapshot,
        imageSlot: ImageSlot,
        functionID: UUID,
        analysisInputFingerprintSHA256: String
    ) throws {
        try ReconstructionValidation.requireSHA256(
            analysisInputFingerprintSHA256,
            field: "native decompiler projection fingerprint"
        )
        self.workspace = workspace
        self.imageSlot = imageSlot
        self.functionID = functionID
        self.analysisInputFingerprintSHA256 = analysisInputFingerprintSHA256
    }
}

struct NativeDecompilerValidatedExecution: Equatable, Sendable {
    let requestSHA256: String
    let analysisInputFingerprintSHA256: String
    let imageSlot: ImageSlot
    let functionID: UUID
    let success: NativeDecompilerWireSuccess
    let source: NativeDecompilerProcessRuntimeExecutionSource
    /// Transient record of request-local context the request omitted; never persisted.
    var contextOmissions: NativeDecompilerContextOmissionManifest = .empty
}

enum NativeDecompilerOwnerAdmissionError: Error, Equatable, Sendable {
    case ownerRetired
    /// The provider ended without a result; `reason` is a bounded single-line cause.
    case terminalProviderResult(reason: String)

    static func terminal(_ completion: NativeDecompilerCompletion) -> Self {
        guard case let .terminal(reason) = completion else { return .terminalProviderResult(reason: "unknown") }
        return .terminalProviderResult(reason: String(reason.diagnosticCode.prefix(160)))
    }
}

protocol NativeDecompilerOwnerAdmission: Sendable {
    func decompile(
        _ request: NativeDecompilerProjectionRequest,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
    ) async throws -> NativeDecompilerValidatedExecution

    func cancelOutstanding() async
    func retire() async
}

protocol ReconstructionNativeDecompilerDurableJobValidating: Sendable {
    func validateActiveDurableJobID(_ jobID: UUID) async throws
}

struct ReconstructionNativeDecompilerAdmissionFactory: Sendable {
    private let runtime: NativeDecompilerRuntimeRegistry
    private let durable: any ReconstructionNativeDecompilerDurableJobValidating

    init(
        runtime: NativeDecompilerRuntimeRegistry,
        durable: any ReconstructionNativeDecompilerDurableJobValidating
    ) {
        self.runtime = runtime
        self.durable = durable
    }

    func admission(
        forDurableJobID jobID: UUID
    ) async throws -> any NativeDecompilerOwnerAdmission {
        try await durable.validateActiveDurableJobID(jobID)
        return await runtime.makeReconstructionAdmission(jobID: jobID)
    }
}

private actor ReconstructionNativeDecompilerAdmission: NativeDecompilerOwnerAdmission {
    private let owner: UUID
    private let runtime: NativeDecompilerRuntimeRegistry
    private var activeTasks: [UUID: Task<NativeDecompilerValidatedExecution, Error>] = [:]
    private var isRetired = false

    init(
        jobID: UUID,
        runtime: NativeDecompilerRuntimeRegistry
    ) {
        owner = jobID
        self.runtime = runtime
    }

    func decompile(
        _ request: NativeDecompilerProjectionRequest,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
    ) async throws -> NativeDecompilerValidatedExecution {
        guard !isRetired else {
            throw NativeDecompilerOwnerAdmissionError.ownerRetired
        }
        let taskID = UUID()
        let task = Task {
            try await runtime.decompileForReconstruction(
                owner: owner,
                request: request,
                cacheLookupPolicy: cacheLookupPolicy
            )
        }
        activeTasks[taskID] = task
        defer { activeTasks[taskID] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelOutstanding() async {
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = await task.result
        }
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        await cancelOutstanding()
    }
}

extension NativeDecompilerRuntimeRegistry {
    fileprivate func makeReconstructionAdmission(
        jobID: UUID
    ) -> any NativeDecompilerOwnerAdmission {
        ReconstructionNativeDecompilerAdmission(jobID: jobID, runtime: self)
    }
}
