import Foundation
import XCTest
@testable import MacScope

/// Toolchain-key detection on hand-built `MachOFile` values, plus the loader retaining every
/// `LC_BUILD_VERSION` on the existing assembled fixtures.
final class NavigatorToolchainKeyTests: XCTestCase {
    private static let sliceSHA256 = String(repeating: "c", count: 64)

    private static func identity(subtype: Int32 = 0) throws -> MachOSliceArtifactIdentity {
        try MachOSliceArtifactIdentity(
            uuid: nil,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: subtype,
            selectedSliceSHA256: sliceSHA256,
            selectedSliceByteCount: 4096
        )
    }

    private static func version(_ major: UInt32, _ minor: UInt32, _ patch: UInt32 = 0) -> MachOVersion {
        MachOVersion(encodedValue: (major << 16) | (minor << 8) | patch)
    }

    private static func buildVersion(
        platform: UInt32,
        minOS: MachOVersion,
        sdk: MachOVersion,
        tools: [MachOBuildToolVersion]
    ) -> MachOBuildVersion {
        MachOBuildVersion(platform: platform, minimumOSVersion: minOS, sdkVersion: sdk, tools: tools)
    }

    private static func section(_ name: String, segment: String = "__TEXT") -> MachOSection {
        MachOSection(
            sectionName: name,
            segmentName: segment,
            address: 0x1000,
            size: 4,
            fileOffset: 0,
            alignment: 2,
            relocationOffset: 0,
            relocationCount: 0,
            flags: 0,
            reserved1: 0,
            reserved2: 0,
            reserved3: 0
        )
    }

    private static func machOFile(
        loadCommands: [MachOLoadCommand] = [],
        sections: [MachOSection] = [],
        buildVersion: MachOBuildVersion? = nil,
        buildVersions: [MachOBuildVersion] = [],
        legacyMinimumOSVersion: MachOMinimumOSVersion? = nil,
        legacyMinimumOSVersions: [MachOMinimumOSVersion] = []
    ) -> MachOFile {
        MachOFile(
            header: MachOHeader(
                magic: 0,
                cpuType: 0,
                cpuSubtype: 0,
                fileType: 0,
                loadCommandCount: 0,
                loadCommandsSize: 0,
                flags: 0,
                reserved: 0
            ),
            loadCommands: loadCommands,
            segments: [],
            sections: sections,
            dylibs: [],
            rpaths: [],
            symbols: [],
            imports: [],
            indirectSymbols: [],
            relocations: [],
            exports: [],
            stringLiterals: [],
            objectiveCMetadata: .empty,
            swiftMetadataSections: [],
            exceptionMetadata: .empty,
            functionStarts: [],
            dataInCodeEntries: [],
            uuid: nil,
            buildVersion: buildVersion ?? buildVersions.last,
            buildVersions: buildVersions,
            sourceVersion: nil,
            legacyMinimumOSVersion: legacyMinimumOSVersion ?? legacyMinimumOSVersions.last,
            legacyMinimumOSVersions: legacyMinimumOSVersions,
            codeSignature: nil,
            dyldChainedFixups: nil,
            entryPointOffset: nil,
            entryPointVirtualAddress: nil,
            selectedSliceOffset: 0,
            universalBinary: nil
        )
    }

    func testTwoBuildVersionsReportBothPlatformsWithExactConfidence() throws {
        let ld = MachOBuildToolVersion(tool: MachOConstants.buildToolLD, version: Self.version(1200, 0))
        let swift = MachOBuildToolVersion(tool: MachOConstants.buildToolSwift, version: Self.version(6, 3))
        let file = Self.machOFile(
            loadCommands: [MachOLoadCommand(command: MachOConstants.loadCommandDyldChainedFixups, commandSize: 16, offset: 32)],
            sections: [Self.section("__text"), Self.section("__swift5_types")],
            buildVersions: [
                Self.buildVersion(platform: MachOConstants.platformMacOS, minOS: Self.version(14, 5), sdk: Self.version(15, 0),
                                  tools: [swift, ld]),
                Self.buildVersion(platform: MachOConstants.platformMacCatalyst, minOS: Self.version(17, 0), sdk: Self.version(18, 0),
                                  tools: [ld]),
            ]
        )

        let key = NavigatorToolchainKeyDetector.detect(file: file, identity: try Self.identity())

        XCTAssertEqual(key.arch, "arm64")
        XCTAssertEqual(key.platforms, [
            NavigatorToolchainKey.Platform(name: "macOS", minOS: "14.5", sdk: "15.0"),
            NavigatorToolchainKey.Platform(name: "Mac Catalyst", minOS: "17.0", sdk: "18.0"),
        ])
        XCTAssertEqual(key.tools, [
            NavigatorToolchainKey.Tool(name: "swift", version: "6.3"),
            NavigatorToolchainKey.Tool(name: "ld", version: "1200.0"),
        ])
        XCTAssertEqual(key.swiftToolVersion, "6.3")
        XCTAssertEqual(key.swiftABI, "5")
        XCTAssertEqual(key.linkerFlavor, "chained")
        XCTAssertEqual(key.confidence, .exact)
        XCTAssertEqual(key.derivedFrom, Self.sliceSHA256)
        XCTAssertEqual(
            key.canonical,
            "toolchain-key/1|arch=arm64|platforms=macOS:14.5:15.0,Mac Catalyst:17.0:18.0|tools=swift:6.3,ld:1200.0|swiftABI=5|linker=chained|confidence=exact"
        )
    }

