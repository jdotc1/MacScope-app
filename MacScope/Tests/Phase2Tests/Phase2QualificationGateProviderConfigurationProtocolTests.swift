import Foundation
import XCTest
@testable import MacScope

final class Phase2QualificationGateProviderConfigurationProtocolTests: XCTestCase {
    // CoreTests also compiles the worker's JSON schema. These fixtures cross the
    // app decoder boundary, so they must use the app module's nominal value type.
    private typealias JSON = MacScopeAnalysisCore.Phase2ProductionJSONValue
    private typealias Decoder = Phase2ProviderConfigurationProtocolDecoder

    func testReadOnlyRequestVocabularyAndOmittedParameters() throws {
        let list = try Phase2StrictJSONParser().parse(Phase2ProviderConfigurationRequest.listLoaded.encoded(callID: 0))
        XCTAssertEqual(list.objectValue?.keys.sorted(), ["callId", "endpoint", "type"])
        for ignore in [false, true] {
            let value = try Phase2StrictJSONParser().parse(Phase2ProviderConfigurationRequest.basePrediction(
                instanceReference: "opaque", ignoreServerSession: ignore).encoded(callID: 3))
            let parameter = value.objectValue?["parameter"]?.objectValue
            XCTAssertEqual(parameter?["ignoreServerSessionConfig"], ignore ? .bool(true) : nil)
            XCTAssertEqual(value.objectValue?["endpoint"], .string("getBasePredictionConfig"))
        }
        XCTAssertThrowsError(try Phase2ProviderConfigurationRequest.listLoaded.encoded(callID: 7))
        XCTAssertThrowsError(try Phase2ProviderConfigurationRequest.modelInfo(instanceReference: "").encoded(callID: 1))
    }

