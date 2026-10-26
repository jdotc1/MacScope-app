import Foundation
import XCTest
@testable import MacScope

extension Int {
    var hexAddress: String {
        UInt64(self).hexAddress
    }
}

final class MachOImportTests: XCTestCase {
    func testMetadataReferenceFallbackRejectsInvalidRangesAndBoundsStrings() {
        var section = MachOSection(
            sectionName: "__objc_methname", segmentName: "__TEXT", address: 0x2000,
            size: 5, fileOffset: 1, alignment: 0, relocationOffset: 0,
            relocationCount: 0, flags: 0, reserved1: 0, reserved2: 0, reserved3: 0
        )
        let bytes = Data([0, 97, 98, 99, 100, 0])
        XCTAssertEqual(MachOParser.metadataReferenceString(in: bytes, section: section, targetAddress: 0x2001), "bcd")
        XCTAssertNil(MachOParser.metadataReferenceString(in: bytes, section: section, targetAddress: 0x2005))
        section.size = UInt64.max
        XCTAssertNil(MachOParser.metadataReferenceString(in: bytes, section: section, targetAddress: 0x2000))
        section.size = 6 // physically extends one byte beyond the payload
        XCTAssertNil(MachOParser.metadataReferenceString(in: bytes, section: section, targetAddress: 0x2000))
        section.fileOffset = 0
        let longBytes = Data(repeating: 97, count: 4097) + Data([0])
        section.size = UInt64(longBytes.count)
        XCTAssertNil(MachOParser.metadataReferenceString(in: longBytes, section: section, targetAddress: 0x2000))
        let boundaryBytes = Data(repeating: 97, count: 4096) + Data([0])
        section.size = UInt64(boundaryBytes.count)
        XCTAssertEqual(MachOParser.metadataReferenceString(in: boundaryBytes, section: section, targetAddress: 0x2000)?.utf8.count, 4096)
    }

    func testExhaustedMetadataBudgetDoesNotTrustLaterOversizedStringSection() throws {
        var bytes = MachOFixture.makeExecutableWithObjectiveCAndSwiftMetadata().bytes
        let original = try MachOParser().parse(bytes)
        let classNames = try XCTUnwrap(original.sections.first { $0.sectionName == "__objc_classname" })
        let selrefs = try XCTUnwrap(original.sections.first { $0.sectionName == "__objc_selrefs" })
        // The fixture's first segment has section records at 104, 184, 264.
        // Fill the first metadata string section's budget with physically valid strings.
        let stringOffset = UInt32(bytes.count)
        let strings = Data((0..<5000).flatMap { _ in [UInt8(97), UInt8(0)] })
        bytes.append(strings)
        // Keep the budget-filling section's VA span disjoint from the later
        // malformed section. Enlarging it at its original VA would alias the
        // class-name target and legitimately resolve that target in the first
        // physically valid string section instead of exercising the fallback.
        MachOFixture.writeUInt64LE(&bytes, at: 184 + 32, value: 0x7000_0000_0000)
        MachOFixture.writeUInt64LE(&bytes, at: 184 + 40, value: UInt64(strings.count))
        bytes.replaceSubrange((184 + 48)..<(184 + 52), with: (0..<4).map {
            UInt8(truncatingIfNeeded: stringOffset >> (8 * $0))
        })
        MachOFixture.writeUInt64LE(&bytes, at: 264 + 40, value: UInt64.max)
        MachOFixture.writeUInt64LE(&bytes, at: Int(selrefs.fileOffset), value: classNames.address)
        let parsed = try MachOParser().parse(bytes)
        let reference = try XCTUnwrap(parsed.objectiveCMetadata.selectorReferences.first)
        XCTAssertEqual(reference.targetAddress, classNames.address)
        XCTAssertNil(reference.resolvedName)
    }

    func testParserReadsArm64HeaderSegmentsSectionsAndEntryPoint() throws {
        let fixture = MachOFixture.makeExecutable()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.header.magic, 0xfeedfacf)
        XCTAssertEqual(machO.header.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(machO.header.cpuSubtype, 0)
        XCTAssertEqual(machO.header.fileType, MachOConstants.fileTypeExecute)
        XCTAssertEqual(machO.header.loadCommandCount, 2)
        XCTAssertEqual(machO.loadCommands.map(\.name), ["LC_SEGMENT_64", "LC_MAIN"])
        XCTAssertEqual(machO.segments.map(\.name), ["__TEXT"])
        XCTAssertEqual(machO.sections.map(\.sectionName), ["__text"])
        XCTAssertEqual(machO.entryPointOffset, UInt64(fixture.codeOffset))
        XCTAssertEqual(machO.entryPointAddress, fixture.baseAddress)
        XCTAssertEqual(machO.executableTextSection?.fileOffset, UInt32(fixture.codeOffset))
        XCTAssertEqual(machO.executableTextSection?.address, fixture.baseAddress)
    }

    func testMachOBinaryLoaderProjectsArm64eCPUSubtype() throws {
        let arm64eSubtype: Int32 = 2
        let fixture = MachOFixture.makeExecutable(cpuSubtype: arm64eSubtype)
        let fileURL = try writeTemporaryFile(named: "FixtureArm64eMachO", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertEqual(loaded.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(loaded.cpuSubtype, arm64eSubtype)
    }

    func testMachOBinaryLoaderAttestsProvableIdentityEffectiveBytesForReadExecuteSegment() throws {
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityEffectiveBytes", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertEqual(loaded.identityEffectiveByteRanges.count, 1)
        let attestation = try XCTUnwrap(loaded.identityEffectiveByteRanges.first)
        XCTAssertEqual(attestation.artifactIdentity, loaded.artifactIdentity)
        XCTAssertEqual(attestation.segmentName, "__TEXT")
        XCTAssertEqual(attestation.startAddress, 0x1_0000_0000)
        XCTAssertEqual(attestation.endAddressExclusive, 0x1_0000_0000 + UInt64(fixture.bytes.count))
        XCTAssertEqual(attestation.sliceRelativeFileOffset, 0)
        XCTAssertEqual(attestation.byteCount, UInt64(fixture.bytes.count))
        XCTAssertEqual(attestation.initialProtections, 5)
        XCTAssertTrue(attestation.isExecutable)
        XCTAssertEqual(attestation.rawBytesSHA256, AnalysisFingerprintBuilder.sha256Hex(fixture.bytes))
    }

    func testMachOBinaryLoaderAttestsReadOnlyNonExecutableBytesWithoutCodeAuthority() throws {
        var fixture = MachOFixture.makeExecutable()
        let parsed = try MachOParser().parse(fixture.bytes)
        let command = try XCTUnwrap(parsed.loadCommands.first {
            $0.command == MachOConstants.loadCommandSegment64
        })
        // LC_SEGMENT_64 maxprot/initprot; the same exact file mapping is readable but not code.
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 56, with: 1)
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 60, with: 1)
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityReadOnly", contents: fixture.bytes)
        let loaded = try MachOBinaryLoader().load(at: fileURL)
        let attestation = try XCTUnwrap(loaded.identityEffectiveByteRanges.first)
        XCTAssertEqual(loaded.identityEffectiveByteRanges.count, 1)
        XCTAssertEqual(attestation.artifactIdentity, loaded.artifactIdentity)
        XCTAssertEqual(attestation.initialProtections, 1)
        XCTAssertFalse(attestation.isExecutable)
        XCTAssertEqual(attestation.byteCount, UInt64(fixture.bytes.count))
        XCTAssertEqual(attestation.rawBytesSHA256, AnalysisFingerprintBuilder.sha256Hex(fixture.bytes))
    }

