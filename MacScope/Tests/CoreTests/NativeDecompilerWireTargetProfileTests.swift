import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerWireTargetProfileTests: XCTestCase {
    private let selectedSliceSHA256 = String(repeating: "a", count: 64)

    func testAcceptsExactlyTheFourFrozenArchitectureVectors() throws {
        let accepted: [(
            rawSubtype: UInt32,
            variant: NativeDecompilerWireArchitectureVariant,
            capabilityBits: String,
            pointerAuthVersion: UInt32?
        )] = [
            (0x0000_0000, .arm64, "00000000", nil),
            (0x8000_0000, .arm64, "80000000", nil),
            (0x0000_0002, .arm64e, "00000000", nil),
            (0x8000_0002, .arm64e, "80000000", 0),
        ]

        for vector in accepted {
            let target = try NativeDecompilerSealedTargetProfile.normalizedTarget(
                rawCPUType: 0x0100_000c,
                rawCPUSubtype: vector.rawSubtype,
                selectedSliceSHA256: selectedSliceSHA256,
                selectedSliceByteCount: 4_096
            )

            XCTAssertEqual(target.rawCPUType, "0100000c")
            XCTAssertEqual(target.rawCPUSubtype, String(format: "%08x", vector.rawSubtype))
            XCTAssertEqual(target.normalizedVariant, vector.variant)
            XCTAssertEqual(target.recognizedCapabilityBits, vector.capabilityBits)
            XCTAssertEqual(target.pointerAuthABIVersion, vector.pointerAuthVersion)
            XCTAssertEqual(target.selectedSliceSHA256, selectedSliceSHA256)
            XCTAssertEqual(target.selectedSliceByteCount, .init(4_096))
            XCTAssertEqual(target.profileID, "apple-aarch64-pac-visible-clobber-v1")
            XCTAssertEqual(target.languageID, "AARCH64:LE:64:AppleSilicon")
            XCTAssertEqual(target.compilerSpecID, "default")
            XCTAssertEqual(
                target.contextProfileSHA256,
                "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
            )
            XCTAssertEqual(
                target.context,
                [
                    .init(name: "ShowPAC", value: 1),
                    .init(name: "PAC_clobber", value: 1),
                    .init(name: "ShowBTI", value: 0),
                    .init(name: "ShowMemTag", value: 0),
                ]
            )
        }
    }

    func testRejectsEveryUnknownSubtypeAndCapabilityVector() {
        let rejectedSubtypes: [UInt32] = [
            0x0000_0001,
            0x7000_0000,
            0x1000_0002,
            0x2000_0002,
            0x3000_0002,
            0x4000_0002,
            0x5000_0002,
            0x6000_0002,
            0x7000_0002,
            0x9000_0002,
            0xa000_0002,
            0xb000_0002,
            0xc000_0002,
            0xd000_0002,
            0xe000_0002,
            0xf000_0002,
            0x8000_0003,
            0xffff_ffff,
        ]

        for rawSubtype in rejectedSubtypes {
            XCTAssertThrowsError(
                try NativeDecompilerSealedTargetProfile.normalizedTarget(
                    rawCPUType: 0x0100_000c,
                    rawCPUSubtype: rawSubtype,
                    selectedSliceSHA256: selectedSliceSHA256,
                    selectedSliceByteCount: 4_096
                ),
                "raw subtype \(String(format: "%08x", rawSubtype)) must reject"
            )
        }

        XCTAssertThrowsError(
            try NativeDecompilerSealedTargetProfile.normalizedTarget(
                rawCPUType: 0x0000_000c,
                rawCPUSubtype: 0,
                selectedSliceSHA256: selectedSliceSHA256,
                selectedSliceByteCount: 4_096
            )
        )
    }

    func testContextProfilePreimageHasFrozenDigest() throws {
        let target = try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c,
            rawCPUSubtype: 0x8000_0002,
            selectedSliceSHA256: selectedSliceSHA256,
            selectedSliceByteCount: 4_096
        )
        var preimage = Data()
        appendField(
            "domain",
            Data("org.macscope.MacScope.native-context-profile.v1".utf8),
            to: &preimage
        )
        appendField("profileID", Data(target.profileID.utf8), to: &preimage)
        appendField("languageID", Data(target.languageID.utf8), to: &preimage)
        appendField("compilerSpecID", Data(target.compilerSpecID.utf8), to: &preimage)
        appendField("context.count", Data(String(target.context.count).utf8), to: &preimage)
        for (index, value) in target.context.enumerated() {
            appendField("context[\(index)].name", Data(value.name.utf8), to: &preimage)
            appendField("context[\(index)].value", Data(String(value.value).utf8), to: &preimage)
        }

        let digest = SHA256.hash(data: preimage)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            digest,
            "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
        )
        XCTAssertEqual(target.contextProfileSHA256, digest)
    }

    func testClientWaitOutlastsTheServiceHardDeadline() {
        let wall = Duration.milliseconds(Int64(NativeDecompilerProductBudgetProfile.v2.maxWallTimeMilliseconds.value))
        let serviceHardDeadline = wall + .milliseconds(500)
        let clientWait = NativeDecompilerProductBudgetProfile.clientWaitBudget()
        XCTAssertEqual(clientWait, .milliseconds(7_500))
        XCTAssertGreaterThan(clientWait, serviceHardDeadline)
        XCTAssertLessThanOrEqual(clientWait, .seconds(15), "never beyond the client's default watchdog")
    }

    func testDefaultBudgetProfileIsV3WithThirtyTwoMiBOutput() {
        let v3 = NativeDecompilerProductBudgetProfile.v3
        let v2 = NativeDecompilerProductBudgetProfile.v2
        let v1 = NativeDecompilerProductBudgetProfile.v1
        XCTAssertEqual(v2.profileID, "native-product-budget-v2")
        XCTAssertEqual(v2.maxOutputBytes, 8_388_608, "v2 stays frozen")
        XCTAssertEqual(v3.profileID, "native-product-budget-v3")
        XCTAssertEqual(v3.maxOutputBytes, 33_554_432)
        XCTAssertLessThan(Int(v3.maxOutputBytes), NativeDecompilerWireCodec.maximumResponseBytes,
                          "under the 64 MiB transport ceiling")
        for profile in [v2, v3] {
            XCTAssertEqual(profile.maxCodeBytes, v1.maxCodeBytes)
            XCTAssertEqual(profile.maxInstructions, v1.maxInstructions)
            XCTAssertEqual(profile.maxOperations, v1.maxOperations)
            XCTAssertEqual(profile.maxWallTimeMilliseconds, v1.maxWallTimeMilliseconds)
            XCTAssertEqual(NativeDecompilerProductBudgetProfile.sealed(profile.wireValue), profile)
        }
        XCTAssertEqual(NativeDecompilerProductBudgetProfile.productDefault, v3)
        XCTAssertEqual(NativeDecompilerRuntimeRegistry.productBudgets, v3.wireValue)
    }

    func testProductionBudgetProfileMatchesFrozenValues() throws {
        let profiled = NativeDecompilerProductBudgetProfile.v1
        XCTAssertEqual(profiled.profileID, "native-product-budget-v1")
        XCTAssertEqual(profiled.maxCodeBytes, 1_048_576)
        XCTAssertEqual(profiled.maxInstructions, 65_536)
        XCTAssertEqual(profiled.maxOperations, 262_144)
        XCTAssertEqual(profiled.maxOutputBytes, 1_048_576)
        XCTAssertEqual(profiled.maxWallTimeMilliseconds, .init(5_000))

        let wire = profiled.wireValue
        XCTAssertEqual(wire.profileID, profiled.profileID)
        XCTAssertEqual(wire.maxCodeBytes, profiled.maxCodeBytes)
        XCTAssertEqual(wire.maxInstructions, profiled.maxInstructions)
        XCTAssertEqual(wire.maxOperations, profiled.maxOperations)
        XCTAssertEqual(wire.maxOutputBytes, profiled.maxOutputBytes)
        XCTAssertEqual(
            wire.maxWallTimeMilliseconds,
            profiled.maxWallTimeMilliseconds
        )

        let encoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire))
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(encoded.keys),
            [
                "maxCodeBytes",
                "maxInstructions",
                "maxOperations",
                "maxOutputBytes",
                "maxWallTimeMilliseconds",
                "profileID",
            ],
            "schema v3 must bind the sealed product budget profile identity"
        )
        XCTAssertEqual(encoded["profileID"] as? String, profiled.profileID)
    }

    func testCanonicalRawArchitectureHexRequiresEightLowercaseDigits() throws {
        for rawSubtype in [
            UInt32(0x0000_0000),
            UInt32(0x8000_0000),
            UInt32(0x0000_0002),
            UInt32(0x8000_0002),
        ] {
            let target = try NativeDecompilerSealedTargetProfile.normalizedTarget(
                rawCPUType: 0x0100_000c,
                rawCPUSubtype: rawSubtype,
                selectedSliceSHA256: selectedSliceSHA256,
                selectedSliceByteCount: 1
            )
            XCTAssertEqual(target.rawCPUType.utf8.count, 8)
            XCTAssertEqual(target.rawCPUSubtype.utf8.count, 8)
            XCTAssertTrue(target.rawCPUType.utf8.allSatisfy(Self.isLowercaseHex))
            XCTAssertTrue(target.rawCPUSubtype.utf8.allSatisfy(Self.isLowercaseHex))
        }
    }

    func testRejectsInvalidSelectedSliceEvidence() {
        for digest in [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            XCTAssertThrowsError(
                try NativeDecompilerSealedTargetProfile.normalizedTarget(
                    rawCPUType: 0x0100_000c,
                    rawCPUSubtype: 0,
                    selectedSliceSHA256: digest,
                    selectedSliceByteCount: 1
                )
            )
        }
        XCTAssertThrowsError(
            try NativeDecompilerSealedTargetProfile.normalizedTarget(
                rawCPUType: 0x0100_000c,
                rawCPUSubtype: 0,
                selectedSliceSHA256: selectedSliceSHA256,
                selectedSliceByteCount: 0
            )
        )
    }

    private func appendField(_ name: String, _ value: Data, to output: inout Data) {
        appendToken(Data(name.utf8), to: &output)
        appendToken(value, to: &output)
    }

    private func appendToken(_ value: Data, to output: inout Data) {
        output.append(Data(String(value.count).utf8))
        output.append(0x3a)
        output.append(value)
        output.append(0x0a)
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}
