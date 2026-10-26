import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class MachOSliceArtifactIdentityTests: XCTestCase {
    private func containerFixture() throws -> (MachOSliceArtifactIdentity, MachOContainerAdmissionWitness) {
        let slice = Data(repeating: 0x5a, count: 32)
        let container = Data([0x01, 0x02]) + slice + Data([0x03])
        let digest = SHA256.hash(data: slice).map { String(format: "%02x", $0) }.joined()
        let identity = try MachOSliceArtifactIdentity(
            uuid: nil, rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
            selectedSliceSHA256: digest, selectedSliceByteCount: UInt64(slice.count))
        let witness = try XCTUnwrap(MachOContainerAdmissionWitness(
            containerBytes: container, sliceOffset: 2, sliceSize: UInt64(slice.count),
            selectedSliceIdentity: identity))
        return (identity, witness)
    }

    private func witnessedImage() throws -> BinaryImage {
        let (identity, witness) = try containerFixture()
        let layout = try MachOPreferredSegmentLayout(records: [
            .init(name: "__TEXT", preferredVMStart: 0x1000, preferredVMSize: 32,
                  sliceRelativeFileOffset: 0, fileSize: 32, initialProtections: 5)
        ], selectedSliceByteCount: identity.selectedSliceByteCount)
        return BinaryImage(id: UUID(), name: "synthetic", path: "/synthetic",
                           kind: "Mach-O", architecture: "arm64",
                           artifactIdentity: identity, preferredSegmentLayout: layout,
                           artifactIntegrityState: .verified,
                           containerAdmissionWitness: witness)
    }

    func testFreshContainerWitnessBindsExactSliceOffsetSizeAndBytes() throws {
        let (identity, witness) = try containerFixture()
        XCTAssertEqual(witness.sliceOffset, 2)
        XCTAssertEqual(witness.sliceSize, 32)
        XCTAssertEqual(witness.containerByteCount, 35)
        XCTAssertEqual(witness.selectedSliceIdentity, identity)
        XCTAssertNil(MachOContainerAdmissionWitness(
            containerBytes: Data(repeating: 0x5a, count: 32), sliceOffset: 1,
            sliceSize: 32, selectedSliceIdentity: identity))
        XCTAssertNil(MachOContainerAdmissionWitness(
            containerBytes: Data(repeating: 0x00, count: 35), sliceOffset: 2,
            sliceSize: 32, selectedSliceIdentity: identity))
    }

    func testSerializedImageCannotRestoreOrForgeContainerWitness() throws {
        let image = try witnessedImage()
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: Any])
        XCTAssertNil(saved["containerAdmissionWitness"])
        saved["containerAdmissionWitness"] = ["containerSHA256": String(repeating: "f", count: 64),
                                                 "sliceOffset": 0, "sliceSize": 32]
        let restored = try JSONDecoder().decode(BinaryImage.self,
                                                from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertNil(restored.containerAdmissionWitness)
        XCTAssertEqual(restored.artifactIdentity, image.artifactIdentity)
    }

    @MainActor
    func testSameVerifiedSliceReanalysisRetainsInMemoryContainerWitness() throws {
        let current = try witnessedImage()
        var fresh = current
        fresh.containerAdmissionWitness = nil
        XCTAssertEqual(WorkspaceStore.containerWitnessForReanalysis(
            current: current, fresh: fresh, preservingArtifactAuthority: true,
            usingThinRecovery: true), current.containerAdmissionWitness)
        fresh.artifactIntegrityState = .unavailable
        XCTAssertNil(WorkspaceStore.containerWitnessForReanalysis(
            current: current, fresh: fresh, preservingArtifactAuthority: true,
            usingThinRecovery: true))
    }

    @MainActor
    func testSliceOnlyRestoreCannotMintContainerAuthority() throws {
        let image = try witnessedImage()
        let restored = try JSONDecoder().decode(BinaryImage.self, from: JSONEncoder().encode(image))
        XCTAssertNil(restored.containerAdmissionWitness)
        XCTAssertNil(WorkspaceStore.containerWitnessForReanalysis(
            current: restored, fresh: restored, preservingArtifactAuthority: true,
            usingThinRecovery: true))
    }

    func testReconstructorBuildsCanonicalIdentityAndPreferredSegmentLayout() throws {
        let uuid = UUID(uuidString: "38121563-B342-3249-BA9C-DAAC2257A52D")!
        let bytes = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: Int32(bitPattern: 0x8000_0002),
            uuid: uuid,
            segments: [
                .init(
                    name: "__TEXT",
                    vmAddress: 0x1_0000_0000,
                    vmSize: 0x4_000,
                    fileOffset: 0,
                    fileSize: 0x200,
                    initialProtections: 0x5
                ),
                .init(
                    name: "__LINKEDIT",
                    vmAddress: 0x1_0000_4000,
                    vmSize: 0x1_000,
                    fileOffset: 0x200,
                    fileSize: 0,
                    initialProtections: 0x1
                ),
            ],
            byteCount: 0x200
        )

        let reconstructed = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: bytes
        )

        XCTAssertEqual(reconstructed.identity.uuid, uuid)
        XCTAssertEqual(reconstructed.identity.rawCPUType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(
            UInt32(bitPattern: reconstructed.identity.rawCPUSubtype),
            0x8000_0002
        )
        XCTAssertEqual(reconstructed.identity.architectureVariant, .arm64e)
        XCTAssertEqual(reconstructed.identity.selectedSliceByteCount, UInt64(bytes.count))
        XCTAssertEqual(
            reconstructed.identity.selectedSliceSHA256,
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(
            reconstructed.preferredSegmentLayout.records,
            [
                MachOPreferredSegmentLayout.Record(
                    name: "__TEXT",
                    preferredVMStart: 0x1_0000_0000,
                    preferredVMSize: 0x4_000,
                    sliceRelativeFileOffset: 0,
                    fileSize: 0x200,
                    initialProtections: 0x5
                ),
                MachOPreferredSegmentLayout.Record(
                    name: "__LINKEDIT",
                    preferredVMStart: 0x1_0000_4000,
                    preferredVMSize: 0x1_000,
                    sliceRelativeFileOffset: 0x200,
                    fileSize: 0,
                    initialProtections: 0x1
                ),
            ]
        )
    }

    func testValidMachOWithoutLCUUIDRetainsNilUUID() throws {
        let bytes = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            uuid: nil,
            segments: [
                .init(
                    name: "__CUSTOM",
                    vmAddress: 0x1_0000_0000,
                    vmSize: 0x1_000,
                    fileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 0x3
                )
            ],
            byteCount: 0x100
        )

        let reconstructed = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: bytes
        )

        XCTAssertNil(reconstructed.identity.uuid)
        XCTAssertEqual(reconstructed.identity.architectureVariant, .arm64)
        XCTAssertEqual(reconstructed.preferredSegmentLayout.records.map(\.name), ["__CUSTOM"])
    }

    func testArchitectureClassificationMasksOnlyCapabilityBits() {
        let cases: [(Int32, UInt32, MachOSliceArchitectureVariant)] = [
            (MachOConstants.cpuTypeARM64, 0, .arm64),
            (MachOConstants.cpuTypeARM64, 2, .arm64e),
            (MachOConstants.cpuTypeARM64, 0x8000_0002, .arm64e),
            (MachOConstants.cpuTypeX86_64, 3, .x86_64),
            (MachOConstants.cpuTypeX86_64, 8, .x86_64h),
            (MachOConstants.cpuTypeX86_64, 0x8000_0008, .x86_64h),
            (MachOConstants.cpuTypeARM64, 1, .other),
            (MachOConstants.cpuTypeX86_64, 4, .other),
        ]

        for (cpuType, rawSubtype, expected) in cases {
            XCTAssertEqual(
                MachOSliceArchitectureVariant.classify(
                    rawCPUType: cpuType,
                    rawCPUSubtype: Int32(bitPattern: rawSubtype)
                ),
                expected
            )
        }
    }

    func testIdentityRejectsNoncanonicalDigestAndZeroByteCount() {
        XCTAssertThrowsError(
            try MachOSliceArtifactIdentity(
                uuid: nil,
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "A", count: 64),
                selectedSliceByteCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? MachOSliceArtifactValidationError, .invalidSHA256)
        }

        XCTAssertThrowsError(
            try MachOSliceArtifactIdentity(
                uuid: nil,
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "0", count: 64),
                selectedSliceByteCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? MachOSliceArtifactValidationError, .invalidByteCount)
        }
    }

    func testIdentityDecodeRejectsForgedDerivedArchitectureVariant() throws {
        let identity = try MachOSliceArtifactIdentity(
            uuid: nil,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 2,
            selectedSliceSHA256: String(repeating: "0", count: 64),
            selectedSliceByteCount: 1
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
        )
        object["architectureVariant"] = MachOSliceArchitectureVariant.x86_64.rawValue

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MachOSliceArtifactIdentity.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testReconstructorRejectsLossyMalformedSegmentNameEvidence() {
        var bytes = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            uuid: nil,
            segments: [
                .init(
                    name: "__TEXT",
                    vmAddress: 0x1_0000_0000,
                    vmSize: 0x1_000,
                    fileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 0x5
                )
            ],
            byteCount: 0x100
        )
        bytes[40] = 0xFF // First byte of LC_SEGMENT_64.segname: invalid UTF-8.

        XCTAssertThrowsError(
            try MachOSliceArtifactReconstructor.reconstruct(selectedSliceBytes: bytes)
        ) { error in
            XCTAssertEqual(error as? MachOSliceArtifactValidationError, .invalidSegmentName)
        }
    }

    func testUniversalLoaderHashesAndCountsExactExplicitSelectedSlice() throws {
        let first = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeX86_64,
            cpuSubtype: 3,
            uuid: nil,
            segments: [
                .init(name: "__TEXT", vmAddress: 0x1_0000_0000, vmSize: 0x1_000,
                      fileOffset: 0, fileSize: 0x100, initialProtections: 0x5)
            ],
            byteCount: 0x100
        )
        let selected = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 2,
            uuid: nil,
            segments: [
                .init(name: "__TEXT", vmAddress: 0x1_0000_0000, vmSize: 0x2_000,
                      fileOffset: 0, fileSize: 0x180, initialProtections: 0x5)
            ],
            byteCount: 0x180
        )
        let container = WS20MachOSliceFixture.fat32(slices: [
            (MachOConstants.cpuTypeX86_64, 3, first),
            (MachOConstants.cpuTypeARM64, 2, selected),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-universal-\(UUID().uuidString)")
        try container.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try MachOBinaryLoader(requestedSliceIndex: 1).load(at: url)
        let identity = try XCTUnwrap(loaded.artifactIdentity)

        XCTAssertEqual(identity.selectedSliceByteCount, UInt64(selected.count))
        XCTAssertEqual(
            identity.selectedSliceSHA256,
            SHA256.hash(data: selected).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(identity.architectureVariant, .arm64e)
    }

    func testReconstructorRejectsSegmentFileSpanOutsideSelectedSlice() {
        let bytes = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            uuid: nil,
            segments: [
                .init(
                    name: "__TEXT",
                    vmAddress: 0x1_0000_0000,
                    vmSize: 0x1_000,
                    fileOffset: 0x80,
                    fileSize: 0x100,
                    initialProtections: 0x5
                )
            ],
            byteCount: 0x100
        )

        XCTAssertThrowsError(
            try MachOSliceArtifactReconstructor.reconstruct(selectedSliceBytes: bytes)
        ) { error in
            XCTAssertEqual(
                error as? MachOSliceArtifactValidationError,
                .segmentFileSpanOutsideSlice(name: "__TEXT")
            )
        }
    }

    func testEvidencePolicyAllowsExactlyOneAnonymousMachOObjectSegment() throws {
        let bytes = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            fileType: MachOConstants.fileTypeObject,
            uuid: nil,
            segments: [
                .init(
                    name: "",
                    vmAddress: 0,
                    vmSize: 0x100,
                    fileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 0x7
                )
            ],
            byteCount: 0x100
        )

        XCTAssertNil(
            try MachOSliceArtifactReconstructor
                .reconstructOrMarkUnavailableForAnonymousObject(selectedSliceBytes: bytes)
        )
    }

    func testEvidencePolicyRejectsAnonymousSegmentOutsideExactObjectTopology() throws {
        for fileType in [MachOConstants.fileTypeExecute, MachOConstants.fileTypeObject] {
            let segmentCount = fileType == MachOConstants.fileTypeObject ? 2 : 1
            let bytes = WS20MachOSliceFixture.thin64(
                cpuType: MachOConstants.cpuTypeARM64,
                cpuSubtype: 0,
                fileType: fileType,
                uuid: nil,
                segments: (0..<segmentCount).map { index in
                    .init(
                        name: "",
                        vmAddress: UInt64(index) * 0x80,
                        vmSize: 0x80,
                        fileOffset: UInt64(index) * 0x80,
                        fileSize: 0x80,
                        initialProtections: 0x7
                    )
                },
                byteCount: 0x100
            )

            XCTAssertThrowsError(
                try MachOSliceArtifactReconstructor
                    .reconstructOrMarkUnavailableForAnonymousObject(selectedSliceBytes: bytes)
            ) { error in
                XCTAssertEqual(
                    error as? MachOSliceArtifactValidationError,
                    .invalidSegmentName
                )
            }
        }
    }

    func testEvidencePolicyRejectsMalformedAnonymousObjectNameField() {
        var bytes = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            fileType: MachOConstants.fileTypeObject,
            uuid: nil,
            segments: [
                .init(
                    name: "",
                    vmAddress: 0,
                    vmSize: 0x100,
                    fileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 0x7
                )
            ],
            byteCount: 0x100
        )
        bytes[41] = 0xFF

        XCTAssertThrowsError(
            try MachOSliceArtifactReconstructor
                .reconstructOrMarkUnavailableForAnonymousObject(selectedSliceBytes: bytes)
        ) { error in
            XCTAssertEqual(
                error as? MachOSliceArtifactValidationError,
                .invalidSegmentName
            )
        }
    }

    func testEvidencePolicyRejectsAnonymousObjectWithInconsistentLoadCommandEnvelope() {
        for declaredCommandsSize in [UInt32(64), UInt32(80)] {
            var bytes = WS20MachOSliceFixture.thin64(
                cpuType: MachOConstants.cpuTypeARM64,
                cpuSubtype: 0,
                fileType: MachOConstants.fileTypeObject,
                uuid: nil,
                segments: [
                    .init(
                        name: "",
                        vmAddress: 0,
                        vmSize: 0x100,
                        fileOffset: 0,
                        fileSize: 0x100,
                        initialProtections: 0x7
                    )
                ],
                byteCount: 0x100
            )
            replaceUInt32LE(declaredCommandsSize, in: &bytes, at: 20)

            XCTAssertThrowsError(
                try MachOSliceArtifactReconstructor
                    .reconstructOrMarkUnavailableForAnonymousObject(selectedSliceBytes: bytes),
                "sizeofcmds=\(declaredCommandsSize) must exactly match the command envelope"
            ) { error in
                XCTAssertEqual(
                    error as? MachOSliceArtifactValidationError,
                    .invalidSegmentName
                )
            }
        }
    }

    private func replaceUInt32LE(_ value: UInt32, in data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }
}

