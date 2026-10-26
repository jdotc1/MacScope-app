import Foundation

enum NativeDecompilerServiceFailure: String, Error, Equatable, Sendable {
    case malformedRequest = "malformed-request"
    case malformedReply = "malformed-reply"
    case invalidRequest = "invalid-request"
    case nativeFailure = "native-failure"
    case packageVerificationFailed = "package-verification-failed"
    case busy
    case cancelled
    case timedOut = "timed-out"
    case unavailable
    case unsupportedSchemaVersion = "unsupported-schema-version"
    case requestIDMismatch = "request-id-mismatch"
    case unsupportedCompiler = "unsupported-compiler"
    case requestTooLarge = "request-too-large"
    case responseTooLarge = "response-too-large"
}

enum NativeDecompilerServiceSubmissionDisposition: Equatable, Sendable {
    case started
    case queued
    case rejected(NativeDecompilerServiceFailure)
}

/// Injectable, schema-independent dependencies for the exported service host.
///
/// The production composition adapts the bounded scheduler and Objective-C++ bridge to these
/// closures. Tests can exercise the XPC-facing safety properties without linking the native
/// provider. A rejected submission must not start native work; the host produces its reply.
struct NativeDecompilerServiceDependencies: Sendable {
    typealias Completion = @Sendable (Data) -> Void
    typealias Submit = @Sendable (
        _ requestID: UUID,
        _ payload: Data,
        _ completion: @escaping Completion
    ) -> NativeDecompilerServiceSubmissionDisposition
    typealias Cancel = @Sendable (_ requestID: UUID) -> Void
    typealias ValidateReply = @Sendable (
        _ requestID: UUID,
        _ requestPayload: Data,
        _ reply: Data
    ) -> Bool
    typealias EncodeFailure = @Sendable (
        _ requestID: UUID,
        _ failure: NativeDecompilerServiceFailure
    ) -> Data

    let submit: Submit
    let cancel: Cancel
    let validateReply: ValidateReply
    let encodeFailure: EncodeFailure

    init(
        submit: @escaping Submit,
        cancel: @escaping Cancel,
        validateReply: @escaping ValidateReply,
        encodeFailure: @escaping EncodeFailure
    ) {
        self.submit = submit
        self.cancel = cancel
        self.validateReply = validateReply
        self.encodeFailure = encodeFailure
    }

    /// Safe composition used until verified package, bridge, and scheduler adapters are injected.
    static let unavailable = NativeDecompilerServiceDependencies(
        submit: { _, _, _ in .rejected(.unavailable) },
        cancel: { _ in },
        validateReply: { _, _, _ in false },
        encodeFailure: NativeDecompilerServiceFailureReplyEncoder.encode
    )
}

enum NativeDecompilerServiceFailureReplyEncoder {
    private struct Failure: Encodable {
        let code: String
        let detail: String? = nil
    }

    private struct Envelope: Encodable {
        // Keep this independent of the app module's result models: this host is compiled into
        // both NativeDecompilerXPCService and CoreTests. Cross-language wire tests require the
        // Swift result envelope and Objective-C++ codec to agree with this closed schema value.
        let schemaVersion: UInt32 = 3
        let requestID: UUID
        let outcome = "failure"
        let failure: Failure
    }

    /// Encodes the closed schema-v3 binary-property-list failure union.
    ///
    /// This encoder only contains fixed strings, one UUID, and the frozen schema version, so
    /// encoding cannot encounter an unsupported property-list value. A failure indicates a
    /// Foundation invariant violation and terminates the service rather than returning an
    /// uncorrelated empty payload.
    static func encode(requestID: UUID, failure: NativeDecompilerServiceFailure) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(
                Envelope(requestID: requestID, failure: Failure(code: failure.rawValue))
            )
        } catch {
            preconditionFailure("closed native-decompiler failure envelope could not encode")
        }
    }
}

/// Testable service-facing boundary around scheduling, response validation, and XPC completion.
final class NativeDecompilerServiceHost: @unchecked Sendable {
    static let maximumRequestBytes = 32 * 1_024 * 1_024
    static let maximumResponseBytes = 64 * 1_024 * 1_024

