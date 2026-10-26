import Foundation
import XCTest
@testable import MacScope
@testable import MacScopeAnalysisCore

final class NavigatorProvenanceResolverTests: XCTestCase {
    // MARK: - Grammar

    func testEveryGrammarKindRoundTrips() {
        let hash = "sha256:" + String(repeating: "0123456789abcdef", count: 4)
        let canonical: [(kind: String, ref: String, parsed: NavigatorProvenanceRef)] = [
            ("loaderRecord", "lc[0]", .loadCommand(index: 0)),
            ("loaderRecord", "lc[12]", .loadCommand(index: 12)),
            ("loaderRecord", "section[__TEXT,__text]", .section(segment: "__TEXT", name: "__text")),
            ("loaderRecord", "functionStarts[1]@0x1000000fc",
             .tableEntry(table: "functionStarts", index: 1, address: 0x1_0000_00fc)),
            ("loaderRecord", "exports[0]@0x340", .tableEntry(table: "exports", index: 0, address: 0x340)),
            ("loaderRecord", "nlist[14]@0x340", .tableEntry(table: "nlist", index: 14, address: 0x340)),
            ("loaderRecord", "unwind[0]@0x0", .tableEntry(table: "unwind", index: 0, address: 0)),
            ("decodedInstruction", "0x1000000f8", .instruction(address: 0x1_0000_00f8)),
            ("metadataRecord", "__swift5_types@0x4e8", .metadataRecord(section: "__swift5_types", address: 0x4e8)),
            ("rule", "proof.function-start-structural@1", .rule(id: "proof.function-start-structural", version: "1")),
            ("proofCertificate", hash, .certificate(hash: hash)),
            ("signatureRecord", "libsystem/strlen", .signatureRecord(corpus: "libsystem", recordID: "strlen")),
            ("analystAction", "ann:session-1/3", .analystAction(session: "session-1", seq: 3)),
            ("symbolGraph", "Swift:s:Si", .symbolGraph(module: "Swift", usr: "s:Si")),
        ]
        for item in canonical {
            let parsed = NavigatorProvenanceRef.parse(kind: item.kind, ref: item.ref)
            XCTAssertEqual(parsed, item.parsed, "\(item.kind) \(item.ref)")
            XCTAssertEqual(parsed?.ref, item.ref, "\(item.kind) \(item.ref)")
            XCTAssertEqual(parsed?.kind, item.kind, "\(item.kind) \(item.ref)")
            XCTAssertEqual(item.parsed.provenance, NavigatorProvenance(kind: item.kind, ref: item.ref))
        }
        XCTAssertEqual(Set(canonical.map(\.kind)), Set(NavigatorContractVocabulary.provenanceKinds))
    }

    func testNonCanonicalRefsDoNotParse() {
        let rejected: [(String, String)] = [
            ("loaderRecord", "lc[01]"),
            ("loaderRecord", "lc[-1]"),
            ("loaderRecord", "lc[]"),
            ("loaderRecord", "section[__TEXT]"),
            ("loaderRecord", "section[__TEXT,]"),
            ("loaderRecord", "section[__TEXT,__a_name_longer_than_16]"),
            ("loaderRecord", "functionStarts[0]@0x0100"),
            ("loaderRecord", "functionStarts[0]@0X100"),
            ("loaderRecord", "function-starts[0]@0x100"),
            ("loaderRecord", "functionStarts@0x100"),
            ("decodedInstruction", "0x"),
            ("decodedInstruction", "4096"),
            ("decodedInstruction", "0xABC"),
            ("metadataRecord", "0x4e8"),
            ("rule", "proof.function-start-structural"),
            ("rule", "@1"),
            ("rule", "id@"),
            ("proofCertificate", "sha256:abc"),
            ("proofCertificate", "sha256:" + String(repeating: "A", count: 64)),
            ("proofCertificate", String(repeating: "a", count: 64)),
            ("signatureRecord", "libsystem"),
            ("signatureRecord", "/strlen"),
            ("analystAction", "session-1/3"),
            ("analystAction", "ann:session-1/03"),
            ("analystAction", "ann:/3"),
            ("symbolGraph", "Swift"),
            ("symbolGraph", ":s:Si"),
            ("notAKind", "lc[0]"),
        ]
        for (kind, ref) in rejected {
            XCTAssertNil(NavigatorProvenanceRef.parse(kind: kind, ref: ref), "\(kind) \(ref)")
        }
    }

