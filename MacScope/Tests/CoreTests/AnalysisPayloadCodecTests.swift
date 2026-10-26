import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/*
 WorkspaceSnapshot transfer inventory (per-image-container update, re-enumerated 2026-07-11):

 Post Step-4 refactor the 22 image-local derived products live in `ImageAnalysis` (owned by
 `WorkspaceSnapshot.analysisBySlot[slot]`), NOT as flat stored vars. `binaries` and the 5 authoring
 collections remain stored on the snapshot. The engine + XPC worker stay IMAGE-LOCAL: one analysis
 produces one image, so `AnalysisResultPayload` is still a FLAT single-image payload (it transfers
 the primary image's `ImageAnalysis` fields via the flat compatibility projections). Optional derived
 fields use conservative missing-field defaults for older replies; the TRANSFER/SKIP inventory
 below records what the codec round-trips.

 TRANSFER binaries — derived binary identity and loader metadata produced by analysis (stored).
 TRANSFER functions — derived function discovery results.
 TRANSFER symbols — derived symbol-table results.
 TRANSFER imports — derived imported-symbol summaries.
 TRANSFER indirectSymbols — derived indirect-symbol table results.
 TRANSFER exports — derived export-trie/symbol results.
 TRANSFER stringLiterals — derived literal recovery results.
 TRANSFER basicBlocks — derived control-flow partitioning.
 TRANSFER instructions — derived decoded instruction rows.
 TRANSFER xrefs — derived recovered cross-references.
 TRANSFER controlFlowEdges — derived CFG edges.
 TRANSFER hexBytes — derived bounded byte prefix for the hex view.
 TRANSFER jumpTables — derived switch targets (encoded as sorted key/value pair objects).
 TRANSFER objcSelectors — derived selector-slot names (encoded as sorted key/value pair objects).
 TRANSFER objcClasses — derived Objective-C runtime metadata.
 TRANSFER objcCategories — derived Objective-C category metadata.
 TRANSFER swiftTypes — derived Swift reflection metadata.
 TRANSFER swiftConformances — derived Swift protocol conformances.
 TRANSFER sections — derived loader sections; includes Wave-8 SectionSummary.fileSize fidelity.
 TRANSFER identityEffectiveByteRanges — loader-issued artifact-bound effective-byte authority.
 TRANSFER relocations — derived format-neutral relocation records.
 TRANSFER sourceLines — derived/imported DWARF line-table rows.
 TRANSFER imageBytes — derived full selected-slice bytes.
 SKIP addressOverrides — authoring owned and re-stamped by WorkspaceStore after reanalysis.
 SKIP typeDefinitions — persisted workspace-global authoring catalog.
 SKIP manualXRefs — persisted user-authored xref additions/suppressions.
 SKIP bookmarks — persisted user navigation authoring.
 SKIP segmentOverrides — persisted section display authoring.
 TRANSFER diagnostics — derived analysis problem records.
 TRANSFER machOMetadata — derived Mach-O signature/import/dependency metadata.
 TRANSFER analysisInputFingerprint — derived exact input/facet provenance for later freshness gates.

 `hexViewByteWindow` is static and therefore is not a snapshot field.
 Storage: binaries + analysisBySlot + workspace authoring on the snapshot. The payload transfers
 the primary image's derived fields, including loader-issued effective-byte authority.
 */

