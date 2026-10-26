import Foundation

/// Translates between the host's rich Swift automation envelope
/// (`PluginAutomationInvocationEnvelope`) and the primitive shapes that cross
/// the XPC boundary (`commandIdentifier: String`, `requestData: Data`).
///
/// Keeping this separate from `PluginXPCHostConnection` means the wire encoding
/// is unit-testable without any connection at all, and the connection state
/// machine is testable without caring about JSON.
struct PluginXPCMessageTranslator {
    /// The JSON request body sent to the service for one command invocation.
    /// Deliberately a flat, Codable struct of primitives so it round-trips
    /// cleanly across the XPC boundary and is easy to validate on the far side.
    struct RequestBody: Codable, Equatable {
        var requestID: String
        var pluginIdentifier: String
        var commandIdentifier: String
        var surface: String
        var serviceMode: String
        var manifestHash: String?
        var arguments: [String: String]
    }

    /// The JSON response body returned by the service.
    struct ResponseBody: Codable, Equatable {
        var requestID: String
        var commandIdentifier: String
        var payload: [String: String]
    }

    var encoder: JSONEncoder
    var decoder: JSONDecoder

    init(
        encoder: JSONEncoder = PluginXPCMessageTranslator.makeEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.encoder = encoder
        self.decoder = decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Encode an automation envelope into the (commandIdentifier, requestData)
    /// pair the XPC interface expects.
    func encodeRequest(
        from envelope: PluginAutomationInvocationEnvelope
    ) throws -> (commandIdentifier: String, requestData: Data) {
        let body = RequestBody(
            requestID: envelope.requestID.uuidString,
            pluginIdentifier: envelope.plan.pluginIdentifier,
            commandIdentifier: envelope.plan.commandIdentifier,
            surface: envelope.plan.surface.rawValue,
            serviceMode: envelope.plan.serviceMode.rawValue,
            manifestHash: envelope.plan.manifestHash,
            arguments: envelope.arguments.values
        )
        let data = try encoder.encode(body)
        return (envelope.plan.commandIdentifier, data)
    }

    /// Decode a service's raw response data into a typed `ResponseBody`.
    /// Hardened: rejects oversized payloads before attempting JSON decoding so a
    /// hostile service cannot force unbounded work.
    func decodeResponse(
        from data: Data,
        maximumBytes: Int = 1_048_576
    ) throws -> ResponseBody {
        guard !data.isEmpty else {
            throw PluginXPCTranslationError.emptyResponse
        }
        guard data.count <= maximumBytes else {
            throw PluginXPCTranslationError.responseTooLarge(
                byteCount: data.count,
                limit: maximumBytes
            )
        }
        do {
            return try decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw PluginXPCTranslationError.malformedResponse(String(describing: error))
        }
    }

    /// Decode the raw request data on the *service* side (symmetric helper, used
    /// by the eventual bundled service and by tests to assert round-tripping).
    func decodeRequest(
        from data: Data,
        maximumBytes: Int = 1_048_576
    ) throws -> RequestBody {
        guard !data.isEmpty else {
            throw PluginXPCTranslationError.emptyResponse
        }
        guard data.count <= maximumBytes else {
            throw PluginXPCTranslationError.responseTooLarge(
                byteCount: data.count,
                limit: maximumBytes
            )
        }
        do {
            return try decoder.decode(RequestBody.self, from: data)
        } catch {
            throw PluginXPCTranslationError.malformedResponse(String(describing: error))
        }
    }

    func encodeResponse(_ body: ResponseBody) throws -> Data {
        try encoder.encode(body)
    }
}

enum PluginXPCTranslationError: Error, Equatable, LocalizedError {
    case emptyResponse
    case responseTooLarge(byteCount: Int, limit: Int)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "Plugin XPC payload was empty."
        case .responseTooLarge(let byteCount, let limit):
            "Plugin XPC payload of \(byteCount) bytes exceeds the \(limit)-byte limit."
        case .malformedResponse(let message):
            "Plugin XPC payload was malformed: \(message)"
        }
    }
}
