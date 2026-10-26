import Foundation
import XCTest

@testable import MacScope

final class Phase2AIWorkerConfigurationTests: XCTestCase {
    func testQualityTimeoutBoundaryAndWireSymmetryPreserveLegacyBounds() throws {
        let codec = Phase2AIWorkerConfigurationWireCodec()
        let policy = Phase2LocalInferencePolicy()
        let valid = validWireConfiguration(requestTimeoutMilliseconds: 900_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: policy)
        XCTAssertEqual(try codec.decodeConfiguration(codec.encodeConfiguration(valid)), valid)
        assertInvalid(validWireConfiguration(requestTimeoutMilliseconds: 900_001,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: policy))
        assertInvalid(validWireConfiguration(requestTimeoutMilliseconds: 900_000,
            resourceTimeoutMilliseconds: 899_999, inferencePolicy: policy))
        assertInvalid(validWireConfiguration(requestTimeoutMilliseconds: 31_000))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encodeConfiguration(valid)) as? [String: Any])
        object["requestTimeoutMilliseconds"] = 900_001
        XCTAssertThrowsError(try codec.decodeConfiguration(JSONSerialization.data(withJSONObject: object)))
    }

    func testAssistantR4ConfigurationRoundTripCarriesExactManifestDigest() throws {
        let configuration = try Phase2AIProviderConfiguration(
            profileID: configID(92), generation: 2,
            endpointOrigin: "http://127.0.0.1:1234", model: "local-model",
            maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let codec = Phase2AIWorkerConfigurationWireCodec()
        let data = try Phase2AIWorkerConfigurationAppCodec().encodeConfiguration(
            configuration, protocolBundle: Phase2AIWorkerProductionProtocol.assistantR4
        )
        XCTAssertEqual(
            try codec.decodeConfiguration(data).protocolManifestDigest,
            Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest
        )
    }

    func testConfigurationRoundTripFreezesIdentityGenerationLoopbackOriginAndModel() throws {
        let configuration = validWireConfiguration()
        let codec = Phase2AIWorkerConfigurationWireCodec()

        let data = try codec.encodeConfiguration(configuration)

        XCTAssertLessThanOrEqual(data.count, 4_096)
        XCTAssertEqual(try codec.decodeConfiguration(data), configuration)
        XCTAssertEqual(
            try jsonKeys(data),
            [
                "endpointOrigin", "generation", "maximumTokens", "model", "profileID",
                "protocolManifestDigest", "requestTimeoutMilliseconds",
                "resourceTimeoutMilliseconds", "schemaVersion",
            ]
        )
        XCTAssertEqual(
            configuration.protocolManifestDigest,
            Phase2AIWorkerProductionProtocol.manifestDigest
        )
    }

    func testConfigurationRejectsUnknownKeysAndOversizedEnvelopes() throws {
        let codec = Phase2AIWorkerConfigurationWireCodec()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: codec.encodeConfiguration(validWireConfiguration()))
                as? [String: Any]
        )
        object["futureAuthority"] = true

        XCTAssertThrowsError(
            try codec.decodeConfiguration(JSONSerialization.data(withJSONObject: object))
        ) { XCTAssertEqual($0 as? Phase2AIWorkerWireError, .invalidEnvelope) }
        XCTAssertThrowsError(try codec.decodeConfiguration(Data(repeating: 0, count: 4_097))) {
            XCTAssertEqual($0 as? Phase2AIWorkerWireError, .envelopeTooLarge)
        }
    }

    func testConfigurationRejectsDuplicateKeysAndTrailingBytes() throws {
        let codec = Phase2AIWorkerConfigurationWireCodec()
        let encoded = try codec.encodeConfiguration(validWireConfiguration())

        assertMalformed(
            try appendingObjectMember(#""generation":8"#, to: encoded),
            decode: codec.decodeConfiguration
        )
        assertMalformed(
            encoded + Data([0x00]),
            decode: codec.decodeConfiguration
        )
    }

    func testConfigurationStructuralJSONBudgetsAcceptExactMaxAndRejectMaxPlusOne() {
        let limits = Phase2AIWorkerConfigurationWireCodec.structuralJSONLimits
        XCTAssertEqual(
            limits,
            Phase2AIWorkerWireJSONLimits(
                maximumDepth: 3,
                maximumTokens: 128,
                maximumMembersAndElements: 32
            )
        )

        let maximumDepth = Data("[[[null]]]".utf8)
        let overDepth = Data("[[[[null]]]]".utf8)
        XCTAssertTrue(Phase2StrictJSONValidator.validate(maximumDepth, limits: limits))
        XCTAssertFalse(Phase2StrictJSONValidator.validate(overDepth, limits: limits))

        let maximumMembers = jsonArray(repeating: "null", count: 32)
        let overMembers = jsonArray(repeating: "null", count: 33)
        XCTAssertTrue(Phase2StrictJSONValidator.validate(maximumMembers, limits: limits))
        XCTAssertFalse(Phase2StrictJSONValidator.validate(overMembers, limits: limits))

        let maximumTokenMembers = (0..<31).map { index in
            #""k\#(index)":\#(index < 3 ? "[]" : "null")"#
        }
        let maximumTokens = Data(("{" + maximumTokenMembers.joined(separator: ",") + "}").utf8)
        let overTokens = Data(("{" + (0..<32).map { #""k\#($0)":null"# }
            .joined(separator: ",") + "}").utf8)
        XCTAssertTrue(Phase2StrictJSONValidator.validate(maximumTokens, limits: limits))
        XCTAssertFalse(Phase2StrictJSONValidator.validate(overTokens, limits: limits))
    }

    func testConfigurationRejectsInvalidVersionGenerationEndpointAndModel() throws {
        assertInvalid(validWireConfiguration(schemaVersion: 2))
        assertInvalid(validWireConfiguration(generation: 0))
        assertInvalid(validWireConfiguration(endpointOrigin: "http://localhost:1234"))
        assertInvalid(validWireConfiguration(endpointOrigin: "http://127.0.0.1:1234/path"))
        assertInvalid(validWireConfiguration(endpointOrigin: "http://127.0.0.1:1234/" + String(repeating: "a", count: 128)))
        assertInvalid(validWireConfiguration(model: ""))
        assertInvalid(validWireConfiguration(model: String(repeating: "m", count: 513)))
        assertInvalid(validWireConfiguration(model: "model\u{7F}"))
        assertInvalid(validWireConfiguration(
            protocolManifestDigest: String(repeating: "0", count: 64)
        ))
    }

    func testConfigurationRejectsInvalidTokenAndTimeoutBounds() {
        assertInvalid(validWireConfiguration(maximumTokens: 0))
        assertInvalid(validWireConfiguration(maximumTokens: 8_193))
        assertInvalid(validWireConfiguration(requestTimeoutMilliseconds: 999))
        assertInvalid(validWireConfiguration(requestTimeoutMilliseconds: 30_001))
        assertInvalid(validWireConfiguration(resourceTimeoutMilliseconds: 999))
        assertInvalid(validWireConfiguration(resourceTimeoutMilliseconds: 120_001))
        assertInvalid(
            validWireConfiguration(
                requestTimeoutMilliseconds: 20_000,
                resourceTimeoutMilliseconds: 19_999
            )
        )
    }

    func testAppConfigurationValidatesAndMapsToClosedWireDTO() throws {
        let profileID = configID(1)
        let configuration = try Phase2AIProviderConfiguration(
            profileID: profileID,
            generation: 7,
            endpointOrigin: "http://[::1]:1234",
            model: "local-model",
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let appCodec = Phase2AIWorkerConfigurationAppCodec()
        let wire = try Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(
            appCodec.encodeConfiguration(configuration)
        )

        XCTAssertEqual(wire.profileID, profileID)
        XCTAssertEqual(wire.generation, 7)
        XCTAssertEqual(wire.endpointOrigin, "http://[::1]:1234")
        XCTAssertEqual(wire.model, "local-model")
        XCTAssertEqual(wire.maximumTokens, 1_024)
        XCTAssertEqual(
            wire.protocolManifestDigest,
            Phase2ModelProfileCanonicalizer().protocolManifestDigest(
                for: .productionGroundedReadOnly
            )
        )
        XCTAssertEqual(wire.requestTimeoutMilliseconds, 10_000)
        XCTAssertEqual(wire.resourceTimeoutMilliseconds, 60_000)

        XCTAssertThrowsError(
            try Phase2AIProviderConfiguration(
                profileID: profileID,
                generation: 0,
                endpointOrigin: "http://127.0.0.1:1234",
                model: "local-model",
                maximumTokens: 1_024,
                requestTimeoutMilliseconds: 10_000,
                resourceTimeoutMilliseconds: 60_000
            )
        )
    }

    func testAssistantR2ConfigurationRoundTripCarriesExactManifestDigest() throws {
        let configuration = try Phase2AIProviderConfiguration(
            profileID: configID(91),
            generation: 2,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "local-model",
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let codec = Phase2AIWorkerConfigurationWireCodec()
        let data = try Phase2AIWorkerConfigurationAppCodec().encodeConfiguration(
            configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.assistantR2
        )
        let wire = try codec.decodeConfiguration(data)

        XCTAssertEqual(
            wire.protocolManifestDigest,
            Phase2AIWorkerProductionProtocol.assistantR2.manifestDigest
        )
        let acknowledgement = Phase2AIWorkerConfigurationAcknowledgement(
            schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
            profileID: wire.profileID,
            generation: wire.generation,
            protocolManifestDigest: wire.protocolManifestDigest,
            status: .accepted
        )
        XCTAssertEqual(
            try codec.decodeAcknowledgement(codec.encodeAcknowledgement(acknowledgement)),
            acknowledgement
        )
    }

    func testAcknowledgementRoundTripHasExactClosedKeys() throws {
        let acknowledgement = Phase2AIWorkerConfigurationAcknowledgement(
            schemaVersion: 1,
            profileID: configID(1),
            generation: 7,
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest,
            status: .accepted
        )
        let codec = Phase2AIWorkerConfigurationWireCodec()
        let data = try codec.encodeAcknowledgement(acknowledgement)

        XCTAssertEqual(try codec.decodeAcknowledgement(data), acknowledgement)
        XCTAssertEqual(
            try jsonKeys(data),
            ["generation", "profileID", "protocolManifestDigest", "schemaVersion", "status"]
        )
        XCTAssertEqual(
            try Phase2AIWorkerConfigurationAppCodec().decodeAcknowledgement(data),
            acknowledgement
        )
    }

    func testAcknowledgementRejectsDuplicateKeysAndTrailingBytes() throws {
        let acknowledgement = Phase2AIWorkerConfigurationAcknowledgement(
            schemaVersion: 1,
            profileID: configID(1),
            generation: 7,
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest,
            status: .accepted
        )
        let codec = Phase2AIWorkerConfigurationWireCodec()
        let encoded = try codec.encodeAcknowledgement(acknowledgement)

        assertMalformed(
            try appendingObjectMember(#""status":"accepted""#, to: encoded),
            decode: codec.decodeAcknowledgement
        )
        assertMalformed(
            encoded + Data([0x00]),
            decode: codec.decodeAcknowledgement
        )
    }

    private func assertInvalid(
        _ value: Phase2AIWorkerConfigurationWire,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(
                try Phase2AIWorkerConfigurationWireCodec().encodeConfiguration(value)
            ),
            file: file,
            line: line
        )
    }

    private func jsonKeys(_ data: Data) throws -> [String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
    }

    private func jsonArray(repeating value: String, count: Int) -> Data {
        Data(("[" + Array(repeating: value, count: count).joined(separator: ",") + "]").utf8)
    }

    private func appendingObjectMember(_ member: String, to data: Data) throws -> Data {
        var bytes = Array(data)
        XCTAssertEqual(bytes.popLast(), UInt8(ascii: "}"))
        bytes.append(UInt8(ascii: ","))
        bytes.append(contentsOf: member.utf8)
        bytes.append(UInt8(ascii: "}"))
        return Data(bytes)
    }

    private func assertMalformed<Value>(
        _ data: Data,
        decode: (Data) throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try decode(data), file: file, line: line) {
            XCTAssertEqual(
                $0 as? Phase2AIWorkerWireError,
                .malformedEnvelope,
                file: file,
                line: line
            )
        }
    }
}

private func validWireConfiguration(
    schemaVersion: Int = 1,
    profileID: UUID = configID(1),
    generation: UInt64 = 7,
    endpointOrigin: String = "http://127.0.0.1:1234",
    model: String = "local-model",
    maximumTokens: Int = 1_024,
    requestTimeoutMilliseconds: Int = 10_000,
    resourceTimeoutMilliseconds: Int = 60_000,
    protocolManifestDigest: String = Phase2AIWorkerProductionProtocol.manifestDigest,
    inferencePolicy: Phase2LocalInferencePolicy? = nil
) -> Phase2AIWorkerConfigurationWire {
    .init(
        schemaVersion: schemaVersion,
        profileID: profileID,
        generation: generation,
        endpointOrigin: endpointOrigin,
        model: model,
        protocolManifestDigest: protocolManifestDigest,
        maximumTokens: maximumTokens,
        requestTimeoutMilliseconds: requestTimeoutMilliseconds,
        resourceTimeoutMilliseconds: resourceTimeoutMilliseconds,
        inferencePolicy: inferencePolicy
    )
}

private func configID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