final class AnalysisPayloadCodecTests: XCTestCase {
    func testCapturedContainerWitnessSurvivesOnlyValidWorkerPayload() throws {
        let selectedBytes = Data(repeating: 0x5a, count: 32)
        let fullContainer = Data([0x01, 0x02]) + selectedBytes + Data([0x03])
        let digest = SHA256.hash(data: selectedBytes).map { String(format: "%02x", $0) }.joined()
        let identity = try MachOSliceArtifactIdentity(
            uuid: nil, rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
            selectedSliceSHA256: digest, selectedSliceByteCount: UInt64(selectedBytes.count))
        let witness = try XCTUnwrap(MachOContainerAdmissionWitness(
            containerBytes: fullContainer, sliceOffset: 2, sliceSize: UInt64(selectedBytes.count),
            selectedSliceIdentity: identity))
        let layout = try MachOPreferredSegmentLayout(records: [
            .init(name: "__TEXT", preferredVMStart: 0x1000, preferredVMSize: 32,
                  sliceRelativeFileOffset: 0, fileSize: 32, initialProtections: 5)
        ], selectedSliceByteCount: identity.selectedSliceByteCount)
        let image = BinaryImage(id: UUID(), name: "synthetic", path: "/synthetic",
                                kind: "Mach-O", architecture: "arm64",
                                artifactIdentity: identity, preferredSegmentLayout: layout,
                                artifactIntegrityState: .verified,
                                containerAdmissionWitness: witness)
        var analysis = ImageAnalysis()
        analysis.imageBytes = selectedBytes
        let snapshot = WorkspaceSnapshot(binaries: [image], analysisBySlot: [.primary: analysis])
        let transferred = try JSONDecoder().decode(AnalysisResultPayload.self,
            from: JSONEncoder().encode(AnalysisPayloadCodec.payload(from: snapshot)))
        XCTAssertNil(transferred.binaries[0].containerAdmissionWitness)
        XCTAssertEqual(AnalysisPayloadCodec.snapshot(from: transferred)
            .binaries.first?.containerAdmissionWitness, witness)
        var mismatched = transferred
        mismatched.imageBytes = Data(repeating: 0, count: selectedBytes.count)
        XCTAssertNil(AnalysisPayloadCodec.snapshot(from: mismatched)
            .binaries.first?.containerAdmissionWitness)
        mismatched = transferred
        mismatched.binaries[0].artifactIntegrityState = .unavailable
        XCTAssertNil(AnalysisPayloadCodec.snapshot(from: mismatched)
            .binaries.first?.containerAdmissionWitness)
        mismatched = transferred
        mismatched.containerAdmissionWitness = nil
        mismatched.binaries[0].containerAdmissionWitness = witness
        XCTAssertNil(AnalysisPayloadCodec.snapshot(from: mismatched)
            .binaries.first?.containerAdmissionWitness)
    }

