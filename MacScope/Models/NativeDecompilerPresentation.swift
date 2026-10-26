import Combine
import Foundation

/// Immutable authority coordinate for one transient native-decompiler publication.
///
/// The wire result binds the artifact/function/request fields. The app additionally binds the
/// owning binary and analysis fingerprint so a valid reply from a superseded analysis cannot be
/// displayed in a replacement window or reanalysis generation.
struct NativeDecompilerPresentationCoordinate: Equatable, Sendable {
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID
    let artifactUUID: UUID
    let imageID: String
    let functionID: String
    let requestSHA256: String
    let analysisInputFingerprintSHA256: String
    /// Transient record of request-local context the request omitted; never persisted.
    var contextOmissions: NativeDecompilerContextOmissionManifest = .empty

    /// The same function and inputs requested under another digest (the document-only retry).
    func withRequestSHA256(_ requestSHA256: String) -> Self {
        Self(imageSlot: imageSlot, ownerBinaryID: ownerBinaryID, artifactUUID: artifactUUID, imageID: imageID,
             functionID: functionID, requestSHA256: requestSHA256,
             analysisInputFingerprintSHA256: analysisInputFingerprintSHA256, contextOmissions: contextOmissions)
    }
}

/// Identity of a ready publication, including its window-session generation. A cached reply can
/// have the same request ID and bytes as an earlier publication; it is still a different action owner.
struct NativeDecompilerPresentationPublicationIdentity: Equatable, Sendable {
    let ownerToken: UUID
    let generation: UInt64
    let coordinate: NativeDecompilerPresentationCoordinate
    let requestID: UUID
}

enum NativeDecompilerPresentationTerminalReason: Equatable, Sendable {
    /// `detail` is the provider's bounded single-line failure detail (for example
    /// `native-provider-output-budget-exceeded`), when the reply carried one.
    case provider(NativeDecompilerWireFailureCode, detail: String? = nil)
    case client(NativeDecompilerXPCClientFailure)
    case invalidReply
    case transportFailure
    case projection(NativeDecompilerSnapshotProjectionError)
    case runtimeValidation(NativeDecompilerRuntimeValidationError)
    case runtime(NativeDecompilerProcessRuntimeError)

    var isUnavailable: Bool {
        switch self {
        case .provider(.unavailable, _), .client(.connectionUnavailable), .projection,
             .runtimeValidation(.runtimeAuthorityMismatch), .runtime(.runtimeAuthorityUnavailable),
             .runtime(.shutDown):
            true
        case .provider, .client, .invalidReply, .transportFailure, .runtimeValidation, .runtime:
            false
        }
    }
}

extension NativeDecompilerPresentationTerminalReason {
    /// Short machine-readable cause for reports: the provider's detail when
    /// present, otherwise the failure class.
    var diagnosticCode: String {
        switch self {
        case let .provider(code, detail): detail ?? "provider-\(code.rawValue)"
        case let .client(failure): "client-\(failure.rawValue)"
        case .invalidReply: "invalid-reply"
        case .transportFailure: "transport-failure"
        case let .projection(error): "projection-\(error)"
        case let .runtimeValidation(error): "runtime-validation-\(error)"
        case let .runtime(error): "runtime-\(error)"
        }
    }
}

enum NativeDecompilerPresentationState: Equatable, Sendable {
    case idle
    case analyzing(NativeDecompilerPresentationCoordinate)
    case ready(
        coordinate: NativeDecompilerPresentationCoordinate,
        success: NativeDecompilerWireSuccess
    )
    case unavailable(
        coordinate: NativeDecompilerPresentationCoordinate?,
        reason: NativeDecompilerPresentationTerminalReason
    )
    case failed(
        coordinate: NativeDecompilerPresentationCoordinate,
        reason: NativeDecompilerPresentationTerminalReason
    )
}

/// Window-owned, nonpersisted publication model for validated native-decompiler results.
///
/// Only the runtime session that installed the current owner/generation binding may change the
/// model. The full validated wire success is retained for presentation and future bounded read
/// tools; no native or third-party object crosses this boundary.
@MainActor
final class NativeDecompilerPresentationModel: ObservableObject {
    private struct Binding: Equatable {
        let ownerToken: UUID
        let generation: UInt64
        let coordinate: NativeDecompilerPresentationCoordinate
    }

    @Published private(set) var state: NativeDecompilerPresentationState = .idle
    private var activeOwnerToken: UUID?
    private var latestGeneration: UInt64 = 0
    private var binding: Binding?