enum WS20MachOSliceFixture {
    struct Segment {
        var name: String
        var vmAddress: UInt64
        var vmSize: UInt64
        var fileOffset: UInt64
        var fileSize: UInt64
        var initialProtections: Int32
    }

    static func thin64(
        cpuType: Int32,
        cpuSubtype: Int32,
        fileType: UInt32 = MachOConstants.fileTypeExecute,
        uuid: UUID?,
        segments: [Segment],
        byteCount: Int
    ) -> Data {
        let commandsSize = (uuid == nil ? 0 : 24) + (segments.count * 72)
        precondition(byteCount >= 32 + commandsSize)

        var data = Data()
        appendUInt32LE(MachOConstants.machMagic64, to: &data)
        appendUInt32LE(UInt32(bitPattern: cpuType), to: &data)
        appendUInt32LE(UInt32(bitPattern: cpuSubtype), to: &data)
        appendUInt32LE(fileType, to: &data)
        appendUInt32LE(UInt32(segments.count + (uuid == nil ? 0 : 1)), to: &data)
        appendUInt32LE(UInt32(commandsSize), to: &data)
        appendUInt32LE(0, to: &data)
        appendUInt32LE(0, to: &data)

        if let uuid {
            appendUInt32LE(MachOConstants.loadCommandUUID, to: &data)
            appendUInt32LE(24, to: &data)
            var raw = uuid.uuid
            withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        }

        for segment in segments {
            appendUInt32LE(MachOConstants.loadCommandSegment64, to: &data)
            appendUInt32LE(72, to: &data)
            var nameBytes = Array(segment.name.utf8.prefix(16))
            nameBytes.append(contentsOf: repeatElement(0, count: 16 - nameBytes.count))
            data.append(contentsOf: nameBytes)
            appendUInt64LE(segment.vmAddress, to: &data)
            appendUInt64LE(segment.vmSize, to: &data)
            appendUInt64LE(segment.fileOffset, to: &data)
            appendUInt64LE(segment.fileSize, to: &data)
            appendUInt32LE(0x7, to: &data)
            appendUInt32LE(UInt32(bitPattern: segment.initialProtections), to: &data)
            appendUInt32LE(0, to: &data)
            appendUInt32LE(0, to: &data)
        }

        data.append(contentsOf: repeatElement(0, count: byteCount - data.count))
        return data
    }

    static func fat32(slices: [(cpuType: Int32, cpuSubtype: Int32, bytes: Data)]) -> Data {
        let tableEnd = 8 + slices.count * 20
        var offsets: [Int] = []
        var cursor = (tableEnd + 0xFF) & ~0xFF
        for slice in slices {
            offsets.append(cursor)
            cursor = (cursor + slice.bytes.count + 0xFF) & ~0xFF
        }

        var data = Data()
        appendUInt32BE(MachOConstants.fatMagic, to: &data)
        appendUInt32BE(UInt32(slices.count), to: &data)
        for (index, slice) in slices.enumerated() {
            appendUInt32BE(UInt32(bitPattern: slice.cpuType), to: &data)
            appendUInt32BE(UInt32(bitPattern: slice.cpuSubtype), to: &data)
            appendUInt32BE(UInt32(offsets[index]), to: &data)
            appendUInt32BE(UInt32(slice.bytes.count), to: &data)
            appendUInt32BE(8, to: &data)
        }
        for (index, slice) in slices.enumerated() {
            data.append(contentsOf: repeatElement(0, count: offsets[index] - data.count))
            data.append(slice.bytes)
        }
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64LE(_ value: UInt64, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }


    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}
