import Foundation
import XCTest

@testable import MacScope

final class Phase2AIWorkerModelLifecycleWireTests: XCTestCase {
    func testLoadAndUnloadRoundTripsPreserveExactClosedAuthorityAndUnionKeys() throws {
        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        let load = lifecycleRequest(operation: .load(modelKey: "publisher/model", contextLength: 4_096))
        let unload = lifecycleRequest(operation: .unload(instanceID: "runtime-instance"))

        for request in [load, unload] {
            let data = try codec.encodeRequest(request)
            XCTAssertEqual(try codec.decodeRequest(data), request)
            XCTAssertEqual(
                try lifecycleKeys(data),
                [
                    "effectID", "endpointOrigin", "generation", "operation", "profileID",
                    "requestTimeoutMilliseconds", "resourceTimeoutMilliseconds", "schemaVersion",
                ]
            )
        }

        XCTAssertEqual(
            try nestedKeys(codec.encodeRequest(load), at: "operation"),
            ["contextLength", "kind", "modelKey"]
        )
        XCTAssertEqual(
            try nestedKeys(codec.encodeRequest(unload), at: "operation"),
            ["instanceID", "kind"]
        )
    }

    func testSuccessfulLoadAndUnloadRepliesRoundTripWithExactReceiptKeys() throws {
        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        let load = lifecycleReply(
            operationKind: .load,
            receipt: .load(.init(
                instanceID: "runtime-instance",
                loadTimeSeconds: 1.25,
                configuration: lifecycleLoadConfiguration()
            ))
        )
        let unload = lifecycleReply(
            operationKind: .unload,
            receipt: .unload(.init(instanceID: "runtime-instance"))
        )

        for reply in [load, unload] {
            let data = try codec.encodeReply(reply)
            XCTAssertEqual(try codec.decodeReply(data), reply)
            XCTAssertEqual(
                try lifecycleKeys(data),
                [
                    "effectID", "generation", "operationKind", "profileID", "receipt",
                    "schemaVersion", "status",
                ]
            )
        }

        XCTAssertEqual(
            try nestedKeys(codec.encodeReply(load), at: "receipt"),
            ["configuration", "instanceID", "kind", "loadTimeSeconds"]
        )
        XCTAssertEqual(
            try nestedKeys(codec.encodeReply(load), at: "receipt", then: "configuration"),
            [
                "contextLength", "evaluationBatchSize", "expertCount", "flashAttention",
                "offloadsKVCacheToGPU",
            ]
        )
        XCTAssertEqual(
            try nestedKeys(codec.encodeReply(unload), at: "receipt"),
            ["instanceID", "kind"]
        )
    }