    var readyPublicationIdentity: NativeDecompilerPresentationPublicationIdentity? {
        guard let activeOwnerToken,
              case let .ready(coordinate, success) = state else { return nil }
        return NativeDecompilerPresentationPublicationIdentity(
            ownerToken: activeOwnerToken,
            generation: latestGeneration,
            coordinate: coordinate,
            requestID: success.result.requestID
        )
    }

    /// Installs the only session permitted to publish into this window model. Replacement is
    /// synchronous on the main actor, so a displaced session cannot reclaim the model even if an
    /// older actor message reaches the runtime after replacement.
    func activate(ownerToken: UUID) {
        guard activeOwnerToken != ownerToken else { return }
        activeOwnerToken = ownerToken
        latestGeneration = 0
        binding = nil
        state = .idle
    }

    @discardableResult
    func begin(
        ownerToken: UUID,
        generation: UInt64,
        coordinate: NativeDecompilerPresentationCoordinate
    ) -> Bool {
        guard activeOwnerToken == ownerToken, generation > latestGeneration else { return false }
        latestGeneration = generation
        binding = Binding(
            ownerToken: ownerToken,
            generation: generation,
            coordinate: coordinate
        )
        state = .analyzing(coordinate)
        return true
    }

    /// Moves the in-flight binding of one generation from `old` to `new` (same function, another
    /// request digest) for the document-only retry. Admitted only from the exact current binding.
    @discardableResult
    func rebindAnalyzing(
        ownerToken: UUID,
        generation: UInt64,
        from old: NativeDecompilerPresentationCoordinate,
        to new: NativeDecompilerPresentationCoordinate
    ) -> Bool {
        guard admits(ownerToken: ownerToken, generation: generation, coordinate: old),
              old.withRequestSHA256(new.requestSHA256) == new else { return false }
        binding = Binding(ownerToken: ownerToken, generation: generation, coordinate: new)
        state = .analyzing(new)
        return true
    }

    @discardableResult
    func publishReady(
        ownerToken: UUID,
        generation: UInt64,
        coordinate: NativeDecompilerPresentationCoordinate,
        success: NativeDecompilerWireSuccess
    ) -> Bool {
        guard admits(ownerToken: ownerToken, generation: generation, coordinate: coordinate),
              success.availability.available,
              success.result.requestSHA256 == coordinate.requestSHA256,
              success.result.image.imageID == coordinate.imageID,
              success.result.image.uuid == coordinate.artifactUUID,
              success.result.function.functionID == coordinate.functionID
        else {
            return false
        }
        state = .ready(coordinate: coordinate, success: success)
        binding = nil
        return true
    }

    @discardableResult
    func publishTerminal(
        ownerToken: UUID,
        generation: UInt64,
        coordinate: NativeDecompilerPresentationCoordinate,
        reason: NativeDecompilerPresentationTerminalReason
    ) -> Bool {
        guard admits(ownerToken: ownerToken, generation: generation, coordinate: coordinate) else {
            return false
        }
        state = reason.isUnavailable
            ? .unavailable(coordinate: coordinate, reason: reason)
            : .failed(coordinate: coordinate, reason: reason)
        binding = nil
        return true
    }

    /// Publishes a typed local projection failure before a request coordinate can be formed. The
    /// owner/generation fence is identical to `begin`, so a displaced or superseded session cannot
    /// replace the current window state with an unbound failure.
    @discardableResult
    func publishProjectionFailure(
        ownerToken: UUID,
        generation: UInt64,
        error: NativeDecompilerSnapshotProjectionError
    ) -> Bool {
        guard activeOwnerToken == ownerToken, generation > latestGeneration else { return false }
        latestGeneration = generation
        binding = nil
        state = .unavailable(coordinate: nil, reason: .projection(error))
        return true
    }

    /// Clears only a current owner's advancing generation. A displaced session's late teardown is
    /// inert even when it was created for the same window ID.
    @discardableResult
    func clear(ownerToken: UUID, generation: UInt64) -> Bool {
        guard activeOwnerToken == ownerToken,
              generation > latestGeneration
        else {
            return false
        }
        latestGeneration = generation
        self.binding = nil
        state = .idle
        return true
    }

    @discardableResult
    func discard(ownerToken: UUID, generation: UInt64) -> Bool {
        guard let binding,
              activeOwnerToken == ownerToken,
              binding.ownerToken == ownerToken,
              binding.generation == generation
        else {
            return false
        }
        self.binding = nil
        state = .idle
        return true
    }

    private func admits(
        ownerToken: UUID,
        generation: UInt64,
        coordinate: NativeDecompilerPresentationCoordinate
    ) -> Bool {
        activeOwnerToken == ownerToken && binding == Binding(
            ownerToken: ownerToken,
            generation: generation,
            coordinate: coordinate
        )
    }
}