    func testMachOBinaryLoaderRejectsWritableUnreadableAndUnknownProtectionAuthority() throws {
        for protections in [UInt32(0), 2, 3, 4, 7, 9] {
            var fixture = MachOFixture.makeExecutable()
            let parsed = try MachOParser().parse(fixture.bytes)
            let command = try XCTUnwrap(parsed.loadCommands.first {
                $0.command == MachOConstants.loadCommandSegment64
            })
            fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 56, with: protections)
            fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 60, with: protections)
            let fileURL = try writeTemporaryFile(
                named: "FixtureIdentityProtection-\(protections)", contents: fixture.bytes
            )
            XCTAssertTrue(try MachOBinaryLoader().load(at: fileURL).identityEffectiveByteRanges.isEmpty)
        }
    }

    func testReadOnlyAttestationStillRejectsRelocationMutationEvidence() throws {
        var fixture = MachOFixture.makeExecutableWithRelocations()
        let parsed = try MachOParser().parse(fixture.bytes)
        let command = try XCTUnwrap(parsed.loadCommands.first {
            $0.command == MachOConstants.loadCommandSegment64
        })
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 56, with: 1)
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 60, with: 1)
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityReadOnlyRelocation", contents: fixture.bytes)
        let loaded = try MachOBinaryLoader().load(at: fileURL)
        XCTAssertFalse(loaded.relocations.isEmpty)
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testMachOBinaryLoaderAbstainsForActiveEncryptionInfoCommands() throws {
        for command in [UInt32(0x21), UInt32(0x2c)] {
            let fixture = MachOFixture.makeExecutableWithEncryptionInfo(
                command: command,
                cryptID: 1
            )
            let parsed = try MachOParser().parse(fixture.bytes)
            let fileURL = try writeTemporaryFile(
                named: "FixtureIdentityEncrypted-\(String(command, radix: 16))",
                contents: fixture.bytes
            )

            let loaded = try MachOBinaryLoader().load(at: fileURL)

            XCTAssertEqual(parsed.encryptionInfos.count, 1)
            XCTAssertEqual(parsed.encryptionInfos.first?.command, command)
            XCTAssertEqual(parsed.encryptionInfos.first?.cryptOffset, UInt32(fixture.codeOffset))
            XCTAssertEqual(parsed.encryptionInfos.first?.cryptSize, UInt32(fixture.code.count))
            XCTAssertEqual(parsed.encryptionInfos.first?.cryptID, 1)
            XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
        }
    }

    func testMachOBinaryLoaderRetainsIdentityAuthorityForInactiveEncryptionInfo() throws {
        let fixture = MachOFixture.makeExecutableWithEncryptionInfo(
            command: 0x2c,
            cryptID: 0
        )
        let fileURL = try writeTemporaryFile(
            named: "FixtureIdentityInactiveEncryption",
            contents: fixture.bytes
        )

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertEqual(loaded.identityEffectiveByteRanges.count, 1)
    }

    func testMachOBinaryLoaderAbstainsForProtectedExecutableSegment() throws {
        let fixture = MachOFixture.makeExecutableWithProtectedTextSegment()
        let parsed = try MachOParser().parse(fixture.bytes)
        let fileURL = try writeTemporaryFile(
            named: "FixtureIdentityProtectedSegment",
            contents: fixture.bytes
        )

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertEqual(parsed.segments.first?.flags, 0x8)
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testMachOBinaryLoaderAbstainsWhenExecutableRangeHasSectionRelocation() throws {
        let fixture = MachOFixture.makeExecutableWithRelocations()
        let fileURL = try writeTemporaryFile(named: "FixtureIdentitySectionRelocation", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertFalse(loaded.relocations.isEmpty)
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testMachOBinaryLoaderAbstainsWhenChainedFixupEvidenceIsPresent() throws {
        let fixture = MachOFixture.makeExecutableWithDyldChainedFixups()
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityChainedFixup", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testMachOBinaryLoaderAttestsOnlyPrecedingUnaffectedSegmentWithChainedFixups() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain()
        let parsed = try MachOParser().parse(fixture.bytes)
        let command = try XCTUnwrap(parsed.loadCommands.first {
            $0.command == MachOConstants.loadCommandDyldChainedFixups
        })
        let payload = Int(try XCTUnwrap(readMachOImportFixtureUInt32LE(fixture.bytes, at: Int(command.offset) + 8)))
        XCTAssertEqual(try XCTUnwrap(readMachOImportFixtureUInt32LE(fixture.bytes, at: payload + 4)), 32)
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityChainedFixupScoped", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertEqual(loaded.identityEffectiveByteRanges.map(\.segmentName), ["__TEXT"])
    }

    func testMachOBinaryLoaderRejectsIncompleteChainedFixupStartsForIdentity() throws {
        var fixture = MachOFixture.makeExecutableWithChainedFixupChain()
        let parsed = try MachOParser().parse(fixture.bytes)
        let command = try XCTUnwrap(parsed.loadCommands.first {
            $0.command == MachOConstants.loadCommandDyldChainedFixups
        })
        let payload = Int(try XCTUnwrap(readMachOImportFixtureUInt32LE(fixture.bytes, at: Int(command.offset) + 8)))
        let startsOffset = Int(try XCTUnwrap(readMachOImportFixtureUInt32LE(fixture.bytes, at: payload + 4)))
        let starts = payload + startsOffset
        // The parser's chain walk degrades to no fixups when this count is not covered.
        fixture.bytes.replaceUInt32LE(at: starts, with: 3)
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityChainedFixupTruncatedStarts", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testMachOBinaryLoaderRejectsMalformedChainedStartsVariants() throws {
        let mutations: [(String, (inout Data, Int) -> Void)] = [
            ("unknown-pointer-format", { bytes, payload in bytes.replaceUInt16LE(at: payload + 32 + 12 + 6, with: 0x7fff) }),
            ("multi-start", { bytes, payload in bytes.replaceUInt16LE(at: payload + 32 + 12 + 22, with: 0x8000) }),
            ("undersized-record", { bytes, payload in bytes.replaceUInt32LE(at: payload + 32 + 12, with: 22) }),
            ("oversized-record", { bytes, payload in bytes.replaceUInt32LE(at: payload + 32 + 12, with: 0xffff_ffff) }),
            ("bad-vm-offset", { bytes, payload in bytes.replaceUInt64LE(at: payload + 32 + 12 + 8, with: 8) }),
            ("unsupported-version", { bytes, payload in bytes.replaceUInt32LE(at: payload, with: 1) })
        ]
        for (name, mutation) in mutations {
            var fixture = MachOFixture.makeExecutableWithChainedFixupChain()
            let parsed = try MachOParser().parse(fixture.bytes)
            let command = try XCTUnwrap(parsed.loadCommands.first {
                $0.command == MachOConstants.loadCommandDyldChainedFixups
            })
            let payload = Int(try XCTUnwrap(readMachOImportFixtureUInt32LE(fixture.bytes, at: Int(command.offset) + 8)))
            mutation(&fixture.bytes, payload)
            let fileURL = try writeTemporaryFile(named: "FixtureIdentityChainedFixup-\(name)", contents: fixture.bytes)

            let loaded = try MachOBinaryLoader().load(at: fileURL)

            XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty, "Expected abstention for \(name)")
        }
    }

    func testMachOBinaryLoaderWithholdsTextWhenStartsDeclareTextMutation() throws {
        var fixture = MachOFixture.makeExecutableWithChainedFixupChain()
        let parsed = try MachOParser().parse(fixture.bytes)
        let command = try XCTUnwrap(parsed.loadCommands.first {
            $0.command == MachOConstants.loadCommandDyldChainedFixups
        })
        let payload = Int(try XCTUnwrap(readMachOImportFixtureUInt32LE(fixture.bytes, at: Int(command.offset) + 8)))
        let starts = payload + Int(try XCTUnwrap(readMachOImportFixtureUInt32LE(fixture.bytes, at: payload + 4)))
        // Move the declared record from __DATA to __TEXT and use __TEXT's correct VM offset.
        fixture.bytes.replaceUInt32LE(at: starts + 4, with: 12)
        fixture.bytes.replaceUInt32LE(at: starts + 8, with: 0)
        fixture.bytes.replaceUInt64LE(at: payload + 32 + 12 + 8, with: 0)
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityChainedFixupText", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testMachOBinaryLoaderAbstainsWhenClassicDyldMutationStreamEvidenceIsPresent() throws {
        var fixture = MachOFixture.makeExecutableWithSymbols()
        let parsed = try MachOParser().parse(fixture.bytes)
        let command = try XCTUnwrap(parsed.loadCommands.first {
            $0.command == MachOConstants.loadCommandDyldInfoOnly
        })
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 8, with: UInt32(fixture.codeOffset))
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 12, with: 1)
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityClassicRebase", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testMachOBinaryLoaderAbstainsWhenLegacyDynamicRelocationEvidenceIsPresent() throws {
        var fixture = MachOFixture.makeExecutableWithSymbols()
        let parsed = try MachOParser().parse(fixture.bytes)
        let command = try XCTUnwrap(parsed.loadCommands.first {
            $0.command == MachOConstants.loadCommandDysymtab
        })
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 64, with: UInt32(fixture.codeOffset))
        fixture.bytes.replaceUInt32LE(at: Int(command.offset) + 68, with: 1)
        let fileURL = try writeTemporaryFile(named: "FixtureIdentityLegacyRelocation", contents: fixture.bytes)

        let loaded = try MachOBinaryLoader().load(at: fileURL)

        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testParserRecordsUniversalArm64SliceMetadata() throws {
        let fixture = MachOFixture.makeUniversalExecutable()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.header.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(machO.selectedSliceOffset, UInt64(fixture.arm64SliceOffset))
        XCTAssertEqual(machO.architectureName, "arm64")
        XCTAssertEqual(
            machO.architectureDisplayName,
            "arm64 (universal slice 2/2 @ 0x\(String(fixture.arm64SliceOffset, radix: 16)))"
        )

        let universal = try XCTUnwrap(machO.universalBinary)
        XCTAssertFalse(universal.is64Bit)
        XCTAssertEqual(universal.slices.count, 2)
        XCTAssertEqual(universal.selectedSliceIndex, 1)
        XCTAssertEqual(universal.slices.map(\.architectureName), ["x86_64", "arm64"])
        XCTAssertEqual(universal.selectedSlice?.offset, UInt64(fixture.arm64SliceOffset))
        XCTAssertEqual(universal.selectedSlice?.size, UInt64(fixture.arm64SliceSize))
        XCTAssertEqual(universal.selectedSlice?.alignment, 4)
        XCTAssertEqual(machO.entryPointAddress, fixture.baseAddress)
    }

    func testParserDefaultSelectionPrefersArm64SliceInDualUniversal() throws {
        let fixture = MachOFixture.makeUniversalDualExecutable()
        let machO = try MachOParser().parse(fixture.bytes)

        // Default rule (no explicit request) prefers host arm64 over the x86_64 slice.
        XCTAssertEqual(machO.header.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(machO.architectureName, "arm64")
        let universal = try XCTUnwrap(machO.universalBinary)
        XCTAssertEqual(universal.slices.map(\.architectureName), ["x86_64", "arm64"])
        XCTAssertEqual(universal.selectedSliceIndex, 1)
        XCTAssertEqual(machO.selectedSliceOffset, UInt64(fixture.arm64SliceOffset))
    }

    func testParserLoadsExplicitlyRequestedX86SliceInDualUniversal() throws {
        let fixture = MachOFixture.makeUniversalDualExecutable()
        var options = MachOParseOptions.default
        options.requestedSliceIndex = 0
        let machO = try MachOParser().parse(fixture.bytes, options: options)

        // The explicit request overrides the arm64 default and loads the x86_64 slice.
        XCTAssertEqual(machO.header.cpuType, MachOConstants.cpuTypeX86_64)
        XCTAssertEqual(machO.architectureName, "x86_64")
        let universal = try XCTUnwrap(machO.universalBinary)
        XCTAssertEqual(universal.selectedSliceIndex, 0)
        XCTAssertEqual(machO.executableTextSection?.sectionName, "__text")
    }

    func testParserRejectsExplicitlyRequestedOutOfRangeSliceIndex() throws {
        let fixture = MachOFixture.makeUniversalDualExecutable()
        var options = MachOParseOptions.default
        options.requestedSliceIndex = 99

        XCTAssertThrowsError(try MachOParser().parse(fixture.bytes, options: options)) { error in
            guard case MachOParserError.invalidUniversalBinary = error else {
                return XCTFail("Expected invalidUniversalBinary, got \(error)")
            }
        }
    }

    func testParserRefusesUniversalSliceRangeOutsideFile() throws {
        let fixture = MachOFixture.makeUniversalWithOutOfRangeSlice()
        XCTAssertThrowsError(try MachOParser().parse(fixture.bytes)) { error in
            guard case MachOParserError.invalidUniversalBinary = error else {
                return XCTFail("Expected invalidUniversalBinary, got \(error)")
            }
        }
    }

    func testParserRefusesUniversalWithOverflowingArchitectureCount() throws {
        let fixture = MachOFixture.makeUniversalWithOverflowingArchCount()
        XCTAssertThrowsError(try MachOParser().parse(fixture.bytes)) { error in
            guard case MachOParserError.invalidUniversalBinary = error else {
                return XCTFail("Expected invalidUniversalBinary, got \(error)")
            }
        }
    }

    func testParserThinBinaryUnaffectedByRequestedSliceIndex() throws {
        // A requested slice index must be ignored for a thin (non-fat) binary — it loads
        // exactly as before, with no universal metadata.
        let fixture = MachOFixture.makeExecutable()
        var options = MachOParseOptions.default
        options.requestedSliceIndex = 5
        let machO = try MachOParser().parse(fixture.bytes, options: options)

        XCTAssertNil(machO.universalBinary)
        XCTAssertEqual(machO.selectedSliceOffset, 0)
        XCTAssertEqual(machO.header.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(machO.entryPointAddress, fixture.baseAddress)
    }

    func testParserRecoversUUIDAndBuildVersionLoadCommands() throws {
        let fixture = MachOFixture.makeExecutableWithLoadCommandMetadata()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_UUID",
            "LC_BUILD_VERSION",
            "LC_SOURCE_VERSION",
            "LC_MAIN"
        ])
        XCTAssertEqual(machO.uuid?.stringValue, "12345678-9abc-def0-1234-56789abcdef0")
        XCTAssertEqual(machO.buildVersion?.platformName, "macOS")
        XCTAssertEqual(machO.buildVersion?.minimumOSVersion.stringValue, "14.5")
        XCTAssertEqual(machO.buildVersion?.sdkVersion.stringValue, "15.0")
        XCTAssertEqual(machO.buildVersion?.tools.map(\.displayName), [
            "swift 6.4",
            "ld 1200.0"
        ])
        XCTAssertEqual(machO.sourceVersion?.encodedValue, MachOFixture.encodedSourceVersion(2026, 6, 19, 4, 12))
        XCTAssertEqual(machO.sourceVersion?.components, [2026, 6, 19, 4, 12])
        XCTAssertEqual(machO.sourceVersion?.stringValue, "2026.6.19.4.12")
    }

    func testParserRecoversLegacyMinimumOSVersionLoadCommand() throws {
        let fixture = MachOFixture.makeExecutableWithLegacyMinimumOSVersion()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_VERSION_MIN_MACOSX",
            "LC_MAIN"
        ])
        XCTAssertNil(machO.buildVersion)
        XCTAssertEqual(machO.legacyMinimumOSVersion?.platformName, "macOS")
        XCTAssertEqual(machO.legacyMinimumOSVersion?.minimumOSVersion.stringValue, "10.13.6")
        XCTAssertEqual(machO.legacyMinimumOSVersion?.sdkVersion.stringValue, "11.0")
    }

    func testParserRecoversRPathsAndCodeSignatureLoadCommands() throws {
        let fixture = MachOFixture.makeExecutableWithRPathsAndCodeSignature()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_RPATH",
            "LC_RPATH",
            "LC_CODE_SIGNATURE",
            "LC_MAIN"
        ])
        XCTAssertEqual(machO.rpaths.map(\.path), [
            "@executable_path/../Frameworks",
            "@loader_path/PlugIns"
        ])
        XCTAssertEqual(machO.rpaths.map(\.command), [
            MachOConstants.loadCommandRPath,
            MachOConstants.loadCommandRPath
        ])
        XCTAssertEqual(machO.rpaths.map(\.pathKind), [
            .executablePathRelative,
            .loaderPathRelative
        ])

        let codeSignature = try XCTUnwrap(machO.codeSignature)
        XCTAssertEqual(codeSignature.dataOffset, fixture.codeSignatureOffset)
        XCTAssertEqual(codeSignature.dataSize, fixture.codeSignatureSize)
        XCTAssertEqual(codeSignature.endOffset, UInt64(fixture.codeSignatureOffset) + UInt64(fixture.codeSignatureSize))

        let superBlob = try XCTUnwrap(codeSignature.superBlob)
        XCTAssertEqual(superBlob.magic, MachOConstants.codeSignatureEmbeddedSignatureMagic)
        XCTAssertEqual(superBlob.magicName, "Embedded Signature SuperBlob")
        XCTAssertEqual(superBlob.length, fixture.codeSignatureSize)
        XCTAssertEqual(superBlob.blobCount, 2)
        XCTAssertEqual(superBlob.blobs.map(\.typeName), ["Code Directory", "Entitlements"])
        XCTAssertEqual(superBlob.blobs.map(\.magicName), ["Code Directory", "XML Entitlements"])
        XCTAssertEqual(superBlob.blobs[0].relativeOffset, 28)
        XCTAssertEqual(superBlob.blobs[0].fileOffset, UInt64(fixture.codeSignatureOffset) + 28)
        XCTAssertEqual(
            superBlob.blobs[1].relativeOffset,
            superBlob.blobs[0].relativeOffset + superBlob.blobs[0].length
        )
        XCTAssertEqual(
            superBlob.blobs[1].fileOffset,
            UInt64(fixture.codeSignatureOffset) + UInt64(superBlob.blobs[1].relativeOffset)
        )

        let codeDirectory = try XCTUnwrap(superBlob.blobs[0].codeDirectory)
        XCTAssertEqual(codeDirectory.versionHexString, "0x20200")
        XCTAssertEqual(codeDirectory.flagsHexString, "0x00010000")
        XCTAssertEqual(codeDirectory.identifier, "com.example.fixture")
        XCTAssertEqual(codeDirectory.teamIdentifier, "TEAMID1234")
        XCTAssertEqual(codeDirectory.specialSlotCount, 2)
        XCTAssertEqual(codeDirectory.codeSlotCount, 3)
        XCTAssertEqual(codeDirectory.codeLimit, UInt32(fixture.code.count))
        XCTAssertEqual(codeDirectory.hashSize, 32)
        XCTAssertEqual(codeDirectory.hashTypeName, "SHA-256")
        XCTAssertEqual(codeDirectory.pageSize, 12)

        let entitlements = try XCTUnwrap(superBlob.blobs[1].entitlements)
        XCTAssertEqual(entitlements.format, .xml)
        XCTAssertTrue(entitlements.isParsed)
        XCTAssertEqual(entitlements.keyCount, 2)
        XCTAssertEqual(entitlements.keys, [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-only"
        ])
    }

    func testParserClassifiesLinkedDylibAndRPathRuntimePaths() throws {
        let fixture = MachOFixture.makeExecutableWithLinkedLibraryMetadata()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_RPATH",
            "LC_RPATH",
            "LC_LOAD_DYLIB",
            "LC_LOAD_WEAK_DYLIB",
            "LC_REEXPORT_DYLIB",
            "LC_LOAD_UPWARD_DYLIB",
            "LC_LAZY_LOAD_DYLIB",
            "LC_MAIN"
        ])
        XCTAssertEqual(machO.rpaths.map(\.pathKind), [
            .executablePathRelative,
            .loaderPathRelative
        ])
        XCTAssertEqual(machO.dylibs.map(\.pathKind), [
            .rpathRelative,
            .loaderPathRelative,
            .systemAbsolute,
            .executablePathRelative,
            .relative
        ])
        XCTAssertEqual(machO.dylibs.map(\.loadKind), [
            "required",
            "weak",
            "reexport",
            "upward",
            "lazy"
        ])
        XCTAssertEqual(machO.dylibs.first?.rpathSuffix, "FixtureSupport.framework/FixtureSupport")
        XCTAssertTrue(machO.dylibs[2].isSystemLibrary)
    }

    func testImporterSurfacesLinkedDylibRPathResolutionDiagnostics() throws {
        let fixture = MachOFixture.makeExecutableWithLinkedLibraryMetadata()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = temporaryDirectory.appendingPathComponent("Fixture.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let frameworksURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
        let frameworkURL = frameworksURL.appendingPathComponent("FixtureSupport.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworkURL, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "FixtureExecutable",
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let executableURL = macOSURL.appendingPathComponent("FixtureExecutable")
        try fixture.bytes.write(to: executableURL)
        let linkedDylibURL = frameworkURL.appendingPathComponent("FixtureSupport")
        try Data([0xca, 0xfe]).write(to: linkedDylibURL)

        let imported = try MachOImportService().importBinary(at: appURL)

        XCTAssertEqual(imported.executableURL, executableURL)
        XCTAssertTrue(imported.isBundle)
        XCTAssertTrue(imported.diagnostics.contains {
            $0.severity == .info && $0.code == "analysis.linkedDylibs.recovered"
        })
        XCTAssertTrue(imported.diagnostics.contains {
            $0.severity == .info && $0.code == "analysis.linkedDylibs.rpathResolved"
        })
        XCTAssertFalse(imported.diagnostics.contains {
            $0.code == "analysis.linkedDylibs.rpathUnresolved"
        })
    }

    func testImporterWarnsWhenRPathLinkedDylibIsUnresolved() throws {
        let fixture = MachOFixture.makeExecutableWithLinkedLibraryMetadata()
        let fileURL = try writeTemporaryFile(named: "FixtureLinkedMachO", contents: fixture.bytes)

        let imported = try MachOImportService().importBinary(at: fileURL)

        XCTAssertTrue(imported.diagnostics.contains {
            $0.severity == .info && $0.code == "analysis.linkedDylibs.recovered"
        })
        XCTAssertTrue(imported.diagnostics.contains {
            $0.severity == .warning && $0.code == "analysis.linkedDylibs.rpathUnresolved"
        })
    }

    func testParserHonorsImportAnalysisOptionsForOptionalMetadataPasses() throws {
        let metadataFixture = MachOFixture.makeExecutableWithObjectiveCAndSwiftMetadata()
        let signedFixture = MachOFixture.makeExecutableWithRPathsAndCodeSignature()
        let options = MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        )

        let metadataMachO = try MachOParser().parse(metadataFixture.bytes, options: options)
        XCTAssertTrue(metadataMachO.stringLiterals.isEmpty)
        XCTAssertEqual(metadataMachO.objectiveCMetadata, .empty)
        XCTAssertTrue(metadataMachO.swiftMetadataSections.isEmpty)

        let signedMachO = try MachOParser().parse(signedFixture.bytes, options: options)
        XCTAssertTrue(signedMachO.loadCommands.contains { $0.command == MachOConstants.loadCommandCodeSignature })
        XCTAssertNil(signedMachO.codeSignature)
    }

    func testImporterSurfacesDiagnosticsForDisabledImportAnalysisOptions() throws {
        let fixture = MachOFixture.makeExecutableWithRPathsAndCodeSignature()
        let fileURL = try writeTemporaryFile(named: "FixtureSignedMachO", contents: fixture.bytes)
        let options = MachOImportOptions(parseOptions: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        ))

        let imported = try MachOImportService().importBinary(at: fileURL, options: options)

        XCTAssertNil(imported.machO.codeSignature)
        XCTAssertEqual(
            imported.diagnostics.map(\.code),
            [
                "analysis.strings.disabled",
                "analysis.objectiveC.disabled",
                "analysis.swift.disabled",
                "analysis.codeSignature.disabled"
            ]
        )
        XCTAssertTrue(imported.diagnostics.allSatisfy { $0.severity == .info })
    }

    func testImporterSurfacesCodeSignaturePayloadSummaryDiagnostic() throws {
        let fixture = MachOFixture.makeExecutableWithRPathsAndCodeSignature()
        let fileURL = try writeTemporaryFile(named: "FixtureSignedMachOPayload", contents: fixture.bytes)

        let imported = try MachOImportService().importBinary(at: fileURL)
        let diagnostic = try XCTUnwrap(imported.diagnostics.first {
            $0.severity == .info && $0.code == "analysis.codeSignature.payloadRecovered"
        })

        XCTAssertTrue(diagnostic.message.contains("1 CodeDirectory blob"))
        XCTAssertTrue(diagnostic.message.contains("1 XML entitlement blob with 2 keys"))
    }

    func testImporterRejectsAdditionalBinaryWhenPolicyDisallowsIt() throws {
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "AdditionalMachO", contents: fixture.bytes)

        XCTAssertThrowsError(try MachOImportService().importBinary(at: fileURL, purpose: .additional)) { error in
            guard case MachOImportError.additionalBinaryRejected(let rejectedURL) = error else {
                return XCTFail("Expected additionalBinaryRejected, got \(error)")
            }
            XCTAssertEqual(rejectedURL, fileURL)
        }
    }

    func testImporterAllowsAdditionalMachOFileWhenPolicyPermitsIt() throws {
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "AdditionalMachO", contents: fixture.bytes)
        let options = MachOImportOptions(additionalBinaryPolicy: .allowMachOFiles)

        let imported = try MachOImportService().importBinary(
            at: fileURL,
            purpose: .additional,
            options: options
        )

        XCTAssertEqual(imported.executableURL, fileURL)
        XCTAssertFalse(imported.isBundle)
        XCTAssertEqual(imported.diagnostics.map(\.code), ["loader.additionalBinary.accepted"])
    }

    func testParserRecoversDyldChainedFixupsLoadCommand() throws {
        let fixture = MachOFixture.makeExecutableWithDyldChainedFixups()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_DYLD_CHAINED_FIXUPS",
            "LC_MAIN"
        ])

        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertEqual(fixups.dataOffset, fixture.dyldChainedFixupsOffset)
        XCTAssertEqual(fixups.dataSize, fixture.dyldChainedFixupsSize)
        XCTAssertEqual(fixups.endOffset, UInt64(fixture.dyldChainedFixupsOffset) + UInt64(fixture.dyldChainedFixupsSize))
        XCTAssertEqual(fixups.fixupsVersion, 0)
        XCTAssertEqual(fixups.startsOffset, 28)
        XCTAssertEqual(fixups.importsOffset, 32)
        XCTAssertEqual(fixups.symbolsOffset, 36)
        XCTAssertEqual(fixups.importsCount, 1)
        XCTAssertEqual(fixups.importsFormatName, "DYLD_CHAINED_IMPORT")
        XCTAssertEqual(fixups.symbolsFormatName, "uncompressed")
        XCTAssertEqual(fixups.startsFileOffset, UInt64(fixture.dyldChainedFixupsOffset) + 28)
        XCTAssertEqual(fixups.importsFileOffset, UInt64(fixture.dyldChainedFixupsOffset) + 32)
        XCTAssertEqual(fixups.symbolsFileOffset, UInt64(fixture.dyldChainedFixupsOffset) + 36)
    }

    func testParserWalksChainedFixupsResolvingBindAndRebaseTargets() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain()
        let machO = try MachOParser().parse(fixture.bytes)

        let fixups = try XCTUnwrap(machO.dyldChainedFixups)

        // The imports table resolved the bind symbol + its library ordinal/name.
        XCTAssertEqual(fixups.imports.map(\.name), ["_puts"])
        XCTAssertEqual(fixups.imports.first?.libraryOrdinal, 1)
        XCTAssertEqual(fixups.imports.first?.libraryName, "/usr/lib/libSystem.B.dylib")
        XCTAssertEqual(fixups.imports.first?.isWeakImport, false)
        XCTAssertEqual(fixups.imports.first?.addend, 0)

        // The chain walk recovered exactly the BIND then the REBASE, in order.
        XCTAssertEqual(fixups.fixups.count, 2)
        XCTAssertEqual(fixups.bindCount, 1)
        XCTAssertEqual(fixups.rebaseCount, 1)

        let bind = try XCTUnwrap(fixups.fixups.first { $0.isBind })
        XCTAssertEqual(bind.address, fixture.chainedBindAddress)
        XCTAssertEqual(bind.boundSymbolName, "_puts")
        XCTAssertEqual(bind.pointerFormat, 2) // DYLD_CHAINED_PTR_64
        if case let .bind(importOrdinal, symbolName, addend) = bind.kind {
            XCTAssertEqual(importOrdinal, 0)
            XCTAssertEqual(symbolName, "_puts")
            XCTAssertEqual(addend, 0)
        } else {
            XCTFail("expected a bind kind")
        }

        let rebase = try XCTUnwrap(fixups.fixups.first { $0.isRebase })
        XCTAssertEqual(rebase.address, fixture.chainedRebaseAddress)
        XCTAssertEqual(rebase.rebaseTargetAddress, fixture.chainedRebaseTargetAddress)
    }

    func testObjectiveCReferencesDeclineCoveredChainedBindWithInvalidImportOrdinal() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(objectiveCReferenceSection: true) { bytes, _ in
            let offset = MachOFixture.chainDataStart(in: bytes)
            let raw = MachOFixture.readUInt64LE(bytes, at: offset)
            // The table has exactly one import. Preserve bind/next bits but refer to ordinal 7.
            MachOFixture.writeUInt64LE(&bytes, at: offset, value: raw | 7)
        }
        let parsed = try MachOParser().parse(fixture.bytes)
        let bind = try XCTUnwrap(parsed.dyldChainedFixups?.fixups.first { $0.isBind })
        XCTAssertEqual(bind.address, fixture.chainedBindAddress)
        XCTAssertNil(bind.boundSymbolName)
        if case let .bind(ordinal, _, _) = bind.kind { XCTAssertEqual(ordinal, 7) }
        else { XCTFail("Expected a covered unresolved bind") }
        XCTAssertFalse(parsed.objectiveCMetadata.selectorReferences.contains {
            $0.sourceAddress == fixture.chainedBindAddress
        })
        // The neighboring successfully decoded rebase remains eligible.
        XCTAssertEqual(parsed.objectiveCMetadata.selectorReferences.map(\.sourceAddress),
                       [fixture.chainedRebaseAddress])
        XCTAssertEqual(parsed.objectiveCMetadata.selectorReferences.first?.targetAddress,
                       fixture.chainedRebaseTargetAddress)
    }

    func testChainedARM64EUserland24BindOrdinalsCross16BitBoundary() throws {
        // Apple dyld fd8d0c4d52320ebf64db34f3cb280310d905c5ae, include/mach-o/fixup-chains.h:
        // bind24/auth_bind24 ordinal fields occupy 24 bits; formats 1/9 retain 16 bits.
        for authenticated in [false, true] {
            for (rawOrdinal, expectedName) in [(UInt64(0xffff), "_ordinal65535"), (0x10000, "_ordinal65536")] {
                let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: 12,
                    importCount: 65537) { bytes, _ in
                    let raw = (UInt64(1) << 62) | (authenticated ? UInt64(1) << 63 : 0) | rawOrdinal
                    MachOFixture.writeUInt64LE(&bytes, at: MachOFixture.chainDataStart(in: bytes, pointerFormat: 12), value: raw)
                }
                let parsed = try MachOParser().parse(fixture.bytes)
                let bind = try XCTUnwrap(parsed.dyldChainedFixups?.fixups.first { $0.isBind })
                if case let .bind(ordinal, name, _) = bind.kind {
                    XCTAssertEqual(ordinal, Int(rawOrdinal), "authenticated=\(authenticated)")
                    XCTAssertEqual(name, expectedName)
                } else { XCTFail("Expected bind") }
            }
        }
    }

    func testChainedARM64EUserland24OutOfRangeOrdinalDoesNotAliasImportZero() throws {
        for authenticated in [false, true] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: 12,
                objectiveCReferenceSection: true) { bytes, _ in
                let raw = (UInt64(1) << 62) | (authenticated ? UInt64(1) << 63 : 0) | 0x10000
                MachOFixture.writeUInt64LE(&bytes, at: MachOFixture.chainDataStart(in: bytes, pointerFormat: 12), value: raw)
            }
            let parsed = try MachOParser().parse(fixture.bytes)
            let bind = try XCTUnwrap(parsed.dyldChainedFixups?.fixups.first { $0.isBind })
            if case let .bind(ordinal, name, _) = bind.kind {
                XCTAssertEqual(ordinal, 0x10000)
                XCTAssertNil(name)
            } else { XCTFail("Expected unresolved bind") }
            XCTAssertFalse(parsed.objectiveCMetadata.selectorReferences.contains {
                $0.sourceAddress == fixture.chainedBindAddress
            })
        }
    }

    func testOtherARM64EBindFormatsRetain16BitOrdinals() throws {
        for format: UInt16 in [1, 9] {
            for authenticated in [false, true] {
                for (rawOrdinal, expectedOrdinal, expectedName) in [
                    (UInt64(0xffff), 0xffff, "_ordinal65535"), (0x10000, 0, "_puts")
                ] {
                    let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format,
                        importCount: 65537) { bytes, _ in
                        let raw = (UInt64(1) << 62) | (authenticated ? UInt64(1) << 63 : 0) | rawOrdinal
                        MachOFixture.writeUInt64LE(&bytes, at: MachOFixture.chainDataStart(in: bytes, pointerFormat: format), value: raw)
                    }
                    let parsed = try MachOParser().parse(fixture.bytes)
                    let bind = try XCTUnwrap(parsed.dyldChainedFixups?.fixups.first { $0.isBind })
                    if case let .bind(ordinal, name, _) = bind.kind {
                        XCTAssertEqual(ordinal, expectedOrdinal)
                        XCTAssertEqual(name, expectedName)
                    } else { XCTFail("Expected bind") }
                }
            }
        }
    }

    // MARK: Chained bind addends, special library ordinals, rebase high8
    // Apple dyld include/mach-o/fixup-chains.h: dyld_chained_ptr_arm64e_bind / _bind24 carry a
    // signed 19-bit addend at bit 32; auth binds carry none; dyld_chained_ptr_64_bind carries an
    // unsigned 8-bit addend at bit 24; import addends add to the inline addend.

    func testChainedARM64EPlainBindInlineAddendIsSignExtended() throws {
        let cases: [(UInt64, Int64)] = [(0x10, 16), (0x3_ffff, 0x3_ffff), (0x7_fff8, -8), (0x4_0000, -0x4_0000)]
        for format: UInt16 in [1, 9, 12] {
            for (field, expected) in cases {
                let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format) { bytes, _ in
                    let offset = MachOFixture.chainDataStart(in: bytes, pointerFormat: format)
                    let raw = MachOFixture.readUInt64LE(bytes, at: offset)
                    MachOFixture.writeUInt64LE(&bytes, at: offset, value: raw | (field << 32))
                }
                let fixups = try XCTUnwrap(MachOParser().parse(fixture.bytes).dyldChainedFixups?.fixups)
                let bind = try XCTUnwrap(fixups.first { $0.isBind })
                XCTAssertEqual(bind.boundSymbolName, "_puts", "format \(format)")
                XCTAssertEqual(bind.boundAddend, expected, "format \(format) field \(field)")
                XCTAssertNil(bind.exactBoundSymbolName, "a nonzero addend is not the symbol itself")
                if case let .bind(ordinal, _, _) = bind.kind { XCTAssertEqual(ordinal, 0) }
                // The chain continues past the bind (next bits preserved).
                XCTAssertEqual(fixups.first { $0.isRebase }?.rebaseTargetAddress, fixture.baseAddress)
            }
        }
    }

    func testChainedARM64EAuthenticatedBindHasNoInlineAddend() throws {
        for format: UInt16 in [1, 9, 12] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format) { bytes, _ in
                let offset = MachOFixture.chainDataStart(in: bytes, pointerFormat: format)
                let raw = MachOFixture.readUInt64LE(bytes, at: offset)
                // auth:1 @63, key:2 @49, addrDiv:1 @48, diversity:16 @32 — none of it is an addend.
                let auth = (UInt64(1) << 63) | (UInt64(3) << 49) | (UInt64(1) << 48) | (UInt64(0xffff) << 32)
                MachOFixture.writeUInt64LE(&bytes, at: offset, value: raw | auth)
            }
            let bind = try XCTUnwrap(MachOParser().parse(fixture.bytes).dyldChainedFixups?.fixups.first { $0.isBind })
            XCTAssertEqual(bind.boundAddend, 0, "format \(format)")
            XCTAssertEqual(bind.exactBoundSymbolName, "_puts")
        }
    }

    func testChainedGeneric64BindInlineAddendIsUnsigned8Bit() throws {
        let cases: [(UInt64, Int64)] = [(0x7f, 0x7f), (0x80, 0x80), (0xff, 0xff)]
        for format: UInt16 in [2, 6] {
            for (field, expected) in cases {
                let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format) { bytes, _ in
                    let offset = MachOFixture.chainDataStart(in: bytes, pointerFormat: format)
                    let raw = MachOFixture.readUInt64LE(bytes, at: offset)
                    MachOFixture.writeUInt64LE(&bytes, at: offset, value: raw | (field << 24))
                }
                let bind = try XCTUnwrap(MachOParser().parse(fixture.bytes).dyldChainedFixups?.fixups.first { $0.isBind })
                XCTAssertEqual(bind.boundSymbolName, "_puts")
                XCTAssertEqual(bind.boundAddend, expected, "format \(format) field \(field)")
                if case let .bind(ordinal, _, _) = bind.kind { XCTAssertEqual(ordinal, 0) }
            }
        }
    }

    func testChainedImportAddendsCombineWithInlineAddend() throws {
        // (imports_format, import addend, pointer format, inline field bits, expected combined addend)
        let cases: [(UInt32, Int64, UInt16, UInt64, Int64)] = [
            (MachOConstants.dyldChainedImportAddend, -0x20, 2, UInt64(0x10) << 24, -0x10),
            (MachOConstants.dyldChainedImportAddend, 0x100, 9, UInt64(0x7_fff8) << 32, 0xf8),
            (MachOConstants.dyldChainedImportAddend, -0x8000_0000, 6, UInt64(0xff) << 24, -0x8000_0000 + 0xff),
            (MachOConstants.dyldChainedImportAddend64, 0x1_0000_0000, 12, UInt64(0x20) << 32, 0x1_0000_0020),
            (MachOConstants.dyldChainedImportAddend64, -0x1_0000_0000, 1, UInt64(0x4_0000) << 32, -0x1_0004_0000),
            // dyld adds in wrapping 64-bit arithmetic.
            (MachOConstants.dyldChainedImportAddend64, Int64.min, 1, UInt64(0x7_ffff) << 32, Int64.max),
        ]
        for (importsFormat, importAddend, format, inlineBits, expected) in cases {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(importsFormat: importsFormat,
                pointerFormat: format, importAddend: importAddend) { bytes, _ in
                let offset = MachOFixture.chainDataStart(in: bytes, pointerFormat: format)
                let raw = MachOFixture.readUInt64LE(bytes, at: offset)
                MachOFixture.writeUInt64LE(&bytes, at: offset, value: raw | inlineBits)
            }
            let chained = try XCTUnwrap(MachOParser().parse(fixture.bytes).dyldChainedFixups)
            let imp = try XCTUnwrap(chained.imports.first)
            XCTAssertEqual(imp.name, "_puts")
            XCTAssertEqual(imp.addend, importAddend)
            XCTAssertEqual(imp.libraryOrdinal, 1)
            XCTAssertEqual(imp.libraryName, "/usr/lib/libSystem.B.dylib")
            let bind = try XCTUnwrap(chained.fixups.first { $0.isBind })
            XCTAssertEqual(bind.boundSymbolName, "_puts")
            XCTAssertEqual(bind.boundAddend, expected, "imports_format \(importsFormat) pointer format \(format)")
        }
    }

    func testChainedImportSpecialLibraryOrdinalsAreSignExtendedInEveryFormat() throws {
        let formats: [(UInt32, Bool)] = [
            (MachOConstants.dyldChainedImport, false),
            (MachOConstants.dyldChainedImportAddend, false),
            (MachOConstants.dyldChainedImportAddend64, true),
        ]
        let specials: [(Int, MachOChainedSpecialLibraryOrdinal, Int?, String)] = [
            (0, .selfImage, nil, "self"),
            (-1, .mainExecutable, MachOConstants.executableLibraryOrdinal, "main executable"),
            (-2, .flatLookup, MachOConstants.dynamicLookupLibraryOrdinal, "dynamic lookup"),
            (-3, .weakLookup, nil, "weak lookup"),
        ]
        for (importsFormat, wide) in formats {
            for (value, special, ordinal, name) in specials {
                let raw = wide ? UInt16(bitPattern: Int16(value)) : UInt16(UInt8(bitPattern: Int8(value)))
                let fixture = MachOFixture.makeExecutableWithChainedFixupChain(importsFormat: importsFormat,
                    importLibraryOrdinalRaw: raw)
                let parsed = try MachOParser().parse(fixture.bytes)
                let chained = try XCTUnwrap(parsed.dyldChainedFixups)
                let imp = try XCTUnwrap(chained.imports.first)
                let label = "imports_format \(importsFormat) ordinal \(value)"
                XCTAssertEqual(imp.encodedLibraryOrdinal, value, label)
                XCTAssertEqual(imp.specialLibraryOrdinal, special, label)
                XCTAssertEqual(imp.libraryOrdinal, ordinal, label)
                XCTAssertEqual(imp.libraryName, name, label)
                let bind = try XCTUnwrap(chained.fixups.first { $0.isBind })
                XCTAssertEqual(bind.boundSymbolName, "_puts", label)
                XCTAssertEqual(bind.boundAddend, 0, label)
                let symbol = MachOLoadMetadata.from(parsed).importedSymbols.first { $0.source == "dyld fixup" }
                XCTAssertEqual(symbol?.libraryOrdinal, ordinal, label)
                XCTAssertEqual(symbol?.libraryName, name, label)
            }
        }
    }

    func testChainedImportOrdinalsBeyondDylibsOrUnknownSpecialsAbstain() throws {
        // The fixture declares exactly one dylib (libSystem = ordinal 1).
        let cases: [(UInt32, UInt16, Int)] = [
            (MachOConstants.dyldChainedImport, 2, 2),
            (MachOConstants.dyldChainedImport, 0xf0, 0xf0),     // largest positive 8-bit ordinal
            (MachOConstants.dyldChainedImport, 0xfc, -4),       // unknown special
            (MachOConstants.dyldChainedImportAddend, 0xf1, -15),
            (MachOConstants.dyldChainedImportAddend64, 0xfe, 0xfe),   // positive 254, NOT flat lookup
            (MachOConstants.dyldChainedImportAddend64, 0xff, 0xff),   // positive 255, NOT main executable
            (MachOConstants.dyldChainedImportAddend64, 0xfff0, 0xfff0),
            (MachOConstants.dyldChainedImportAddend64, 0xfffc, -4),
        ]
        for (importsFormat, raw, encoded) in cases {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(importsFormat: importsFormat,
                importLibraryOrdinalRaw: raw)
            let parsed = try MachOParser().parse(fixture.bytes)
            let imp = try XCTUnwrap(parsed.dyldChainedFixups?.imports.first)
            let label = "imports_format \(importsFormat) raw \(raw)"
            XCTAssertEqual(imp.encodedLibraryOrdinal, encoded, label)
            XCTAssertNil(imp.specialLibraryOrdinal, label)
            XCTAssertNil(imp.libraryOrdinal, label)
            XCTAssertNil(imp.libraryName, label)
            let symbol = MachOLoadMetadata.from(parsed).importedSymbols.first { $0.source == "dyld fixup" }
            XCTAssertEqual(symbol?.name, "_puts", label)
            XCTAssertNil(symbol?.libraryOrdinal, label)
            XCTAssertNil(symbol?.libraryName, label)
        }
    }

    func testObjectiveCReferencesDeclineChainedBindWithNonzeroAddend() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(objectiveCReferenceSection: true) { bytes, _ in
            let offset = MachOFixture.chainDataStart(in: bytes)
            let raw = MachOFixture.readUInt64LE(bytes, at: offset)
            MachOFixture.writeUInt64LE(&bytes, at: offset, value: raw | (UInt64(8) << 24))
        }
        let parsed = try MachOParser().parse(fixture.bytes)
        let bind = try XCTUnwrap(parsed.dyldChainedFixups?.fixups.first { $0.isBind })
        XCTAssertEqual(bind.boundSymbolName, "_puts")
        XCTAssertEqual(bind.boundAddend, 8)
        XCTAssertNil(bind.exactBoundSymbolName)
        XCTAssertFalse(parsed.objectiveCMetadata.selectorReferences.contains {
            $0.sourceAddress == fixture.chainedBindAddress
        })
        XCTAssertEqual(parsed.objectiveCMetadata.selectorReferences.map(\.sourceAddress),
                       [fixture.chainedRebaseAddress])
    }

    func testChainedOffsetRebasesKeepHigh8() throws {
        // _64_OFFSET: target:36, high8:8 @36. dyld adds the image base to the unpacked target.
        let generic = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: 6,
            rebaseRawOverride: 0x1234 | (UInt64(0xab) << 36))
        XCTAssertEqual(try MachOParser().parse(generic.bytes).dyldChainedFixups?.fixups
            .first(where: { $0.isRebase })?.rebaseTargetAddress, 0xab00_0001_0000_1234)
        // USERLAND / USERLAND24 plain rebase: target:43, high8:8 @43, image-relative.
        for format: UInt16 in [9, 12] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format,
                rebaseRawOverride: 0x1234 | (UInt64(0xab) << 43))
            XCTAssertEqual(try MachOParser().parse(fixture.bytes).dyldChainedFixups?.fixups
                .first(where: { $0.isRebase })?.rebaseTargetAddress, 0xab00_0001_0000_1234, "format \(format)")
        }
        // Authenticated rebases have a 32-bit target and no high8; bits 32+ are diversity/key.
        for format: UInt16 in [1, 9, 12] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format,
                rebaseRawOverride: (UInt64(1) << 63) | 0x1234 | (UInt64(0xab) << 43))
            XCTAssertEqual(try MachOParser().parse(fixture.bytes).dyldChainedFixups?.fixups
                .first(where: { $0.isRebase })?.rebaseTargetAddress, 0x1_0000_1234, "format \(format)")
        }
    }

    func testChainedRebasesUseZeroBasedTextInsteadOfDataSegment() throws {
        for format: UInt16 in [6, 9, 12] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(imageBase: 0, pointerFormat: format)
            let parsed = try MachOParser().parse(fixture.bytes)
            XCTAssertEqual(parsed.dyldChainedFixups?.fixups.first(where: { $0.isRebase })?.rebaseTargetAddress,
                           fixture.baseAddress, "pointer format \(format)")
        }
    }

    func testChainedARM64EPlainRebaseIsAbsoluteButUserlandIsRelative() throws {
        for format: UInt16 in [1, 9, 12] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format)
            let parsed = try MachOParser().parse(fixture.bytes)
            XCTAssertEqual(parsed.dyldChainedFixups?.fixups.first(where: { $0.isRebase })?.rebaseTargetAddress,
                           fixture.baseAddress, "pointer format \(format)")
        }
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: 1,
            rebaseRawOverride: 0x1234 | (UInt64(0xab) << 43))
        let parsed = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(parsed.dyldChainedFixups?.fixups.first(where: { $0.isRebase })?.rebaseTargetAddress,
                       0xab00_0000_0000_1234)
    }

    func testAuthenticatedARM64ERebasesUseImageRelativeOffset() throws {
        for format: UInt16 in [1, 9, 12] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format,
                rebaseRawOverride: (UInt64(1) << 63) | 0x100)
            let parsed = try MachOParser().parse(fixture.bytes)
            XCTAssertEqual(parsed.dyldChainedFixups?.fixups.first(where: { $0.isRebase })?.rebaseTargetAddress,
                           0x1_0000_0100, "pointer format \(format)")
        }
    }

    func testChainedRebaseOverflowDoesNotInventWrappedAddress() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(imageBase: UInt64.max - 0x1000,
            pointerFormat: 6, rebaseRawOverride: 0x2000)
        let parsed = try MachOParser().parse(fixture.bytes)
        XCTAssertTrue(parsed.dyldChainedFixups?.fixups.filter { $0.isRebase }.isEmpty == true)
    }

    /// The chained-pointer FORMAT constants are an external ABI defined by `<mach-o/fixup-chains.h>`.
    /// They were SWAPPED (ARM64E and _64 transposed), so a real DYLD_CHAINED_PTR_64 (format 2) binary
    /// was decoded with the arm64e bit layout (every fixup mis-resolved). Pin them to the ABI so the
    /// swap can never silently return.
    func testChainedPointerFormatConstantsMatchABI() {
        XCTAssertEqual(MachOConstants.dyldChainedPtrArm64e, 1)          // DYLD_CHAINED_PTR_ARM64E
        XCTAssertEqual(MachOConstants.dyldChainedPtr64, 2)             // DYLD_CHAINED_PTR_64
        XCTAssertEqual(MachOConstants.dyldChainedPtr64Offset, 6)       // DYLD_CHAINED_PTR_64_OFFSET
        XCTAssertEqual(MachOConstants.dyldChainedPtrArm64eUserland, 9) // DYLD_CHAINED_PTR_ARM64E_USERLAND
        XCTAssertEqual(MachOConstants.dyldChainedPtrArm64eUserland24, 12) // ..._USERLAND24
    }

    func testImporterSurfacesChainedFixupsWalkDiagnostic() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain()
        let fileURL = try writeTemporaryFile(named: "FixtureChainedFixupsWalk", contents: fixture.bytes)

        let imported = try MachOImportService().importBinary(at: fileURL)

        let diagnostic = try XCTUnwrap(imported.diagnostics.first {
            $0.severity == .info && $0.code == "analysis.dyldChainedFixups.walked"
        })
        XCTAssertTrue(diagnostic.message.contains("1 bind"))
        XCTAssertTrue(diagnostic.message.contains("1 rebase"))
    }

    func testParserRefusesChainedFixupsStartsOffsetOutsidePayloadWithoutThrowing() throws {
        // An out-of-range starts_offset must degrade to an empty walk (the header still
        // parses), never trap or throw — this is untrusted-byte hardening.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, chainedFixupsOffset in
            // starts_offset is the second u32 of the header.
            bytes.replaceUInt32LE(at: chainedFixupsOffset + 4, with: 0xffff_fff0)
        }

        let machO = try MachOParser().parse(fixture.bytes)
        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertTrue(fixups.fixups.isEmpty, "out-of-range starts_offset yields no walked fixups")
    }

    func testParserRefusesChainedFixupsImportsOffsetOutsidePayload() throws {
        // The header parse already rejects an import/symbol offset that points outside the
        // payload (an out-of-range imports_offset). Confirm that refusal still holds and
        // is raised as a structured error, not a trap.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, chainedFixupsOffset in
            // imports_offset is the third u32 of the header — push it past the payload size.
            bytes.replaceUInt32LE(at: chainedFixupsOffset + 8, with: 0x00ff_ffff)
        }

        XCTAssertThrowsError(try MachOParser().parse(fixture.bytes)) { error in
            guard case MachOParserError.invalidLoadCommand(_, let reason) = error else {
                return XCTFail("Expected invalidLoadCommand, got \(error)")
            }
            XCTAssertTrue(reason.contains("imports_offset points outside the payload"))
        }
    }

    func testParserHandlesBogusChainedImportsFormatGracefully() throws {
        // A bogus imports_format must not throw and must not produce phantom imports;
        // the chain walk still runs but binds resolve to a nil symbol name.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(importsFormat: 0x7fff_ffff)

        let machO = try MachOParser().parse(fixture.bytes)
        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertTrue(fixups.imports.isEmpty, "bogus imports_format yields no decoded imports")
        // The bind entry is still walked, but its symbol can't be resolved.
        let bind = try XCTUnwrap(fixups.fixups.first { $0.isBind })
        XCTAssertNil(bind.boundSymbolName)
    }

    func testParserBoundsOverlongChainedFixupChainWithoutHanging() throws {
        // An oversized `next` field must terminate the walk promptly (bounded by the
        // file-range + iteration cap), not hang. Corrupt entry0's `next` (bits 51..62) to
        // the max 0xfff so the stepped cursor lands far out of range and the walk stops.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, _ in
            let dataStart = MachOFixture.chainDataStart(in: bytes)
            var raw = MachOFixture.readUInt64LE(bytes, at: dataStart)
            raw = (raw & ~(UInt64(0xfff) << 51)) | (UInt64(0xfff) << 51) // next = 0xfff (max)
            MachOFixture.writeUInt64LE(&bytes, at: dataStart, value: raw)
        }

        // Must return promptly (bounded), not hang.
        let machO = try MachOParser().parse(fixture.bytes)
        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        // entry0 (the bind) is recorded; the oversized `next` steps out of range and stops,
        // so entry1 is never reached.
        XCTAssertEqual(fixups.fixups.count, 1)
        XCTAssertEqual(fixups.fixups.first?.isBind, true)
    }

    func testParserBoundsCyclicChainedFixupChainWithoutHanging() throws {
        // A genuine cycle: rewrite the page to start at entry1 and make entry1's `next`
        // step back onto entry0, and entry0's `next` step forward onto entry1 — the
        // visited-offset guard must break the loop rather than spin forever.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, _ in
            let dataStart = MachOFixture.chainDataStart(in: bytes)
            // entry0 at dataStart, entry1 at dataStart+8 (stride 4 => next=2 steps +8 bytes).
            // entry0.next = 2 (forward to entry1); entry1.next = 2 would step +8 past the
            // region. To force a revisit, set entry1 as a rebase whose `next` steps back is
            // impossible (forward-only). Instead overlap: set both entries' next = 2 and
            // craft a 4-slot region so the chain eventually revisits a visited offset.
            // Simplest deterministic cycle the guard catches: a self-step of next=0 is the
            // terminator, so we instead point entry0.next=2 -> entry1, entry1.next=2 ->
            // (dataStart+16) which we set equal to entry0's bytes, forming a logical loop
            // bounded by the Set<Int> visited guard once it wraps file bounds.
            var e0 = MachOFixture.readUInt64LE(bytes, at: dataStart)
            e0 = (e0 & ~(UInt64(0xfff) << 51)) | (UInt64(2) << 51) // entry0.next = 2 -> entry1
            MachOFixture.writeUInt64LE(&bytes, at: dataStart, value: e0)
            var e1 = MachOFixture.readUInt64LE(bytes, at: dataStart + 8)
            e1 = (e1 & ~(UInt64(0xfff) << 51)) | (UInt64(1) << 51) // entry1.next = 1 -> +4 (overlaps entry0/entry1)
            MachOFixture.writeUInt64LE(&bytes, at: dataStart + 8, value: e1)
        }

        // Must terminate (the iteration cap + file-bounds guard), not hang.
        let machO = try MachOParser().parse(fixture.bytes)
        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        // Whatever the crafted overlap walks, it is finite and small.
        XCTAssertLessThan(fixups.fixups.count, 16)
    }

    func testParserRecoversSectionRelocationRecords() throws {
        let fixture = MachOFixture.makeExecutableWithRelocations()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_SYMTAB",
            "LC_MAIN"
        ])
        XCTAssertEqual(machO.sections.first?.relocationOffset, fixture.relocationOffset)
        XCTAssertEqual(machO.sections.first?.relocationCount, fixture.relocationCount)
        XCTAssertEqual(machO.relocations.map(\.sourceSection), [
            "__TEXT,__text",
            "__TEXT,__text"
        ])
        XCTAssertEqual(machO.relocations.map(\.fileOffset), [
            UInt64(fixture.relocationOffset),
            UInt64(fixture.relocationOffset) + 8
        ])
        XCTAssertEqual(machO.relocations.map(\.relocationAddress), [4, 0])
        XCTAssertEqual(machO.relocations.compactMap(\.resolvedAddress), [
            fixture.baseAddress + 4,
            fixture.baseAddress
        ])
        XCTAssertEqual(machO.relocations.compactMap(\.symbolNumber), [1, 1])
        XCTAssertEqual(machO.relocations.compactMap(\.symbolName), ["_puts"])
        XCTAssertEqual(machO.relocations.map(\.isPCRelative), [true, false])
        XCTAssertEqual(machO.relocations.map(\.length), [2, 2])
        XCTAssertEqual(machO.relocations.map(\.widthInBytes), [4, 4])
        XCTAssertEqual(machO.relocations.map(\.isExternal), [true, false])
        XCTAssertEqual(machO.relocations.map(\.typeName), [
            "ARM64_RELOC_BRANCH26",
            "ARM64_RELOC_PAGE21"
        ])
        XCTAssertTrue(machO.relocations.allSatisfy { !$0.isScattered })
    }

    func testImporterSurfacesRelocationAndFixupMetadataDiagnostics() throws {
        let relocationFixture = MachOFixture.makeExecutableWithRelocations()
        let relocationURL = try writeTemporaryFile(named: "FixtureRelocatableMachO", contents: relocationFixture.bytes)

        let relocatedImport = try MachOImportService().importBinary(at: relocationURL)

        XCTAssertEqual(relocatedImport.machO.relocations.count, 2)
        XCTAssertTrue(relocatedImport.diagnostics.contains {
            $0.severity == .info && $0.code == "analysis.relocations.recovered"
        })

        let fixupFixture = MachOFixture.makeExecutableWithDyldChainedFixups()
        let fixupURL = try writeTemporaryFile(named: "FixtureFixupsMachO", contents: fixupFixture.bytes)

        let fixupImport = try MachOImportService().importBinary(at: fixupURL)

        XCTAssertNotNil(fixupImport.machO.dyldChainedFixups)
        XCTAssertTrue(fixupImport.diagnostics.contains {
            $0.severity == .info && $0.code == "analysis.dyldChainedFixups.recovered"
        })
    }

    func testParserRejectsCodeSignatureSuperBlobIndexOutsidePayload() throws {
        var fixture = MachOFixture.makeExecutableWithRPathsAndCodeSignature()
        fixture.bytes.replaceUInt32BE(
            at: Int(fixture.codeSignatureOffset) + 16,
            with: fixture.codeSignatureSize
        )

        XCTAssertThrowsError(try MachOParser().parse(fixture.bytes)) { error in
            guard case MachOParserError.invalidLoadCommand(let index, let reason) = error else {
                return XCTFail("Expected invalidLoadCommand, got \(error)")
            }
            XCTAssertEqual(index, 3)
            XCTAssertTrue(reason.contains("blob offset points outside the SuperBlob"))
        }
    }

    func testParserRejectsCodeSignatureCodeDirectoryIdentifierOutsidePayload() throws {
        var fixture = MachOFixture.makeExecutableWithRPathsAndCodeSignature()
        let codeDirectoryOffset = Int(fixture.codeSignatureOffset) + 28
        fixture.bytes.replaceUInt32BE(
            at: codeDirectoryOffset + 20,
            with: fixture.codeSignatureSize
        )

        XCTAssertThrowsError(try MachOParser().parse(fixture.bytes)) { error in
            guard case MachOParserError.invalidLoadCommand(let index, let reason) = error else {
                return XCTFail("Expected invalidLoadCommand, got \(error)")
            }
            XCTAssertEqual(index, 3)
            XCTAssertTrue(reason.contains("CodeDirectory identifier offset points outside the blob"))
        }
    }

    func testParserRecoversFunctionStartsLoadCommand() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_FUNCTION_STARTS",
            "LC_MAIN"
        ])
        XCTAssertEqual(machO.functionStarts.map(\.offsetFromImageBase), [
            UInt64(fixture.codeOffset),
            UInt64(fixture.codeOffset + 0x1c)
        ])
        XCTAssertEqual(machO.functionStarts.map(\.address), [
            fixture.baseAddress,
            fixture.baseAddress + 0x1c
        ])
    }

    func testParserDetectsExceptionAndUnwindMetadata() throws {
        let fixture = MachOFixture.makeExecutableWithExceptionMetadata()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_SEGMENT_64",
            "LC_FUNCTION_STARTS",
            "LC_MAIN"
        ])

        let metadata = machO.exceptionMetadata
        XCTAssertFalse(metadata.isEmpty)
        XCTAssertEqual(metadata.sections.map(\.qualifiedName), [
            "__TEXT,__unwind_info",
            "__TEXT,__eh_frame",
            "__TEXT,__gcc_except_tab",
            "__LD,__compact_unwind"
        ])
        XCTAssertEqual(metadata.sections.map(\.kind), [
            .unwindInfo,
            .dwarfEHFrame,
            .languageSpecificData,
            .compactUnwind
        ])
        XCTAssertEqual(metadata.totalByteCount, UInt64(
            fixture.unwindInfoSize
                + fixture.ehFrameSize
                + fixture.exceptionTableSize
                + fixture.compactUnwindSize
        ))

        let unwindInfo = try XCTUnwrap(metadata.sections.first { $0.kind == .unwindInfo })
        XCTAssertEqual(unwindInfo.address, fixture.unwindInfoAddress)
        XCTAssertEqual(unwindInfo.fileOffset, fixture.unwindInfoOffset)
        XCTAssertEqual(unwindInfo.endFileOffset, UInt64(fixture.unwindInfoOffset) + UInt64(fixture.unwindInfoSize))
        XCTAssertNil(unwindInfo.entrySize)
        XCTAssertNil(unwindInfo.entryCount)

        let unwindHeader = try XCTUnwrap(unwindInfo.unwindInfoHeader)
        XCTAssertEqual(unwindHeader.version, 1)
        XCTAssertEqual(unwindHeader.commonEncodingsArraySectionOffset, 28)
        XCTAssertEqual(unwindHeader.commonEncodingsArrayCount, 2)
        XCTAssertEqual(unwindHeader.personalityArraySectionOffset, 36)
        XCTAssertEqual(unwindHeader.personalityArrayCount, 1)
        XCTAssertEqual(unwindHeader.indexSectionOffset, 40)
        XCTAssertEqual(unwindHeader.indexCount, 2)

        let compactUnwind = try XCTUnwrap(metadata.sections.first { $0.kind == .compactUnwind })
        XCTAssertEqual(compactUnwind.address, fixture.compactUnwindAddress)
        XCTAssertEqual(compactUnwind.fileOffset, fixture.compactUnwindOffset)
        XCTAssertEqual(compactUnwind.entrySize, MachOConstants.compactUnwindEntrySize64)
        XCTAssertEqual(compactUnwind.entryCount, 2)
        XCTAssertEqual(metadata.compactUnwindEntryCount, 2)

        XCTAssertEqual(metadata.relatedLoadCommands.map(\.name), ["LC_FUNCTION_STARTS"])
        XCTAssertEqual(metadata.relatedLoadCommands.first?.dataOffset, fixture.functionStartsOffset)
        XCTAssertEqual(metadata.relatedLoadCommands.first?.dataSize, fixture.functionStartsSize)
    }

    func testImporterSurfacesExceptionMetadataDiagnostic() throws {
        let fixture = MachOFixture.makeExecutableWithExceptionMetadata()
        let fileURL = try writeTemporaryFile(named: "FixtureExceptionMetadataMachO", contents: fixture.bytes)

        let imported = try MachOImportService().importBinary(at: fileURL)
        let diagnostic = try XCTUnwrap(imported.diagnostics.first {
            $0.severity == .info && $0.code == "analysis.exceptionMetadata.detected"
        })

        XCTAssertTrue(diagnostic.message.contains("__TEXT,__unwind_info"))
        XCTAssertTrue(diagnostic.message.contains("__TEXT,__eh_frame"))
        XCTAssertTrue(diagnostic.message.contains("__LD,__compact_unwind"))
        XCTAssertTrue(diagnostic.message.contains("2 compact unwind rows"))
        XCTAssertTrue(diagnostic.message.contains("__unwind_info header v1"))
        XCTAssertTrue(diagnostic.message.contains("LC_FUNCTION_STARTS"))
    }

    func testParserRecoversSymbolsImportsAndExportsFromMachOTables() throws {
        let fixture = MachOFixture.makeExecutableWithSymbols()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_LOAD_DYLIB",
            "LC_SYMTAB",
            "LC_DYSYMTAB",
            "LC_DYLD_INFO_ONLY",
            "LC_MAIN"
        ])
        let dylib = try XCTUnwrap(machO.dylibs.first)
        XCTAssertEqual(machO.dylibs.map(\.name), ["/usr/lib/libSystem.B.dylib"])
        XCTAssertEqual(dylib.displayName, "libSystem.B.dylib")
        XCTAssertEqual(dylib.ordinal, 1)
        XCTAssertEqual(dylib.commandName, "LC_LOAD_DYLIB")
        XCTAssertEqual(dylib.loadKind, "required")
        XCTAssertEqual(dylib.timestamp, 0x6650_1234)
        XCTAssertEqual(dylib.currentVersion.stringValue, "1400.0.29")
        XCTAssertEqual(dylib.compatibilityVersion.stringValue, "1.0.0")
        XCTAssertEqual(machO.symbols.map(\.name), ["_local_helper", "_exported_entry", "_puts"])
        XCTAssertEqual(machO.symbols.map(\.kind), [.local, .export, .import])
        XCTAssertEqual(machO.imports.map(\.name), ["_puts"])
        XCTAssertEqual(machO.imports.first?.libraryOrdinal, 1)
        XCTAssertEqual(machO.imports.first?.libraryName, "/usr/lib/libSystem.B.dylib")
        XCTAssertEqual(machO.exports.map(\.name), ["_exported_entry", "_trie_export"])
        XCTAssertEqual(machO.exports.first?.address, fixture.baseAddress)
        XCTAssertEqual(machO.exports.last?.source, "LC_DYLD_INFO")
    }

    /// Modern linkers emit LC_DYLD_EXPORTS_TRIE (a linkedit_data_command) INSTEAD of LC_DYLD_INFO,
    /// with the export trie as its payload. The parser must recover exports from it too — otherwise
    /// a modern dylib's exports are silently empty.
    func testParserRecoversExportsFromDyldExportsTrieCommand() throws {
        let fixture = MachOFixture.makeExecutableWithSymbols(useExportsTrieCommand: true)
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertTrue(machO.loadCommands.map(\.name).contains("LC_DYLD_EXPORTS_TRIE"),
                      "the load command must be recognized by name")
        // `_exported_entry` from the symtab + `_trie_export` from the LC_DYLD_EXPORTS_TRIE trie.
        XCTAssertEqual(machO.exports.map(\.name), ["_exported_entry", "_trie_export"])
        XCTAssertEqual(machO.exports.last?.source, "LC_DYLD_EXPORTS_TRIE")
    }

    func testExportTrieRegularAddressesAreImageRelativeForBothCommands() throws {
        for modern in [false, true] {
            for base: UInt64 in [0, 0x1_0000_0000] {
                let fixture = MachOFixture.makeExecutableWithSymbols(useExportsTrieCommand: modern, imageBase: base)
                let parsed = try MachOParser().parse(fixture.bytes)
                XCTAssertEqual(parsed.exports.first { $0.name == "_trie_export" }?.address, fixture.baseAddress + 4)
            }
        }
    }

    func testExportTrieAbsoluteValuesAreNotRebasedAndOverflowHasNoAddress() throws {
        for modern in [false, true] {
            let absolute = MachOFixture.makeExecutableWithSymbols(useExportsTrieCommand: modern,
                exportFlags: 2, exportValue: 0x1234)
            XCTAssertEqual(try MachOParser().parse(absolute.bytes).exports.first { $0.name == "_trie_export" }?.address, 0x1234)
            let overflow = MachOFixture.makeExecutableWithSymbols(useExportsTrieCommand: modern,
                exportValue: UInt64.max)
            let exported = try XCTUnwrap(MachOParser().parse(overflow.bytes).exports.first { $0.name == "_trie_export" })
            XCTAssertNil(exported.address)
        }
    }

    func testParserRecoversImportedStubsFromIndirectSymbolTable() throws {
        let fixture = MachOFixture.makeExecutableWithImportedStubs()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.loadCommands.map(\.name), [
            "LC_SEGMENT_64",
            "LC_SEGMENT_64",
            "LC_LOAD_DYLIB",
            "LC_SYMTAB",
            "LC_DYSYMTAB",
            "LC_MAIN"
        ])
        XCTAssertEqual(machO.sections.map(\.sectionName), ["__text", "__stubs", "__la_symbol_ptr"])
        XCTAssertEqual(machO.imports.map(\.name), ["_puts"])

        let stubSection = try XCTUnwrap(machO.sections.first { $0.sectionName == "__stubs" })
        XCTAssertEqual(stubSection.reserved1, 0)
        XCTAssertEqual(stubSection.reserved2, 12)
        let pointerSection = try XCTUnwrap(machO.sections.first { $0.sectionName == "__la_symbol_ptr" })
        XCTAssertEqual(pointerSection.reserved1, 1)

        XCTAssertEqual(machO.indirectSymbols.map(\.kind), [.symbolStub, .lazySymbolPointer])
        XCTAssertEqual(machO.indirectSymbols.map(\.sourceSection), ["__TEXT,__stubs", "__DATA,__la_symbol_ptr"])
        XCTAssertEqual(machO.indirectSymbols.map(\.address), [
            fixture.stubAddress,
            fixture.lazyPointerAddress
        ])
        XCTAssertEqual(machO.indirectSymbols.map(\.entrySize), [12, 8])
        XCTAssertEqual(machO.indirectSymbols.map(\.tableIndex), [0, 1])
        XCTAssertEqual(machO.indirectSymbols.compactMap(\.symbolIndex), [0, 0])
        XCTAssertEqual(machO.indirectSymbols.compactMap(\.symbolName), ["_puts", "_puts"])
        XCTAssertEqual(machO.indirectSymbols.compactMap(\.libraryName), [
            "/usr/lib/libSystem.B.dylib",
            "/usr/lib/libSystem.B.dylib"
        ])
        XCTAssertTrue(machO.indirectSymbols.allSatisfy { !$0.isLocal && !$0.isAbsolute })
    }

    func testParserRecoversCStringLiteralsFromTextCStringSection() throws {
        let fixture = MachOFixture.makeExecutableWithCStringLiterals()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.sections.map(\.sectionName), ["__text", "__cstring"])
        XCTAssertEqual(machO.stringLiterals.map(\.value), [
            "Usage: MacScope <binary>",
            "Analyze Objective-C metadata"
        ])
        XCTAssertEqual(machO.stringLiterals.map(\.sourceSection), ["__TEXT,__cstring", "__TEXT,__cstring"])
        XCTAssertEqual(machO.stringLiterals.map(\.byteLength), [24, 28])
        XCTAssertEqual(machO.stringLiterals.first?.address, fixture.stringLiteralAddress)
    }

    func testParserRecoversObjectiveCAndSwiftMetadataSections() throws {
        let fixture = MachOFixture.makeExecutableWithObjectiveCAndSwiftMetadata()
        let machO = try MachOParser().parse(fixture.bytes)

        XCTAssertEqual(machO.objectiveCMetadata.selectorStrings.map(\.value), [
            "viewDidLoad",
            "setRepresentedObject:"
        ])
        XCTAssertEqual(machO.objectiveCMetadata.classNameStrings.map(\.value), [
            "AppDelegate",
            "DocumentViewController"
        ])
        XCTAssertEqual(machO.objectiveCMetadata.methodTypeStrings, [])
        XCTAssertEqual(machO.objectiveCMetadata.selectorStrings.first?.sourceSection, "__TEXT,__objc_methname")
        XCTAssertEqual(machO.objectiveCMetadata.selectorStrings.first?.address, fixture.selectorStringAddress)
        XCTAssertEqual(machO.objectiveCMetadata.classNameStrings.first?.address, fixture.classNameStringAddress)
        let selectorStringAddress = try XCTUnwrap(fixture.selectorStringAddress)
        let classNameStringAddress = try XCTUnwrap(fixture.classNameStringAddress)
        XCTAssertEqual(machO.objectiveCMetadata.selectorReferences.map(\.resolvedName), [
            "viewDidLoad",
            "setRepresentedObject:"
        ])
        XCTAssertEqual(machO.objectiveCMetadata.selectorReferences.map(\.targetAddress), [
            selectorStringAddress,
            selectorStringAddress + UInt64("viewDidLoad".utf8.count + 1)
        ])
        XCTAssertEqual(machO.objectiveCMetadata.selectorReferences.first?.sourceAddress, fixture.selectorReferenceAddress)
        XCTAssertEqual(machO.objectiveCMetadata.selectorReferences.first?.sourceSection, "__DATA_CONST,__objc_selrefs")
        XCTAssertEqual(machO.objectiveCMetadata.classReferences.map(\.resolvedName), [
            "AppDelegate",
            "DocumentViewController"
        ])
        XCTAssertEqual(machO.objectiveCMetadata.classReferences.first?.sourceAddress, fixture.classReferenceAddress)
        XCTAssertEqual(machO.objectiveCMetadata.classReferences.first?.targetAddress, classNameStringAddress)
        XCTAssertEqual(machO.objectiveCMetadata.classReferences.first?.sourceSection, "__DATA_CONST,__objc_classrefs")

        XCTAssertEqual(machO.objectiveCMetadata.sections.map(\.qualifiedName), [
            "__TEXT,__objc_methname",
            "__TEXT,__objc_classname",
            "__DATA_CONST,__objc_selrefs",
            "__DATA_CONST,__objc_classrefs"
        ])
        XCTAssertEqual(machO.objectiveCMetadata.sections.map(\.kind), [
            "Objective-C selector names",
            "Objective-C class names",
            "Objective-C selector references",
            "Objective-C class references"
        ])
        XCTAssertEqual(machO.objectiveCMetadata.sections.compactMap(\.entryCount), [2, 2, 2, 2])
        XCTAssertEqual(machO.objectiveCMetadata.sections.map(\.entrySize), [nil, nil, 8, 8])

        XCTAssertEqual(machO.swiftMetadataSections.map(\.qualifiedName), [
            "__TEXT,__swift5_types",
            "__TEXT,__swift5_proto"
        ])
        XCTAssertEqual(machO.swiftMetadataSections.map(\.kind), [
            "Swift type descriptors",
            "Swift protocol descriptors"
        ])
        XCTAssertEqual(machO.swiftMetadataSections.compactMap(\.entrySize), [4, 4])
        XCTAssertEqual(machO.swiftMetadataSections.compactMap(\.entryCount), [2, 1])
    }

    func testParserRecoversImportsFromSystemMachOFixture() throws {
        let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls is not readable on this host")
        }

        let machO = try MachOParser().parse(Data(contentsOf: systemBinaryURL))

        XCTAssertGreaterThan(machO.symbols.count, 0)
        XCTAssertGreaterThan(machO.imports.count, 0)
        XCTAssertTrue(machO.imports.contains { $0.libraryName?.contains("libSystem") == true })
        XCTAssertTrue(machO.imports.contains { ["_printf", "_puts", "_exit"].contains($0.name) })
    }

    func testARM64DecoderRecognizesCoreInstructionSubset() {
        let fixture = MachOFixture.makeExecutable()
        let rows = ARM64Decoder().decode(fixture.code, baseAddress: fixture.baseAddress)

        XCTAssertEqual(rows.map(\.mnemonic), ["sub", "stp", "add", "ldr", "str", "mov", "bl", "ret"])
        XCTAssertEqual(rows[0].operands, "sp, sp, #0x20")
        XCTAssertEqual(rows[1].operands, "x29, x30, [sp, #0x10]")
        XCTAssertEqual(rows[2].operands, "x29, sp, #0x10")
        XCTAssertEqual(rows[3].operands, "x0, [x8]")
        XCTAssertEqual(rows[4].operands, "x0, [x8]")
        XCTAssertEqual(rows[5].operands, "w0, #0")
        XCTAssertEqual(rows[6].branchTarget, fixture.baseAddress + 0x1c)
        XCTAssertEqual(rows.last?.byteText, "c0 03 5f d6")
    }

    func testAnalysisEngineBuildsWorkspaceSnapshotFromRealMachOBytes() async throws {
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "FixtureMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.binaries.first?.name, "FixtureMachO")
        XCTAssertEqual(snapshot.binaries.first?.kind, "Mach-O executable")
        XCTAssertEqual(snapshot.binaries.first?.architecture, "arm64")
        XCTAssertEqual(snapshot.functions.first?.name, "_entry")
        XCTAssertEqual(snapshot.functions.first?.startAddress, fixture.baseAddress)
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [
            fixture.baseAddress,
            fixture.baseAddress + 0x1c
        ])
        XCTAssertEqual(snapshot.functions.map(\.name), [
            "_entry",
            "sub_\((fixture.baseAddress + 0x1c).hexAddress)"
        ])
        XCTAssertEqual(snapshot.basicBlocks.count, 2)
        XCTAssertEqual(snapshot.basicBlocks.map(\.startAddress), [fixture.baseAddress, fixture.baseAddress + 0x1c])
        XCTAssertEqual(snapshot.basicBlocks.map(\.instructionCount), [7, 1])
        XCTAssertEqual(snapshot.basicBlocks.map(\.functionID), snapshot.functions.map(\.id))
        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["sub", "stp", "add", "ldr", "str", "mov", "bl", "ret"])
        XCTAssertEqual(snapshot.instructions.first?.address, fixture.baseAddress)
        XCTAssertEqual(snapshot.instructions.first?.bytes, "ff 83 00 d1")
        XCTAssertFalse(snapshot.instructions.contains { $0.comment?.contains("Synthetic") == true })
        XCTAssertEqual(snapshot.xrefs.count, 1)
        XCTAssertEqual(snapshot.xrefs.first?.from, fixture.baseAddress + 0x18)
        XCTAssertEqual(snapshot.xrefs.first?.to, fixture.baseAddress + 0x1c)
        XCTAssertEqual(snapshot.controlFlowEdges.count, 1)
        XCTAssertEqual(snapshot.controlFlowEdges.first?.kind, "call")
        XCTAssertEqual(snapshot.controlFlowEdges.first?.from, fixture.baseAddress + 0x18)
        XCTAssertEqual(snapshot.controlFlowEdges.first?.to, fixture.baseAddress + 0x1c)
        XCTAssertEqual(snapshot.hexBytes, fixture.bytes)
    }

    // MARK: - Override-driven re-analysis (mark-as-data re-drives the analysis)

    @MainActor
    func testAnalysisHonorsMarkAsDataOverride() throws {
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "FixtureOverride", contents: fixture.bytes)
        let engine = AnalysisEngine()
        let blAddress = fixture.baseAddress + 0x18   // the `bl` instruction (one call xref + edge)

        let base = try engine.analyze(url: fileURL)
        XCTAssertEqual(base.xrefs.count, 1)
        XCTAssertEqual(base.controlFlowEdges.count, 1)
        let baseBlockInstructions = base.basicBlocks.map(\.instructionCount).reduce(0, +)

        // Marking the `bl` as DATA must re-drive every analysis pass: the call xref and
        // CFG edge disappear and the instruction is excluded from the basic blocks — yet
        // the row is still present for the listing, and the override rides the result.
        let marked = try engine.analyze(url: fileURL, overrides: [blAddress: AddressOverride(isData: true)])
        XCTAssertTrue(marked.xrefs.isEmpty, "the call xref from the data-marked bl is gone")
        XCTAssertTrue(marked.controlFlowEdges.isEmpty, "the CFG edge from the data-marked bl is gone")
        XCTAssertEqual(marked.basicBlocks.map(\.instructionCount).reduce(0, +), baseBlockInstructions - 1,
                       "the data-marked instruction is excluded from the basic blocks")
        XCTAssertTrue(marked.instructions.contains { $0.address == blAddress }, "the row is still in the listing")
        XCTAssertEqual(marked.addressOverrides[.primary(blAddress)]?.isData, true, "the override rides the re-analyzed snapshot")
    }

    @MainActor
    func testStoreReanalyzesOnMarkAsDataAndUndo() async throws {
        // End-to-end through the store: marking a call instruction as data re-drives the
        // analysis (the call xref disappears), and Undo re-flows it back. The override applies
        // synchronously; the derived re-flow runs off the main actor, so the derived assertions
        // await it (the interactive UI lets it land behind the "Re-analyzing…" indicator).
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let snapshot = try AnalysisEngine().analyze(url: lsURL)
        guard let callFrom = snapshot.xrefs.first(where: { $0.kind == "call" })?.from else { throw XCTSkip("no call xref") }
        let store = WorkspaceStore(workspaceName: "ls", snapshot: snapshot, engine: AnalysisEngine())
        XCTAssertTrue(store.snapshot.xrefs.contains { $0.from == callFrom })

        store.setIsData(callFrom, true)
        await store.awaitPendingReanalysis()
        XCTAssertFalse(store.snapshot.xrefs.contains { $0.from == callFrom }, "store re-analyzed: the call xref is gone")
        XCTAssertTrue(store.snapshot.instructions.contains { $0.address == callFrom }, "the row is still present")

        store.undoManager.undo()
        await store.awaitPendingReanalysis()
        XCTAssertTrue(store.snapshot.xrefs.contains { $0.from == callFrom }, "undo re-flowed: the call xref is back")
        XCTAssertNil(store.snapshot.addressOverrides[.primary(callFrom)], "the override was undone")
    }

    // MARK: - v22: Mark-as-Undefined re-drive + Patch re-decode

    @MainActor
    func testAnalysisHonorsMarkAsUndefinedOverride() throws {
        // Mark-as-Undefined excludes the address from every code pass, exactly like
        // mark-as-data — the call xref and CFG edge from the undefined `bl` disappear.
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "FixtureUndefined", contents: fixture.bytes)
        let engine = AnalysisEngine()
        let blAddress = fixture.baseAddress + 0x18

        let base = try engine.analyze(url: fileURL)
        XCTAssertEqual(base.xrefs.count, 1)

        let marked = try engine.analyze(url: fileURL, overrides: [blAddress: AddressOverride(isUndefined: true)])
        XCTAssertTrue(marked.xrefs.isEmpty, "the call xref from the undefined bl is gone")
        XCTAssertTrue(marked.controlFlowEdges.isEmpty, "the CFG edge from the undefined bl is gone")
        XCTAssertTrue(marked.instructions.contains { $0.address == blAddress }, "the row is still in the listing")
        XCTAssertEqual(marked.addressOverrides[.primary(blAddress)]?.isUndefined, true)
    }

    @MainActor
    func testAnalysisReDecodesPatchedBytes() throws {
        // Patching the first instruction (`sub sp, ...` -> NOP) re-decodes that row from the
        // patched bytes: the mnemonic becomes `nop` while the address is preserved.
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "FixturePatch", contents: fixture.bytes)
        let engine = AnalysisEngine()
        let target = fixture.baseAddress // first instruction "ff 83 00 d1" (sub)

        let base = try engine.analyze(url: fileURL)
        XCTAssertEqual(base.instructions.first { $0.address == target }?.mnemonic, "sub")

        let patched = try engine.analyze(url: fileURL, overrides: [target: AddressOverride(patch: BytePatch.arm64NOP)])
        let row = patched.instructions.first { $0.address == target }
        XCTAssertEqual(row?.mnemonic, "nop", "the patched row re-decoded to the new encoding")
        XCTAssertEqual(row?.bytes, "1f 20 03 d5", "the row carries the patched bytes")
        XCTAssertEqual(patched.patch(at: target), BytePatch.arm64NOP)
    }

    @MainActor
    func testStoreReanalyzesOnMarkAsUndefinedAndUndo() async throws {
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let snapshot = try AnalysisEngine().analyze(url: lsURL)
        guard let callFrom = snapshot.xrefs.first(where: { $0.kind == "call" })?.from else { throw XCTSkip("no call xref") }
        let store = WorkspaceStore(workspaceName: "ls", snapshot: snapshot, engine: AnalysisEngine())

        store.setMarkAsUndefined(callFrom, true)
        await store.awaitPendingReanalysis()
        XCTAssertFalse(store.snapshot.xrefs.contains { $0.from == callFrom }, "store re-analyzed: the call xref is gone")
        XCTAssertTrue(store.snapshot.isUndefined(at: callFrom))
        store.undoManager.undo()
        await store.awaitPendingReanalysis()
        XCTAssertTrue(store.snapshot.xrefs.contains { $0.from == callFrom }, "undo re-flowed the call xref")
        XCTAssertFalse(store.snapshot.isUndefined(at: callFrom))
    }

    @MainActor
    func testStorePatchAndClearReDecodesAndUndoes() async throws {
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let snapshot = try AnalysisEngine().analyze(url: lsURL)
        guard let target = snapshot.instructions.first(where: { $0.mnemonic != "nop" })?.address else { throw XCTSkip("no instruction") }
        let store = WorkspaceStore(workspaceName: "ls", snapshot: snapshot, engine: AnalysisEngine())

        XCTAssertTrue(store.patchBytes(target, hex: "1f 20 03 d5"))
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.instructions.first { $0.address == target }?.mnemonic, "nop")
        XCTAssertEqual(store.snapshot.patch(at: target), BytePatch.arm64NOP)

        // Invalid hex is rejected (no patch applied at a fresh address) — no re-flow kicked.
        XCTAssertFalse(store.patchBytes(target, hex: "xyz"))

        store.clearPatch(target)
        await store.awaitPendingReanalysis()
        XCTAssertNil(store.snapshot.patch(at: target))
        store.undoManager.undo() // undo the clear -> the patch returns
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.patch(at: target), BytePatch.arm64NOP)
    }

    @MainActor
    func testStoreManualXRefAndBookmarkUndoWithoutReanalysis() throws {
        let snapshot = WorkspaceSnapshot(
            binaries: [], functions: [],
            instructions: [InstructionRow(address: 0x1000, bytes: "", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)],
            xrefs: [XRef(id: UUID(), from: 0x1004, to: 0x2000, kind: XRefKind.call)],
            hexBytes: Data()
        )
        let store = WorkspaceStore(workspaceName: "manual", snapshot: snapshot, engine: AnalysisEngine())

        // Add + suppress are merged at query time.
        store.addManualXRef(from: 0x1000, to: 0x3000, kind: XRefKind.call)
        XCTAssertEqual(store.snapshot.effectiveXRefs(from: 0x1000).count, 1)
        store.suppressXRef(from: 0x1004, to: 0x2000, kind: XRefKind.call)
        XCTAssertTrue(store.snapshot.effectiveXRefs(from: 0x1004).isEmpty)
        store.undoManager.undo() // undo suppression
        XCTAssertEqual(store.snapshot.effectiveXRefs(from: 0x1004).count, 1)

        // Bookmarks add/remove + undo.
        store.addBookmark(at: 0x1000, name: "entry")
        XCTAssertEqual(store.snapshot.bookmark(at: 0x1000)?.name, "entry")
        store.removeBookmark(at: 0x1000)
        XCTAssertNil(store.snapshot.bookmark(at: 0x1000))
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.bookmark(at: 0x1000)?.name, "entry")
    }

    @MainActor
    func testReanalysisPreservesBinaryProvenanceBookmark() async throws {
        // Re-analysis rebuilds the BinaryImage, so the store-set security-scoped bookmark
        // must be re-attached — otherwise a routine mark-as-data would drop the provenance
        // and the next Save would persist nil. (Awaits the off-main re-flow so the assertion
        // observes the rebuilt-then-re-attached BinaryImage, not the pre-re-flow snapshot.)
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        var snapshot = try AnalysisEngine().analyze(url: lsURL)
        let bookmark = Data([0xBE, 0xEF])   // stand-in for a security-scoped bookmark
        snapshot.binaries[0].originalPathBookmark = bookmark
        guard let callFrom = snapshot.xrefs.first(where: { $0.kind == "call" })?.from else { throw XCTSkip("no call xref") }
        let store = WorkspaceStore(workspaceName: "ls", snapshot: snapshot, engine: AnalysisEngine())

        store.setIsData(callFrom, true)   // triggers re-analysis (rebuilds the BinaryImage)
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.binaries.first?.originalPathBookmark, bookmark, "re-analysis kept the provenance bookmark")
        store.undoManager.undo()
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.binaries.first?.originalPathBookmark, bookmark, "undo re-analysis kept it too")
    }

    @MainActor
    func testStoreMarkAsProcedureForcesAndUndoesAFunctionStart() async throws {
        // Mark as Procedure through the store re-drives function discovery: an interior
        // instruction becomes a function start, and Undo re-flows it away.
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let snapshot = try AnalysisEngine().analyze(url: lsURL)
        let starts = Set(snapshot.functions.map(\.startAddress))
        guard let interior = snapshot.instructions.map(\.address).first(where: { !starts.contains($0) }) else {
            throw XCTSkip("no interior instruction")
        }
        let store = WorkspaceStore(workspaceName: "ls", snapshot: snapshot, engine: AnalysisEngine())
        XCTAssertFalse(store.snapshot.functions.contains { $0.startAddress == interior })

        store.setMarkAsProcedure(interior, true)
        await store.awaitPendingReanalysis()
        XCTAssertTrue(store.snapshot.functions.contains { $0.startAddress == interior },
                      "store re-drove discovery: the forced procedure start appears")
        store.undoManager.undo()
        await store.awaitPendingReanalysis()
        XCTAssertFalse(store.snapshot.functions.contains { $0.startAddress == interior },
                       "undo re-flowed: the forced start is gone")
    }

    @MainActor
    func testHexByteReaderIsSectionAccurateOnARealBinary() throws {
        // The byte-anchoring fix: hexByteReader must map a virtual address through the
        // SECTION TABLE (not the broken `va - firstInstruction` linear assumption), so it
        // returns the REAL bytes at that address — not the Mach-O header.
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let snapshot = try AnalysisEngine().analyze(url: lsURL)
        guard let first = snapshot.instructions.first else { throw XCTSkip("no instructions") }
        let read = try XCTUnwrap(snapshot.hexByteReader()(first.address, 4))
        // The reader's bytes equal the decoder's instruction bytes — and are NOT the
        // Mach-O magic (cf fa ed fe), which the old linear mapping would have returned.
        let decoderBytes = first.bytes.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        XCTAssertEqual(Array(read), decoderBytes, "reader returns the real instruction bytes at its address")
        XCTAssertNotEqual(Array(read.prefix(4)), [0xcf, 0xfa, 0xed, 0xfe], "not the Mach-O header")
    }

    func testPseudocodeTargetExcludesDataMarkedRows() {
        let fnID = UUID()
        var snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "t", path: "/tmp/t", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: fnID, name: "_main", startAddress: 0x1000, endAddress: 0x1010, confidence: 0.9)],
            instructions: [
                InstructionRow(address: 0x1000, bytes: "e0 03 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data()
        )
        XCTAssertEqual(snapshot.pseudocodeTarget(selectedAddress: 0x1000)?.instructions.count, 2)
        // A data-marked row is excluded from the decompiler body (still in `instructions`).
        snapshot.addressOverrides[.primary(0x1004)] = AddressOverride(isData: true)
        let body = snapshot.pseudocodeTarget(selectedAddress: 0x1000)?.instructions
        XCTAssertEqual(body?.count, 1)
        XCTAssertEqual(body?.first?.address, 0x1000)
    }

    func testAnalysisEngineRoutesX86_64BinaryThroughTheX86Decoder() async throws {
        // An x86_64 Mach-O must load (the importer accepts it), decode through the
        // X86_64Decoder (selected by CPU type), and drive the SAME arch-neutral
        // pipeline: function discovery from the direct `call`, basic blocks split on
        // `ret`, a call xref, and a call-kind CFG edge.
        //   0x00 push %rbp          (55)
        //   0x01 mov %rsp,%rbp      (48 89 e5)
        //   0x04 call 0x0b          (e8 02 00 00 00)   -> target at +0xb
        //   0x09 leave              (c9)
        //   0x0a ret                (c3)
        //   0x0b xor %eax,%eax      (31 c0)            <- discovered callee
        //   0x0d ret                (c3)
        let code = Data([0x55, 0x48, 0x89, 0xE5, 0xE8, 0x02, 0x00, 0x00, 0x00,
                         0xC9, 0xC3, 0x31, 0xC0, 0xC3])
        let fixture = MachOFixture.makeExecutable(code: code, cpuType: MachOConstants.cpuTypeX86_64)
        let fileURL = try writeTemporaryFile(named: "FixtureX86MachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.binaries.first?.architecture, "x86_64")
        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["push", "mov", "call", "leave", "ret", "xor", "ret"])
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [fixture.baseAddress, fixture.baseAddress + 0x0b])
        XCTAssertEqual(snapshot.functions.map(\.name), ["_entry", "sub_\((fixture.baseAddress + 0x0b).hexAddress)"])
        XCTAssertEqual(snapshot.basicBlocks.map(\.startAddress), [fixture.baseAddress, fixture.baseAddress + 0x0b])
        XCTAssertEqual(snapshot.basicBlocks.map(\.instructionCount), [5, 2])
        XCTAssertEqual(snapshot.xrefs.count, 1)
        XCTAssertEqual(snapshot.xrefs.first?.kind, XRefKind.call)
        XCTAssertEqual(snapshot.xrefs.first?.from, fixture.baseAddress + 0x04)
        XCTAssertEqual(snapshot.xrefs.first?.to, fixture.baseAddress + 0x0b)
        XCTAssertEqual(snapshot.controlFlowEdges.map(\.kind), ["call"])
        XCTAssertEqual(snapshot.controlFlowEdges.first?.from, fixture.baseAddress + 0x04)
        XCTAssertEqual(snapshot.controlFlowEdges.first?.to, fixture.baseAddress + 0x0b)
    }

    func testAnalysisEngineAnalyzesThroughTheInjectedBinaryLoaderSeam() async throws {
        // The engine consumes only the neutral `LoadedBinary` — a non-Mach-O loader
        // (the path ELF/PE will take) drives the full pipeline. A stub loader hands
        // over arm64 `ret` bytes in a code section; the snapshot must reflect them
        // with no Mach-O parsing involved.
        let code = Data([0xC0, 0x03, 0x5F, 0xD6]) // ret
        let text = BinarySection(name: ".text", address: 0x4000, size: 4, fileOffset: 0, isExecutable: true)
        let loaded = LoadedBinary(
            name: "stub.elf", path: "/tmp/stub.elf", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64, fileTypeName: "Stub executable",
            architectureDisplayName: "arm64", metadata: .empty,
            bytes: code, sliceOffset: 0,
            sections: [text], executableTextSection: text, entryPointAddress: 0x4000,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [0x4000], objcSelectors: [:]
        )

        let engine = AnalysisEngine(loader: StubBinaryLoader(binary: loaded))
        let snapshot = try await engine.openBinary(url: URL(fileURLWithPath: "/tmp/stub.elf"))

        XCTAssertEqual(snapshot.binaries.first?.kind, "Stub executable")
        XCTAssertEqual(snapshot.binaries.first?.architecture, "arm64")
        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["ret"])
        XCTAssertEqual(snapshot.instructions.first?.address, 0x4000)
        XCTAssertEqual(snapshot.functions.first?.startAddress, 0x4000)
    }

    func testAnalysisEngineDecodesThroughTheInjectedDisassemblerSeam() async throws {
        // The engine must consume the injected `any Disassembler`, not a hardcoded
        // arm64 decoder — the seam that lets a second architecture plug in. A stub
        // decoder emits a sentinel instruction; it must be what the snapshot shows.
        let fixture = MachOFixture.makeExecutable()
        let fileURL = try writeTemporaryFile(named: "FixtureSeamMachO", contents: fixture.bytes)

        let engine = AnalysisEngine(decoder: SeamStubDisassembler())
        let snapshot = try await engine.openBinary(url: fileURL)

        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["seam_stub"])
        XCTAssertEqual(snapshot.instructions.first?.address, fixture.baseAddress) // == codeSection.address
        XCTAssertEqual(snapshot.instructions.first?.operands, "seam x0")
    }

    func testAnalysisEngineDecodesEntireTextSectionBeyondLegacyWindow() async throws {
        // The historical decoder window stopped after the first 1024 bytes
        // (256 instructions). Build a __text section larger than that and assert
        // every instruction is decoded so coverage is no longer truncated.
        let instructionCount = 400
        var code = Data()
        for _ in 0..<(instructionCount - 1) {
            code.appendUInt32LE(0xd503_201f) // nop
        }
        code.appendUInt32LE(0xd65f_03c0) // ret
        let fixture = MachOFixture.makeExecutable(code: code)
        let fileURL = try writeTemporaryFile(named: "FixtureLargeText", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertGreaterThan(instructionCount, 256, "fixture must exceed the legacy window")
        XCTAssertEqual(snapshot.instructions.count, instructionCount)
        XCTAssertEqual(
            snapshot.instructions.last?.address,
            fixture.baseAddress + UInt64((instructionCount - 1) * 4)
        )
        XCTAssertEqual(snapshot.instructions.last?.mnemonic, "ret")
    }

    func testAnalysisEngineHandlesSingleInstructionTextSection() async throws {
        // Degenerate merge-walk (cursor 0 -> scan 1) and binary-search base case
        // (index = low - 1 = 0): one instruction, one function, one block.
        let fixture = MachOFixture.makeExecutable(code: Data([0xc0, 0x03, 0x5f, 0xd6])) // ret
        let fileURL = try writeTemporaryFile(named: "FixtureSingleInstr", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["ret"])
        XCTAssertEqual(snapshot.functions.count, 1)
        XCTAssertEqual(snapshot.basicBlocks.count, 1)
        XCTAssertEqual(snapshot.basicBlocks.first?.startAddress, fixture.baseAddress)
        XCTAssertEqual(snapshot.basicBlocks.first?.endAddress, fixture.baseAddress + 4)
        XCTAssertEqual(snapshot.basicBlocks.first?.instructionCount, 1)
        XCTAssertEqual(snapshot.basicBlocks.first?.functionID, snapshot.functions.first?.id)
        XCTAssertTrue(snapshot.controlFlowEdges.isEmpty)
    }

    func testAnalysisEngineBuildsConditionalAndUnconditionalBranchCFGEdges() async throws {
        let fixture = MachOFixture.makeExecutableWithConditionalBranches()
        let fileURL = try writeTemporaryFile(named: "FixtureBranchCFG", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["mov", "cbz", "mov", "b", "mov", "ret"])
        XCTAssertEqual(snapshot.basicBlocks.map(\.startAddress), [
            fixture.baseAddress,
            fixture.baseAddress + 0x8,
            fixture.baseAddress + 0x10,
            fixture.baseAddress + 0x14
        ])
        XCTAssertEqual(snapshot.basicBlocks.map(\.instructionCount), [2, 2, 1, 1])
        XCTAssertEqual(
            snapshot.controlFlowEdges.map { "\($0.kind):\($0.from.hexAddress)->\($0.to.hexAddress)" },
            [
                "branch:\((fixture.baseAddress + 0x4).hexAddress)->\((fixture.baseAddress + 0x10).hexAddress)",
                "fallthrough:\((fixture.baseAddress + 0x4).hexAddress)->\((fixture.baseAddress + 0x8).hexAddress)",
                "branch:\((fixture.baseAddress + 0xc).hexAddress)->\((fixture.baseAddress + 0x14).hexAddress)",
                // The `mov` block at +0x10 ends only because +0x14 is a join (the `b` target);
                // control still falls into it.
                "fallthrough:\((fixture.baseAddress + 0x10).hexAddress)->\((fixture.baseAddress + 0x14).hexAddress)"
            ]
        )
    }

    func testAnalysisEngineDecodesSelectedUniversalArm64Slice() async throws {
        let fixture = MachOFixture.makeUniversalExecutable()
        let fileURL = try writeTemporaryFile(named: "FixtureUniversalMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.binaries.first?.architecture, "arm64 (universal slice 2/2 @ 0x40)")
        XCTAssertEqual(snapshot.functions.first?.name, "_entry")
        XCTAssertEqual(snapshot.functions.first?.startAddress, fixture.baseAddress)
        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["sub", "stp", "add", "ldr", "str", "mov", "bl", "ret"])
        XCTAssertEqual(snapshot.instructions.first?.address, fixture.baseAddress)
        XCTAssertEqual(snapshot.instructions.first?.bytes, "ff 83 00 d1")
        XCTAssertEqual(Data(snapshot.hexBytes.prefix(4)), Data([0xcf, 0xfa, 0xed, 0xfe]))
    }

    func testAnalysisEngineLoadsExplicitlyRequestedUniversalSlice() async throws {
        let fixture = MachOFixture.makeUniversalDualExecutable()
        let fileURL = try writeTemporaryFile(named: "FixtureUniversalDual", contents: fixture.bytes)

        // Default open prefers arm64 (slice 1).
        let arm64Snapshot = try await AnalysisEngine().openBinary(url: fileURL)
        XCTAssertEqual(arm64Snapshot.binaries.first?.architecture, "arm64 (universal slice 2/2 @ 0x\(String(fixture.arm64SliceOffset, radix: 16)))")
        XCTAssertNil(arm64Snapshot.binaries.first?.selectedSliceIndex)

        // Explicit request for slice 0 loads the x86_64 slice and records the pick on the
        // BinaryImage so re-analysis/restore can preserve it.
        let x86Snapshot = try await AnalysisEngine().openBinary(url: fileURL, requestedSliceIndex: 0)
        let x86Architecture = try XCTUnwrap(x86Snapshot.binaries.first?.architecture)
        XCTAssertTrue(x86Architecture.hasPrefix("x86_64 (universal slice 1/2 @ 0x"), x86Architecture)
        XCTAssertEqual(x86Snapshot.binaries.first?.selectedSliceIndex, 0)
    }

    func testAnalysisEngineThreadsRecoveredSymbolsIntoWorkspaceSnapshot() async throws {
        let fixture = MachOFixture.makeExecutableWithSymbols()
        let fileURL = try writeTemporaryFile(named: "FixtureSymbolsMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.symbols.map(\.name), ["_local_helper", "_exported_entry", "_puts"])
        XCTAssertEqual(snapshot.symbols.map(\.kind), ["local", "export", "import"])
        XCTAssertEqual(snapshot.imports.map(\.name), ["_puts"])
        XCTAssertEqual(snapshot.imports.first?.libraryName, "/usr/lib/libSystem.B.dylib")
        XCTAssertEqual(snapshot.exports.map(\.name), ["_exported_entry", "_trie_export"])
        XCTAssertEqual(snapshot.exports.map(\.source), ["LC_SYMTAB", "LC_DYLD_INFO"])
    }

    func testAnalysisEngineThreadsRecoveredIndirectSymbolsIntoWorkspaceSnapshot() async throws {
        let fixture = MachOFixture.makeExecutableWithImportedStubs()
        let fileURL = try writeTemporaryFile(named: "FixtureImportedStubsMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.imports.map(\.name), ["_puts"])
        XCTAssertEqual(snapshot.indirectSymbols.map(\.kind), ["symbolStub", "lazySymbolPointer"])
        XCTAssertEqual(snapshot.indirectSymbols.map(\.sourceSection), ["__TEXT,__stubs", "__DATA,__la_symbol_ptr"])
        XCTAssertEqual(snapshot.indirectSymbols.map(\.address), [
            fixture.stubAddress,
            fixture.lazyPointerAddress
        ])
        XCTAssertEqual(snapshot.indirectSymbols.map(\.entrySize), [12, 8])
        XCTAssertEqual(snapshot.indirectSymbols.map(\.tableIndex), [0, 1])
        XCTAssertEqual(snapshot.indirectSymbols.map(\.rawSymbolIndex), [0, 0])
        XCTAssertEqual(snapshot.indirectSymbols.compactMap(\.symbolIndex), [0, 0])
        XCTAssertEqual(snapshot.indirectSymbols.compactMap(\.symbolName), ["_puts", "_puts"])
        XCTAssertEqual(snapshot.indirectSymbols.compactMap(\.libraryName), [
            "/usr/lib/libSystem.B.dylib",
            "/usr/lib/libSystem.B.dylib"
        ])
        XCTAssertTrue(snapshot.indirectSymbols.allSatisfy { !$0.isLocal && !$0.isAbsolute })
    }

    func testAnalysisEngineThreadsRecoveredStringLiteralsIntoWorkspaceSnapshot() async throws {
        let fixture = MachOFixture.makeExecutableWithCStringLiterals()
        let fileURL = try writeTemporaryFile(named: "FixtureStringsMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.stringLiterals.map(\.value), [
            "Usage: MacScope <binary>",
            "Analyze Objective-C metadata"
        ])
        XCTAssertEqual(snapshot.stringLiterals.first?.sourceSection, "__TEXT,__cstring")
        XCTAssertEqual(snapshot.stringLiterals.first?.address, fixture.stringLiteralAddress)
    }

    func testAnalysisEngineThreadsRecoveredObjectiveCStringMetadataIntoWorkspaceSnapshot() async throws {
        let fixture = MachOFixture.makeExecutableWithObjectiveCAndSwiftMetadata()
        let fileURL = try writeTemporaryFile(named: "FixtureObjectiveCMetadataMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.stringLiterals.map(\.value), [
            "viewDidLoad",
            "setRepresentedObject:",
            "AppDelegate",
            "DocumentViewController"
        ])
        XCTAssertEqual(snapshot.stringLiterals.map(\.sourceSection), [
            "__TEXT,__objc_methname",
            "__TEXT,__objc_methname",
            "__TEXT,__objc_classname",
            "__TEXT,__objc_classname"
        ])
    }

    func testAnalysisEngineThreadsRecoveredLoadCommandMetadataIntoWorkspaceSnapshot() async throws {
        let fixture = MachOFixture.makeExecutableWithLoadCommandMetadata()
        let fileURL = try writeTemporaryFile(named: "FixtureMetadataMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)
        let metadata = try XCTUnwrap(snapshot.binaries.first?.metadata)

        XCTAssertEqual(metadata.uuid, "12345678-9abc-def0-1234-56789abcdef0")
        XCTAssertEqual(metadata.platformName, "macOS")
        XCTAssertEqual(metadata.minimumOSVersion, "14.5")
        XCTAssertEqual(metadata.sdkVersion, "15.0")
        XCTAssertEqual(metadata.buildTools, [
            "swift 6.4",
            "ld 1200.0"
        ])
    }

    func testAnalysisEngineThreadsLegacyMinimumOSVersionIntoWorkspaceSnapshot() async throws {
        let fixture = MachOFixture.makeExecutableWithLegacyMinimumOSVersion()
        let fileURL = try writeTemporaryFile(named: "FixtureLegacyVersionMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)
        let metadata = try XCTUnwrap(snapshot.binaries.first?.metadata)

        XCTAssertEqual(metadata.platformName, "macOS")
        XCTAssertEqual(metadata.minimumOSVersion, "10.13.6")
        XCTAssertEqual(metadata.sdkVersion, "11.0")
        XCTAssertEqual(metadata.buildTools, [])
    }

    func testAnalysisEngineOpensMachOWithRPathsAndCodeSignatureMetadata() async throws {
        let fixture = MachOFixture.makeExecutableWithRPathsAndCodeSignature()
        let fileURL = try writeTemporaryFile(named: "FixtureRPathSignedMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.binaries.first?.name, "FixtureRPathSignedMachO")
        XCTAssertEqual(snapshot.functions.first?.startAddress, fixture.baseAddress)
        XCTAssertEqual(snapshot.instructions.last?.mnemonic, "ret")
        XCTAssertEqual(snapshot.hexBytes, fixture.bytes)
    }

    func testAnalysisEngineUsesFunctionStartsForFunctionDiscovery() async throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let fileURL = try writeTemporaryFile(named: "FixtureFunctionStartsMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.functions.map(\.startAddress), [
            fixture.baseAddress,
            fixture.baseAddress + 0x1c
        ])
        XCTAssertEqual(snapshot.functions.map(\.name), [
            "_entry",
            "sub_\((fixture.baseAddress + 0x1c).hexAddress)"
        ])
        XCTAssertEqual(snapshot.functions.first?.endAddress, fixture.baseAddress + 0x1c)
        XCTAssertEqual(snapshot.functions.last?.endAddress, fixture.baseAddress + UInt64(fixture.code.count))
        XCTAssertEqual(snapshot.basicBlocks.first?.functionID, snapshot.functions.first?.id)
    }

    func testAnalysisEngineRecoversDirectCallTargetsInsideExecutableText() async throws {
        let fixture = MachOFixture.makeExecutableWithInternalAndExternalDirectCalls()
        let fileURL = try writeTemporaryFile(named: "FixtureDirectCallRecoveryMachO", contents: fixture.bytes)

        let snapshot = try await AnalysisEngine().openBinary(url: fileURL)

        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["mov", "bl", "bl", "ret", "sub", "mov", "ret"])
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [
            fixture.baseAddress,
            fixture.baseAddress + 0x10
        ])
        XCTAssertFalse(snapshot.functions.contains { $0.startAddress == fixture.baseAddress + UInt64(fixture.code.count) })
        XCTAssertEqual(snapshot.functions.map(\.name), [
            "_entry",
            "sub_\((fixture.baseAddress + 0x10).hexAddress)"
        ])
        XCTAssertEqual(snapshot.functions.last?.confidence, 0.62)
        XCTAssertEqual(snapshot.basicBlocks.map(\.startAddress), [
            fixture.baseAddress,
            fixture.baseAddress + 0x10
        ])
    }

    func testImporterResolvesAppBundleExecutableFromInfoPlist() async throws {
        let fixture = MachOFixture.makeExecutable()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = temporaryDirectory.appendingPathComponent("Fixture.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "FixtureExecutable",
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let executableURL = macOSURL.appendingPathComponent("FixtureExecutable")
        try fixture.bytes.write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let resolved = try MachOImportService().resolveExecutable(at: appURL)
        XCTAssertEqual(resolved.executableURL, executableURL)
        XCTAssertTrue(resolved.isBundle)

        let snapshot = try await AnalysisEngine().openBinary(url: appURL)
        XCTAssertEqual(snapshot.binaries.first?.name, "Fixture.app")
        XCTAssertEqual(snapshot.binaries.first?.kind, "app bundle")
        XCTAssertEqual(snapshot.instructions.last?.mnemonic, "ret")
    }

    private func writeTemporaryFile(named name: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    private func readMachOImportFixtureUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return (0..<4).reduce(UInt32(0)) { value, index in
            value | (UInt32(data[offset + index]) << UInt32(index * 8))
        }
    }
}