    func testRequestUnionRejectsCrossBranchAndUnknownAuthorityFields() throws {
        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        var loadObject = try lifecycleObject(codec.encodeRequest(lifecycleRequest()))
        loadObject["credential"] = "secret"
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: loadObject),
            decode: codec.decodeRequest
        )

        loadObject.removeValue(forKey: "credential")
        var loadOperation = try XCTUnwrap(loadObject["operation"] as? [String: Any])
        loadOperation["instanceID"] = "must-not-cross-union"
        loadObject["operation"] = loadOperation
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: loadObject),
            decode: codec.decodeRequest
        )

        var unloadObject = try lifecycleObject(codec.encodeRequest(
            lifecycleRequest(operation: .unload(instanceID: "runtime-instance"))
        ))
        var unloadOperation = try XCTUnwrap(unloadObject["operation"] as? [String: Any])
        unloadOperation["modelKey"] = "must-not-cross-union"
        unloadObject["operation"] = unloadOperation
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: unloadObject),
            decode: codec.decodeRequest
        )
    }

    func testReplyRejectsUnknownKeysAtTopReceiptAndLoadConfigurationDepths() throws {
        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        var object = try lifecycleObject(codec.encodeReply(lifecycleReply()))
        object["providerMessage"] = "private"
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: object),
            decode: codec.decodeReply
        )

        object.removeValue(forKey: "providerMessage")
        var receipt = try XCTUnwrap(object["receipt"] as? [String: Any])
        receipt["endpointOrigin"] = "http://127.0.0.1:1234"
        object["receipt"] = receipt
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: object),
            decode: codec.decodeReply
        )

        receipt.removeValue(forKey: "endpointOrigin")
        var configuration = try XCTUnwrap(receipt["configuration"] as? [String: Any])
        configuration["parallelPredictions"] = 4
        receipt["configuration"] = configuration
        object["receipt"] = receipt
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: object),
            decode: codec.decodeReply
        )
    }

    func testDecoderRejectsDuplicateKeysAtEveryLifecycleObjectDepth() throws {
        let request = lifecycleRequestJSON(
            operation: #"{"kind":"load","modelKey":"publisher/model","contextLength":4096}"#
        )
        let duplicateRequestCases = [
            request.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":1,"schemaVersion":1"#),
            request.replacingOccurrences(of: #""kind":"load""#, with: #""kind":"load","kind":"load""#),
        ]
        for text in duplicateRequestCases {
            assertLifecycleWireError(
                Data(text.utf8),
                decode: Phase2AIWorkerModelLifecycleWireCodec().decodeRequest
            )
        }

        let reply = lifecycleReplyJSON()
        let duplicateReplyCases = [
            reply.replacingOccurrences(of: #""status":"succeeded""#, with: #""status":"succeeded","status":"succeeded""#),
            reply.replacingOccurrences(of: #""kind":"load""#, with: #""kind":"load","kind":"load""#),
            reply.replacingOccurrences(of: #""contextLength":4096"#, with: #""contextLength":4096,"contextLength":4096"#),
        ]
        for text in duplicateReplyCases {
            assertLifecycleWireError(
                Data(text.utf8),
                decode: Phase2AIWorkerModelLifecycleWireCodec().decodeReply
            )
        }
    }

    func testRequestRejectsNoncanonicalIdentityEndpointGenerationAndTimeoutBounds() throws {
        assertLifecycleRequestInvalid(lifecycleRequest(generation: 0))
        assertLifecycleRequestInvalid(lifecycleRequest(endpointOrigin: "http://localhost:1234"))
        assertLifecycleRequestInvalid(lifecycleRequest(endpointOrigin: "http://127.0.0.1:1234/path"))
        assertLifecycleRequestInvalid(lifecycleRequest(requestTimeoutMilliseconds: 999))
        assertLifecycleRequestInvalid(lifecycleRequest(requestTimeoutMilliseconds: 30_001))
        assertLifecycleRequestInvalid(lifecycleRequest(resourceTimeoutMilliseconds: 999))
        assertLifecycleRequestInvalid(lifecycleRequest(resourceTimeoutMilliseconds: 120_001))
        assertLifecycleRequestInvalid(lifecycleRequest(
            requestTimeoutMilliseconds: 20_000,
            resourceTimeoutMilliseconds: 19_999
        ))

        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        var object = try lifecycleObject(codec.encodeRequest(lifecycleRequest()))
        object["effectID"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: object),
            decode: codec.decodeRequest
        )
        object["effectID"] = lifecycleID(1).uuidString
        object["profileID"] = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        assertLifecycleWireError(
            try JSONSerialization.data(withJSONObject: object),
            decode: codec.decodeRequest
        )
    }

    func testRequestRejectsFloatingAndExponentLexemesForEveryIntegerAuthorityField() throws {
        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        let text = try XCTUnwrap(String(data: codec.encodeRequest(lifecycleRequest()), encoding: .utf8))
        for field in [
            "schemaVersion", "generation", "requestTimeoutMilliseconds",
            "resourceTimeoutMilliseconds", "contextLength",
        ] {
            for suffix in [".0", "e0"] {
                assertLifecycleWireError(
                    Data(replacingInteger(field, in: text, suffix: suffix).utf8),
                    decode: codec.decodeRequest
                )
            }
        }
    }

    func testReplyRejectsFloatingAndExponentLexemesForIntegerConfigurationFields() throws {
        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        let text = try XCTUnwrap(String(data: codec.encodeReply(lifecycleReply()), encoding: .utf8))
        for field in ["schemaVersion", "generation", "contextLength", "evaluationBatchSize", "expertCount"] {
            for suffix in [".0", "e0"] {
                assertLifecycleWireError(
                    Data(replacingInteger(field, in: text, suffix: suffix).utf8),
                    decode: codec.decodeReply
                )
            }
        }
    }

    func testOperationAndReceiptIdentifiersEnforceExactUTF8BoundsAndControls() {
        assertLifecycleRequestValid(lifecycleRequest(operation: .load(
            modelKey: String(repeating: "m", count: 512),
            contextLength: 4_096
        )))
        assertLifecycleRequestInvalid(lifecycleRequest(operation: .load(
            modelKey: String(repeating: "m", count: 513),
            contextLength: 4_096
        )))
        assertLifecycleRequestInvalid(lifecycleRequest(operation: .load(
            modelKey: "model\u{7F}",
            contextLength: 4_096
        )))
        assertLifecycleRequestInvalid(lifecycleRequest(operation: .unload(instanceID: "")))
        assertLifecycleRequestInvalid(lifecycleRequest(operation: .unload(
            instanceID: String(repeating: "i", count: 513)
        )))

        assertLifecycleReplyValid(lifecycleReply(receipt: .load(.init(
            instanceID: String(repeating: "i", count: 512),
            loadTimeSeconds: 0,
            configuration: lifecycleLoadConfiguration()
        ))))
        assertLifecycleReplyInvalid(lifecycleReply(receipt: .load(.init(
            instanceID: "instance\ninvalid",
            loadTimeSeconds: 1,
            configuration: lifecycleLoadConfiguration()
        ))))
    }

    func testContextLoadConfigurationAndLoadTimeBoundsAreClosed() {
        assertLifecycleRequestValid(lifecycleRequest(operation: .load(
            modelKey: "publisher/model",
            contextLength: 1
        )))
        assertLifecycleRequestValid(lifecycleRequest(operation: .load(
            modelKey: "publisher/model",
            contextLength: 4_194_304
        )))
        assertLifecycleRequestInvalid(lifecycleRequest(operation: .load(
            modelKey: "publisher/model",
            contextLength: 0
        )))
        assertLifecycleRequestInvalid(lifecycleRequest(operation: .load(
            modelKey: "publisher/model",
            contextLength: 4_194_305
        )))

        assertLifecycleReplyInvalid(lifecycleReply(receipt: .load(.init(
            instanceID: "runtime-instance",
            loadTimeSeconds: -0.01,
            configuration: lifecycleLoadConfiguration()
        ))))
        assertLifecycleReplyInvalid(lifecycleReply(receipt: .load(.init(
            instanceID: "runtime-instance",
            loadTimeSeconds: .infinity,
            configuration: lifecycleLoadConfiguration()
        ))))
        assertLifecycleReplyInvalid(lifecycleReply(receipt: .load(.init(
            instanceID: "runtime-instance",
            loadTimeSeconds: 1,
            configuration: lifecycleLoadConfiguration(contextLength: 4_194_305)
        ))))
        assertLifecycleReplyInvalid(lifecycleReply(receipt: .load(.init(
            instanceID: "runtime-instance",
            loadTimeSeconds: 1,
            configuration: lifecycleLoadConfiguration(evaluationBatchSize: 0)
        ))))
        assertLifecycleReplyInvalid(lifecycleReply(receipt: .load(.init(
            instanceID: "runtime-instance",
            loadTimeSeconds: 1,
            configuration: lifecycleLoadConfiguration(expertCount: 0)
        ))))
    }

    func testReplyStatusesAndReceiptsAreMutuallyConstrained() {
        let failures: [Phase2AIWorkerModelLifecycleReply.Status] = [
            .authenticationRequired,
            .unavailableBeforeDispatch,
            .incompatibleBeforeDispatch,
            .rejected,
            .cancelledBeforeDispatch,
            .reconciliationRequired,
        ]
        for status in failures {
            assertLifecycleReplyValid(lifecycleReply(status: status, receipt: nil))
            assertLifecycleReplyInvalid(lifecycleReply(status: status))
        }

        assertLifecycleReplyInvalid(lifecycleReply(status: .succeeded, receipt: nil))
        assertLifecycleReplyInvalid(lifecycleReply(
            operationKind: .load,
            receipt: .unload(.init(instanceID: "runtime-instance"))
        ))
        assertLifecycleReplyInvalid(lifecycleReply(
            operationKind: .unload,
            receipt: .load(.init(
                instanceID: "runtime-instance",
                loadTimeSeconds: 1,
                configuration: lifecycleLoadConfiguration()
            ))
        ))
        assertLifecycleReplyValid(lifecycleReply())
        assertLifecycleReplyValid(lifecycleReply(
            operationKind: .unload,
            receipt: .unload(.init(instanceID: "runtime-instance"))
        ))
    }

    func testReplyPreservesExactEffectProfileGenerationAndOperationIdentity() throws {
        let reply = lifecycleReply(
            effectID: lifecycleID(9),
            profileID: lifecycleID(8),
            generation: 77,
            operationKind: .unload,
            receipt: .unload(.init(instanceID: "exact-instance"))
        )

        let decoded = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(
            Phase2AIWorkerModelLifecycleWireCodec().encodeReply(reply)
        )

        XCTAssertEqual(decoded.effectID, lifecycleID(9))
        XCTAssertEqual(decoded.profileID, lifecycleID(8))
        XCTAssertEqual(decoded.generation, 77)
        XCTAssertEqual(decoded.operationKind, .unload)
        guard case .unload(let receipt) = decoded.receipt else {
            return XCTFail("expected an exact unload receipt")
        }
        XCTAssertEqual(receipt.instanceID, "exact-instance")
    }

    func testEnvelopeLimitsMalformedUTF8AndTrailingContentFailClosed() {
        let codec = Phase2AIWorkerModelLifecycleWireCodec()
        XCTAssertThrowsError(try codec.decodeRequest(Data(repeating: 0x20, count: 4_097))) {
            XCTAssertEqual($0 as? Phase2AIWorkerWireError, .envelopeTooLarge)
        }
        XCTAssertThrowsError(try codec.decodeReply(Data(repeating: 0x20, count: 65_537))) {
            XCTAssertEqual($0 as? Phase2AIWorkerWireError, .envelopeTooLarge)
        }
        for data in [Data([0xFF]), Data("{} trailing".utf8)] {
            assertLifecycleWireError(data, decode: codec.decodeRequest)
            assertLifecycleWireError(data, decode: codec.decodeReply)
        }
    }
}

private func lifecycleRequest(
    schemaVersion: Int = 1,
    effectID: UUID = lifecycleID(1),
    profileID: UUID = lifecycleID(2),
    generation: UInt64 = 7,
    endpointOrigin: String = "http://127.0.0.1:1234",
    requestTimeoutMilliseconds: Int = 10_000,
    resourceTimeoutMilliseconds: Int = 60_000,
    operation: Phase2AIWorkerModelLifecycleOperationWire = .load(
        modelKey: "publisher/model",
        contextLength: 4_096
    )
) -> Phase2AIWorkerModelLifecycleRequest {
    .init(
        schemaVersion: schemaVersion,
        effectID: effectID,
        profileID: profileID,
        generation: generation,
        endpointOrigin: endpointOrigin,
        requestTimeoutMilliseconds: requestTimeoutMilliseconds,
        resourceTimeoutMilliseconds: resourceTimeoutMilliseconds,
        operation: operation
    )
}

private func lifecycleReply(
    schemaVersion: Int = 1,
    effectID: UUID = lifecycleID(1),
    profileID: UUID = lifecycleID(2),
    generation: UInt64 = 7,
    operationKind: Phase2AIWorkerModelLifecycleOperationKindWire = .load,
    status: Phase2AIWorkerModelLifecycleReply.Status = .succeeded,
    receipt: Phase2AIWorkerModelLifecycleReceiptWire? = .load(.init(
        instanceID: "runtime-instance",
        loadTimeSeconds: 1.25,
        configuration: lifecycleLoadConfiguration()
    ))
) -> Phase2AIWorkerModelLifecycleReply {
    .init(
        schemaVersion: schemaVersion,
        effectID: effectID,
        profileID: profileID,
        generation: generation,
        operationKind: operationKind,
        status: status,
        receipt: receipt
    )
}

private func lifecycleLoadConfiguration(
    contextLength: Int = 4_096,
    evaluationBatchSize: Int? = 512,
    flashAttention: Bool? = true,
    expertCount: Int? = 8,
    offloadsKVCacheToGPU: Bool? = true
) -> Phase2AIWorkerModelLoadConfigurationWire {
    .init(
        contextLength: contextLength,
        evaluationBatchSize: evaluationBatchSize,
        flashAttention: flashAttention,
        expertCount: expertCount,
        offloadsKVCacheToGPU: offloadsKVCacheToGPU
    )
}

private func assertLifecycleRequestValid(
    _ value: Phase2AIWorkerModelLifecycleRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNoThrow(
        try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(value),
        file: file,
        line: line
    )
}

private func assertLifecycleRequestInvalid(
    _ value: Phase2AIWorkerModelLifecycleRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(
        try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(value),
        file: file,
        line: line
    )
}

private func assertLifecycleReplyValid(
    _ value: Phase2AIWorkerModelLifecycleReply,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNoThrow(
        try Phase2AIWorkerModelLifecycleWireCodec().encodeReply(value),
        file: file,
        line: line
    )
}

private func assertLifecycleReplyInvalid(
    _ value: Phase2AIWorkerModelLifecycleReply,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(
        try Phase2AIWorkerModelLifecycleWireCodec().encodeReply(value),
        file: file,
        line: line
    )
}

private func assertLifecycleWireError<Value>(
    _ data: Data,
    decode: (Data) throws -> Value,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try decode(data), file: file, line: line) { error in
        XCTAssertNotNil(error as? Phase2AIWorkerWireError, file: file, line: line)
    }
}

private func lifecycleObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func lifecycleKeys(_ data: Data) throws -> [String] {
    try lifecycleObject(data).keys.sorted()
}

private func nestedKeys(_ data: Data, at key: String) throws -> [String] {
    try XCTUnwrap(lifecycleObject(data)[key] as? [String: Any]).keys.sorted()
}

private func nestedKeys(_ data: Data, at key: String, then nestedKey: String) throws -> [String] {
    let first = try XCTUnwrap(lifecycleObject(data)[key] as? [String: Any])
    return try XCTUnwrap(first[nestedKey] as? [String: Any]).keys.sorted()
}

private func replacingInteger(_ field: String, in text: String, suffix: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "\\\"\(field)\\\":([0-9]+)")
    let range = NSRange(text.startIndex..., in: text)
    return pattern.stringByReplacingMatches(
        in: text,
        range: range,
        withTemplate: "\"\(field)\":$1\(suffix)"
    )
}

private func lifecycleID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func lifecycleRequestJSON(operation: String) -> String {
    """
    {"schemaVersion":1,"effectID":"00000000-0000-0000-0000-000000000001","profileID":"00000000-0000-0000-0000-000000000002","generation":7,"endpointOrigin":"http://127.0.0.1:1234","requestTimeoutMilliseconds":10000,"resourceTimeoutMilliseconds":60000,"operation":\(operation)}
    """
}

private func lifecycleReplyJSON() -> String {
    """
    {"schemaVersion":1,"effectID":"00000000-0000-0000-0000-000000000001","profileID":"00000000-0000-0000-0000-000000000002","generation":7,"operationKind":"load","status":"succeeded","receipt":{"kind":"load","instanceID":"runtime-instance","loadTimeSeconds":1.25,"configuration":{"contextLength":4096,"evaluationBatchSize":512,"flashAttention":true,"expertCount":8,"offloadsKVCacheToGPU":true}}}
    """
}