    // MARK: - Loader records (bytes built in the test)

    func testResolvesLoadCommandsAndSectionHeader() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let binary = ResolverFixtures.binary(fixture.bytes)
        let evidence = try XCTUnwrap(NavigatorImageEvidence(binary: binary))
        XCTAssertEqual(evidence.file.loadCommands.count, 3)

        // Header (32 bytes), LC_SEGMENT_64 with one section (152), LC_FUNCTION_STARTS (16), LC_MAIN (24).
        let expected: [(String, Range<Int>)] = [("lc[0]", 32 ..< 184), ("lc[1]", 184 ..< 200), ("lc[2]", 200 ..< 224)]
        for (ref, range) in expected {
            let resolved = NavigatorProvenanceResolver.resolve(NavigatorProvenance(kind: "loaderRecord", ref: ref), in: binary)
            XCTAssertEqual(resolved.range, range, ref)
            XCTAssertEqual(resolved.sha256, ResolverFixtures.sha256(fixture.bytes, range), ref)
        }
        let functionStarts = NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "loaderRecord", ref: "lc[1]"), in: binary)
        guard case .record(let description, _, _) = functionStarts else { return XCTFail("expected record") }
        XCTAssertTrue(description.hasPrefix(evidence.file.loadCommands[1].name))

        let section = NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "loaderRecord", ref: "section[__TEXT,__text]"), in: binary)
        XCTAssertEqual(section.range, 104 ..< 184)
        XCTAssertEqual(section.sha256, ResolverFixtures.sha256(fixture.bytes, 104 ..< 184))
        XCTAssertEqual(evidence.sectionHeaderRange(segment: "__TEXT", name: "__text"), 104 ..< 184)

        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "lc[3]", binary), .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "lc[99]", binary), .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "section[__DATA,__data]", binary), .noSuchRecord)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "lc[x]", binary), .noSuchRecord)
    }

    func testResolvesFunctionStartsEntries() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let binary = ResolverFixtures.binary(fixture.bytes)
        let code = fixture.baseAddress
        let startsOffset = ResolverFixtures.functionStartsOffset(fixture)
        XCTAssertEqual(startsOffset, 256)

        let first = NavigatorProvenanceResolver.resolve(
            NavigatorProvenanceRef.tableEntry(table: "functionStarts", index: 0, address: code).provenance, in: binary)
        XCTAssertEqual(first.range, startsOffset ..< (startsOffset + 2))
        XCTAssertEqual(first.sha256, ResolverFixtures.sha256(fixture.bytes, startsOffset ..< (startsOffset + 2)))

        let second = NavigatorProvenanceResolver.resolve(
            NavigatorProvenanceRef.tableEntry(table: "functionStarts", index: 1, address: code + 0x1c).provenance, in: binary)
        XCTAssertEqual(second.range, (startsOffset + 2) ..< (startsOffset + 3))
        XCTAssertEqual(Array(fixture.bytes[(startsOffset + 2) ..< (startsOffset + 3)]), [0x1c])

        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "functionStarts[0]@\(NavigatorSubjectRef.address(code + 4))", binary),
                       .noSuchRecord)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "functionStarts[2]@\(NavigatorSubjectRef.address(code))", binary),
                       .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "unwind[0]@\(NavigatorSubjectRef.address(code))", binary),
                       .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "nlist[0]@\(NavigatorSubjectRef.address(code))", binary),
                       .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "relocations[0]@\(NavigatorSubjectRef.address(code))", binary),
                       .noSuchRecord)
    }

    func testResolvesDecodedInstructionBytes() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let binary = ResolverFixtures.binary(fixture.bytes)
        let blAddress = fixture.baseAddress + 0x18
        let resolved = NavigatorProvenanceResolver.resolve(
            NavigatorProvenanceRef.instruction(address: blAddress).provenance, in: binary)
        let offset = fixture.codeOffset + 0x18
        guard case .bytes(let range, let sha256) = resolved else { return XCTFail("expected bytes, got \(resolved)") }
        XCTAssertEqual(range, offset ..< (offset + 4))
        XCTAssertEqual(Array(fixture.bytes[range]), [0x01, 0x00, 0x00, 0x94])
        XCTAssertEqual(sha256, ResolverFixtures.sha256(fixture.bytes, range))

        XCTAssertEqual(ResolverFixtures.reason("decodedInstruction", NavigatorSubjectRef.address(blAddress + 2), binary),
                       .noSuchRecord)
        XCTAssertEqual(ResolverFixtures.reason("decodedInstruction", "0xdead0000", binary), .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("decodedInstruction",
                                               NavigatorSubjectRef.address(fixture.baseAddress + UInt64(fixture.code.count)),
                                               binary), .outOfBounds)
    }

    func testResolvesSymbolTableAndExportEntries() throws {
        for useExportsTrieCommand in [false, true] {
            let fixture = MachOFixture.makeExecutableWithSymbols(useExportsTrieCommand: useExportsTrieCommand)
            let binary = ResolverFixtures.binary(fixture.bytes)
            let evidence = try XCTUnwrap(NavigatorImageEvidence(binary: binary))
            let code = fixture.baseAddress
            let symbolOffset = (fixture.codeOffset + fixture.code.count + 7) & ~7
            let label = useExportsTrieCommand ? "LC_DYLD_EXPORTS_TRIE" : "LC_DYLD_INFO_ONLY"

            XCTAssertEqual(evidence.symtabCommand, 2, label)
            XCTAssertEqual(evidence.exportTrieCommand, 4, label)
            XCTAssertEqual(evidence.symbolTableOffset, symbolOffset, label)
            XCTAssertEqual(evidence.symbolCount, 3, label)
            XCTAssertEqual(evidence.sectionSymbolHits(code), [0, 1], label)

            let local = NavigatorProvenanceResolver.resolve(
                NavigatorProvenanceRef.tableEntry(table: "nlist", index: 0, address: code).provenance, in: binary)
            XCTAssertEqual(local.range, symbolOffset ..< (symbolOffset + 16), label)
            XCTAssertEqual(local.sha256, ResolverFixtures.sha256(fixture.bytes, symbolOffset ..< (symbolOffset + 16)), label)
            let external = NavigatorProvenanceResolver.resolve(
                NavigatorProvenanceRef.tableEntry(table: "nlist", index: 1, address: code).provenance, in: binary)
            XCTAssertEqual(external.range, (symbolOffset + 16) ..< (symbolOffset + 32), label)
            // nlist[2] is the undefined `_puts` import: not an N_SECT symbol.
            XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "nlist[2]@0x0", binary), .noSuchRecord, label)
            XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "nlist[3]@\(NavigatorSubjectRef.address(code))", binary),
                           .outOfBounds, label)

            // `_exported_entry` comes from LC_SYMTAB and resolves to its nlist_64 entry.
            let symbolExport = try XCTUnwrap(evidence.file.exports.firstIndex { $0.name == "_exported_entry" }, label)
            XCTAssertEqual(evidence.file.exports[symbolExport].symbolIndex, 1, label)
            XCTAssertEqual(evidence.exportHits(code), [symbolExport], label)
            let symbolExportResolved = NavigatorProvenanceResolver.resolve(
                NavigatorProvenanceRef.tableEntry(table: "exports", index: symbolExport, address: code).provenance, in: binary)
            XCTAssertEqual(symbolExportResolved.range, external.range, label)

            // `_trie_export` comes from the export trie and resolves to its terminal bytes.
            let trieExport = try XCTUnwrap(evidence.file.exports.firstIndex { $0.name == "_trie_export" }, label)
            XCTAssertNil(evidence.file.exports[trieExport].symbolIndex, label)
            let trie = try XCTUnwrap(evidence.exportTrie, label)
            let terminal = try XCTUnwrap(evidence.exportTerminal(named: "_trie_export"), label)
            XCTAssertEqual(terminal.flags, 0, label)
            XCTAssertEqual(terminal.value, UInt64(fixture.codeOffset + 4), label)
            XCTAssertEqual(evidence.exportAddress(of: terminal), code + 4, label)
            XCTAssertTrue(trie.contains(terminal.range.lowerBound) && terminal.range.upperBound <= trie.upperBound, label)
            XCTAssertNil(evidence.exportTerminal(named: "_trie_expor"), label)
            XCTAssertNil(evidence.exportTerminal(named: "_missing"), label)
            let trieResolved = NavigatorProvenanceResolver.resolve(
                NavigatorProvenanceRef.tableEntry(table: "exports", index: trieExport, address: code + 4).provenance, in: binary)
            XCTAssertEqual(trieResolved.range, terminal.range, label)
            XCTAssertEqual(trieResolved.sha256, ResolverFixtures.sha256(fixture.bytes, terminal.range), label)

            XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "exports[\(trieExport)]@\(NavigatorSubjectRef.address(code))", binary),
                           .noSuchRecord, label)
            XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "exports[\(evidence.file.exports.count)]@0x0", binary),
                           .outOfBounds, label)
        }
    }

    // MARK: - Loader records (unwind fixture)

    func testResolvesUnwindLoaderTables() throws {
        let binary = try ResolverFixtures.unwindLoops()
        let evidence = try XCTUnwrap(NavigatorImageEvidence(binary: binary))
        XCTAssertEqual(evidence.image, ResolverFixtures.unwindImageRef)
        XCTAssertEqual(evidence.imageBase, 0)
        XCTAssertEqual(evidence.functionStartsCommand, 11)
        XCTAssertEqual(evidence.exportTrieCommand, 4)
        XCTAssertEqual(evidence.symtabCommand, 5)
        XCTAssertEqual(evidence.exportTrie, 16432 ..< 16688)

        let cases: [(String, Range<Int>)] = [
            ("functionStarts[0]@0x340", 16688 ..< 16690),
            ("nlist[14]@0x340", 16936 ..< 16952),
            ("unwind[0]@0x340", 1336 ..< 1340),
            ("section[__TEXT,__text]", 104 ..< 184),
            ("section[__TEXT,__unwind_info]", 184 ..< 264),
            ("lc[11]", 752 ..< 768),
        ]
        for (ref, range) in cases {
            let resolved = NavigatorProvenanceResolver.resolve(NavigatorProvenance(kind: "loaderRecord", ref: ref), in: binary)
            XCTAssertEqual(resolved.range, range, ref)
            XCTAssertEqual(resolved.sha256, ResolverFixtures.sha256(binary.bytes, range), ref)
        }
        XCTAssertEqual(Array(binary.bytes[16688 ..< 16690]), [0xc0, 0x06])

        let export = try XCTUnwrap(evidence.file.exports.firstIndex { $0.name == "_loop_zero" })
        XCTAssertEqual(evidence.exportHits(0x340), [export])
        let exportResolved = NavigatorProvenanceResolver.resolve(
            NavigatorProvenanceRef.tableEntry(table: "exports", index: export, address: 0x340).provenance, in: binary)
        let exportRange = try XCTUnwrap(exportResolved.range)
        XCTAssertTrue(exportRange.lowerBound >= 16432 && exportRange.upperBound <= 16688)

        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "functionStarts[0]@0x344", binary), .noSuchRecord)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "unwind[0]@0x36c", binary), .noSuchRecord)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "nlist[15]@0x340", binary), .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "unwind[\(evidence.unwindRows.count)]@0x340", binary),
                       .outOfBounds)
    }

    func testResolvesUnwindMetadataRecordAndInstruction() throws {
        let binary = try ResolverFixtures.unwindLoops()
        let record = NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "metadataRecord", ref: "__unwind_info@0x4e8"), in: binary)
        XCTAssertEqual(record.range, 1256 ..< 1384)
        XCTAssertEqual(record.sha256, ResolverFixtures.sha256(binary.bytes, 1256 ..< 1384))
        let qualified = NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "metadataRecord", ref: "__TEXT,__unwind_info@0x4f0"), in: binary)
        XCTAssertEqual(qualified.range, 1264 ..< 1384)
        XCTAssertEqual(ResolverFixtures.reason("metadataRecord", "__unwind_info@0x340", binary), .outOfBounds)
        XCTAssertEqual(ResolverFixtures.reason("metadataRecord", "__swift5_types@0x340", binary), .noSuchRecord)

        let instruction = NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "decodedInstruction", ref: "0x340"), in: binary)
        XCTAssertEqual(instruction.range, 832 ..< 836)
        // __unwind_info holds no instructions.
        XCTAssertEqual(ResolverFixtures.reason("decodedInstruction", "0x4e8", binary), .noSuchRecord)
    }

    // MARK: - Non-image kinds

    func testResolvesRulesFromTheRegistry() throws {
        let standard = NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "rule", ref: "macho.slice-identity@1"), in: nil)
        guard case .rule(let descriptor) = standard else { return XCTFail("expected rule, got \(standard)") }
        XCTAssertEqual(descriptor.id, "macho.slice-identity")
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "rule", ref: "macho.slice-identity@2"), in: nil).unresolvableReason, .noSuchRecord)
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "rule", ref: "no.such-rule@1"), in: nil).unresolvableReason, .noSuchRecord)

        let registry = NavigatorPrimitiveRegistry(
            primitives: [.functionStartStructuralProof, .functionStartCallTargetDerivation], catalogues: [])
        let context = NavigatorProvenanceResolver.Context(registry: registry)
        let derived = NavigatorProvenanceResolver.resolve(FunctionStartCallTargetDerivation.ruleProvenance, in: nil,
                                                          context: context)
        guard case .rule(let derivedDescriptor) = derived else { return XCTFail("expected rule, got \(derived)") }
        XCTAssertEqual(derivedDescriptor, .functionStartCallTargetDerivation)
        let proof = NavigatorProvenanceResolver.resolve(FunctionStartStructuralProof.ruleProvenance, in: nil, context: context)
        XCTAssertEqual(proof, .rule(.functionStartStructuralProof))
    }

    func testResolvesCertificatesByHash() throws {
        let certificate = try ResolverFixtures.certificate(outcome: .proven)
        let other = try ResolverFixtures.certificate(outcome: .insufficientEvidence)
        XCTAssertNotEqual(certificate.hash, other.hash)

        var context = NavigatorProvenanceResolver.Context(certificates: [certificate])
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(certificate.reference, in: nil, context: context),
                       .certificate(certificate))
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(other.reference, in: nil, context: context).unresolvableReason,
                       .noSuchRecord)

        // A store that files a certificate under a hash it does not carry is a hash mismatch.
        context.certificates[other.hash] = certificate
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(other.reference, in: nil, context: context).unresolvableReason,
                       .hashMismatch)
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "proofCertificate", ref: "sha256:xyz"), in: nil, context: context).unresolvableReason,
            .noSuchRecord)
    }

    func testResolvesAnnotationsAndExternalRecords() throws {
        let annotation = try NavigatorAnnotation.make(
            session: "session-1", seq: 3, author: "analyst", action: "rename",
            subject: NavigatorSubject(kind: "function", ref: "0x340"), predicate: "hasName", value: .string("loop_zero"))
        let strlen = NavigatorProvenanceResolver.ExternalRecord(description: "strlen signature", bytes: Data("size_t strlen(const char *)".utf8))
        let usr = NavigatorProvenanceResolver.ExternalRecord(description: "Swift.Int", bytes: Data("s:Si".utf8))
        let context = NavigatorProvenanceResolver.Context(
            annotations: [annotation],
            signatureRecord: { corpus, recordID in corpus == "libsystem" && recordID == "strlen" ? strlen : nil },
            symbolGraph: { module, symbol in module == "Swift" && symbol == "s:Si" ? usr : nil })

        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "analystAction", ref: "ann:session-1/3"), in: nil, context: context),
            .annotation(id: annotation.id))
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "analystAction", ref: "ann:session-1/4"), in: nil, context: context).unresolvableReason,
            .noSuchRecord)
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "analystAction", ref: "ann:session-2/3"), in: nil, context: context).unresolvableReason,
            .noSuchRecord)

        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "signatureRecord", ref: "libsystem/strlen"), in: nil, context: context),
            .record(description: "strlen signature", range: nil, sha256: AnalysisFingerprintBuilder.sha256Hex(strlen.bytes)))
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "signatureRecord", ref: "libsystem/memcpy"), in: nil, context: context).unresolvableReason,
            .noSuchRecord)

        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "symbolGraph", ref: "Swift:s:Si"), in: nil, context: context),
            .record(description: "Swift.Int", range: nil, sha256: AnalysisFingerprintBuilder.sha256Hex(usr.bytes)))
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "symbolGraph", ref: "Swift:s:Sd"), in: nil, context: context).unresolvableReason,
            .noSuchRecord)
    }

    func testUnknownKindsAndMissingImage() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let binary = ResolverFixtures.binary(fixture.bytes)
        XCTAssertEqual(ResolverFixtures.reason("loaderRecords", "lc[0]", binary), .unknownKind)
        XCTAssertEqual(ResolverFixtures.reason("LoaderRecord", "lc[0]", binary), .unknownKind)
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "bogus", ref: "x"), in: nil).unresolvableReason, .unknownKind)
        // Image kinds need image evidence.
        XCTAssertEqual(NavigatorProvenanceResolver.resolve(
            NavigatorProvenance(kind: "loaderRecord", ref: "lc[0]"), in: nil).unresolvableReason, .noSuchRecord)
        // Bytes that do not parse as a thin Mach-O slice yield no evidence.
        let garbage = ResolverFixtures.binary(Data(repeating: 0, count: 64))
        XCTAssertNil(NavigatorImageEvidence(binary: garbage))
        XCTAssertEqual(ResolverFixtures.reason("loaderRecord", "lc[0]", garbage), .noSuchRecord)
        XCTAssertTrue(NavigatorProvenanceResolver.resolve(NavigatorProvenance(kind: "loaderRecord", ref: "lc[0]"), in: binary)
            .isResolved)
    }

    func testEvidenceUsesTheSelectedSliceOfAFatFile() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        var fat = Data(repeating: 0xee, count: 4096)
        fat.append(fixture.bytes)
        var binary = ResolverFixtures.binary(fat)
        binary.sliceOffset = 4096
        binary.sliceSize = UInt64(fixture.bytes.count)
        let evidence = try XCTUnwrap(NavigatorImageEvidence(binary: binary))
        XCTAssertEqual(evidence.slice, fixture.bytes)
        let resolved = NavigatorProvenanceResolver.resolve(NavigatorProvenance(kind: "loaderRecord", ref: "lc[1]"), in: binary)
        // Ranges are slice-relative.
        XCTAssertEqual(resolved.range, 184 ..< 200)
        XCTAssertEqual(resolved.sha256, ResolverFixtures.sha256(fixture.bytes, 184 ..< 200))

        binary.sliceSize = UInt64(fixture.bytes.count + 1)
        XCTAssertNil(NavigatorImageEvidence(binary: binary))
    }
}