/// A stand-in `Disassembler` that proves `AnalysisEngine` decodes through the
/// injected seam rather than a hardcoded arm64 decoder.
private struct SeamStubDisassembler: Disassembler {
    func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int) -> [DecodedInstruction] {
        [DecodedInstruction(address: baseAddress, bytes: [0xff], mnemonic: "seam_stub", operands: "seam x0", branchTarget: nil, comment: nil)]
    }
}

/// A non-Mach-O `BinaryLoader` — proves the engine analyzes purely from the neutral
/// `LoadedBinary`, which is exactly how an ELF/PE loader will plug in.
private struct StubBinaryLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func replaceUInt32BE(at offset: Int, with value: UInt32) {
        self[offset] = UInt8((value >> 24) & 0xff)
        self[offset + 1] = UInt8((value >> 16) & 0xff)
        self[offset + 2] = UInt8((value >> 8) & 0xff)
        self[offset + 3] = UInt8(value & 0xff)
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func replaceUInt32LE(at offset: Int, with value: UInt32) {
        let base = startIndex + offset
        self[base] = UInt8(value & 0xff)
        self[base + 1] = UInt8((value >> 8) & 0xff)
        self[base + 2] = UInt8((value >> 16) & 0xff)
        self[base + 3] = UInt8((value >> 24) & 0xff)
    }

