import Foundation
import XCTest
@testable import MacScope

/// Unit tests for `MachOLoadMetadata`.  These tests exercise both the
/// projection of metadata from a parsed `MachOFile` as well as the
/// direct parsing of a code signature from a raw Mach‑O slice.
final class MachOLoadMetadataTests: XCTestCase {
    // MARK: Helpers

    /// Builds a minimal code signature SuperBlob containing a single
    /// entitlements blob.  The blob offset is set to follow the index table.
    ///
    /// - Parameter xml: The XML plist string to embed in the entitlements blob.
    /// - Returns: A `Data` buffer containing the SuperBlob.
    private func makeEntitlementsSuperBlob(xml: String) -> Data {
        // Entitlements payload (raw plist text).
        let payload = Data(xml.utf8)
        // Build the entitlements blob: header (magic + length) + payload.
        var entBlob = Data()
        entBlob.appendUInt32BE(MachOConstants.codeSignatureEmbeddedEntitlementsMagic)
        let blobLength = UInt32(MachOConstants.codeSignatureBlobHeaderSize) + UInt32(payload.count)
        entBlob.appendUInt32BE(blobLength)
        entBlob.append(payload)
        // Build the SuperBlob header: magic, total length, blob count.
        let blobCount: UInt32 = 1
        let headerSize = Int(MachOConstants.codeSignatureSuperBlobHeaderSize)
        let indexSize = Int(blobCount) * 8
        let totalLength = UInt32(headerSize + indexSize + entBlob.count)
        var superBlob = Data()
        superBlob.appendUInt32BE(MachOConstants.codeSignatureEmbeddedSignatureMagic)
        superBlob.appendUInt32BE(totalLength)
        superBlob.appendUInt32BE(blobCount)
        // Single index entry: type and offset.
        superBlob.appendUInt32BE(MachOConstants.codeSignatureSlotEntitlements)
        let entBlobOffset = UInt32(headerSize + indexSize)
        superBlob.appendUInt32BE(entBlobOffset)
        // Append the entitlements blob itself.
        superBlob.append(entBlob)
        return superBlob
    }

    /// Builds a minimal code signature SuperBlob containing a DER entitlements
    /// blob.  The DER payload is arbitrary and not parsed.
    private func makeDerEntitlementsSuperBlob(payload: Data) -> Data {
        var entBlob = Data()
        entBlob.appendUInt32BE(MachOConstants.codeSignatureDerEntitlementsMagic)
        let blobLength = UInt32(MachOConstants.codeSignatureBlobHeaderSize) + UInt32(payload.count)
        entBlob.appendUInt32BE(blobLength)
        entBlob.append(payload)
        let blobCount: UInt32 = 1
        let headerSize = Int(MachOConstants.codeSignatureSuperBlobHeaderSize)
        let indexSize = Int(blobCount) * 8
        let totalLength = UInt32(headerSize + indexSize + entBlob.count)
        var superBlob = Data()
        superBlob.appendUInt32BE(MachOConstants.codeSignatureEmbeddedSignatureMagic)
        superBlob.appendUInt32BE(totalLength)
        superBlob.appendUInt32BE(blobCount)
        superBlob.appendUInt32BE(MachOConstants.codeSignatureSlotDerEntitlements)
        let offset = UInt32(headerSize + indexSize)
        superBlob.appendUInt32BE(offset)
        superBlob.append(entBlob)
        return superBlob
    }

    // MARK: Tests