    func testAuthenticationUsesEphemeralGuestShapeAndStrictSuccess() throws {
        let data = try Phase2ProviderConfigurationRequest.authentication(
            guestNonce: Data(repeating: 1, count: 18), passkeyNonce: Data(repeating: 2, count: 18))
        let object = try XCTUnwrap(Phase2StrictJSONParser().parse(data).objectValue)
        XCTAssertEqual(object["authVersion"], .integer(1))
        XCTAssertTrue(object["clientIdentifier"]?.stringValue?.hasPrefix("guest:") == true)
        XCTAssertThrowsError(try Phase2ProviderConfigurationRequest.authentication(guestNonce: Data(), passkeyNonce: Data()))
        for response in [#"{"success":false,"error":"private"}"#, #"{"success":true,"extra":1}"#, #"{"success":1}"#] {
            var decoder = Decoder()
            XCTAssertThrowsError(try decoder.authentication(Data(response.utf8)))
            XCTAssertThrowsError(try decoder.authentication(Data(#"{"success":true}"#.utf8)))
        }
    }

    func testStrictEnvelopeRejectsDuplicateKeysAndUnexpectedIDs() throws {
        let responses = [
            #"{"type":"rpcResult","callId":0,"callId":0,"result":[]}"#,
            #"{"type":"rpcResult","callId":true,"result":[]}"#,
            #"{"type":"rpcResult","callId":0.0,"result":[]}"#,
            #"{"type":"rpcResult","callId":1,"result":[]}"#,
            #"{"type":"rpcResult","callId":0,"result":[],"extra":0}"#,
            #"{"type":"rpcResult","callId":0,"result":[]} trailing"#,
        ]
        for response in responses {
            var decoder = try ready()
            XCTAssertThrowsError(try decoder.reply(Data(response.utf8), to: .listLoaded, callID: 0))
            XCTAssertThrowsError(try decoder.reply(envelope(.array([])), to: .listLoaded, callID: 0))
        }
    }

    func testReplyIDsAndReplayAreClosed() throws {
        var decoder = try ready()
        for id in 0...6 { _ = try decoder.reply(envelope(.array([]), id: id), to: .listLoaded, callID: id) }
        XCTAssertThrowsError(try decoder.reply(envelope(.array([]), id: 7), to: .listLoaded, callID: 7))
        decoder = try ready()
        _ = try decoder.reply(envelope(.array([])), to: .listLoaded, callID: 0)
        XCTAssertThrowsError(try decoder.reply(envelope(.array([])), to: .listLoaded, callID: 0))
    }

    func testModelProjectionRetainsOnlySourceDeclaredTemporalExclusions() throws {
        var before = model()
        var after = before
        after["lastUsedTime"] = .number("2.5")
        after["ttlMs"] = .number("1000")
        let first = try decodeModel(before)
        let second = try decodeModel(after)
        XCTAssertEqual(first.immutableFields, second.immutableFields)
        XCTAssertNotEqual(first.temporalFields, second.temporalFields)
        after["path"] = .string("other")
        XCTAssertNotEqual(first.immutableFields, try decodeModel(after).immutableFields)
        before["unknownIdentity"] = .string("changed")
        XCTAssertThrowsError(try decodeModel(before))
        before = model(); before.removeValue(forKey: "deviceIdentifier")
        XCTAssertThrowsError(try decodeModel(before))
        before = model(); before["instanceReference"] = .string("other")
        XCTAssertThrowsError(try decodeModel(before))
    }

    func testRawLoadPreservesAcceleratedValuesWithoutFreezingDiscoveryCPUSettings() throws {
        var fields = load()
        fields["llm.load.llama.acceleration.offloadRatio"] = .number("1")
        fields["llm.load.llama.cpuThreadPoolSize"] = .integer(12)
        var decoder = try ready()
        guard case .configuration(let result) = try decoder.reply(envelope(kv(fields)),
            to: .loadConfiguration(instanceReference: "opaque"), callID: 0) else { return XCTFail() }
        XCTAssertEqual(result.fields, fields)
        fields["llm.load.contextLength"] = .bool(true)
        decoder = try ready()
        XCTAssertThrowsError(try decoder.reply(envelope(kv(fields)), to: .loadConfiguration(instanceReference: "opaque"), callID: 0))
    }

    func testKVRejectsDuplicateUnknownAndMissingFields() throws {
        let known = load()
        var duplicate = try XCTUnwrap(kv(known).objectValue?["fields"]?.arrayValue)
        duplicate.append(duplicate[0])
        var unknown = known; unknown["llm.load.unreviewed"] = .integer(1)
        var missing = known; missing.removeValue(forKey: "llm.load.contextLength")
        for result in [JSON.object(["fields": .array(duplicate)]), kv(unknown), kv(missing)] {
            var decoder = try ready()
            XCTAssertThrowsError(try decoder.reply(envelope(result), to: .loadConfiguration(instanceReference: "opaque"), callID: 0))
        }
    }

    func testBaseConfigRetainsExplicitThinkingAndExactTemplateShape() throws {
        var decoder = try ready()
        guard case .configuration(let result) = try decoder.reply(envelope(kv(base())),
            to: .basePrediction(instanceReference: "opaque", ignoreServerSession: false), callID: 0) else { return XCTFail() }
        XCTAssertEqual(result.fields["llm.prediction.reasoning.enableThinking"], .bool(false))
        for bad in [JSON.null, .string("false"), .integer(0)] {
            var fields = base(); fields["llm.prediction.reasoning.enableThinking"] = bad
            decoder = try ready()
            XCTAssertThrowsError(try decoder.reply(envelope(kv(fields)), to: .basePrediction(instanceReference: "opaque", ignoreServerSession: true), callID: 0))
        }
    }

    func testTemplateBoundAndRemoteFailureAreTerminal() throws {
        var fields = base()
        fields["llm.prediction.promptTemplate"] = .object([
            "type": .string("jinja"), "jinjaPromptTemplate": .object(["template": .string(String(repeating: "x", count: 65_537))]),
            "stopStrings": .array([]),
        ])
        var decoder = try ready()
        XCTAssertThrowsError(try decoder.reply(envelope(kv(fields)), to: .basePrediction(instanceReference: "opaque", ignoreServerSession: false), callID: 0))
        decoder = try ready()
        XCTAssertThrowsError(try decoder.reply(Data(#"{"type":"rpcError","callId":0,"error":{"message":"not logged"}}"#.utf8), to: .listLoaded, callID: 0)) { error in
            XCTAssertEqual(error as? Phase2ProviderConfigurationProtocolError, .remoteFailure)
        }
        XCTAssertThrowsError(try decoder.reply(envelope(.array([])), to: .listLoaded, callID: 0)) { error in
            XCTAssertEqual(error as? Phase2ProviderConfigurationProtocolError, .terminal)
        }
    }

    private func ready() throws -> Decoder {
        var decoder = Decoder(); try decoder.authentication(Data(#"{"success":true}"#.utf8)); return decoder
    }
    private func envelope(_ result: JSON, id: Int = 0) -> Data {
        JSON.object(["type": .string("rpcResult"), "callId": .integer(id), "result": result]).canonicalJSONBytes()
    }
    private func kv(_ fields: [String: JSON]) -> JSON {
        .object(["fields": .array(fields.keys.sorted().map { .object(["key": .string($0), "value": fields[$0]!]) })])
    }
    private func decodeModel(_ fields: [String: JSON]) throws -> Phase2ProviderConfigurationModelInfo {
        var decoder = try ready()
        guard case .model(let model) = try decoder.reply(envelope(.object(fields)), to: .modelInfo(instanceReference: "opaque"), callID: 0) else {
            throw Phase2ProviderConfigurationProtocolError.schema
        }
        return model
    }
    private func model() -> [String: JSON] {
        var fields: [String: JSON] = [:]
        for key in ["modelKey", "format", "displayName", "publisher", "path", "indexedModelIdentifier", "identifier"] { fields[key] = .string("synthetic") }
        for key in ["sizeBytes", "maxContextLength", "contextLength"] { fields[key] = .integer(32_768) }
        fields["instanceReference"] = .string("opaque"); fields["type"] = .string("llm")
        fields["deviceIdentifier"] = .null; fields["ttlMs"] = .null; fields["lastUsedTime"] = .number("1.5")
        fields["vision"] = .bool(false); fields["trainedForToolUse"] = .bool(true)
        return fields
    }
    private func load() -> [String: JSON] {
        ["llm.load.contextLength": .integer(32_768), "llm.load.numParallelSessions": .integer(1),
         "llm.load.llama.acceleration.offloadRatio": .number("0"), "llm.load.llama.autoFit": .bool(false),
         "llm.load.llama.cpuThreadPoolSize": .integer(7), "llm.load.llama.tryDirectIO": .bool(false), "llm.load.mlx.autoFit": .bool(false)]
    }
    private func base() -> [String: JSON] {
        ["llm.prediction.llama.cpuThreads": .integer(7), "llm.prediction.reasoning.enableThinking": .bool(false),
         "llm.prediction.temperature": .integer(0), "llm.prediction.repeatPenalty": .object(["checked": .bool(true), "value": .number("1.15")]),
         "llm.prediction.topPSampling": .object(["checked": .bool(false), "value": .number("0.95")]),
         "llm.prediction.promptTemplate": .object(["type": .string("jinja"), "jinjaPromptTemplate": .object(["template": .string("synthetic")]), "stopStrings": .array([])])]
    }
}