    mutating func replaceUInt16LE(at offset: Int, with value: UInt16) {
        let base = startIndex + offset
        self[base] = UInt8(value & 0xff)
        self[base + 1] = UInt8((value >> 8) & 0xff)
    }

    mutating func replaceUInt64LE(at offset: Int, with value: UInt64) {
        let base = startIndex + offset
        for index in 0..<8 { self[base + index] = UInt8((value >> UInt64(index * 8)) & 0xff) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 32) & 0xff))
        append(UInt8((value >> 40) & 0xff))
        append(UInt8((value >> 48) & 0xff))
        append(UInt8((value >> 56) & 0xff))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendFixedCString(_ string: String, length: Int) {
        let bytes = Array(string.utf8.prefix(length))
        append(contentsOf: bytes)
        append(contentsOf: repeatElement(UInt8(0), count: Swift.max(0, length - bytes.count)))
    }

    mutating func appendNullTerminatedString(_ string: String) {
        append(contentsOf: string.utf8)
        append(0)
    }

    mutating func appendPadding(to targetCount: Int) {
        precondition(count <= targetCount)
        append(contentsOf: repeatElement(UInt8(0), count: targetCount - count))
    }

    mutating func appendSymbol(
        stringOffset: UInt32,
        type: UInt8,
        sectionIndex: UInt8,
        description: UInt16,
        value: UInt64
    ) {
        appendUInt32LE(stringOffset)
        append(type)
        append(sectionIndex)
        appendUInt16LE(description)
        appendUInt64LE(value)
    }

    mutating func appendRelocation(
        address: UInt32,
        symbolNumber: UInt32,
        isPCRelative: Bool,
        length: UInt8,
        isExternal: Bool,
        type: UInt8
    ) {
        var info = symbolNumber & MachOConstants.relocationSymbolNumberMask
        if isPCRelative {
            info |= MachOConstants.relocationPCRelativeMask
        }
        info |= UInt32(length & 0x3) << 25
        if isExternal {
            info |= MachOConstants.relocationExternalMask
        }
        info |= UInt32(type & 0xf) << 28

        appendUInt32LE(address)
        appendUInt32LE(info)
    }

    mutating func appendULEB128(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            append(byte)
        } while remaining != 0
    }
}

