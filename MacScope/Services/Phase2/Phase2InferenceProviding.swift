import Foundation

/// Provider-neutral transient inference mechanics. The awaited sink is the backpressure boundary.
protocol Phase2InferenceProviding: Sendable {
    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws

    func cancel(requestID: UUID) async
}

/// Ephemeral proof that inference is bound to one configured, live AI-worker connection.
/// The process identifier is used only for launch-local measurement-scope attestation and must
/// never be persisted in a qualification report.
struct Phase2InferenceWorkerProcessReceipt: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidProcessIdentifier
        case invalidConfigurationGeneration
        case invalidManifestDigest
    }

    let processIdentifier: Int32
    let providerGeneration: UInt64
    let connectionIdentity: UUID
    let profileID: UUID
    let configurationGeneration: UInt64
    let protocolManifestDigest: String

    init(
        processIdentifier: Int32,
        providerGeneration: UInt64,
        connectionIdentity: UUID,
        profileID: UUID,
        configurationGeneration: UInt64,
        protocolManifestDigest: String
    ) throws {
        guard processIdentifier > 1 else { throw ValidationError.invalidProcessIdentifier }
        guard configurationGeneration > 0 else {
            throw ValidationError.invalidConfigurationGeneration
        }
        guard phase2IsSHA256Hex(protocolManifestDigest) else {
            throw ValidationError.invalidManifestDigest
        }
        self.processIdentifier = processIdentifier
        self.providerGeneration = providerGeneration
        self.connectionIdentity = connectionIdentity
        self.profileID = profileID
        self.configurationGeneration = configurationGeneration
        self.protocolManifestDigest = protocolManifestDigest
    }
}

/// Qualification-only evidence for the concrete TCP connection used by one provider request.
/// The signed AI worker derives this tuple from `URLSessionTaskMetrics`; callers cannot provide
/// or persist it. Gate-G4 accepts it only while the worker keeps that exact connection alive.
struct Phase2InferenceProviderConnectionReceipt: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidAddress
        case invalidPort
    }

    let localAddress: String
    let localPort: UInt16
    let remoteAddress: String
    let remotePort: UInt16

    init(
        localAddress: String,
        localPort: Int,
        remoteAddress: String,
        remotePort: Int
    ) throws {
        guard Self.isLoopbackAddress(localAddress), Self.isLoopbackAddress(remoteAddress) else {
            throw ValidationError.invalidAddress
        }
        guard (1...Int(UInt16.max)).contains(localPort),
              (1...Int(UInt16.max)).contains(remotePort)
        else { throw ValidationError.invalidPort }
        self.localAddress = localAddress
        self.localPort = UInt16(localPort)
        self.remoteAddress = remoteAddress
        self.remotePort = UInt16(remotePort)
    }

    private static func isLoopbackAddress(_ value: String) -> Bool {
        value == "127.0.0.1" || value == "::1"
    }
}

/// Request-qualified proof that the signed worker crossed the provider HTTP dispatch boundary.
/// It is emitted only after validated response headers arrive and before streamed body semantics;
/// callers cannot substitute task creation or app-to-XPC acceptance for provider contact.
struct Phase2InferenceDispatchReceipt: Hashable, Sendable {
    enum Boundary: String, Hashable, Sendable {
        case httpResponseHeaders = "http-response-headers"
    }

    let requestID: UUID
    let boundary: Boundary

    init(requestID: UUID, boundary: Boundary = .httpResponseHeaders) {
        self.requestID = requestID
        self.boundary = boundary
    }
}

/// Exact qualification requires this stronger provider capability for controlled cancellation.
/// Ordinary inference continues to use `Phase2InferenceProviding`; there is no compatibility
/// fallback when the production Gate asks for an after-dispatch cancellation boundary.
protocol Phase2InferenceDispatchReceiptProviding: Phase2InferenceProviding {
    func run(
        request: Phase2InferenceRequest,
        onDispatched: @escaping @Sendable (Phase2InferenceDispatchReceipt) -> Void,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws
}

/// Capability required by exact qualification. Ordinary inference providers need not implement
/// it; qualification fails closed when the concrete provider cannot prepare and revalidate the
/// process that owns its active worker connection.
protocol Phase2InferenceWorkerProcessReceiptProviding: Phase2InferenceProviding {
    typealias ProviderConnectionValidator = @MainActor @Sendable (
        Phase2InferenceProviderConnectionReceipt
    ) -> Bool

    func prepareWorkerProcessReceipt() async throws -> Phase2InferenceWorkerProcessReceipt
    func bindProviderConnectionValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping ProviderConnectionValidator
    ) async -> Bool
    func bindProviderDispatchValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping @MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool
    ) async -> Bool
    func acceptedProviderConnectionReceipt(
        requestID: UUID,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool
    func revalidateWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool
}
