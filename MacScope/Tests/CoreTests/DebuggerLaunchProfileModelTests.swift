import Foundation
import XCTest
@testable import MacScope

final class DebuggerLaunchProfileModelTests: XCTestCase {
    func testImportedExecutableSealAcceptsOnlyExactNativeExecutableEvidence() throws {
        let seal = try importedSeal()

        XCTAssertEqual(seal.canonicalPath, "/tmp/MacScopeFixture")
        XCTAssertEqual(seal.architecture, .arm64)
        XCTAssertNoThrow(try importedSeal(architecture: .arm64e))
        XCTAssertThrowsError(try importedSeal(path: "relative/tool"))
        XCTAssertThrowsError(try importedSeal(path: "/tmp/../tmp/tool"))
        XCTAssertThrowsError(try importedSeal(deviceID: 0))
        XCTAssertThrowsError(try importedSeal(fileID: 0))
        XCTAssertThrowsError(try importedSeal(byteCount: 0))
        XCTAssertThrowsError(try importedSeal(sha256: String(repeating: "A", count: 64)))
        XCTAssertThrowsError(try importedSeal(sha256: String(repeating: "a", count: 63)))
        XCTAssertNoThrow(
            try importedSeal(path: "/" + String(repeating: "p", count: 1_023))
        )
        XCTAssertThrowsError(
            try importedSeal(path: "/" + String(repeating: "p", count: 1_024))
        )
    }

    func testImportedExecutableSealAndTargetIdentityUseExactPathUTF8Bytes() throws {
        let composed = try importedSeal(path: "/tmp/Caf\u{00E9}")
        let decomposed = try importedSeal(path: "/tmp/Cafe\u{0301}")

        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
        XCTAssertNotEqual(
            DebuggerLaunchProfileTarget.importedExecutable(composed),
            DebuggerLaunchProfileTarget.importedExecutable(decomposed)
        )
    }

    func testWorkspaceTargetRequiresAnExactNativeArtifactOwner() throws {
        let owner = try workspaceOwner()
        XCTAssertNoThrow(
            try profile(target: .workspaceImage(owner))
        )

        let unsealed = DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: owner.binaryID,
            artifactIdentity: nil
        )
        XCTAssertThrowsError(try profile(target: .workspaceImage(unsealed)))