    func testLoaderAttestationsSurvivePayloadTransferAndNativeProjection() throws {
        let original = try Self.loaderAttestedSnapshot()
        XCTAssertFalse(original.identityEffectiveByteRanges.isEmpty)
        let decoded = try Self.roundTrip(AnalysisPayloadCodec.payload(from: original))
        let received = AnalysisPayloadCodec.snapshot(from: decoded)
        XCTAssertEqual(received.identityEffectiveByteRanges, original.identityEffectiveByteRanges)
        XCTAssertEqual(received.analysisInputFingerprint, original.analysisInputFingerprint)
        let binary = try XCTUnwrap(received.binaries.first)
        let analysis = try XCTUnwrap(received.analysis(in: binary.slot))
        XCTAssertEqual(try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis),
            original.analysisInputFingerprint)
        let function = try XCTUnwrap(received.functions.first)
        let projection = try NativeDecompilerSnapshotBuilder.build(from: received,
            imageSlot: binary.slot, functionID: function.id,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)
        XCTAssertEqual(projection.function.entryAddress.value, function.startAddress)
        XCTAssertEqual(projection.memoryRegions.first?.rawBytes, Data([0x1F, 0x20, 0x03, 0xD5, 0xC0, 0x03, 0x5F, 0xD6]))
    }

    func testPayloadDecodeRejectsMalformedEffectiveByteAttestations() throws {
        let payload = AnalysisPayloadCodec.payload(from: try Self.loaderAttestedSnapshot())
        let bytes = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let evidence = try XCTUnwrap(object["identityEffectiveByteRanges"] as? [[String: Any]])
        for (key, value) in [("byteCount", 0 as Any), ("initialProtections", 3 as Any),
                             ("segmentName", "" as Any), ("rawBytesSHA256", "bad" as Any)] {
            var malformed = object
            var modifiedEvidence = evidence
            modifiedEvidence[0][key] = value
            malformed["identityEffectiveByteRanges"] = modifiedEvidence
            let encoded = try JSONSerialization.data(withJSONObject: malformed)
            XCTAssertThrowsError(try JSONDecoder().decode(AnalysisResultPayload.self, from: encoded), key) {
                XCTAssertEqual($0 as? IdentityEffectiveByteRangeAttestationError, .invalidEvidence)
            }
        }
    }

    func testLegacyPayloadWithoutEffectiveByteAttestationsRemainsConservative() throws {
        let payload = AnalysisPayloadCodec.payload(from: try Self.loaderAttestedSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)) as? [String: Any])
        object.removeValue(forKey: "identityEffectiveByteRanges")
        let decoded = try JSONDecoder().decode(AnalysisResultPayload.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.identityEffectiveByteRanges.isEmpty)
        var received = AnalysisPayloadCodec.snapshot(from: decoded)
        let binary = try XCTUnwrap(received.binaries.first)
        var analysis = try XCTUnwrap(received.analysis(in: binary.slot))
        // Reconstruction recomputes this fingerprint; missing legacy authority still rejects.
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        received.replaceAnalysis(analysis, in: binary.slot)
        XCTAssertThrowsError(try NativeDecompilerSnapshotBuilder.build(from: received,
            imageSlot: binary.slot, functionID: XCTUnwrap(received.functions.first).id,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)) {
                XCTAssertEqual($0 as? NativeDecompilerSnapshotProjectionError, .effectiveLoadImageAuthorityUnavailable)
            }
    }

    private static func loaderAttestedSnapshot() throws -> WorkspaceSnapshot {
        // Actual Mach-O loader input: mapped, non-writable executable __TEXT and LC_UUID.
        var bytes = Data()
        func append32(_ value: UInt32) {
            Swift.withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func append64(_ value: UInt64) {
            Swift.withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        append32(0xFEEDFACF); append32(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        append32(0); append32(MachOConstants.fileTypeExecute)
        append32(2); append32(96); append32(0); append32(0)
        append32(MachOConstants.loadCommandSegment64); append32(72)
        bytes.append(Data("__TEXT".utf8)); bytes.append(Data(count: 10))
        append64(0x1000); append64(160); append64(0); append64(160)
        append32(5); append32(5); append32(0); append32(0)
        append32(MachOConstants.loadCommandUUID); append32(24)
        bytes.append(contentsOf: (1...16).map { UInt8($0) })
        append32(0xD503201F); append32(0xD65F03C0)
        bytes.append(Data(count: 160 - bytes.count))
        let directory = TestWorkRoot.scratchURL("macscope-analysis-attestation-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attested.macho")
        try bytes.write(to: url)
        let loaded = try MachOBinaryLoader().load(at: url)
        let binary = BinaryImage(id: UUID(), name: loaded.name, path: loaded.path,
            kind: loaded.fileTypeName, architecture: loaded.architectureDisplayName,
            artifactIdentity: loaded.artifactIdentity, preferredSegmentLayout: loaded.preferredSegmentLayout,
            artifactIntegrityState: loaded.artifactIntegrityState,
            resolvedExecutablePath: loaded.resolvedExecutablePath, slot: .primary)
        let function = FunctionSummary(id: UUID(), name: "attested_entry",
            startAddress: 0x1080, endAddress: 0x1088, confidence: 1)
        var analysis = ImageAnalysis(functions: [function],
            identityEffectiveByteRanges: loaded.identityEffectiveByteRanges, imageBytes: loaded.bytes)
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        return WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis])
    }

    func testPayloadAndSnapshotConvertersPreserveEveryDerivedFieldAndClearAuthoring() throws {
        let original = Self.exhaustiveSnapshot()
        let payload = AnalysisPayloadCodec.payload(from: original)
        let decoded = try Self.roundTrip(payload)
        let reconstructed = AnalysisPayloadCodec.snapshot(from: decoded)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(AnalysisPayloadCodec.payload(from: reconstructed), payload)
        XCTAssertTrue(reconstructed.addressOverrides.isEmpty)
        XCTAssertTrue(reconstructed.typeDefinitions.isEmpty)
        XCTAssertTrue(reconstructed.manualXRefs.isEmpty)
        XCTAssertTrue(reconstructed.bookmarks.isEmpty)
        XCTAssertTrue(reconstructed.segmentOverrides.isEmpty)
    }

    func testEveryPayloadConstituentRoundTripsAtBoundaries() throws {
        let snapshot = Self.exhaustiveSnapshot()

        try Self.assertRoundTrip(snapshot.binaries[0])
        try Self.assertRoundTrip(snapshot.binaries[0].metadata)
        try Self.assertRoundTrip(snapshot.binaries[0].slot)
        try Self.assertRoundTrip(snapshot.functions[0])
        try Self.assertRoundTrip(snapshot.symbols[0])
        try Self.assertRoundTrip(snapshot.symbols[1])
        try Self.assertRoundTrip(snapshot.imports[0])
        try Self.assertRoundTrip(snapshot.imports[1])
        try Self.assertRoundTrip(snapshot.indirectSymbols[0])
        try Self.assertRoundTrip(snapshot.exports[0])
        try Self.assertRoundTrip(snapshot.exports[1])
        try Self.assertRoundTrip(snapshot.stringLiterals[0])
        try Self.assertRoundTrip(snapshot.basicBlocks[0])
        try Self.assertRoundTrip(snapshot.instructions[0])
        try Self.assertRoundTrip(snapshot.xrefs[0])
        try Self.assertRoundTrip(snapshot.controlFlowEdges[0])
        try Self.assertRoundTrip(snapshot.sections[0])
        try Self.assertRoundTrip(snapshot.sections[1])
        try Self.assertRoundTrip(snapshot.relocations[0])
        try Self.assertRoundTrip(snapshot.relocations[1])
        try Self.assertRoundTrip(snapshot.sourceLines[0])
        try Self.assertRoundTrip(snapshot.sourceLines[1])
        try Self.assertRoundTrip(snapshot.diagnostics[0])
        try Self.assertRoundTrip(snapshot.diagnostics[0].severity)
        try Self.assertRoundTrip(snapshot.diagnostics[0].kind)
        try Self.assertRoundTrip(try XCTUnwrap(snapshot.machOMetadata))
        try Self.assertRoundTrip(try XCTUnwrap(snapshot.analysisInputFingerprint))

        let objcClass = snapshot.objcClasses[0]
        try Self.assertRoundTrip(objcClass)
        try Self.assertRoundTrip(objcClass.classMethods[0])
        try Self.assertRoundTrip(objcClass.instanceMethods[0])
        try Self.assertRoundTrip(objcClass.ivars[0])
        try Self.assertRoundTrip(objcClass.properties[0])
        try Self.assertRoundTrip(snapshot.objcCategories[0])

        let swiftType = snapshot.swiftTypes[0]
        try Self.assertRoundTrip(swiftType)
        try Self.assertRoundTrip(swiftType.kind)
        try Self.assertRoundTrip(swiftType.fields[0])
        try Self.assertRoundTrip(swiftType.fields[1])
        try Self.assertRoundTrip(snapshot.swiftConformances[0])

        let metadata = try XCTUnwrap(snapshot.machOMetadata)
        try Self.assertRoundTrip(try XCTUnwrap(metadata.codeSignature))
        try Self.assertRoundTrip(metadata.importedSymbols[0])
        try Self.assertRoundTrip(metadata.importedSymbols[1])
        try Self.assertRoundTrip(metadata.dependentDylibs[0])
    }

    func testUInt64MapsUseSortedPairArraysAndRoundTripMaximumKeys() throws {
        let payload = AnalysisPayloadCodec.payload(from: Self.exhaustiveSnapshot())
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let jumpPairs = try XCTUnwrap(json["jumpTables"] as? [[String: Any]])
        XCTAssertEqual(jumpPairs.count, 3)
        XCTAssertEqual(jumpPairs.map { ($0["address"] as? NSNumber)?.uint64Value }, [0, 7, UInt64.max])
        XCTAssertEqual(Set(jumpPairs[0].keys), ["address", "value"])

        let selectorPairs = try XCTUnwrap(json["objcSelectors"] as? [[String: Any]])
        XCTAssertEqual(selectorPairs.count, 3)
        XCTAssertEqual(selectorPairs.map { ($0["address"] as? NSNumber)?.uint64Value }, [0, 9, UInt64.max])
        XCTAssertEqual(Set(selectorPairs[0].keys), ["address", "value"])

        let decoded = try JSONDecoder().decode(AnalysisResultPayload.self, from: data)
        XCTAssertEqual(decoded.jumpTables, payload.jumpTables)
        XCTAssertEqual(decoded.objcSelectors, payload.objcSelectors)
    }

    func testUInt64MapsEncodeAndDecodeAsEmptyPairArrays() throws {
        var snapshot = Self.exhaustiveSnapshot()
        snapshot.jumpTables = [:]
        snapshot.objcSelectors = [:]
        let payload = AnalysisPayloadCodec.payload(from: snapshot)
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((json["jumpTables"] as? [Any])?.count, 0)
        XCTAssertEqual((json["objcSelectors"] as? [Any])?.count, 0)
        let decoded = try JSONDecoder().decode(AnalysisResultPayload.self, from: data)
        XCTAssertTrue(decoded.jumpTables.isEmpty)
        XCTAssertTrue(decoded.objcSelectors.isEmpty)
    }

    func testUInt64PairArraysRejectDuplicateKeys() throws {
        let payload = AnalysisPayloadCodec.payload(from: Self.exhaustiveSnapshot())
        let encoded = try JSONEncoder().encode(payload)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let first = try XCTUnwrap((json["jumpTables"] as? [[String: Any]])?.first)
        json["jumpTables"] = [first, first]
        let duplicateData = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(AnalysisResultPayload.self, from: duplicateData))
    }

    func testWave8SectionFileSizeSurvivesPresentAndNilForms() throws {
        let present = SectionSummary(
            id: Self.uuid(40), name: "raw-padding", address: UInt64.max, size: 0,
            fileOffset: UInt64.max - 1, isExecutable: true, isZeroFill: false,
            fileSize: UInt64.max
        )
        let absent = SectionSummary(
            id: Self.uuid(41), name: "", address: 0, size: UInt64.max,
            fileOffset: 0, isExecutable: false, isZeroFill: true, fileSize: nil
        )

        XCTAssertEqual(try Self.roundTrip(present), present)
        XCTAssertEqual(try Self.roundTrip(absent), absent)
    }

    func testOptionalNilAndEmptyCollectionFormsRoundTrip() throws {
        try Self.assertRoundTrip(
            BinaryImage(
                id: Self.uuid(42), name: "", path: "", kind: "", architecture: "",
                originalPathBookmark: nil, metadata: .empty, selectedSliceIndex: nil,
                slot: .primary
            )
        )
        try Self.assertRoundTrip(BinaryMetadataSummary.empty)
        try Self.assertRoundTrip(
            IndirectSymbolSummary(
                id: Self.uuid(43), kind: "", sourceSection: "", address: 0,
                entrySize: 0, tableIndex: 0, rawSymbolIndex: 0, symbolIndex: nil,
                symbolName: nil, libraryOrdinal: nil, libraryName: nil,
                isLocal: false, isAbsolute: false
            )
        )
        try Self.assertRoundTrip(
            InstructionRow(
                address: 0, bytes: "", mnemonic: "", operands: "",
                hasBreakpoint: false, comment: nil
            )
        )
        try Self.assertRoundTrip(
            ObjCClass(
                name: "", superclassName: nil, adoptedProtocols: [], classMethods: [],
                instanceMethods: [], ivars: [], properties: []
            )
        )
        try Self.assertRoundTrip(
            MachOLoadMetadata(codeSignature: nil, importedSymbols: [], dependentDylibs: [])
        )

        var snapshot = Self.exhaustiveSnapshot()
        snapshot.machOMetadata = nil
        let nilMetadataPayload = AnalysisPayloadCodec.payload(from: snapshot)
        XCTAssertEqual(try Self.roundTrip(nilMetadataPayload), nilMetadataPayload)
    }

    func testPrimaryImageAuthoringEntriesKeepLegacyOmitWhenDefaultJSONKeys() throws {
        let entry = AddressOverrideEntry(
            address: UInt64.max,
            override: AddressOverride(customName: "λ", customComment: "")
        )
        let bookmark = Bookmark(id: Self.uuid(50), address: UInt64.max, name: "")
        let manual = ManualXRef(
            id: Self.uuid(51), from: 0, to: UInt64.max, kind: "用户", isSuppression: true
        )
        let segment = SegmentOverride(
            id: Self.uuid(52), originalName: "", displayName: nil, rebaseDelta: Int64.min
        )

        XCTAssertEqual(try Self.jsonKeys(entry), ["address", "override"])
        XCTAssertEqual(try Self.jsonKeys(entry.override), ["customComment", "customName"])
        XCTAssertEqual(try Self.jsonKeys(bookmark), ["address", "id", "name"])
        XCTAssertEqual(try Self.jsonKeys(manual), ["from", "id", "isSuppression", "kind", "to"])
        XCTAssertEqual(try Self.jsonKeys(segment), ["id", "originalName", "rebaseDelta"])
        try Self.assertRoundTrip(entry)
        try Self.assertRoundTrip(bookmark)
        try Self.assertRoundTrip(manual)
        try Self.assertRoundTrip(segment)
    }

    func testNonPrimaryAuthoringEntriesRetainImageSlotKey() throws {
        let slot = ImageSlot(rawValue: Int.max)
        let entry = AddressOverrideEntry(address: 1, imageSlot: slot, override: AddressOverride())
        let bookmark = Bookmark(id: Self.uuid(60), address: 2, imageSlot: slot, name: "名")

        XCTAssertEqual(try Self.jsonKeys(entry), ["address", "imageSlot", "override"])
        XCTAssertEqual(try Self.jsonKeys(bookmark), ["address", "id", "imageSlot", "name"])
        try Self.assertRoundTrip(entry)
        try Self.assertRoundTrip(bookmark)
    }

    // MARK: - Corpus

    private static func exhaustiveSnapshot() -> WorkspaceSnapshot {
        let objcMethod = ObjCMethod(
            selector: "doThing:🌐", typeEncoding: "v24@0:8i16", isClassMethod: true,
            implementation: UInt64.max
        )
        let objcNilMethod = ObjCMethod(
            selector: "", typeEncoding: nil, isClassMethod: false, implementation: nil
        )
        let objcProperty = ObjCProperty(name: "标题", attributes: "T@\"NSString\",&,N,V_标题")
        let objcClass = ObjCClass(
            name: "ΔClass", superclassName: "NSObject", adoptedProtocols: ["NSCopying", "协议"],
            classMethods: [objcMethod], instanceMethods: [objcNilMethod],
            ivars: [ObjCIvar(name: "_值", typeEncoding: nil)], properties: [objcProperty]
        )
        let objcCategory = ObjCCategory(
            name: "Extras", className: "外部类", classMethods: [objcNilMethod],
            instanceMethods: [objcMethod], adoptedProtocols: [""], properties: [objcProperty]
        )
        let swiftType = SwiftTypeDescriptor(
            kind: .enum,
            name: "模块.类型🌈",
            fields: [
                SwiftField(name: "值", typeName: "Swift.Int", mangledTypeName: "$sSi", isVar: true),
                SwiftField(name: "", typeName: nil, mangledTypeName: nil, isVar: false)
            ]
        )
        let machO = MachOLoadMetadata(
            codeSignature: MachOLoadMetadata.CodeSignatureInfo(
                teamIdentifier: "TEAM🌐", identifier: "", hashTypeName: "sha256",
                codeSignatureFlags: UInt32.max, entitlementsFormat: "XML",
                entitlementsXML: "<plist><dict><key>键</key></dict></plist>",
                entitlementsDER: true, entitlementsKeyCount: Int.max,
                entitlementsKeys: ["", "com.apple.权限"], entitlementsParsed: true
            ),
            importedSymbols: [
                MachOLoadMetadata.ImportedSymbol(
                    name: "_符号", libraryOrdinal: Int.min, libraryName: "lib🌐.dylib",
                    isWeak: true, addend: Int64.min, source: "dyld fixup"
                ),
                MachOLoadMetadata.ImportedSymbol(
                    name: "", libraryOrdinal: nil, libraryName: nil,
                    isWeak: false, addend: nil, source: ""
                )
            ],
            dependentDylibs: [
                MachOLoadMetadata.DependentDylib(
                    path: "/路径/lib.dylib", kind: "weak", currentVersion: "",
                    compatibilityVersion: "18446744073709551615", ordinal: Int.min
                )
            ]
        )
        let fingerprintFacet = try! AnalysisFacetFingerprint(
            kind: .selectedSliceBytes,
            itemCount: 1,
            byteCount: 3,
            sha256: String(repeating: "1", count: 64)
        )
        let fingerprint = try! AnalysisInputFingerprint(
            imageSlot: ImageSlot(rawValue: Int.max),
            binaryID: uuid(1),
            binaryName: "",
            binaryPath: "/tmp/二进制🌐",
            selectedSliceIndex: Int.min,
            artifactIdentity: nil,
            imageByteCount: 3,
            imageBytesSHA256: String(repeating: "2", count: 64),
            facets: [fingerprintFacet],
            overallSHA256: String(repeating: "3", count: 64)
        )

        return WorkspaceSnapshot(
            binaries: [
                BinaryImage(
                    id: uuid(1), name: "", path: "/tmp/二进制🌐", kind: "Mach-O",
                    architecture: "arm64e", originalPathBookmark: Data([0, 0xff]),
                    metadata: BinaryMetadataSummary(
                        uuid: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", platformName: "macOS 🌐",
                        minimumOSVersion: nil, sdkVersion: "", buildTools: ["clang-∞", ""]
                    ),
                    selectedSliceIndex: Int.min, slot: ImageSlot(rawValue: Int.max)
                )
            ],
            functions: [
                FunctionSummary(
                    id: uuid(2), name: "函数🌐", startAddress: 0, endAddress: UInt64.max,
                    confidence: -Double.greatestFiniteMagnitude
                )
            ],
            symbols: [
                SymbolSummary(id: uuid(3), name: "", address: UInt64.max, kind: "调试", libraryName: ""),
                SymbolSummary(id: uuid(4), name: "nil-optionals", address: nil, kind: "", libraryName: nil)
            ],
            imports: [
                ImportSummary(id: uuid(5), name: "导入", libraryName: "", libraryOrdinal: Int.min),
                ImportSummary(id: uuid(6), name: "", libraryName: nil, libraryOrdinal: nil)
            ],
            indirectSymbols: [
                IndirectSymbolSummary(
                    id: uuid(7), kind: "stub", sourceSection: "__TEXT,__stubs🌐",
                    address: UInt64.max, entrySize: UInt32.max, tableIndex: UInt32.max,
                    rawSymbolIndex: UInt32.max, symbolIndex: Int.min, symbolName: "",
                    libraryOrdinal: Int.min, libraryName: "库", isLocal: true, isAbsolute: true
                )
            ],
            exports: [
                ExportSummary(id: uuid(8), name: "导出", address: UInt64.max, source: "trie"),
                ExportSummary(id: uuid(9), name: "", address: nil, source: "")
            ],
            stringLiterals: [
                StringLiteralSummary(
                    id: uuid(10), value: "\0雪🌐", address: UInt64.max,
                    sourceSection: "__TEXT,__cstring", byteLength: Int.max
                )
            ],
            basicBlocks: [
                BasicBlockSummary(
                    id: uuid(11), functionID: uuid(2), startAddress: 0,
                    endAddress: UInt64.max, instructionCount: Int.min
                )
            ],
            instructions: [
                InstructionRow(
                    address: UInt64.max, bytes: "", mnemonic: "udf", operands: "雪, #∞",
                    hasBreakpoint: true, comment: ""
                )
            ],
            xrefs: [XRef(id: uuid(12), from: 0, to: UInt64.max, kind: "调用🌐")],
            controlFlowEdges: [
                ControlFlowEdge(id: uuid(13), from: UInt64.max, to: 0, kind: "fallthrough")
            ],
            hexBytes: Data([0, 0x7f, 0xff]),
            jumpTables: [UInt64.max: [UInt64.max, 0], 0: [], 7: [1]],
            objcSelectors: [UInt64.max: "选择器:🌐", 0: "", 9: "nine"],
            objcClasses: [objcClass],
            objcCategories: [objcCategory],
            swiftTypes: [swiftType],
            swiftConformances: [SwiftConformance(typeName: "模块.类型🌈", protocolName: "协议")],
            sections: [
                SectionSummary(
                    id: uuid(14), name: "__DATA,__bss", address: UInt64.max, size: 0,
                    fileOffset: UInt64.max, isExecutable: true, isZeroFill: true,
                    fileSize: UInt64.max
                ),
                SectionSummary(
                    id: uuid(15), name: "", address: 0, size: UInt64.max,
                    fileOffset: 0, isExecutable: false, isZeroFill: false, fileSize: nil
                )
            ],
            relocations: [
                RelocationSummary(
                    id: uuid(16), address: UInt64.max, sectionName: "重定位",
                    typeCode: UInt32.max, typeName: "", symbolName: "符号",
                    symbolIndex: UInt32.max, addend: Int64.min, isPCRelative: true,
                    widthInBytes: UInt32.max
                ),
                RelocationSummary(
                    id: uuid(17), address: 0, sectionName: "", typeCode: 0,
                    typeName: nil, symbolName: nil, symbolIndex: nil, addend: nil,
                    isPCRelative: false, widthInBytes: 0
                )
            ],
            sourceLines: [
                SourceLineEntry(address: UInt64.max, file: "路径/源.swift", line: Int.min, column: Int.max, endSequence: false),
                SourceLineEntry(address: 0, file: nil, line: 0, column: Int.min, endSequence: true)
            ],
            imageBytes: Data([0xff, 0, 0x80]),
            addressOverrides: [
                ImageAddress.primary(UInt64.max): AddressOverride(customName: "must-not-transfer")
            ],
            typeDefinitions: [],
            manualXRefs: [
                ManualXRef(id: uuid(18), from: 1, to: 2, kind: "authoring", isSuppression: false)
            ],
            bookmarks: [Bookmark(id: uuid(19), address: 3, name: "authoring")],
            segmentOverrides: [
                SegmentOverride(id: uuid(20), originalName: "__TEXT", displayName: "Edited", rebaseDelta: -1)
            ],
            diagnostics: [
                AnalysisDiagnostic(
                    severity: .warning, address: UInt64.max,
                    kind: .loaderTruncation, message: "截断🌐"
                )
            ],
            machOMetadata: machO,
            analysisInputFingerprint: fingerprint
        )
    }

    private static func assertRoundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try roundTrip(value), value, file: file, line: line)
    }

    private static func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func jsonKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    private static func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }
}