    /// Verifies that `parse(slice:loadCommands:)` can recover an XML
    /// entitlements blob and its keys from a raw Mach‑O slice.  The binary is
    /// synthesized on the fly: an LC_CODE_SIGNATURE command followed by the
    /// SuperBlob.
    func testParseExtractsXMLEntitlements() throws {
        // Reuse the entitlements XML from the fixtures in MachOImportTests.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.app-sandbox</key>
            <true/>
            <key>com.apple.security.files.user-selected.read-only</key>
            <true/>
        </dict>
        </plist>
        """
        // Construct the code signature SuperBlob and the surrounding load command.
        let superBlob = makeEntitlementsSuperBlob(xml: xml)
        let loadCommandSize: UInt32 = 16
        let command: UInt32 = MachOConstants.loadCommandCodeSignature
        let dataOffset: UInt32 = 16
        let dataSize: UInt32 = UInt32(superBlob.count)
        var slice = Data()
        slice.appendUInt32LE(command)
        slice.appendUInt32LE(loadCommandSize)
        slice.appendUInt32LE(dataOffset)
        slice.appendUInt32LE(dataSize)
        slice.append(superBlob)
        // Describe the single load command for the parser.
        let lc = MachOLoadCommand(command: command, commandSize: loadCommandSize, offset: 0)
        let metadata = MachOLoadMetadata.parse(slice: slice, loadCommands: [lc])
        let cs = metadata.codeSignature
        XCTAssertNotNil(cs, "code signature should be present")
        guard let info = cs else { return }
        XCTAssertEqual(info.entitlementsFormat, MachOCodeSignatureEntitlementsFormat.xml.rawValue)
        XCTAssertEqual(info.entitlementsXML, xml)
        // The keys should be sorted lexicographically.
        XCTAssertEqual(info.entitlementsKeys, [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-only"
        ])
        XCTAssertEqual(info.entitlementsKeyCount, 2)
        XCTAssertTrue(info.entitlementsParsed)
        XCTAssertFalse(info.entitlementsDER)
    }

    /// Verifies that DER entitlements are surfaced but never decoded.
    func testParseExtractsDerEntitlements() {
        let derPayload = Data([0x01, 0x02, 0x03])
        let superBlob = makeDerEntitlementsSuperBlob(payload: derPayload)
        let loadCommandSize: UInt32 = 16
        let command: UInt32 = MachOConstants.loadCommandCodeSignature
        let dataOffset: UInt32 = 16
        let dataSize: UInt32 = UInt32(superBlob.count)
        var slice = Data()
        slice.appendUInt32LE(command)
        slice.appendUInt32LE(loadCommandSize)
        slice.appendUInt32LE(dataOffset)
        slice.appendUInt32LE(dataSize)
        slice.append(superBlob)
        let lc = MachOLoadCommand(command: command, commandSize: loadCommandSize, offset: 0)
        let metadata = MachOLoadMetadata.parse(slice: slice, loadCommands: [lc])
        let cs = metadata.codeSignature
        XCTAssertNotNil(cs, "code signature should be present")
        guard let info = cs else { return }
        XCTAssertEqual(info.entitlementsFormat, MachOCodeSignatureEntitlementsFormat.der.rawValue)
        XCTAssertNil(info.entitlementsXML)
        XCTAssertTrue(info.entitlementsDER)
        XCTAssertFalse(info.entitlementsParsed)
        XCTAssertTrue(info.entitlementsKeys.isEmpty)
    }

    /// Verifies that `from(_:)` reshapes code signature summaries, merges
    /// imported symbols, resolves ordinals to library names and surfaces dylib
    /// information correctly.
    func testProjectionFromMachOFile() {
        // Build a minimal code directory summary.
        let codeDir = MachOCodeDirectorySummary(
            version: 0x20200,
            flags: 0x0001_0000,
            hashOffset: 0,
            identifierOffset: 0,
            specialSlotCount: 0,
            codeSlotCount: 0,
            codeLimit: 0,
            hashSize: 32,
            hashType: MachOConstants.codeSignatureHashTypeSHA256,
            platform: 0,
            pageSize: 0,
            identifier: "com.example",
            teamIdentifier: "TEAM"
        )
        // Build an entitlements summary.
        let entSummary = MachOCodeSignatureEntitlementsSummary(
            format: .xml,
            keyCount: 2,
            keys: ["a", "b"],
            isParsed: true
        )
        // Attach the code directory summary to the blob.  In a real
        // SuperBlob the code directory and entitlements would be separate
        // blobs, but for projection purposes it is sufficient to hang the
        // summary off any blob.
        let blob = MachOCodeSignatureBlob(
            type: MachOConstants.codeSignatureSlotEntitlements,
            relativeOffset: 0,
            fileOffset: 0,
            magic: MachOConstants.codeSignatureEmbeddedEntitlementsMagic,
            length: 0,
            codeDirectory: codeDir,
            entitlements: entSummary
        )
        let superBlob = MachOCodeSignatureSuperBlob(
            magic: MachOConstants.codeSignatureEmbeddedSignatureMagic,
            length: 0,
            blobCount: 1,
            blobs: [blob]
        )
        let codeSignature = MachOCodeSignature(
            dataOffset: 0,
            dataSize: 0,
            superBlob: superBlob
        )
        // Create dyld chained import entries.  The first entry shares a name
        // with the classic import table and therefore should override it.
        let fixupImports: [MachOChainedImport] = [
            MachOChainedImport(
                index: 0,
                name: "func1",
                libraryOrdinal: 1,
                libraryName: nil,
                isWeakImport: false,
                addend: 5
            ),
            MachOChainedImport(
                index: 1,
                name: "func2",
                libraryOrdinal: MachOConstants.dynamicLookupLibraryOrdinal,
                libraryName: nil,
                isWeakImport: true,
                addend: 0
            )
        ]
        let chainedFixups = MachODyldChainedFixups(
            dataOffset: 0,
            dataSize: 0,
            fixupsVersion: 0,
            startsOffset: 0,
            importsOffset: 0,
            symbolsOffset: 0,
            importsCount: 0,
            importsFormat: 0,
            symbolsFormat: 0,
            imports: fixupImports,
            fixups: []
        )
        // Classic import table contains a duplicate of func1.  It should be
        // dropped in favour of the chained fixup entry.
        let importTable: [MachOImport] = [
            MachOImport(symbolIndex: 1, name: "func1", libraryOrdinal: 1, libraryName: nil)
        ]
        // Two dylibs.  The first matches libraryOrdinal 1; the second ensures
        // that an ordinal greater than 1 resolves correctly.
        let dylibs: [MachODylib] = [
            MachODylib(
                name: "/usr/lib/libSystem.B.dylib",
                ordinal: 1,
                command: MachOConstants.loadCommandLoadDylib,
                pathKind: .systemAbsolute,
                timestamp: 0,
                currentVersion: MachODylibVersion(encodedValue: 0x00010003),
                compatibilityVersion: MachODylibVersion(encodedValue: 0x00010000)
            ),
            MachODylib(
                name: "@rpath/libSomething.dylib",
                ordinal: 2,
                command: MachOConstants.loadCommandLoadWeakDylib,
                pathKind: .rpathRelative,
                timestamp: 0,
                currentVersion: MachODylibVersion(encodedValue: 0x00000003),
                compatibilityVersion: MachODylibVersion(encodedValue: 0x00000002)
            )
        ]
        // Assemble a minimal MachOFile stub.  Only the fields that are
        // consumed by `MachOLoadMetadata.from(_:)` need to be populated.
        let machO = MachOFile(
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
            loadCommands: [],
            segments: [],
            sections: [],
            dylibs: dylibs,
            rpaths: [],
            symbols: [],
            imports: importTable,
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
            buildVersion: nil,
            sourceVersion: nil,
            legacyMinimumOSVersion: nil,
            codeSignature: codeSignature,
            dyldChainedFixups: chainedFixups,
            entryPointOffset: nil,
            entryPointVirtualAddress: nil,
            selectedSliceOffset: 0,
            universalBinary: nil
        )
        let metadata = MachOLoadMetadata.from(machO)
        // Validate code signature fields.
        XCTAssertNotNil(metadata.codeSignature)
        if let cs = metadata.codeSignature {
            XCTAssertEqual(cs.teamIdentifier, "TEAM")
            XCTAssertEqual(cs.identifier, "com.example")
            XCTAssertEqual(cs.hashTypeName, "SHA-256")
            XCTAssertEqual(cs.codeSignatureFlags, 0x0001_0000)
            XCTAssertEqual(cs.entitlementsFormat, MachOCodeSignatureEntitlementsFormat.xml.rawValue)
            XCTAssertNil(cs.entitlementsXML)
            XCTAssertEqual(cs.entitlementsKeys, ["a", "b"])
            XCTAssertEqual(cs.entitlementsKeyCount, 2)
            XCTAssertTrue(cs.entitlementsParsed)
            XCTAssertFalse(cs.entitlementsDER)
        }
        // Validate imported symbols: func1 from chained fixups and func2.
        XCTAssertEqual(metadata.importedSymbols.count, 2)
        // func1 should resolve to the first dylib and carry the addend.
        let first = metadata.importedSymbols[0]
        XCTAssertEqual(first.name, "func1")
        XCTAssertEqual(first.libraryOrdinal, 1)
        XCTAssertEqual(first.libraryName, "/usr/lib/libSystem.B.dylib")
        XCTAssertFalse(first.isWeak)
        XCTAssertEqual(first.addend, 5)
        XCTAssertEqual(first.source, "dyld fixup")
        // func2 resolves to dynamic lookup.
        let second = metadata.importedSymbols[1]
        XCTAssertEqual(second.name, "func2")
        XCTAssertEqual(second.libraryOrdinal, Int(MachOConstants.dynamicLookupLibraryOrdinal))
        XCTAssertEqual(second.libraryName, "dynamic lookup")
        XCTAssertTrue(second.isWeak)
        XCTAssertEqual(second.addend, 0)
        XCTAssertEqual(second.source, "dyld fixup")
        // Validate dependent dylibs.
        XCTAssertEqual(metadata.dependentDylibs.count, 2)
        let dep0 = metadata.dependentDylibs[0]
        XCTAssertEqual(dep0.path, "/usr/lib/libSystem.B.dylib")
        XCTAssertEqual(dep0.kind, "required")
        XCTAssertEqual(dep0.currentVersion, "1.0.3")
        XCTAssertEqual(dep0.compatibilityVersion, "1.0.0")
        XCTAssertEqual(dep0.ordinal, 1)
        let dep1 = metadata.dependentDylibs[1]
        XCTAssertEqual(dep1.path, "@rpath/libSomething.dylib")
        XCTAssertEqual(dep1.kind, "weak")
        XCTAssertEqual(dep1.currentVersion, "0.0.3")
        XCTAssertEqual(dep1.compatibilityVersion, "0.0.2")
        XCTAssertEqual(dep1.ordinal, 2)
    }

    // MARK: - BUG-004: nonzero library ordinal with zero declared dylibs

    func testChainedImportsWithSameNameAndDistinctSpecialOrdinalsRemainDistinct() throws {
        let imports = [
            MachOChainedImport(
                index: 0,
                name: "_shared_symbol",
                libraryOrdinal: nil,
                libraryName: "self",
                isWeakImport: false,
                addend: 0,
                encodedLibraryOrdinal: MachOChainedSpecialLibraryOrdinal.selfImage.rawValue
            ),
            MachOChainedImport(
                index: 1,
                name: "_shared_symbol",
                libraryOrdinal: nil,
                libraryName: "weak lookup",
                isWeakImport: true,
                addend: 0,
                encodedLibraryOrdinal: MachOChainedSpecialLibraryOrdinal.weakLookup.rawValue
            )
        ]
        let fixups = MachODyldChainedFixups(
            dataOffset: 0,
            dataSize: 0,
            fixupsVersion: 0,
            startsOffset: 0,
            importsOffset: 0,
            symbolsOffset: 0,
            importsCount: UInt32(imports.count),
            importsFormat: 0,
            symbolsFormat: 0,
            imports: imports,
            fixups: []
        )
        let machO = MachOFile(
            header: MachOHeader(
                magic: 0, cpuType: 0, cpuSubtype: 0, fileType: 0,
                loadCommandCount: 0, loadCommandsSize: 0, flags: 0, reserved: 0
            ),
            loadCommands: [],
            segments: [],
            sections: [],
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
            buildVersion: nil,
            sourceVersion: nil,
            legacyMinimumOSVersion: nil,
            codeSignature: nil,
            dyldChainedFixups: fixups,
            entryPointOffset: nil,
            entryPointVirtualAddress: nil,
            selectedSliceOffset: 0,
            universalBinary: nil
        )

        let symbols = MachOLoadMetadata.from(machO).importedSymbols

        XCTAssertEqual(symbols.count, 2)
        XCTAssertEqual(symbols.map(\.name), ["_shared_symbol", "_shared_symbol"])
        XCTAssertEqual(symbols.map(\.libraryName), ["self", "weak lookup"])
        XCTAssertEqual(symbols.map(\.isWeak), [false, true])
    }

    /// A crafted binary can carry an undefined external symbol whose library
    /// ordinal is 1 while declaring no `LC_LOAD_DYLIB` at all. The old
    /// `case 1...dylibs.count` then formed the invalid range `1...0`, which
    /// traps. `MachOLoadMetadata.from` runs this on every Mach-O load, so the
    /// resolver must fall through to nil instead of aborting the process. Every
    /// existing import fixture ships at least one dylib, so this boundary was
    /// uncovered.
    func testLibraryOrdinalWithZeroDylibsDoesNotTrap() throws {
        let machO = MachOFile(
            header: MachOHeader(
                magic: 0, cpuType: 0, cpuSubtype: 0, fileType: 0,
                loadCommandCount: 0, loadCommandsSize: 0, flags: 0, reserved: 0
            ),
            loadCommands: [],
            segments: [],
            sections: [],
            dylibs: [], // ← zero declared dylibs is the lever
            rpaths: [],
            symbols: [],
            imports: [
                MachOImport(symbolIndex: 1, name: "func_undef", libraryOrdinal: 1, libraryName: nil)
            ],
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
            buildVersion: nil,
            sourceVersion: nil,
            legacyMinimumOSVersion: nil,
            codeSignature: nil,
            dyldChainedFixups: nil,
            entryPointOffset: nil,
            entryPointVirtualAddress: nil,
            selectedSliceOffset: 0,
            universalBinary: nil
        )

        let metadata = MachOLoadMetadata.from(machO)

        let imported = try XCTUnwrap(metadata.importedSymbols.first { $0.name == "func_undef" })
        XCTAssertEqual(imported.libraryOrdinal, 1)
        XCTAssertNil(imported.libraryName, "an out-of-range ordinal resolves to no library, not a trap")
    }
}

// MARK: - Data extension for building little‑endian and big‑endian values

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