        let x86Owner = DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: owner.binaryID,
            artifactIdentity: try artifact(
                rawCPUType: MachOConstants.cpuTypeX86_64,
                rawCPUSubtype: 3
            )
        )
        XCTAssertThrowsError(try profile(target: .workspaceImage(x86Owner)))
    }

    func testProfileNormalizesEnvironmentOrderButPreservesArgumentOrder() throws {
        let value = try profile(
            arguments: ["second", "first", ""],
            environment: [
                try DebuggerLaunchProfileEnvironmentEntry(key: "ZED", value: "last"),
                try DebuggerLaunchProfileEnvironmentEntry(key: "ALPHA", value: "first"),
            ]
        )

        XCTAssertEqual(value.arguments, ["second", "first", ""])
        XCTAssertEqual(value.environment.map(\.key), ["ALPHA", "ZED"])
        XCTAssertThrowsError(
            try profile(environment: [
                try DebuggerLaunchProfileEnvironmentEntry(key: "DUP", value: "one"),
                try DebuggerLaunchProfileEnvironmentEntry(key: "DUP", value: "two"),
            ])
        )
    }

    func testProfileRejectsMalformedOrUnboundedAuthoring() throws {
        XCTAssertThrowsError(try profile(revision: 0))
        XCTAssertNoThrow(try profile(revision: UInt64(Int64.max)))
        XCTAssertThrowsError(try profile(revision: UInt64(Int64.max) + 1))
        XCTAssertThrowsError(try profile(name: ""))
        XCTAssertThrowsError(try profile(name: " padded "))
        XCTAssertThrowsError(try profile(name: "bad\nname"))
        XCTAssertThrowsError(try profile(name: String(repeating: "n", count: 257)))
        XCTAssertThrowsError(
            try profile(arguments: Array(repeating: "argument", count: 129))
        )
        XCTAssertThrowsError(
            try profile(arguments: [String(repeating: "a", count: 1_025)])
        )
        XCTAssertThrowsError(
            try profile(workingDirectory: "relative")
        )
        XCTAssertThrowsError(
            try profile(workingDirectory: "/tmp/../private/tmp")
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileEnvironmentEntry(key: "9INVALID", value: "value")
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileEnvironmentEntry(key: "VALID", value: "bad\nvalue")
        )
        XCTAssertThrowsError(
            try profile(
                environment: try (0..<129).map { index in
                    try DebuggerLaunchProfileEnvironmentEntry(
                        key: "KEY_\(index)",
                        value: "value"
                    )
                }
            )
        )
    }

    func testCatalogPreservesProfileOrderAndRequiresConsistentAuthority() throws {
        let first = try profile(
            id: id("00000000-0000-4000-8000-000000000001"),
            revision: 2,
            name: "First"
        )
        let second = try profile(
            id: id("00000000-0000-4000-8000-000000000002"),
            revision: 3,
            name: "Second"
        )
        let catalog = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            revision: 3,
            profiles: [second, first],
            selectedProfileID: first.id
        )

        XCTAssertEqual(catalog.profiles.map(\.id), [second.id, first.id])
        XCTAssertEqual(catalog.profile(id: first.id), first)
        XCTAssertEqual(catalog.selectedProfileID, first.id)
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: 3,
                profiles: [first, first],
                selectedProfileID: first.id
            )
        )
        XCTAssertNoThrow(
            try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: UInt64(Int64.max),
                profiles: [],
                selectedProfileID: nil
            )
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: UInt64(Int64.max) + 1,
                profiles: [],
                selectedProfileID: nil
            )
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: 1,
                profiles: [first],
                selectedProfileID: first.id
            )
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: 3,
                profiles: [first],
                selectedProfileID: id("00000000-0000-4000-8000-000000000099")
            )
        )

        let excessiveProfiles = try (0..<257).map { index in
            try profile(
                id: DebuggerLaunchProfileID(
                    rawValue: UUID(
                        uuidString: String(
                            format: "90000000-0000-4000-8000-%012llX",
                            UInt64(index + 1)
                        )
                    )!
                ),
                revision: 1,
                name: "Profile \(index)"
            )
        }
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: 3,
                profiles: excessiveProfiles,
                selectedProfileID: nil
            )
        )
    }

    func testPristineAndEmptyTombstoneRemainDistinct() throws {
        let catalogID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let pristine = DebuggerLaunchProfileCatalog.freshPristine(catalogID: catalogID)
        let tombstone = try DebuggerLaunchProfileCatalog(
            catalogID: catalogID,
            revision: 2,
            profiles: [],
            selectedProfileID: nil
        )

        XCTAssertTrue(pristine.isPristine)
        XCTAssertFalse(tombstone.isPristine)
        XCTAssertNotEqual(pristine, tombstone)
    }

    func testCanonicalCodecRoundTripsExactOrderedCatalog() throws {
        let first = try profile(
            id: id("30000000-0000-4000-8000-000000000001"),
            revision: 2,
            name: "First"
        )
        let second = try profile(
            id: id("30000000-0000-4000-8000-000000000002"),
            revision: 2,
            name: "Second"
        )
        let catalog = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "30000000-0000-4000-8000-000000000003")!,
            revision: 2,
            profiles: [second, first],
            selectedProfileID: second.id
        )

        let encoded = try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(catalog)
        XCTAssertEqual(
            try DebuggerLaunchProfileCanonicalCodec.decodeCatalog(encoded),
            catalog
        )
        XCTAssertEqual(
            try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(
                DebuggerLaunchProfileCanonicalCodec.decodeCatalog(encoded)
            ),
            encoded
        )

        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let prettyCanonical = try JSONSerialization.data(
            withJSONObject: canonicalObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeCatalog(prettyCanonical)
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["runtimePID"] = 41
        let unknownField = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeCatalog(unknownField)
        )

    }

    func testCanonicalCodecRejectsUnknownSchemaAndDuplicateKeys() throws {
        let value = try profile()
        let encoded = try DebuggerLaunchProfileCanonicalCodec.encodeProfile(value)
        let canonical = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let unknownVersion = canonical.replacingOccurrences(
            of: #""schemaVersion":1"#,
            with: #""schemaVersion":2"#
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeProfile(Data(unknownVersion.utf8))
        )

        let duplicate = canonical.replacingOccurrences(
            of: "{",
            with: "{\"schemaVersion\":1,",
            options: [],
            range: canonical.startIndex..<canonical.index(after: canonical.startIndex)
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeProfile(Data(duplicate.utf8))
        )
    }

    func testDurableLaunchProfileTypesExposeNoGenericCodableBypass() {
        func isDecodable(_ type: Any.Type) -> Bool {
            type is any Decodable.Type
        }
        func isEncodable(_ type: Any.Type) -> Bool {
            type is any Encodable.Type
        }

        for type in [
            DebuggerLaunchProfileID.self,
            DebuggerLaunchProfileArchitecture.self,
            DebuggerLaunchProfileStandardIOPolicy.self,
            DebuggerLaunchProfileEnvironmentEntry.self,
            DebuggerImportedExecutableSeal.self,
            DebuggerLaunchProfileTarget.self,
            DebuggerLaunchProfile.self,
            DebuggerLaunchProfileCatalog.self,
        ] as [Any.Type] {
            XCTAssertFalse(isDecodable(type))
            XCTAssertFalse(isEncodable(type))
        }
    }

    func testCanonicalCodecRejectsNestedUnknownDuplicateAndEnvironmentOrderBypasses() throws {
        let value = try profile(
            environment: [
                try DebuggerLaunchProfileEnvironmentEntry(key: "ALPHA", value: "first"),
                try DebuggerLaunchProfileEnvironmentEntry(key: "ZED", value: "last"),
            ]
        )
        let canonicalData = try DebuggerLaunchProfileCanonicalCodec.encodeProfile(value)
        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )

        var reorderedObject = canonicalObject
        var environment = try XCTUnwrap(
            reorderedObject["environment"] as? [[String: Any]]
        )
        environment.reverse()
        reorderedObject["environment"] = environment
        let reorderedEnvironment = try JSONSerialization.data(
            withJSONObject: reorderedObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeProfile(reorderedEnvironment)
        )

        var nestedUnknownObject = canonicalObject
        var target = try XCTUnwrap(nestedUnknownObject["target"] as? [String: Any])
        var importedExecutable = try XCTUnwrap(
            target["importedExecutable"] as? [String: Any]
        )
        importedExecutable["runtimePID"] = 41
        target["importedExecutable"] = importedExecutable
        nestedUnknownObject["target"] = target
        let nestedUnknownField = try JSONSerialization.data(
            withJSONObject: nestedUnknownObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeProfile(nestedUnknownField)
        )

        let workspaceData = try DebuggerLaunchProfileCanonicalCodec.encodeProfile(
            profile(target: .workspaceImage(try workspaceOwner()))
        )
        let workspaceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: workspaceData) as? [String: Any]
        )
        let workspaceTarget = try XCTUnwrap(workspaceObject["target"] as? [String: Any])
        var mixedDiscriminatorObject = canonicalObject
        var mixedTarget = try XCTUnwrap(
            mixedDiscriminatorObject["target"] as? [String: Any]
        )
        mixedTarget["workspaceImage"] = workspaceTarget["workspaceImage"]
        mixedDiscriminatorObject["target"] = mixedTarget
        let mixedDiscriminatorPayload = try JSONSerialization.data(
            withJSONObject: mixedDiscriminatorObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeProfile(mixedDiscriminatorPayload)
        )

        let canonicalText = try XCTUnwrap(String(data: canonicalData, encoding: .utf8))
        let duplicateNestedKey = canonicalText.replacingOccurrences(
            of: #""key":"ALPHA""#,
            with: #""key":"ALPHA","key":"ALPHA""#
        )
        XCTAssertNotEqual(duplicateNestedKey, canonicalText)
        XCTAssertThrowsError(
            try DebuggerLaunchProfileCanonicalCodec.decodeProfile(Data(duplicateNestedKey.utf8))
        )
    }

    func testCatalogConstructionCapsWholeCanonicalEncodingIncludingContainerOverhead() throws {
        let maximumEnvironmentPayload = try maximumBoundaryEnvironmentPayloadBytes()
        let profiles = try (0..<32).map { index in
            try boundaryProfile(index: index, environmentPayloadBytes: maximumEnvironmentPayload)
        }
        let aggregateProfileBytes = try profiles.reduce(into: 0) { total, profile in
            total += try DebuggerLaunchProfileCanonicalCodec.encodeProfile(profile).count
        }
        XCTAssertEqual(
            try DebuggerLaunchProfileCanonicalCodec.encodeProfile(profiles[0]).count,
            DebuggerLaunchProfileCanonicalCodec.maximumProfileBytes
        )
        XCTAssertLessThanOrEqual(
            aggregateProfileBytes,
            DebuggerLaunchProfileCanonicalCodec.maximumCatalogBytes
        )

        let nearBoundary = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "41000000-0000-4000-8000-000000000001")!,
            revision: 1,
            profiles: Array(profiles.dropLast()),
            selectedProfileID: nil
        )
        XCTAssertLessThanOrEqual(
            try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(nearBoundary).count,
            DebuggerLaunchProfileCanonicalCodec.maximumCatalogBytes
        )

        XCTAssertThrowsError(
            try DebuggerLaunchProfileCatalog(
                catalogID: UUID(uuidString: "41000000-0000-4000-8000-000000000002")!,
                revision: 1,
                profiles: profiles,
                selectedProfileID: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLaunchProfileValidationError,
                .payloadTooLarge
            )
        }
    }

    func testAuthoredStringIdentityUsesExactUTF8Bytes() throws {
        let composed = try profile(name: "Caf\u{00E9}")
        let decomposed = try profile(name: "Cafe\u{0301}")

        XCTAssertNotEqual(composed, decomposed)
        XCTAssertNotEqual(
            try DebuggerLaunchProfileCanonicalCodec.encodeProfile(composed),
            try DebuggerLaunchProfileCanonicalCodec.encodeProfile(decomposed)
        )
    }

    func testEncodedCatalogContainsNoRuntimeOrProcessAuthority() throws {
        let catalog = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "40000000-0000-4000-8000-000000000001")!,
            revision: 1,
            profiles: [try profile()],
            selectedProfileID: nil
        )
        let text = try XCTUnwrap(
            String(
                data: DebuggerLaunchProfileCanonicalCodec.encodeCatalog(catalog),
                encoding: .utf8
            )
        ).lowercased()

        for forbidden in [
            "processid", "pid", "session", "epoch", "generation", "lldb",
            "stopid", "runtime", "module", "binding", "console", "adapter",
        ] {
            XCTAssertFalse(text.contains("\"\(forbidden)\""), forbidden)
        }
    }

    private func requireSendableModelTypes() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(DebuggerImportedExecutableSeal.self)
        requireSendable(DebuggerLaunchProfile.self)
        requireSendable(DebuggerLaunchProfileCatalog.self)
    }

    private func profile(
        id: DebuggerLaunchProfileID = DebuggerLaunchProfileID(
            rawValue: UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
        ),
        revision: UInt64 = 1,
        name: String = "Default",
        target: DebuggerLaunchProfileTarget? = nil,
        arguments: [String] = [],
        environment: [DebuggerLaunchProfileEnvironmentEntry] = [],
        workingDirectory: String? = "/tmp"
    ) throws -> DebuggerLaunchProfile {
        try DebuggerLaunchProfile(
            id: id,
            revision: revision,
            name: name,
            target: target ?? .importedExecutable(try importedSeal()),
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            standardIOPolicy: .inheritNoCapture
        )
    }

    private func importedSeal(
        path: String = "/tmp/MacScopeFixture",
        deviceID: UInt64 = 1,
        fileID: UInt64 = 2,
        byteCount: UInt64 = 4_096,
        sha256: String = String(repeating: "a", count: 64),
        architecture: DebuggerLaunchProfileArchitecture = .arm64
    ) throws -> DebuggerImportedExecutableSeal {
        try DebuggerImportedExecutableSeal(
            canonicalPath: path,
            deviceID: deviceID,
            fileID: fileID,
            byteCount: byteCount,
            sha256: sha256,
            architecture: architecture,
            machOUUID: UUID(uuidString: "60000000-0000-4000-8000-000000000001")
        )
    }

    private func workspaceOwner() throws -> DebuggerWorkspaceImageOwnerSeal {
        DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: UUID(uuidString: "70000000-0000-4000-8000-000000000001")!,
            artifactIdentity: try artifact()
        )
    }

    private func artifact(
        rawCPUType: Int32 = MachOConstants.cpuTypeARM64,
        rawCPUSubtype: Int32 = 0
    ) throws -> MachOSliceArtifactIdentity {
        try MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "80000000-0000-4000-8000-000000000001"),
            rawCPUType: rawCPUType,
            rawCPUSubtype: rawCPUSubtype,
            selectedSliceSHA256: String(repeating: "b", count: 64),
            selectedSliceByteCount: 8_192
        )
    }

    private func id(_ value: String) -> DebuggerLaunchProfileID {
        DebuggerLaunchProfileID(rawValue: UUID(uuidString: value)!)
    }

    private func maximumBoundaryEnvironmentPayloadBytes() throws -> Int {
        var lowerBound = 0
        var upperBound = DebuggerLaunchProfileEnvironmentEntry.maximumValueBytes * 128

        while lowerBound < upperBound {
            let candidate = lowerBound + (upperBound - lowerBound + 1) / 2
            do {
                _ = try boundaryProfile(index: 0, environmentPayloadBytes: candidate)
                lowerBound = candidate
            } catch DebuggerLaunchProfileValidationError.payloadTooLarge {
                upperBound = candidate - 1
            }
        }
        return lowerBound
    }

    private func boundaryProfile(
        index: Int,
        environmentPayloadBytes: Int
    ) throws -> DebuggerLaunchProfile {
        var remainingBytes = environmentPayloadBytes
        let environment = try (0..<128).map { entryIndex in
            let byteCount = min(
                remainingBytes,
                DebuggerLaunchProfileEnvironmentEntry.maximumValueBytes
            )
            remainingBytes -= byteCount
            return try DebuggerLaunchProfileEnvironmentEntry(
                key: String(format: "KEY_%03d", entryIndex),
                value: String(repeating: "v", count: byteCount)
            )
        }
        XCTAssertEqual(remainingBytes, 0)

        return try profile(
            id: id(String(format: "42000000-0000-4000-8000-%012X", index + 1)),
            name: "Boundary",
            arguments: Array(
                repeating: String(
                    repeating: "a",
                    count: DebuggerLaunchProfile.maximumArgumentBytes
                ),
                count: DebuggerLaunchProfile.maximumArgumentCount
            ),
            environment: environment
        )
    }
}