private enum ResolverFixtures {
    static let unwindImageRef = "9f20e834-0ec1-31f0-aa9c-6153bbab70c6/e4957a86d91eb372"

    static func binary(_ bytes: Data, identity: MachOSliceArtifactIdentity? = nil) -> LoadedBinary {
        LoadedBinary(
            name: "provenance-fixture", path: "/tmp/provenance-fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty,
            artifactIdentity: identity,
            bytes: bytes,
            sliceOffset: 0,
            sliceSize: UInt64(bytes.count),
            sections: [], executableTextSection: nil, entryPointAddress: nil,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [], objcSelectors: [:]
        )
    }

    /// `UnwindLoops.dylib` with the identity its existing oracle test records (no re-hash).
    static func unwindLoops() throws -> LoadedBinary {
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent("UnwindLoops.dylib")
        let bytes = try Data(contentsOf: url)
        let identity = try MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "9f20e834-0ec1-31f0-aa9c-6153bbab70c6"), rawCPUType: 0x0100000c, rawCPUSubtype: 0,
            selectedSliceSHA256: "e4957a86d91eb3722f975b48aee12bace61211e7a737a56a9249dad9b598d8d1",
            selectedSliceByteCount: 17480)
        return binary(bytes, identity: identity)
    }

    static func functionStartsOffset(_ fixture: MachOFixture) -> Int {
        (fixture.codeOffset + fixture.code.count + 7) & ~7
    }

    static func sha256(_ bytes: Data, _ range: Range<Int>) -> String {
        AnalysisFingerprintBuilder.sha256Hex(Data(bytes[(bytes.startIndex + range.lowerBound) ..< (bytes.startIndex + range.upperBound)]))
    }

    static func reason(_ kind: String, _ ref: String, _ binary: LoadedBinary) -> NavigatorProvenanceResolver.Unresolvable? {
        NavigatorProvenanceResolver.resolve(NavigatorProvenance(kind: kind, ref: ref), in: binary).unresolvableReason
    }

    static func certificate(outcome: NavigatorProofCertificate.Outcome) throws -> NavigatorProofCertificate {
        try NavigatorProofCertificate.make(
            rule: FunctionStartStructuralProof.rule, ruleVersion: FunctionStartStructuralProof.ruleVersion,
            subject: NavigatorSubject(kind: "function", ref: "0x340"), predicate: "isFunctionStart", value: .bool(true),
            premises: [NavigatorProvenance(kind: "loaderRecord", ref: "functionStarts[0]@0x340")],
            assumptions: FunctionStartStructuralProof.assumptions, conclusion: "0x340 \(outcome.rawValue)",
            trustedBase: FunctionStartStructuralProof.trustedBase, outcome: outcome,
            budget: .init(wallMs: 0, bytesRead: 2))
    }
}