final class IPAImportTests: XCTestCase {
    private struct Member {
        var name: String
        var bytes: Data = Data()
        var mode: UInt32 = 0x8000
        var declaredSize: Int? = nil
        var method: UInt16 = 0
        var compressed: Data? = nil
    }
    private func archive(_ members: [Member], prefix: Data = Data()) -> Data {
        var data = prefix, central = Data()
        func word(_ value: UInt32, _ count: Int = 4) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        for member in members {
            let name = Data(member.name.utf8)
            let body = member.compressed ?? member.bytes
            let size = member.declaredSize ?? member.bytes.count
            var crc: UInt32 = 0xffffffff
            for byte in member.bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
            }
            crc ^= 0xffffffff
            let offset = data.count
            data += word(0x04034b50) + word(20, 2) + word(0, 2) + word(UInt32(member.method), 2)
            data += word(0) + word(crc) + word(UInt32(body.count)) + word(UInt32(size))
            data += word(UInt32(name.count), 2) + word(0, 2) + name + body
            central += word(0x02014b50) + word(0x0314, 2) + word(20, 2) + word(0, 2) + word(UInt32(member.method), 2)
            central += word(0) + word(crc) + word(UInt32(body.count)) + word(UInt32(size))
            central += word(UInt32(name.count), 2) + word(0, 2) + word(0, 2) + word(0, 2) + word(0, 2)
            central += word(member.mode << 16) + word(UInt32(offset)) + name
        }
        let start = data.count
        data += central
        data += word(0x06054b50) + word(0) + word(UInt32(members.count), 2) + word(UInt32(members.count), 2)
        data += word(UInt32(central.count)) + word(UInt32(start)) + word(0, 2)
        return data
    }
    private func members(executableName: String = "Main", encrypted: Bool = false) throws -> [Member] {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executableName], format: .xml, options: 0)
        let bytes = encrypted ? MachOFixture.makeExecutableWithEncryptionInfo(command: 0x2c, cryptID: 1).bytes : MachOFixture.makeExecutable().bytes
        return [Member(name: "Payload/Fixture.app/Info.plist", bytes: plist), Member(name: "Payload/Fixture.app/Main", bytes: bytes)]
    }
    private func removeImported(_ executable: URL) {
        IPAArchive.removeExtraction(at: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }
    func testFlatBundleAndIPAImportPreserveSourceAndReadOnlyExecutable() throws {
        let data = archive(try members())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).ipa")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try MachOImportService().importBinary(at: source)
        defer { removeImported(imported.executableURL) }
        XCTAssertTrue(imported.isBundle)
        XCTAssertEqual(imported.originalURL, source)
        XCTAssertEqual(imported.bytes, MachOFixture.makeExecutable().bytes)
        XCTAssertEqual(imported.executableURL.lastPathComponent, "Main")
        for url in [imported.executableURL, imported.executableURL.deletingLastPathComponent()] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o222, 0)
        }
        XCTAssertEqual(try MachOImportService().resolveExecutable(at: imported.executableURL.deletingLastPathComponent()).executableURL, imported.executableURL)
    }
    func testExtensionlessArchiveAndCapturedBytesUseArchiveAuthority() throws {
        let data = archive(try members())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let pathLoaded = try MachOImportService().importBinary(at: source)
        defer { removeImported(pathLoaded.executableURL) }
        let nonexistent = URL(fileURLWithPath: "/nonexistent/descriptive.ipa")
        let captured = try MachOImportService().importBinary(bytes: data, sourceURL: nonexistent)
        defer { removeImported(captured.executableURL) }
        XCTAssertEqual(captured.originalURL, nonexistent)
        XCTAssertEqual(captured.bytes, pathLoaded.bytes)
    }
    func testPrefixedIPAUsesAbsoluteZIPOffsetsAndRetainsIPAAdmission() throws {
        let prefix = Data("#!/bin/sh\nexit 0\n".utf8)
        let data = archive(try members(), prefix: prefix)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(IPAArchive.isZIP(data))
        XCTAssertTrue(IPAArchive.isZIP(at: source))
        let loaded = try MachOImportService().importBinary(at: source)
        defer { removeImported(loaded.executableURL) }
        XCTAssertEqual(loaded.originalURL, source)
        XCTAssertEqual(loaded.bytes, MachOFixture.makeExecutable().bytes)
        let captured = try MachOImportService().importBinary(bytes: data, sourceURL: source)
        defer { removeImported(captured.executableURL) }
        XCTAssertEqual(captured.bytes, loaded.bytes)

        var wrongOffset = data
        let centralOffset = wrongOffset.count - 6 // EOCD central-directory offset field
        wrongOffset[centralOffset] = 0
        wrongOffset[centralOffset + 1] = 0
        wrongOffset[centralOffset + 2] = 0
        wrongOffset[centralOffset + 3] = 0
        XCTAssertFalse(IPAArchive.isZIP(wrongOffset))
        XCTAssertThrowsError(try IPAArchive.extract(wrongOffset))
        let ordinaryZIP = archive([Member(name: "plain.txt", bytes: Data("text".utf8))], prefix: prefix)
        XCTAssertTrue(IPAArchive.isZIP(ordinaryZIP))
        XCTAssertThrowsError(try IPAArchive.extract(ordinaryZIP))
    }
    func testRejectsTraversalLinksDuplicateAndAmbiguousBundles() throws {
        let base = try members()
        let cases: [[Member]] = [
            base + [Member(name: "../escape")], base + [Member(name: "/absolute")],
            base + [Member(name: "Payload/Fixture.app/../escape")],
            base + [Member(name: "Payload/Fixture.app/link", bytes: Data("/tmp".utf8), mode: 0xa000)],
            base + [Member(name: "Payload/Fixture.app/pipe", mode: 0x1000)],
            base + [Member(name: "payload/fixture.app/main")],
            base + [Member(name: "Payload/Other.app/Main")],
            base + [Member(name: "Payload/Fixture.app/Main/child")],
            [Member(name: "outside/Main")]
        ]
        for entries in cases { XCTAssertThrowsError(try IPAArchive.extract(archive(entries))) }
    }
    func testRefusesExpansionCapsAndActualDeflateOverflow() throws {
        let data = archive(try members())
        var limits = IPAArchive.Limits()
        limits.archiveBytes = data.count - 1
        XCTAssertThrowsError(try IPAArchive.extract(data, limits: limits))
        limits = IPAArchive.Limits(); limits.entryBytes = 1
        XCTAssertThrowsError(try IPAArchive.extract(data, limits: limits))
        limits = IPAArchive.Limits(); limits.expandedBytes = 1
        XCTAssertThrowsError(try IPAArchive.extract(data, limits: limits))
        limits = IPAArchive.Limits(); limits.entries = 1
        XCTAssertThrowsError(try IPAArchive.extract(data, limits: limits))
        // Raw deflate of "hello": valid output is five bytes, not the declared one.
        let compressed = Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00])
        XCTAssertThrowsError(try IPAArchive.extract(archive(try members() + [Member(name: "Payload/Fixture.app/resource", bytes: Data("hello".utf8), declaredSize: 1, method: 8, compressed: compressed)])))
        let extracted = try IPAArchive.extract(archive(try members() + [Member(name: "Payload/Fixture.app/resource", bytes: Data("hello".utf8), method: 8, compressed: compressed)]))
        defer { IPAArchive.removeExtraction(at: extracted.root) }
        XCTAssertEqual(try Data(contentsOf: extracted.app.appendingPathComponent("resource")), Data("hello".utf8))
    }
    func testRejectsUnsafeExecutableNameAndRetainsFairPlayHoldback() throws {
        XCTAssertThrowsError(try MachOImportService().importBinary(bytes: archive(try members(executableName: "../Main")), sourceURL: URL(fileURLWithPath: "/fixture.ipa")))
        let imported = try MachOImportService().importBinary(bytes: archive(try members(encrypted: true)), sourceURL: URL(fileURLWithPath: "/encrypted.ipa"))
        defer { removeImported(imported.executableURL) }
        XCTAssertEqual(imported.machO.encryptionInfos.first?.cryptID, 1)
        let loaded = try MachOBinaryLoader().load(bytes: imported.bytes, sourceURL: imported.executableURL)
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }
    func testRejectsTruncationChecksumAndHeaderDisagreement() throws {
        let data = archive(try members())
        XCTAssertThrowsError(try IPAArchive.extract(data.dropLast()))
        var mismatch = data
        mismatch[30] ^= 1
        XCTAssertThrowsError(try IPAArchive.extract(mismatch))
        var corrupt = data
        let payload = 30 + "Payload/Fixture.app/Info.plist".utf8.count
        corrupt[payload] ^= 1
        XCTAssertThrowsError(try IPAArchive.extract(corrupt))
    }
}
