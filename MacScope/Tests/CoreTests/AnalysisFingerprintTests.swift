import CryptoKit
import XCTest
@testable import MacScope

final class AnalysisFingerprintTests: XCTestCase {
    func testSelectedSliceByteFingerprintUsesImageBytesNotHexPrefix() throws {
        let binary = Self.binary()
        var analysis = Self.analysis()
        analysis.imageBytes = Data([0, 1, 2, 3, 4, 5])
        analysis.hexBytes = Data([0, 1])

        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        analysis.hexBytes = Data([9, 9, 9, 9])
        let changedDisplayPrefix = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertEqual(baseline.imageByteCount, 6)
        XCTAssertEqual(baseline.imageBytesSHA256, Self.sha256Hex(Data([0, 1, 2, 3, 4, 5])))
        XCTAssertEqual(
            try baseline.facet(.selectedSliceBytes).sha256,
            try changedDisplayPrefix.facet(.selectedSliceBytes).sha256
        )
        XCTAssertEqual(baseline.overallSHA256, changedDisplayPrefix.overallSHA256)
    }

    func testFingerprintIsDeterministicAcrossRepeatedBuilds() throws {
        let binary = Self.binary()
        let analysis = Self.analysis()

        let first = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        let second = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.overallSHA256, second.overallSHA256)
        XCTAssertEqual(
            first.facets.map(\.kind).sorted { $0.rawValue < $1.rawValue },
            AnalysisFingerprintFacetKind.allCases.sorted { $0.rawValue < $1.rawValue }
        )
    }

    func testFacetDigestChangesOnlyForMutatedInstructionFacet() throws {
        let binary = Self.binary()
        var analysis = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        analysis.instructions[0].mnemonic = "mov"
        let mutated = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertNotEqual(try baseline.facet(.decodedInstructions).sha256, try mutated.facet(.decodedInstructions).sha256)
        XCTAssertEqual(try baseline.facet(.selectedSliceBytes).sha256, try mutated.facet(.selectedSliceBytes).sha256)
        XCTAssertEqual(try baseline.facet(.loaderSections).sha256, try mutated.facet(.loaderSections).sha256)
        XCTAssertEqual(try baseline.facet(.codeDataRanges).sha256, try mutated.facet(.codeDataRanges).sha256)
        XCTAssertEqual(try baseline.facet(.debugSourceLines).sha256, try mutated.facet(.debugSourceLines).sha256)
        XCTAssertNotEqual(baseline.overallSHA256, mutated.overallSHA256)
    }

    func testCodeDataRangesParticipateInFacetDigest() throws {
        let binary = Self.binary()
        var analysis = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        analysis.codeDataRanges[0].kind = "jump-table-8"
        let mutated = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertNotEqual(try baseline.facet(.codeDataRanges).sha256, try mutated.facet(.codeDataRanges).sha256)
        XCTAssertEqual(try baseline.facet(.selectedSliceBytes).sha256, try mutated.facet(.selectedSliceBytes).sha256)
        XCTAssertNotEqual(baseline.overallSHA256, mutated.overallSHA256)
    }

    func testDebugSourceLineArtifactEvidenceParticipatesInFacetDigest() throws {
        let binary = Self.binary()
        var analysis = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        analysis.sourceLines[0].debugArtifactMachOSHA256 = String(repeating: "b", count: 64)
        let mutated = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertNotEqual(try baseline.facet(.debugSourceLines).sha256, try mutated.facet(.debugSourceLines).sha256)
        XCTAssertEqual(try baseline.facet(.selectedSliceBytes).sha256, try mutated.facet(.selectedSliceBytes).sha256)
        XCTAssertEqual(try baseline.facet(.decodedInstructions).sha256, try mutated.facet(.decodedInstructions).sha256)
        XCTAssertNotEqual(baseline.overallSHA256, mutated.overallSHA256)
    }

    func testIdentityEffectiveByteAttestationParticipatesInRelocationFacetDigest() throws {
        let binary = Self.binary()
        var analysis = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        analysis.identityEffectiveByteRanges = [try IdentityEffectiveByteRangeAttestation(
            artifactIdentity: try XCTUnwrap(binary.artifactIdentity),
            segmentName: "__TEXT",
            startAddress: 0x1000,
            endAddressExclusive: 0x1006,
            sliceRelativeFileOffset: 0,
            byteCount: 6,
            initialProtections: 5,
            rawBytesSHA256: Self.sha256Hex(analysis.imageBytes)
        )]

        let attested = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertNotEqual(try baseline.facet(.relocations).sha256, try attested.facet(.relocations).sha256)
        XCTAssertEqual(try baseline.facet(.selectedSliceBytes).sha256, try attested.facet(.selectedSliceBytes).sha256)
        XCTAssertNotEqual(baseline.overallSHA256, attested.overallSHA256)
    }

    func testELFGNUBuildIDChangesOnlyTheLoadMetadataFacet() throws {
        var binary = Self.binary()
        let analysis = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        binary.metadata.elfGNUBuildID = "00112233445566778899aabbccddeeff"
        let identified = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertNotEqual(
            try baseline.facet(.machOLoadMetadata).sha256,
            try identified.facet(.machOLoadMetadata).sha256
        )
        for kind in AnalysisFingerprintFacetKind.allCases where kind != .machOLoadMetadata {
            XCTAssertEqual(try baseline.facet(kind).sha256, try identified.facet(kind).sha256, "\(kind)")
        }
        XCTAssertNotEqual(baseline.overallSHA256, identified.overallSHA256)
    }

    func testAbsentELFGNUBuildIDDoesNotAddAFingerprintField() throws {
        let binary = Self.binary()
        var analysis = Self.analysis()
        analysis.machOMetadata = nil
        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        var legacyWriter = AnalysisFingerprintCanonicalWriter()
        legacyWriter.optionalField("metadataUUID", binary.metadata.uuid)
        legacyWriter.optionalField("platformName", binary.metadata.platformName)
        legacyWriter.optionalField("minimumOSVersion", binary.metadata.minimumOSVersion)
        legacyWriter.optionalField("sdkVersion", binary.metadata.sdkVersion)
        for tool in binary.metadata.buildTools.sorted() {
            legacyWriter.field("buildTool", tool)
        }
        let identity = try XCTUnwrap(binary.artifactIdentity)
        legacyWriter.optionalField("artifactUUID", identity.uuid?.uuidString)
        legacyWriter.field("rawCPUType", identity.rawCPUType)
        legacyWriter.field("rawCPUSubtype", identity.rawCPUSubtype)
        legacyWriter.field("architectureVariant", identity.architectureVariant.rawValue)
        legacyWriter.field("selectedSliceSHA256", identity.selectedSliceSHA256)
        legacyWriter.field("selectedSliceByteCount", identity.selectedSliceByteCount)
        legacyWriter.field("machOMetadata", "nil")

        XCTAssertNil(binary.metadata.elfGNUBuildID)
        XCTAssertEqual(
            try fingerprint.facet(.machOLoadMetadata).sha256,
            legacyWriter.digestHex(),
            "nil GNU build-ID must preserve the pre-v41 metadata facet bytes"
        )
    }

    func testELFArchiveMemberIdentityChangesOverallDigestWithoutChangingAnalysisFacets() throws {
        var binary = Self.binary()
        binary.kind = "ELF relocatable object"
        binary.artifactIdentity = nil
        binary.selectedSliceIndex = nil
        let analysis = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        binary.elfArchiveMemberIdentity = Self.archiveSelection(
            memberName: "member.o",
            memberSHA256: Self.sha256Hex(analysis.imageBytes)
        )
        let selected = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)

        XCTAssertNil(baseline.elfArchiveMemberIdentity)
        XCTAssertEqual(selected.elfArchiveMemberIdentity, binary.elfArchiveMemberIdentity)
        XCTAssertEqual(baseline.facets, selected.facets)
        XCTAssertNotEqual(baseline.overallSHA256, selected.overallSHA256)

        var reordered = binary
        reordered.elfArchiveMemberIdentity = Self.archiveSelection(
            memberName: "member.o",
            memberSHA256: Self.sha256Hex(analysis.imageBytes),
            archiveHeaderIndex: 2
        )
        XCTAssertNotEqual(
            selected.overallSHA256,
            try AnalysisFingerprintBuilder.fingerprint(binary: reordered, analysis: analysis).overallSHA256
        )
    }

    func testLegacyUnavailableArtifactIdentityStillFingerprintsWithoutFabricatingArtifact() throws {
        var binary = Self.binary()
        binary.artifactIdentity = nil
        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: Self.analysis())

        XCTAssertNil(fingerprint.artifactIdentity)
        XCTAssertEqual(fingerprint.imageByteCount, UInt64(Self.analysis().imageBytes.count))
        XCTAssertTrue(AnalysisFacetFingerprint.isLowercaseSHA256(fingerprint.imageBytesSHA256))
        XCTAssertTrue(AnalysisFacetFingerprint.isLowercaseSHA256(fingerprint.overallSHA256))
    }

    func testValidationRejectsMalformedDigest() {
        XCTAssertThrowsError(
            try AnalysisFacetFingerprint(kind: .decodedInstructions, itemCount: 1, sha256: "NOT_A_SHA")
        ) { error in
            XCTAssertEqual(error as? AnalysisFingerprintError, .invalidSHA256(field: "sha256"))
        }

        XCTAssertThrowsError(
            try AnalysisInputFingerprint(
                imageSlot: .primary,
                binaryID: UUID(),
                binaryName: "bad",
                binaryPath: "/tmp/bad",
                selectedSliceIndex: nil,
                artifactIdentity: nil,
                imageByteCount: 0,
                imageBytesSHA256: String(repeating: "0", count: 64),
                facets: [],
                overallSHA256: "ABC"
            )
        ) { error in
            XCTAssertEqual(error as? AnalysisFingerprintError, .invalidSHA256(field: "overallSHA256"))
        }
    }

    func testDecodingRejectsMalformedFacetValues() throws {
        let data = """
        {
          "kind": "functions",
          "schemaVersion": 1,
          "itemCount": -1,
          "sha256": "\(String(repeating: "a", count: 64))"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(AnalysisFacetFingerprint.self, from: data)) { error in
            XCTAssertEqual(error as? AnalysisFingerprintError, .invalidItemCount)
        }
    }

    func testDecodingRejectsDuplicateFacetKinds() throws {
        let binary = Self.binary()
        let analysis = Self.analysis()
        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        let encoded = try JSONEncoder().encode(fingerprint)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let facets = try XCTUnwrap(object["facets"] as? [[String: Any]])
        object["facets"] = [facets[0], facets[0]]
        let duplicateData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(AnalysisInputFingerprint.self, from: duplicateData)
        ) { error in
            XCTAssertEqual(
                error as? AnalysisFingerprintError,
                .duplicateFacetKind(fingerprint.facets[0].kind)
            )
        }
    }

    func testInstructionAndControlFlowMemosFollowValueMutationsAndCopies() throws {
        let binary = Self.binary()
        var original = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: original)
        var copy = original
        XCTAssertTrue(copy.instructionFingerprintMemo === original.instructionFingerprintMemo)
        XCTAssertTrue(copy.controlFlowFingerprintMemo === original.controlFlowFingerprintMemo)
        copy.instructions[0].mnemonic = "changed"
        XCTAssertFalse(copy.instructionFingerprintMemo === original.instructionFingerprintMemo)
        XCTAssertTrue(copy.controlFlowFingerprintMemo === original.controlFlowFingerprintMemo)
        let edited = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: copy)
        XCTAssertNotEqual(try baseline.facet(.decodedInstructions), try edited.facet(.decodedInstructions))
        XCTAssertEqual(try baseline.facet(.controlFlow), try edited.facet(.controlFlow))
        original.controlFlowEdges[0].to += 4
        XCTAssertFalse(copy.controlFlowFingerprintMemo === original.controlFlowFingerprintMemo)
        let flowEdit = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: original)
        XCTAssertNotEqual(try baseline.facet(.controlFlow), try flowEdit.facet(.controlFlow))
        XCTAssertEqual(try baseline.facet(.decodedInstructions), try flowEdit.facet(.decodedInstructions))
    }

    func testCanonicalMemoPreservesSchemaOneAndPresentationIndependence() throws {
        let binary = Self.binary()
        var analysis = Self.analysis()
        let baseline = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        // Independent reproduction of the historical length-prefixed schema-1 instruction stream.
        var bytes = Data()
        func field(_ name: String, _ value: String) {
            for item in [name, value] {
                bytes.append(contentsOf: "\(item.utf8.count):".utf8)
                bytes.append(contentsOf: item.utf8)
                bytes.append(10)
            }
        }
        for row in analysis.instructions.sorted(by: { $0.address < $1.address }) {
            field("begin", "instruction")
            field("address", String(row.address))
            field("bytes", row.bytes)
            field("mnemonic", row.mnemonic)
            field("operands", row.operands)
            field("end", "instruction")
        }
        XCTAssertEqual(try baseline.facet(.decodedInstructions).sha256, Self.sha256Hex(bytes))
        XCTAssertEqual(baseline.schemaVersion, 1)
        analysis.instructions[0].comment = "a different comment"
        analysis.instructions[0].hasBreakpoint.toggle()
        let edge = analysis.controlFlowEdges[0]
        analysis.controlFlowEdges[0] = ControlFlowEdge(id: UUID(), from: edge.from, to: edge.to, kind: edge.kind)
        let presentation = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        XCTAssertEqual(presentation, baseline)
    }

    // MARK: - Lane AL: streaming writer parity (schema 1 unchanged)

    /// Independent reference for the historical schema-1 stream: Foundation Data, Swift's own
    /// decimal formatting, `"<utf8 count>:" + utf8 + "\n"` per name and value.
    private struct ReferenceCanonicalStream {
        var bytes = Data()
        mutating func raw(_ item: String) {
            bytes.append(contentsOf: Array("\(item.utf8.count):".utf8))
            bytes.append(contentsOf: Array(item.utf8))
            bytes.append(0x0A)
        }
        mutating func field(_ name: String, _ value: String) { raw(name); raw(value) }
    }

    func testStreamingCanonicalWriterMatchesReferenceByteStreamForEveryFieldShape() {
        XCTAssertEqual(AnalysisFingerprintCanonicalWriter().digestHex(), Self.sha256Hex(Data()))
        var writer = AnalysisFingerprintCanonicalWriter()
        var reference = ReferenceCanonicalStream()
        let bridged = NSString(string: "bridged \u{2713} NSString operand") as String
        let bridgedLong = NSString(string: String(repeating: "q\u{00e9}", count: 9_000)) as String
        let strings = ["", "a", "nop", "x0, x1, #4095", "\u{03b1}\u{2192}\u{03b2} \u{1F9EA}", "1f 20 03 d5", bridged]
        let longStrings = [String(repeating: "z", count: 70_000), String(repeating: "\u{00e9}", count: 40_000), bridgedLong]
        let ints: [Int] = [0, 1, -1, 9, 10, -10, 99, 100, 12_345, Int.max, Int.min, Int(Int32.min)]
        let int32s: [Int32] = [0, -1, 7, Int32.max, Int32.min]
        let uint32s: [UInt32] = [0, 1, 9, 10, UInt32.max]
        let uint64s: [UInt64] = [0, 1, 9, 10, 0x1000, UInt64(Int64.max), UInt64.max, UInt64.max / 10]
        let int64s: [Int64?] = [nil, 0, -1, Int64.min, Int64.max, 42]
        let doubles: [Double] = [0, 1, 0.1, -2.5, 1e300, .pi]
        for round in 0..<300 {
            writer.beginRecord("r\(round)"); reference.field("begin", "r\(round)")
            for value in strings { writer.field("s", value); reference.field("s", value) }
            if round.isMultiple(of: 60) {
                for value in longStrings { writer.field("long", value); reference.field("long", value) }
            }
            for value in ints {
                writer.field("i", value); reference.field("i", String(value))
                writer.optionalField("oi", value); reference.field("oi", String(value))
            }
            for value in int32s { writer.field("i32", value); reference.field("i32", String(value)) }
            for value in uint32s {
                writer.field("u32", value); reference.field("u32", String(value))
                writer.optionalField("ou32", value); reference.field("ou32", String(value))
            }
            for value in uint64s {
                writer.field("u64", value); reference.field("u64", String(value))
                writer.optionalField("ou64", value); reference.field("ou64", String(value))
            }
            for value in int64s { writer.optionalField("oi64", value); reference.field("oi64", value.map(String.init) ?? "<nil>") }
            for value in doubles { writer.field("d", value); reference.field("d", String(format: "%.17g", value)) }
            writer.field("b", round.isMultiple(of: 2)); reference.field("b", round.isMultiple(of: 2) ? "true" : "false")
            writer.optionalField("os", round.isMultiple(of: 3) ? nil : "v\(round)")
            reference.field("os", round.isMultiple(of: 3) ? "<nil>" : "v\(round)")
            writer.optionalField("oiNil", Int?.none); reference.field("oiNil", "<nil>")
            writer.optionalField("ou32Nil", UInt32?.none); reference.field("ou32Nil", "<nil>")
            writer.optionalField("ou64Nil", UInt64?.none); reference.field("ou64Nil", "<nil>")
            writer.endRecord("r\(round)"); reference.field("end", "r\(round)")
        }
        XCTAssertGreaterThan(reference.bytes.count, 1 << 20)
        XCTAssertEqual(writer.digestHex(), Self.sha256Hex(reference.bytes))
    }

    /// Goldens captured once from the pre-streaming builder (github/main 5a3b0e367). Any change
    /// to the canonical stream, sort order or facet composition fails here.
    func testRichFixtureFingerprintsMatchPreStreamingGoldens() throws {
        let fixtures = try Self.parityFixtures()
        var lines: [String] = []
        for (label, binary, analysis) in fixtures {
            let fingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
            let facets = fingerprint.facets.sorted { $0.kind.rawValue < $1.kind.rawValue }
                .map { "\($0.kind.rawValue)=\($0.itemCount)/\($0.sha256)" }
            lines.append("\(label) overall=\(fingerprint.overallSHA256) " + facets.joined(separator: " "))
        }
        print("AL_PARITY_GOLDENS\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(lines, Self.parityGoldens)
    }

    private static let parityGoldens: [String] = [
        [
            "rich",
            "overall=ade29c5fb44c916e6555d20dce995a202dbbe0fa7cb787bf8bb5309cb60f157c",
            "codeDataRanges=1/9f0f90ac10dec2caf58e790a85e37da14875f6f1d96d8fc5e26cb97c80f834af",
            "controlFlow=3000/639d297274380d720ec6ac5471a3757fe0516685d5011ac6fb145ad7800c93d6",
            "debugSourceLines=1/3ad6b8b052760cd91f6310b7faa5cf1014a6124f4437c77c2e44e8a8cf7d763f",
            "decodedInstructions=5000/539d8d8a228cfec0b3b451dd62a9ebb36392445817b27c04843a68e1188207de",
            "functions=2/2c93141ec62f8e546d72b3b9caf55bb4a1a94cf1c58ffc61d1dea7c6c7bf9dc2",
            "loaderSections=1/81c3fbf1c8ff79bf45b5bc507698229404242c89433d72d7f504dd9f37357305",
            "machOLoadMetadata=1/12fea467bc4afa0bd21c8237ec1bc26d14bc2a778dff53619ac12df9e6599c17",
            "relocations=3/0add9c985737e3dcfd2aaf08c4822aaf00cf4364ebf244f2cb47f82ef92fdf2a",
            "selectedSliceBytes=1/231fdd1eb3593ed82017fe7437835ea9b7f81b65c91b0333fd2faaf9618826da",
            "xrefs=1/f5201344a154df529ef295808ac6db5ec8cd36ea0c8f48d67edb8105dd586f68",
        ].joined(separator: " "),
        [
            "sortedDuplicates",
            "overall=193937cae5b098cba098369f58ac0eba028d4892e7ab53aa0cdef212eff0cc81",
            "codeDataRanges=1/9f0f90ac10dec2caf58e790a85e37da14875f6f1d96d8fc5e26cb97c80f834af",
            "controlFlow=1/ede2af314a327fea342d192bfeaedafafe318145cbb5ab12a7abab482c881989",
            "debugSourceLines=1/3ad6b8b052760cd91f6310b7faa5cf1014a6124f4437c77c2e44e8a8cf7d763f",
            "decodedInstructions=4000/66474c5d391598cfa4cb5f87fbeac72724c8adf590de64280b9e592c6ca05300",
            "functions=1/ec17034cd20d9586ec1d708a305391b52d2223171fb7d257a88696adfd84b2d2",
            "loaderSections=1/81c3fbf1c8ff79bf45b5bc507698229404242c89433d72d7f504dd9f37357305",
            "machOLoadMetadata=1/12fea467bc4afa0bd21c8237ec1bc26d14bc2a778dff53619ac12df9e6599c17",
            "relocations=0/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "selectedSliceBytes=1/231fdd1eb3593ed82017fe7437835ea9b7f81b65c91b0333fd2faaf9618826da",
            "xrefs=1/f5201344a154df529ef295808ac6db5ec8cd36ea0c8f48d67edb8105dd586f68",
        ].joined(separator: " "),
        [
            "elfArchive",
            "overall=71da1e06cb3e35aff893e409de85a7d84fc3089cbf05bdfae8c23d2d6c5371db",
            "codeDataRanges=1/9f0f90ac10dec2caf58e790a85e37da14875f6f1d96d8fc5e26cb97c80f834af",
            "controlFlow=3000/639d297274380d720ec6ac5471a3757fe0516685d5011ac6fb145ad7800c93d6",
            "debugSourceLines=1/3ad6b8b052760cd91f6310b7faa5cf1014a6124f4437c77c2e44e8a8cf7d763f",
            "decodedInstructions=5000/539d8d8a228cfec0b3b451dd62a9ebb36392445817b27c04843a68e1188207de",
            "functions=2/2c93141ec62f8e546d72b3b9caf55bb4a1a94cf1c58ffc61d1dea7c6c7bf9dc2",
            "loaderSections=1/81c3fbf1c8ff79bf45b5bc507698229404242c89433d72d7f504dd9f37357305",
            "machOLoadMetadata=1/86f9b1fd1dfbde122dcb5c02b5f966e907ff075e18a323fea8e1d738a2715c93",
            "relocations=2/f9aedf53e94cc854a9f6d209167bd014dc99a473b1db71c3278be3032c2a97f5",
            "selectedSliceBytes=1/231fdd1eb3593ed82017fe7437835ea9b7f81b65c91b0333fd2faaf9618826da",
            "xrefs=1/f5201344a154df529ef295808ac6db5ec8cd36ea0c8f48d67edb8105dd586f68",
        ].joined(separator: " "),
    ]

    private static func parityFixtures() throws -> [(String, BinaryImage, ImageAnalysis)] {
        let binary = Self.binary()
        var rich = Self.analysis()
        rich.relocations = [
            RelocationSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!, address: 0x1010,
                              sectionName: "__DATA,__const", typeCode: 0, typeName: "ARM64_RELOC_UNSIGNED",
                              symbolName: "_puts", symbolIndex: 3, addend: -8, isPCRelative: false, widthInBytes: 8),
            RelocationSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!, address: 0x1004,
                              sectionName: "__TEXT,__text", typeCode: 2, typeName: nil, symbolName: nil,
                              symbolIndex: nil, addend: nil, isPCRelative: true, widthInBytes: 4),
        ]
        rich.identityEffectiveByteRanges = [try IdentityEffectiveByteRangeAttestation(
            artifactIdentity: try XCTUnwrap(binary.artifactIdentity), segmentName: "__TEXT",
            startAddress: 0x1000, endAddressExclusive: 0x1006, sliceRelativeFileOffset: 0, byteCount: 6,
            initialProtections: 5, rawBytesSHA256: Self.sha256Hex(rich.imageBytes)
        )]
        // Unsorted rows with duplicate addresses exercise the stable-sort path; varied text
        // lengths cross the writer's internal buffer boundaries.
        rich.instructions = (0..<5_000).map { index in
            let address = 0x2000 + UInt64((index * 7_919) % 4_999) * 4
            return InstructionRow(address: address, bytes: index.isMultiple(of: 5) ? "" : "1f 20 03 d5",
                                  mnemonic: index.isMultiple(of: 3) ? "add" : "nop",
                                  operands: String(repeating: "x\(index % 31), ", count: index % 9) + "\u{03b1}",
                                  hasBreakpoint: false, comment: nil)
        }
        rich.controlFlowEdges = (0..<3_000).map { index in
            ControlFlowEdge(id: UUID(), from: 0x2000 + UInt64((index * 31) % 1_500) * 4,
                            to: 0x2000 + UInt64(index % 97) * 4, kind: index.isMultiple(of: 2) ? "branch" : "fallthrough")
        }
        rich.functions.append(FunctionSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
                                              name: "_second", startAddress: 0x2000, endAddress: 0x3000, confidence: 0.625))
        var sortedRows = Self.analysis()
        sortedRows.instructions = (0..<4_000).map { index in
            InstructionRow(address: 0x1000 + UInt64(index / 2) * 4, bytes: "c0 03 5f d6", mnemonic: "ret",
                           operands: index.isMultiple(of: 2) ? "" : "dup\(index)", hasBreakpoint: false, comment: nil)
        }
        var elfBinary = binary
        elfBinary.kind = "ELF relocatable object"
        elfBinary.artifactIdentity = nil
        elfBinary.selectedSliceIndex = nil
        elfBinary.metadata.elfGNUBuildID = "00112233445566778899aabbccddeeff"
        elfBinary.elfArchiveMemberIdentity = Self.archiveSelection(memberName: "member.o",
                                                                   memberSHA256: Self.sha256Hex(rich.imageBytes))
        var elf = rich
        elf.machOMetadata = nil
        elf.identityEffectiveByteRanges = []
        return [("rich", binary, rich), ("sortedDuplicates", binary, sortedRows), ("elfArchive", elfBinary, elf)]
    }

    private static func binary() -> BinaryImage {
        let identity = try! MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 6
        )
        return BinaryImage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "FingerprintFixture",
            path: "/tmp/FingerprintFixture",
            kind: "Mach-O executable",
            architecture: "arm64",
            selectedSliceIndex: 0,
            artifactIdentity: identity,
            slot: .primary
        )
    }

    private static func analysis() -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data([0, 1, 2, 3, 4, 5])
        analysis.hexBytes = Data([0, 1])
        analysis.sections = [
            SectionSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                name: "__TEXT,__text",
                address: 0x1000,
                size: 0x20,
                fileOffset: 0,
                isExecutable: true
            ),
        ]
        analysis.codeDataRanges = [
            CodeDataRangeSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                address: 0x1008,
                size: 4,
                kind: "data"
            ),
        ]
        analysis.instructions = [
            InstructionRow(address: 0x1000, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: true, comment: "user"),
            InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        analysis.functions = [
            FunctionSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                name: "_main",
                startAddress: 0x1000,
                endAddress: 0x1008,
                confidence: 1
            ),
        ]
        analysis.basicBlocks = [
            BasicBlockSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                functionID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                startAddress: 0x1000,
                endAddress: 0x1008,
                instructionCount: 2
            ),
        ]
        analysis.controlFlowEdges = [
            ControlFlowEdge(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                from: 0x1000,
                to: 0x1004,
                kind: "fallthrough"
            ),
        ]
        analysis.xrefs = [
            XRef(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
                from: 0x1000,
                to: 0x2000,
                kind: XRefKind.data
            ),
        ]
        analysis.sourceLines = [
            SourceLineEntry(
                address: 0x1000,
                file: "/tmp/main.c",
                line: 12,
                column: 3,
                endSequence: false,
                debugArtifactUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
                debugArtifactMachOSHA256: String(repeating: "a", count: 64),
                debugArtifactMachOByteCount: 128,
                lineProgramUnitOffset: 0x20,
                fileTableIndex: 1,
                tablePath: nil
            ),
        ]
        analysis.machOMetadata = MachOLoadMetadata(
            codeSignature: MachOLoadMetadata.CodeSignatureInfo(
                teamIdentifier: "ABCDE12345",
                identifier: "com.example.fixture",
                hashTypeName: "SHA-256",
                codeSignatureFlags: 0,
                entitlementsDER: false,
                entitlementsKeys: ["com.apple.security.get-task-allow"],
                entitlementsParsed: true
            ),
            importedSymbols: [
                MachOLoadMetadata.ImportedSymbol(
                    name: "_puts",
                    libraryOrdinal: 1,
                    libraryName: "/usr/lib/libSystem.B.dylib",
                    isWeak: false,
                    addend: nil,
                    source: "import table"
                ),
            ],
            dependentDylibs: [
                MachOLoadMetadata.DependentDylib(
                    path: "/usr/lib/libSystem.B.dylib",
                    kind: "required",
                    currentVersion: "1.0.0",
                    compatibilityVersion: "1.0.0",
                    ordinal: 1
                ),
            ]
        )
        return analysis
    }

    private static func archiveSelection(
        memberName: String,
        memberSHA256: String,
        archiveHeaderIndex: Int = 1
    ) -> ELFArchiveMemberSelection {
        ELFArchiveMemberSelection(
            container: ELFArchiveContainerIdentity(
                byteCount: 256,
                sha256: String(repeating: "c", count: 64)
            ),
            member: ELFArchiveMemberIdentity(
                index: 0,
                archiveHeaderIndex: archiveHeaderIndex,
                name: memberName,
                payloadOffset: 64,
                byteCount: 6,
                sha256: memberSHA256
            )
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension AnalysisInputFingerprint {
    func facet(_ kind: AnalysisFingerprintFacetKind) throws -> AnalysisFacetFingerprint {
        try XCTUnwrap(facets.first { $0.kind == kind })
    }
}
