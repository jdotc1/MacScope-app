import Foundation

/// App boundary only. Native admission, deadlines and exclusive reaping remain worker-owned.
/// No production adapter is supplied until the owned-child channel is qualified.
protocol PatternInterpretationTransport: AnyObject, Sendable {
    var patternAvailable: Bool { get }
    func sendPatternInterpretation(requestID: UUID, payload: Data) async throws -> Data
    func cancelPatternInterpretation(requestID: UUID)
}

final class UnavailablePatternInterpretationTransport: PatternInterpretationTransport {
    var patternAvailable: Bool { false }
    func sendPatternInterpretation(requestID: UUID, payload: Data) async throws -> Data {
        throw PatternInterpretationError.nativeUnavailable
    }
    func cancelPatternInterpretation(requestID: UUID) {}
}

@MainActor
protocol PatternAppTransport: AnyObject {
    var available: Bool { get }
    func send(requestID: UUID, payload: Data) async throws -> Data
    func cancel(requestID: UUID)
}

@MainActor
final class UnavailablePatternAppTransport: PatternAppTransport {
    var available: Bool { false }
    func send(requestID: UUID, payload: Data) async throws -> Data {
        throw PatternInterpretationError.nativeUnavailable
    }
    func cancel(requestID: UUID) {}
}

/// Captures one immutable channel, never a fresh connection during cancellation.
/// An injected channel must retain its worker lease after waiter cancellation; this facade
/// never constructs OwnedChildController or interprets a transport error as child exit.
@MainActor
final class PatternAppChannelTransport: PatternAppTransport {
    private let channel: any PatternInterpretationTransport
    init(channel: any PatternInterpretationTransport) { self.channel = channel }
    var available: Bool { channel.patternAvailable }
    func send(requestID: UUID, payload: Data) async throws -> Data {
        guard available else { throw PatternInterpretationError.nativeUnavailable }
        guard payload.count <= 2_097_152 else { throw PatternInterpretationError.invalidRequest }
        let reply = try await channel.sendPatternInterpretation(requestID: requestID, payload: payload)
        guard reply.count <= 4_194_304 else { throw PatternInterpretationError.malformedReply }
        return reply
    }
    func cancel(requestID: UUID) { channel.cancelPatternInterpretation(requestID: requestID) }
}