    private let dependencies: NativeDecompilerServiceDependencies

    init(dependencies: NativeDecompilerServiceDependencies) {
        self.dependencies = dependencies
    }

    func decompile(
        requestID: UUID,
        payload: Data,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        let terminal = NativeDecompilerServiceTerminalReply(reply)

        guard payload.count <= Self.maximumRequestBytes else {
            terminal.send(
                NativeDecompilerServiceFailureReplyEncoder.encode(
                    requestID: requestID,
                    failure: .requestTooLarge
                )
            )
            return
        }

        // Native execution may finish synchronously in tests or future adapters. Buffer that first
        // callback until the submit disposition is known so a rejected request can never publish a
        // success even if an adapter violates its rejection contract.
        let submission = NativeDecompilerServiceSubmissionReply { [self] candidate in
            guard candidate.count <= Self.maximumResponseBytes else {
                terminal.send(
                    failureReply(
                        requestID: requestID,
                        requestPayload: payload,
                        failure: .responseTooLarge
                    )
                )
                return
            }
            guard dependencies.validateReply(requestID, payload, candidate) else {
                terminal.send(
                    failureReply(
                        requestID: requestID,
                        requestPayload: payload,
                        failure: .malformedReply
                    )
                )
                return
            }
            terminal.send(candidate)
        }

        let disposition = dependencies.submit(requestID, payload, submission.receive)
        switch disposition {
        case .started, .queued:
            submission.accept()
        case let .rejected(failure):
            submission.reject()
            terminal.send(
                failureReply(requestID: requestID, requestPayload: payload, failure: failure)
            )
        }
    }

    func cancel(requestID: UUID) {
        dependencies.cancel(requestID)
    }

    private func failureReply(
        requestID: UUID,
        requestPayload: Data,
        failure: NativeDecompilerServiceFailure
    ) -> Data {
        let encoded = dependencies.encodeFailure(requestID, failure)
        guard encoded.count <= Self.maximumResponseBytes,
              dependencies.validateReply(requestID, requestPayload, encoded)
        else {
            return NativeDecompilerServiceFailureReplyEncoder.encode(
                requestID: requestID,
                failure: encoded.count > Self.maximumResponseBytes ? .responseTooLarge : failure
            )
        }
        return encoded
    }
}

/// Allows exactly one terminal Data value to reach the exported XPC reply block.
private final class NativeDecompilerServiceTerminalReply: @unchecked Sendable {
    private let lock = NSLock()
    private var didReply = false
    private let reply: @Sendable (Data) -> Void

    init(_ reply: @escaping @Sendable (Data) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data) {
        let shouldReply = lock.withLock {
            guard !didReply else { return false }
            didReply = true
            return true
        }
        if shouldReply {
            reply(data)
        }
    }
}

/// Serializes a possibly synchronous adapter callback with the submit disposition.
private final class NativeDecompilerServiceSubmissionReply: @unchecked Sendable {
    private enum State {
        case awaitingDisposition
        case accepted
        case rejected
        case delivered
    }

    private let lock = NSLock()
    private var state = State.awaitingDisposition
    private var pending: Data?
    private let deliver: @Sendable (Data) -> Void

    init(deliver: @escaping @Sendable (Data) -> Void) {
        self.deliver = deliver
    }

    func receive(_ data: Data) {
        let valueToDeliver: Data? = lock.withLock {
            switch state {
            case .awaitingDisposition:
                guard pending == nil else { return nil }
                pending = data
                return nil
            case .accepted:
                state = .delivered
                return data
            case .rejected, .delivered:
                return nil
            }
        }
        if let valueToDeliver {
            deliver(valueToDeliver)
        }
    }

    func accept() {
        let valueToDeliver: Data? = lock.withLock {
            guard state == .awaitingDisposition else { return nil }
            if let pending {
                self.pending = nil
                state = .delivered
                return pending
            }
            state = .accepted
            return nil
        }
        if let valueToDeliver {
            deliver(valueToDeliver)
        }
    }

    func reject() {
        lock.withLock {
            guard state == .awaitingDisposition else { return }
            pending = nil
            state = .rejected
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