    func testLegacyMinimumVersionOnlyIsPartial() throws {
        let file = Self.machOFile(
            loadCommands: [MachOLoadCommand(command: MachOConstants.loadCommandDyldInfoOnly, commandSize: 48, offset: 32)],
            legacyMinimumOSVersion: MachOMinimumOSVersion(
                command: MachOConstants.loadCommandVersionMinMacOSX,
                minimumOSVersion: Self.version(10, 13, 6),
                sdkVersion: Self.version(11, 0)
            )
        )

        let key = NavigatorToolchainKeyDetector.detect(file: file, identity: try Self.identity())

        XCTAssertEqual(key.platforms, [NavigatorToolchainKey.Platform(name: "macOS", minOS: "10.13.6", sdk: "11.0")])
        XCTAssertEqual(key.tools, [])
        XCTAssertNil(key.swiftABI)
        XCTAssertEqual(key.linkerFlavor, "classic")
        XCTAssertEqual(key.confidence, .partial)
        XCTAssertEqual(
            key.canonical,
            "toolchain-key/1|arch=arm64|platforms=macOS:10.13.6:11.0|tools=|swiftABI=-|linker=classic|confidence=partial"
        )
    }

    func testParserRetainsTwoLegacyMinimumVersionsInLoadCommandOrder() throws {
        // A minimal 64-bit Mach-O with two deliberately differently ordered legacy targets.
        let records = [
            MachOMinimumOSVersion(command: MachOConstants.loadCommandVersionMinIPhoneOS,
                                  minimumOSVersion: Self.version(12, 1), sdkVersion: Self.version(13, 0)),
            MachOMinimumOSVersion(command: MachOConstants.loadCommandVersionMinMacOSX,
                                  minimumOSVersion: Self.version(10, 13, 6), sdkVersion: Self.version(11, 0)),
        ]
        var words: [UInt32] = [
            MachOConstants.machMagic64, UInt32(bitPattern: MachOConstants.cpuTypeARM64), 0,
            2, 2, 32, 0, 0,
        ]
        for record in records {
            words += [record.command, 16, record.minimumOSVersion.encodedValue, record.sdkVersion.encodedValue]
        }
        var bytes = Data()
        for word in words {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        let file = try MachOParser().parse(bytes)
        XCTAssertEqual(file.legacyMinimumOSVersions, records)
        XCTAssertEqual(file.legacyMinimumOSVersion, records.last)
        XCTAssertEqual(file.buildVersions, [])
        let key = NavigatorToolchainKeyDetector.detect(file: file, identity: try Self.identity())
        XCTAssertEqual(key.platforms, [
            NavigatorToolchainKey.Platform(name: "iOS", minOS: "12.1", sdk: "13.0"),
            NavigatorToolchainKey.Platform(name: "macOS", minOS: "10.13.6", sdk: "11.0"),
        ])
        XCTAssertEqual(key.confidence, .partial)
        XCTAssertEqual(key.tools, [])

        // Array-only manually built values also supply both records to the detector.
        var manual = Self.machOFile(legacyMinimumOSVersions: records)
        manual.legacyMinimumOSVersion = nil
        XCTAssertEqual(NavigatorToolchainKeyDetector.detect(file: manual, identity: try Self.identity()), key)
    }

    func testBuildVersionWithoutToolsIsPartial() throws {
        let file = Self.machOFile(buildVersions: [
            Self.buildVersion(platform: MachOConstants.platformMacOS, minOS: Self.version(13, 0), sdk: Self.version(14, 0), tools: []),
        ])

        let key = NavigatorToolchainKeyDetector.detect(file: file, identity: try Self.identity())

        XCTAssertEqual(key.platforms, [NavigatorToolchainKey.Platform(name: "macOS", minOS: "13.0", sdk: "14.0")])
        XCTAssertEqual(key.confidence, .partial)
    }

    func testNeitherBuildVersionNorMinimumVersionIsUnknown() throws {
        let key = NavigatorToolchainKeyDetector.detect(file: Self.machOFile(), identity: try Self.identity(subtype: 2))

        XCTAssertEqual(key.arch, "arm64e")
        XCTAssertEqual(key.platforms, [])
        XCTAssertEqual(key.tools, [])
        XCTAssertNil(key.swiftABI)
        XCTAssertNil(key.swiftToolVersion)
        XCTAssertEqual(key.linkerFlavor, "none")
        XCTAssertEqual(key.confidence, .unknown)
        XCTAssertEqual(key.canonical, "toolchain-key/1|arch=arm64e|platforms=|tools=|swiftABI=-|linker=none|confidence=unknown")
    }

    func testFallsBackToLastWinsBuildVersionWhenListIsEmpty() throws {
        let only = Self.buildVersion(
            platform: MachOConstants.platformMacOS,
            minOS: Self.version(14, 0),
            sdk: Self.version(15, 0),
            tools: [MachOBuildToolVersion(tool: MachOConstants.buildToolClang, version: Self.version(17, 0))]
        )
        let file = Self.machOFile(buildVersion: only, buildVersions: [])

        let key = NavigatorToolchainKeyDetector.detect(file: file, identity: try Self.identity())

        XCTAssertEqual(key.platforms, [NavigatorToolchainKey.Platform(name: "macOS", minOS: "14.0", sdk: "15.0")])
        XCTAssertEqual(key.tools, [NavigatorToolchainKey.Tool(name: "clang", version: "17.0")])
        XCTAssertEqual(key.confidence, .exact)
    }

    func testCanonicalExcludesSliceAndCodableRoundTripRecomputesIt() throws {
        let first = NavigatorToolchainKey(
            arch: "arm64",
            platforms: [NavigatorToolchainKey.Platform(name: "macOS", minOS: "14.5", sdk: "15.0")],
            tools: [NavigatorToolchainKey.Tool(name: "ld", version: "1200.0")],
            swiftABI: nil,
            linkerFlavor: "chained",
            confidence: .exact,
            derivedFrom: String(repeating: "a", count: 64)
        )
        var second = first
        second.derivedFrom = String(repeating: "b", count: 64)
        let rebuilt = NavigatorToolchainKey(
            arch: second.arch,
            platforms: second.platforms,
            tools: second.tools,
            swiftABI: second.swiftABI,
            linkerFlavor: second.linkerFlavor,
            confidence: second.confidence,
            derivedFrom: second.derivedFrom
        )
        XCTAssertEqual(first.canonical, rebuilt.canonical)

        let data = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(NavigatorToolchainKey.self, from: data), first)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["swiftABI"])
        object["canonical"] = "toolchain-key/1|tampered"
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(NavigatorToolchainKey.self, from: tampered))
    }

    func testParserRetainsEveryBuildVersionAndKeepsLastWins() throws {
        let machO = try MachOParser().parse(MachOFixture.makeExecutableWithLoadCommandMetadata().bytes)

        XCTAssertEqual(machO.buildVersions.count, 1)
        XCTAssertEqual(machO.buildVersion, machO.buildVersions.last)
        XCTAssertEqual(machO.buildVersions.first?.platformName, "macOS")

        let key = NavigatorToolchainKeyDetector.detect(file: machO, identity: try Self.identity())
        XCTAssertEqual(key.platforms, [NavigatorToolchainKey.Platform(name: "macOS", minOS: "14.5", sdk: "15.0")])
        XCTAssertEqual(key.tools, [
            NavigatorToolchainKey.Tool(name: "swift", version: "6.4"),
            NavigatorToolchainKey.Tool(name: "ld", version: "1200.0"),
        ])
        XCTAssertEqual(key.linkerFlavor, "none")
        XCTAssertNil(key.swiftABI)
        XCTAssertEqual(key.confidence, .exact)
    }

    func testParserLegacyMinimumVersionFixtureIsPartial() throws {
        let machO = try MachOParser().parse(MachOFixture.makeExecutableWithLegacyMinimumOSVersion().bytes)

        XCTAssertEqual(machO.buildVersions, [])
        XCTAssertNil(machO.buildVersion)

        let key = NavigatorToolchainKeyDetector.detect(file: machO, identity: try Self.identity())
        XCTAssertEqual(key.platforms, [NavigatorToolchainKey.Platform(name: "macOS", minOS: "10.13.6", sdk: "11.0")])
        XCTAssertEqual(key.tools, [])
        XCTAssertEqual(key.confidence, .partial)
    }
}
